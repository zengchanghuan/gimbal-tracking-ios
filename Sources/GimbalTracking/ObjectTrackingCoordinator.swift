import Foundation
import CoreGraphics
import CoreVideo
import CoreImage
import Vision

protocol ObjectTrackingAppearanceFeature {
    var revision: Int { get }
    func distance(to other: ObjectTrackingAppearanceFeature) throws -> Float
}

private struct VisionTrackingAppearanceFeature: ObjectTrackingAppearanceFeature {
    let observation: VNFeaturePrintObservation
    var revision: Int { observation.requestRevision }
    func distance(to other: ObjectTrackingAppearanceFeature) throws -> Float {
        guard let other = other as? VisionTrackingAppearanceFeature else {
            throw NSError(domain: "ObjectTracking.Appearance", code: 1)
        }
        var value: Float = .nan
        try observation.computeDistance(&value, to: other.observation)
        return value
    }
}

struct ObjectTrackingSnapshot {
    let state: ObjectTrackingState
    let sessionID: UUID
    let controlID: UUID
    let frameID: UInt64
    let capturedAt: TimeInterval
    let geometryID: UInt64
    let candidates: [ObjectDetection]
    let candidatesCapturedAt: TimeInterval
    let selectedDetection: ObjectDetection?
    let shouldMove: Bool
    let semanticAt: TimeInterval
    let error: String?
    // Set only while publishing under the admission lock. Optional preserves
    // hand-constructed test snapshots; production transport refuses nil motion.
    var controlLease: ObjectTrackingControlLease? = nil

    /// Immutable authorization survives queues without extending either lease.
    var motionExpiresAt: TimeInterval? {
        guard shouldMove, capturedAt.isFinite, capturedAt > 0,
              semanticAt.isFinite, semanticAt > 0 else { return nil }
        let deadline = min(capturedAt + ObjectTrackingPolicy.positionLifetime,
                           semanticAt + ObjectTrackingPolicy.semanticLifetime)
        return deadline.isFinite ? deadline : nil
    }

    func isMotionValid(at now: TimeInterval) -> Bool {
        guard now.isFinite, now >= capturedAt, now >= semanticAt,
              let deadline = motionExpiresAt else { return false }
        return now <= deadline
    }
}

/// Owns one detector and one Vision tracker on a serial worker. Camera callbacks
/// retain at most one in-flight and one replaceable latest pixel buffer.
/// No BLE or UIKit access occurs here. Callers must independently expire motion.
final class ObjectTrackingCoordinator {
    enum Mode: String {
        case semanticTracking
        /// Visual discovery only. User rectangles belong to the existing
        /// camera tracker, which starts after this coordinator has stopped.
        case discoveryOnly
    }
    typealias DetectorFactory = (ObjectDetectionBackend) throws -> ObjectDetecting
    typealias TrackerPerformer = (VNSequenceRequestHandler, VNTrackObjectRequest, CVPixelBuffer) throws -> Void
    typealias AppearanceProvider = (CVPixelBuffer, CGRect) throws -> ObjectTrackingAppearanceFeature
    typealias MotionExpiryScheduler = (DispatchWorkItem, TimeInterval) -> Void
    private struct Token: Equatable {
        let sessionID: UUID
        let controlID: UUID
    }
    private struct Frame {
        let token: Token
        let id: UInt64
        let pixelBuffer: CVPixelBuffer
        let capturedAt: TimeInterval
        let mediaPTS: Double
        let geometryID: UInt64
        let diagnostics: ObjectTrackingDiagnostics?
    }
    private struct CorrectionCandidate {
        let detection: ObjectDetection
        let frameID: UInt64
        let capturedAt: TimeInterval
    }
    private struct AppearanceTemplate {
        let feature: ObjectTrackingAppearanceFeature
        let selectionID: UUID
        let frameID: UInt64
        let capturedAt: TimeInterval
        let label: String
    }

    // Delivery and admission share one transaction. UI consumers may call back
    // synchronously (stop, recordEvent, expireMotionAuthorization), hence recursive.
    // Never wait synchronously for the worker or pump a nested run loop in onUpdate.
    private let lock = NSRecursiveLock()
    private let worker = DispatchQueue(label: "ObjectTracking.Analysis", qos: .userInitiated)
    private let onUpdate: (ObjectTrackingSnapshot) -> Void
    private let factory: DetectorFactory
    private let mode: Mode
    private let trackerUsesCPUOnly: Bool
    private let trackerRevision: Int
    private let trackerPerformer: TrackerPerformer
    private let appearanceProvider: AppearanceProvider
    private let appearanceProviderKind: String
    private let motionExpiryScheduler: MotionExpiryScheduler
    private let expirySchedulerKind: String
    private let appearanceWarmupEnabled: Bool
    // Main-thread-owned delivery lease, independent of the analysis worker.
    private var deliveryExpiryWorkItem: DispatchWorkItem?
    private var deliveredMotion: (token: Token, frameID: UInt64)?
    private let diagnosticsRootDirectory: URL?
    // Lock-owned admission state; invalidation never waits for the worker.
    private var active = false
    private var controlLease: ObjectTrackingControlLease?
    private var token = Token(sessionID: UUID(), controlID: UUID()) {
        didSet {
            // Every token mutation occurs under `lock`, including stop, loss,
            // geometry and failure. No queued old-control motion may outlive it.
            guard token != oldValue else { return }
            controlLease?.revoke()
            controlLease = ObjectTrackingControlLease(sessionID: token.sessionID, controlID: token.controlID)
        }
    }
    private var geometryID: UInt64?
    private var nextFrameID: UInt64 = 0
    private var admissionStartedAt: TimeInterval = 0
    private var latestFrame: Frame?
    private var drainScheduled = false
    private var latestSnapshot: ObjectTrackingSnapshot?
    private var pendingUISnapshot: ObjectTrackingSnapshot?
    private var uiDeliveryScheduled = false
    private var diagnostics: ObjectTrackingDiagnostics?
    private var diagnosticsBySession: [UUID: ObjectTrackingDiagnostics] = [:]
    private var diagnosticSessionOrder: [UUID] = []
    // Worker-owned state; never accessed by main/capture threads.
    private var workerToken: Token?
    private var detector: ObjectDetecting?
    private var state: ObjectTrackingState = .idle
    private var candidates: [ObjectDetection] = []
    private var candidatesCapturedAt: TimeInterval = 0
    private var selected: ObjectDetection?
    private var confirmationCount = 0
    private var selectionStartedAt: TimeInterval = 0
    private var lostAt: TimeInterval?
    private var lastDetectionAt: TimeInterval = -.infinity
    private var lastSemanticAt: TimeInterval = 0
    private var lastTrackerSeedAt: TimeInterval = -.infinity
    private var pendingCorrection: CorrectionCandidate?
    // This is a stationary hold, bounded by the original semantic deadline.
    private var correctionSuspensionDeadline: TimeInterval?
    private var selectionID = UUID()
    private var appearanceTemplate: AppearanceTemplate?
    private var appearanceDisabled = false
    // Session lifecycle, not selection/control lifecycle: failed warmup must
    // not be retried or re-enable appearance after a tap or geometry reset.
    private var appearanceWarmupAttemptedSession: UUID?
    private var appearanceWarmupFailedSession: UUID?
    private var appearanceWarmupCompletedAt: TimeInterval = 0
    private var appearanceRecoveryCandidate: CorrectionCandidate?
    private var frameAppearanceMs: Double = 0
    private var frameAppearanceWarmupMs: Double?
    private var frameAppearanceOperations: [[String: Any]] = []
    private var consecutiveDetectionErrors = 0
    private var trackingRequest: VNTrackObjectRequest?
    private var sequenceHandler = VNSequenceRequestHandler()

    init(onUpdate: @escaping (ObjectTrackingSnapshot) -> Void,
         detectorFactory: DetectorFactory? = nil,
         trackerUsesCPUOnly: Bool = false, trackerRevision: Int = VNTrackObjectRequestRevision2,
         diagnosticsRootDirectory: URL? = nil,
         trackerPerformer: @escaping TrackerPerformer = { handler, request, buffer in
             try handler.perform([request], on: buffer, orientation: .up)
         }, appearanceProvider: AppearanceProvider? = nil,
         motionExpiryScheduler: MotionExpiryScheduler? = nil,
         appearanceWarmupEnabled: Bool = true, mode: Mode = .semanticTracking) {
        self.onUpdate = onUpdate
        self.mode = mode
        factory = detectorFactory ?? { backend in
            try ObjectDetectorFactory.make(backend: backend,
                labelPolicy: mode == .discoveryOnly ? .allModelLabels : .benchmarkSixClasses)
        }
        self.trackerUsesCPUOnly = trackerUsesCPUOnly
        self.trackerRevision = trackerRevision
        self.trackerPerformer = trackerPerformer
        self.appearanceProvider = appearanceProvider ?? Self.makeAppearanceFeature
        appearanceProviderKind = appearanceProvider == nil ? "vision_feature_print" : "injected_test"
        self.motionExpiryScheduler = motionExpiryScheduler ?? { work, deadline in
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime), execute: work)
        }
        expirySchedulerKind = motionExpiryScheduler == nil ? "dispatch_main" : "injected_test"
        self.appearanceWarmupEnabled = mode == .semanticTracking && appearanceWarmupEnabled
        self.diagnosticsRootDirectory = diagnosticsRootDirectory
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    var exportURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return diagnostics?.exportURL
    }

    var snapshot: ObjectTrackingSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return latestSnapshot
    }

    func start(backend: ObjectDetectionBackend) {
        stop(reason: "restart")
        let newToken = Token(sessionID: UUID(), controlID: UUID())
        let logger = ObjectTrackingDiagnostics(backend: backend, sessionID: newToken.sessionID,
                                              trackerRevision: trackerRevision,
                                              rootDirectory: diagnosticsRootDirectory)
        logger.updateManifest(["trackerUsesCPUOnly": trackerUsesCPUOnly,
                               "trackingStrategy": "confirmed_correction_hold_stable_tracker_auto_feature_v5",
                               "detectorInputPolicy": ObjectDetectionModels.preprocessingDescription(for: backend),
                               "coreMLAllLowConfidenceConfirmationThreshold": ObjectTrackingPolicy.correctionTrackingConfidenceTrigger,
                               "coreMLAllLowConfidenceConfirmationPolicy": "current_source_detector_required_below_existing_correction_trigger; miss_holds; match_requires_two_fresh_sources",
                               "coreMLAllCorrectionConfirmationInterval": ObjectTrackingPolicy.correctionConfirmationInterval,
                               "otherBackendCorrectionConfirmationInterval": ObjectTrackingPolicy.confirmationInterval,
                               "correctionHoldProcessingOrder": "fresh_detector_pair_then_new_seed_no_old_tracker_advance",
                               "correctionMotionPolicy": "suspend_until_two_fresh_confirmations_and_seed_before_original_semantic_deadline",
                               "deliveryMotionExpiryPolicy": "min(position250ms,semantic750ms)",
                               "expirySchedulerKind": expirySchedulerKind,
                               "appearanceWarmupEnabled": appearanceWarmupEnabled,
                               "appearanceWarmupPolicy": "once_per_session_first_searching_frame_full_frame_discard",
                               "appearanceWarmupStatus": appearanceWarmupEnabled ? "pending" : "disabled_test",
                               "appearanceWarmupRevisionRequested": 2,
                               "appearanceWarmupRevisionApplied": NSNull(),
                               "appearanceWarmupFixedCrop": [0, 0, 1, 1],
                               "appearanceWarmupResultUse": "discard_only_runtime_initialization",
                               "appearanceWarmupNextSourcePolicy": "captured_after_warmup_completion",
                               "semanticRefreshLeadTimeSeconds": ObjectTrackingPolicy.semanticRefreshLeadTime,
                               "correctionMinimumIntervalSeconds": ObjectTrackingPolicy.correctionMinimumInterval,
                               "correctionMaximumIntervalSeconds": ObjectTrackingPolicy.correctionMaximumInterval,
                               "coreMLAllPeriodicReseedingEnabled": false,
                               "coreMLAllStableTrackerPolicy": "unique_same_source_detector_iou_at_least_0.85_and_tracker_confidence_at_least_0.75_keeps_tracker",
                               "correctionConfirmationsRequired": 2,
                               "correctionConfirmationLifetimeSeconds": ObjectTrackingPolicy.correctionConfirmationLifetime,
                               "correctionConfirmationMinimumIoU": Double(ObjectTrackingPolicy.correctionConfirmationMinimumIoU),
                               "appearanceFeatureRevisionRequested": 2,
                               "appearanceFeatureRevisionApplied": NSNull(),
                               "appearanceDistanceThreshold": ObjectTrackingPolicy.appearanceDistanceThreshold,
                               "appearanceRecoveryWindowSeconds": ObjectTrackingPolicy.appearanceRecoveryWindow,
                               "appearanceFeatureCrop": "sRGB; normalized lower-left; floor-min/ceil-max top-left; scaleFill",
                               "appearanceProviderKind": appearanceProviderKind,
                               "appearanceComputePolicy": appearanceProviderKind == "injected_test" ? "injected_test"
                                   : (backend == .coreMLAll ? "system_automatic" : "cpu_only"),
                               "appearanceActualComputeDevice": "not_observed"])
        if mode == .discoveryOnly {
            logger.updateManifest([
                "trackingStrategy": "discovery_prompt_then_existing_manual_rectangle_tracker",
                "coordinatorMode": mode.rawValue,
                "detectionLabelPolicy": ObjectDetectionLabelPolicy.allModelLabels.rawValue,
                "trackingSelectionEnabled": false,
                "motionAuthorizationEnabled": false,
                "appearanceWarmupStatus": "disabled_discovery_only"
            ])
        }
        lock.lock()
        active = true
        token = newToken
        geometryID = nil
        nextFrameID = 0
        admissionStartedAt = ProcessInfo.processInfo.systemUptime
        latestFrame = nil
        diagnostics = logger
        diagnosticsBySession[newToken.sessionID] = logger
        diagnosticSessionOrder.append(newToken.sessionID)
        // Keep recent stopped sessions available for delayed BLE acknowledgments.
        if diagnosticSessionOrder.count > 8 {
            diagnosticsBySession.removeValue(forKey: diagnosticSessionOrder.removeFirst())
        }
        lock.unlock()
        logger.recordEvent("start", details: ["backend": backend.rawValue])
        publish(emptySnapshot(state: .loading, token: newToken))
        worker.async { [weak self] in
            guard let self, self.isSessionCurrent(newToken.sessionID) else { return }
            self.resetWorker(token: newToken, state: .loading)
            self.detector = nil
            let loadStartedAt = ProcessInfo.processInfo.systemUptime
            do {
                let loaded = try self.factory(backend)
                guard let current = self.currentToken(for: newToken.sessionID) else { return }
                self.detector = loaded
                self.workerToken = current
                self.state = .searching
                logger.updateManifest(["modelIdentifier": loaded.modelIdentifier,
                                       "modelLoadMs": (ProcessInfo.processInfo.systemUptime - loadStartedAt) * 1000])
                logger.recordEvent("model_ready", details: ["model": loaded.modelIdentifier])
                self.publish(self.emptySnapshot(state: .searching, token: current))
            } catch {
                self.failSession(newToken.sessionID, message: error.localizedDescription)
            }
        }
    }

    /// Immediately invalidates callbacks/motion authorization. In-flight Vision
    /// can finish, but its result can no longer publish or touch the next target.
    func stop(reason: String = "user") {
        lock.lock()
        let wasActive = active
        let previousSession = token.sessionID
        token = Token(sessionID: previousSession, controlID: UUID())
        let stoppedToken = token
        active = false
        admissionStartedAt = ProcessInfo.processInfo.systemUptime
        latestFrame = nil
        let logger = diagnostics
        lock.unlock()
        if wasActive {
            logger?.recordEvent("stop", details: ["reason": reason])
            publish(emptySnapshot(state: .idle, token: stoppedToken))
            logger?.finish(reason: reason)
        }
        worker.async { [weak self] in
            guard let self, self.workerToken?.sessionID == previousSession else { return }
            self.resetWorker(token: nil, state: .idle)
            self.detector = nil
        }
    }

    /// Used by the independent main-thread watchdog and camera lifecycle owner.
    /// This is intentionally conservative: a timeout requires a new selection.
    func invalidateControl(reason: String) {
        _ = invalidateControl(reason: reason, expected: nil)
    }

    /// UI/watchdog consumers share the exact token-checked cutoff decision.
    /// They must not hold the old BLE token before discovering a newer frame.
    func expireMotionAuthorization(_ snapshot: ObjectTrackingSnapshot, boundary: String) {
        precondition(Thread.isMainThread)
        let now = ProcessInfo.processInfo.systemUptime
        guard snapshot.shouldMove, !snapshot.isMotionValid(at: now) else { return }
        rejectExpiredMotion(snapshot, event: "motion_rejected_at_consumer", now: now, boundary: boundary)
    }

    @discardableResult
    private func invalidateControl(reason: String, expected: Token?, sourceFrameID: UInt64? = nil,
                                   beforePublish: (() -> Void)? = nil) -> Bool {
        lock.lock()
        guard active, expected == nil || token == expected,
              sourceFrameID == nil || latestSnapshot?.frameID == sourceFrameID else { lock.unlock(); return false }
        token = Token(sessionID: token.sessionID, controlID: UUID())
        let newToken = token
        admissionStartedAt = ProcessInfo.processInfo.systemUptime
        latestFrame = nil
        let logger = diagnostics
        lock.unlock()
        beforePublish?()
        logger?.recordEvent("control_invalidated", details: ["reason": reason, "controlID": newToken.controlID.uuidString])
        publish(emptySnapshot(state: .searching, token: newToken))
        worker.async { [weak self] in
            guard let self, self.isCurrent(newToken) else { return }
            self.resetWorker(token: newToken, state: .searching)
        }
        return true
    }

    /// Input is in actual pixel-buffer orientation, normalized with bottom-left
    /// origin. The UI must convert from the preview, including crop/mirror.
    @discardableResult
    func selectNormalizedPoint(_ point: CGPoint) -> Bool {
        guard mode == .semanticTracking else {
            recordEvent("selection_rejected", details: ["reason": "discovery_requires_manual_rectangle_handoff"])
            return false
        }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard active, let previous = latestSnapshot,
              ObjectTrackingPolicy.isFresh(previous.candidatesCapturedAt, now: now,
                                           lifetime: ObjectTrackingPolicy.selectionLifetime),
              let chosen = ObjectTrackingPolicy.candidate(at: point, in: previous.candidates) else {
            let logger = diagnostics
            lock.unlock()
            logger?.recordEvent("selection_rejected", details: ["reason": "missing_ambiguous_or_stale_candidate"])
            return false
        }
        token = Token(sessionID: token.sessionID, controlID: UUID())
        let newToken = token
        admissionStartedAt = now
        latestFrame = nil
        let logger = diagnostics
        lock.unlock()
        logger?.recordEvent("selected", details: ["label": chosen.label, "controlID": newToken.controlID.uuidString,
                                                  "sourceFrameID": String(previous.frameID)])
        publish(ObjectTrackingSnapshot(state: .confirming, sessionID: newToken.sessionID,
                                       controlID: newToken.controlID, frameID: previous.frameID,
                                       capturedAt: previous.capturedAt, geometryID: previous.geometryID,
                                       candidates: previous.candidates, candidatesCapturedAt: previous.candidatesCapturedAt,
                                       selectedDetection: chosen, shouldMove: false, semanticAt: 0, error: nil))
        worker.async { [weak self] in
            guard let self, self.isCurrent(newToken) else { return }
            self.resetWorker(token: newToken, state: .confirming)
            self.selected = chosen
            self.selectionStartedAt = now
            self.candidates = previous.candidates
            self.candidatesCapturedAt = previous.candidatesCapturedAt
        }
        return true
    }

    @discardableResult
    func submit(pixelBuffer: CVPixelBuffer, capturedAt: TimeInterval,
                mediaPTS: Double, geometryID incomingGeometry: UInt64) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard ObjectTrackingPolicy.isFresh(capturedAt, now: now), mediaPTS.isFinite else {
            withDiagnostics { $0.recordDrop("invalid_or_expired_capture_time") }
            return false
        }
        lock.lock()
        guard active else { lock.unlock(); return false }
        guard capturedAt >= admissionStartedAt else {
            let logger = diagnostics
            lock.unlock()
            logger?.recordDrop("captured_before_control_generation")
            return false
        }
        var geometryReset: Token?
        if let previousGeometry = geometryID, previousGeometry != incomingGeometry {
            token = Token(sessionID: token.sessionID, controlID: UUID())
            geometryReset = token
            latestFrame = nil
        }
        geometryID = incomingGeometry
        nextFrameID &+= 1
        let frame = Frame(token: token, id: nextFrameID, pixelBuffer: pixelBuffer,
                          capturedAt: capturedAt, mediaPTS: mediaPTS, geometryID: incomingGeometry,
                          diagnostics: diagnostics)
        let replacedID = latestFrame?.id
        latestFrame = frame
        let shouldSchedule = !drainScheduled
        if shouldSchedule { drainScheduled = true }
        lock.unlock()
        if let replacedID { frame.diagnostics?.recordDrop("latest_frame_replaced", frameID: replacedID) }
        if let resetToken = geometryReset {
            frame.diagnostics?.recordEvent("geometry_changed", details: ["geometryID": String(incomingGeometry)])
            publish(emptySnapshot(state: .paused, token: resetToken, geometry: incomingGeometry))
            worker.async { [weak self] in
                guard let self, self.isCurrent(resetToken) else { return }
                self.resetWorker(token: resetToken, state: .searching)
            }
        }
        if shouldSchedule { worker.async { [weak self] in self?.drainOneFrame() } }
        return true
    }

    func recordEvent(_ name: String, details: [String: String] = [:]) {
        lock.lock()
        let logger: ObjectTrackingDiagnostics?
        if let session = details["sessionID"] {
            // Unknown/evicted sessions are dropped, never attributed to a new run.
            logger = UUID(uuidString: session).flatMap { diagnosticsBySession[$0] }
        } else {
            logger = diagnostics
        }
        lock.unlock()
        logger?.recordEvent(name, details: details)
    }

    /// Captures the current run while holding the same lock as session changes;
    /// callers may supply immutable JSON values from main or capture queues.
    func recordConfiguration(_ fields: [String: Any]) {
        lock.lock()
        let logger = diagnostics
        lock.unlock()
        logger?.updateManifest(fields)
    }

    func prepareExport(completion: @escaping (URL?) -> Void) {
        lock.lock(); let logger = diagnostics; lock.unlock()
        guard let logger else { DispatchQueue.main.async { completion(nil) }; return }
        logger.flush(completion: completion)
    }

    private func drainOneFrame() {
        lock.lock()
        let frame = latestFrame
        latestFrame = nil
        lock.unlock()
        if let frame, isCurrent(frame.token) {
            autoreleasepool { process(frame) }
        }
        // Yield between frames so select/stop/lifecycle work cannot starve.
        lock.lock()
        let hasNext = latestFrame != nil && active
        drainScheduled = hasNext
        lock.unlock()
        if hasNext { worker.async { [weak self] in self?.drainOneFrame() } }
    }

    private func process(_ frame: Frame) {
        guard workerToken == frame.token, isCurrent(frame.token), let detector else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        frameAppearanceMs = 0
        frameAppearanceWarmupMs = nil
        frameAppearanceOperations = []
        guard ObjectTrackingPolicy.isFresh(frame.capturedAt, now: startedAt) else {
            clearPendingCorrection(frame, reason: "source_frame_expired")
            clearAppearanceConfirmation(frame, reason: "source_frame_expired")
            frame.diagnostics?.recordDrop("expired_before_analysis", frameID: frame.id)
            return
        }
        var detectorRan = false
        var trackerRan = false
        var detectorMs: Double?
        var trackerMs: Double?
        var trackerCorrectionMs: Double?
        var trackerObservation: VNDetectedObjectObservation?
        var trackerPhase: String?
        var trackerFailureReason: String?
        var movementPublished = false
        var lowConfidenceRequiresDetection = false
        let trackerAdvanceSkippedForCorrectionHold = state == .tracking && correctionSuspensionDeadline != nil
        defer {
            let endedAt = ProcessInfo.processInfo.systemUptime
            var row: [String: Any] = [
                "frameID": frame.id, "sessionID": frame.token.sessionID.uuidString,
                "sourceControlID": frame.token.controlID.uuidString,
                "controlID": workerToken?.controlID.uuidString ?? "invalidated",
                "geometryID": frame.geometryID, "capturedAt": frame.capturedAt, "mediaPTS": frame.mediaPTS,
                "analysisStart": startedAt, "analysisEnd": endedAt,
                "queueWaitMs": (startedAt - frame.capturedAt) * 1000,
                "captureToAnalysisEndMs": (endedAt - frame.capturedAt) * 1000,
                "detectorRan": detectorRan, "trackerRan": trackerRan,
                "shouldMove": movementPublished, "state": state.rawValue,
                "shouldMoveAtAnalysisPublication": movementPublished,
                "backend": detector.backend.rawValue,
                "candidates": candidates.map(Self.detectionJSON)
            ]
            if let selected { row["selected"] = Self.detectionJSON(selected) }
            if let detectorMs { row["detectorMs"] = detectorMs }
            if let trackerMs { row["trackerMs"] = trackerMs }
            if let trackerCorrectionMs { row["trackerCorrectionMs"] = trackerCorrectionMs }
            row["semanticAgeMs"] = lastSemanticAt > 0 ? (endedAt - lastSemanticAt) * 1000 as Any : NSNull()
            row["semanticAt"] = lastSemanticAt > 0 ? lastSemanticAt as Any : NSNull()
            row["motionExpiresAt"] = movementPublished
                ? min(frame.capturedAt + ObjectTrackingPolicy.positionLifetime,
                      lastSemanticAt + ObjectTrackingPolicy.semanticLifetime) as Any : NSNull()
            row["trackerAdvanceSkippedForCorrectionHold"] = trackerAdvanceSkippedForCorrectionHold
            row["trackerRequiresSemanticConfirmation"] = lowConfidenceRequiresDetection
            row["correctionPending"] = pendingCorrection != nil
            row["correctionMotionSuspended"] = correctionSuspensionDeadline != nil
            row["correctionMotionDeadline"] = correctionSuspensionDeadline.map { $0 as Any } ?? NSNull()
            row["appearanceMs"] = frameAppearanceMs
            row["appearanceWarmupRan"] = frameAppearanceWarmupMs != nil
            if let frameAppearanceWarmupMs { row["appearanceWarmupMs"] = frameAppearanceWarmupMs }
            row["appearanceOperations"] = frameAppearanceOperations
            row["appearanceRecoveryWindowSeconds"] = recoveryWindow
            row["hasAppearanceTemplate"] = hasAppearanceTemplate
            if trackerRan {
                row["trackerPhase"] = trackerPhase ?? "unknown"
                row["trackerObservationMissing"] = trackerObservation == nil
                if let observation = trackerObservation {
                    row["trackerObservationConfidence"] = observation.confidence.isFinite
                        ? observation.confidence as Any : NSNull()
                    row["trackerObservationConfidenceFinite"] = observation.confidence.isFinite
                    let box = observation.boundingBox
                    row["trackerObservationBoundingBox"] = [box.origin.x, box.origin.y, box.width, box.height].map {
                        $0.isFinite ? Double($0) as Any : NSNull()
                    }
                }
                if let trackerFailureReason { row["trackerFailureReason"] = trackerFailureReason }
            }
            frame.diagnostics?.recordFrame(row)
        }

        if state == .temporarilyLost, let lostAt, startedAt - lostAt > recoveryWindow {
            returnToSearching(frame, reason: "recovery_window_expired")
            return
        }
        if state == .confirming, startedAt - selectionStartedAt > ObjectTrackingPolicy.selectionLifetime {
            returnToSearching(frame, reason: "selection_confirmation_expired")
            return
        }
        if warmAppearanceRuntimeIfNeeded(frame) { return }
        // A buffer queued during initialization is not a post-warmup source,
        // even if it is still within the ordinary position lifetime.
        if appearanceWarmupEnabled, frame.capturedAt <= appearanceWarmupCompletedAt {
            frame.diagnostics?.recordDrop("captured_before_warmup_completed", frameID: frame.id)
            return
        }

        var trackingConfidence: Float = 0
        // Once motion is suspended for a measured discrepancy, advancing the
        // old tracker cannot authorize movement. Let the next newly captured
        // detector frame confirm the fixed pair before a fresh tracker seed;
        // a failing old tracker must not preempt that identity confirmation.
        if state == .tracking, correctionSuspensionDeadline == nil {
            let trackerStarted = ProcessInfo.processInfo.systemUptime
            trackerPhase = "advance"
            do {
                let observation = try advanceTracker(frame.pixelBuffer)
                trackerObservation = observation
                trackerRan = true
                trackerMs = (ProcessInfo.processInfo.systemUptime - trackerStarted) * 1000
                guard isCurrent(frame.token) else { return }
                guard let observation,
                      observation.confidence >= ObjectTrackingPolicy.minimumTrackingConfidence,
                      let box = ObjectTrackingPolicy.validBoundingBox(observation.boundingBox),
                      let previous = selected else {
                    if let observation {
                        if !observation.confidence.isFinite { trackerFailureReason = "nonfinite_confidence" }
                        else if observation.confidence < ObjectTrackingPolicy.minimumTrackingConfidence { trackerFailureReason = "low_confidence" }
                        else if ObjectTrackingPolicy.validBoundingBox(observation.boundingBox) == nil { trackerFailureReason = "invalid_bounding_box" }
                        else { trackerFailureReason = "missing_selected_detection" }
                    } else { trackerFailureReason = "missing_observation" }
                    enterLost(frame, reason: "tracker_unreliable")
                    return
                }
                trackingConfidence = observation.confidence
                lowConfidenceRequiresDetection = detector.backend == .coreMLAll && ObjectTrackingPolicy.requiresDetectorConfirmation(
                    trackingConfidence: trackingConfidence)
                selected = ObjectDetection(label: previous.label, confidence: previous.confidence, boundingBox: box)
            } catch {
                trackerRan = true
                trackerFailureReason = "perform_error"
                trackerMs = (ProcessInfo.processInfo.systemUptime - trackerStarted) * 1000
                guard isCurrent(frame.token) else { return }
                frame.diagnostics?.recordEvent("tracker_error", details: ["message": error.localizedDescription])
                enterLost(frame, reason: "tracker_error")
                return
            }
        }

        if lowConfidenceRequiresDetection || ObjectTrackingPolicy.detectionIsDue(state: state, lastDetectionAt: lastDetectionAt,
                                               capturedAt: frame.capturedAt, semanticAt: lastSemanticAt,
                                               hasPendingCorrection: pendingCorrection != nil, backend: detector.backend) {
            lastDetectionAt = frame.capturedAt
            let detectorStarted = ProcessInfo.processInfo.systemUptime
            detectorRan = true
            do {
                let detections = try detector.detect(pixelBuffer: frame.pixelBuffer,
                                                     timestampMilliseconds: Int(frame.capturedAt * 1000))
                detectorMs = (ProcessInfo.processInfo.systemUptime - detectorStarted) * 1000
                guard isCurrent(frame.token) else { return }
                consecutiveDetectionErrors = 0
                let completedAt = ProcessInfo.processInfo.systemUptime
                guard ObjectTrackingPolicy.isFresh(frame.capturedAt, now: completedAt) else {
                    clearPendingCorrection(frame, reason: "detector_result_expired")
                    clearAppearanceConfirmation(frame, reason: "detector_result_expired")
                    frame.diagnostics?.recordDrop("expired_detector_result", frameID: frame.id)
                    if state == .tracking { enterLost(frame, reason: "expired_detector_result") }
                    else { _ = emit(frame, shouldMove: false) }
                    return
                }
                if mode == .discoveryOnly {
                    // A tracking-size cutoff must not hide a small discovery.
                    // These boxes are hints, never tracker seeds or motion.
                    let normalized = detections.compactMap { detection -> ObjectDetection? in
                        guard let box = ObjectDetectionDefaults.normalizedBox(detection.boundingBox) else { return nil }
                        return ObjectDetection(label: detection.label, confidence: detection.confidence, boundingBox: box)
                    }
                    candidates = ObjectDetectionDefaults.filtered(normalized, labelPolicy: .allModelLabels)
                } else {
                    candidates = ObjectTrackingPolicy.reliable(detections)
                }
                candidatesCapturedAt = frame.capturedAt
                if state == .confirming || state == .temporarilyLost {
                    var confirmedMatch: ObjectDetection?
                    if hasAppearanceTemplate {
                        // The fixed template is mandatory after cold-template retry
                        // as well as throughout appearance-assisted recovery. Neither
                        // a matching class nor an old geometric overlap bypasses it.
                        confirmedMatch = appearanceConfirmationMatch(frame)
                        guard isCurrent(frame.token), state == .confirming || state == .temporarilyLost else { return }
                    } else {
                        guard let reference = selected else { returnToSearching(frame, reason: "missing_selection"); return }
                        if candidates.contains(where: { $0.label != reference.label
                            && ObjectTrackingPolicy.intersectionOverUnion($0.boundingBox, reference.boundingBox) > 0.50 }) {
                            confirmationCount = 0
                        } else {
                            switch ObjectTrackingPolicy.associate(reference, with: candidates) {
                            case .ambiguous:
                                returnToSearching(frame, reason: "ambiguous_identity")
                                return
                            case .missing:
                                confirmationCount = 0
                            case .unique(let match):
                                selected = match
                                confirmationCount += 1
                                if confirmationCount >= ObjectTrackingPolicy.confirmationsRequired { confirmedMatch = match }
                            }
                        }
                    }
                    if let match = confirmedMatch {
                        guard prepareInitialAppearanceTemplate(match, frame: frame), isCurrent(frame.token) else { return }
                        let seedStarted = ProcessInfo.processInfo.systemUptime
                        trackerPhase = "seed"
                        do {
                            let result = try seedTracker(match, on: frame.pixelBuffer, diagnostics: frame.diagnostics)
                            trackerObservation = result
                            trackerRan = true
                            trackerMs = (ProcessInfo.processInfo.systemUptime - seedStarted) * 1000
                            guard isCurrent(frame.token) else { return }
                            let seedCompletedAt = ProcessInfo.processInfo.systemUptime
                            if state == .confirming,
                               seedCompletedAt - selectionStartedAt > ObjectTrackingPolicy.selectionLifetime {
                                returnToSearching(frame, reason: "selection_confirmation_expired")
                                return
                            }
                            if state == .temporarilyLost, let lostAt,
                               seedCompletedAt - lostAt > recoveryWindow {
                                returnToSearching(frame, reason: "recovery_window_expired")
                                return
                            }
                            guard let result, result.confidence >= ObjectTrackingPolicy.minimumTrackingConfidence,
                                  let box = ObjectTrackingPolicy.validBoundingBox(result.boundingBox),
                                  ObjectTrackingPolicy.isFresh(frame.capturedAt, now: seedCompletedAt) else {
                                if let result {
                                    if !result.confidence.isFinite { trackerFailureReason = "nonfinite_confidence" }
                                    else if result.confidence < ObjectTrackingPolicy.minimumTrackingConfidence { trackerFailureReason = "low_confidence" }
                                    else if ObjectTrackingPolicy.validBoundingBox(result.boundingBox) == nil { trackerFailureReason = "invalid_bounding_box" }
                                    else { trackerFailureReason = "source_frame_expired" }
                                } else { trackerFailureReason = "missing_observation" }
                                if trackerFailureReason == "source_frame_expired" {
                                    // The model may have initialized successfully but too
                                    // late. Preserve only the bounded user selection,
                                    // never this tracker or its motion authorization.
                                    retryConfirmationWithFreshFrames(frame, reason: "source_frame_expired")
                                } else {
                                    returnToSearching(frame, reason: "tracker_seed_unreliable")
                                }
                                return
                            }
                            guard rotateWorkerControl() else { return }
                            state = .tracking
                            lostAt = nil
                            selected = ObjectDetection(label: match.label, confidence: match.confidence, boundingBox: box)
                            trackingConfidence = result.confidence
                            lastTrackerSeedAt = frame.capturedAt
                            lastSemanticAt = frame.capturedAt
                            appearanceRecoveryCandidate = nil
                            frame.diagnostics?.recordEvent("target_confirmed", details: ["label": match.label,
                                "controlID": workerToken!.controlID.uuidString, "frameID": String(frame.id),
                                "selectionID": selectionID.uuidString, "hasAppearanceTemplate": String(hasAppearanceTemplate)])
                        } catch {
                            trackerRan = true
                            trackerMs = (ProcessInfo.processInfo.systemUptime - seedStarted) * 1000
                            trackerFailureReason = "perform_error"
                            frame.diagnostics?.recordEvent("tracker_seed_error", details: ["message": error.localizedDescription])
                            returnToSearching(frame, reason: "tracker_seed_error")
                            return
                        }
                    }
                } else if state == .tracking, let reference = selected {
                    // Conflicting classes remain a hold even when another
                    // same-class candidate would otherwise be uniquely matched.
                    let conflict = candidates.contains {
                        $0.label != reference.label && ObjectTrackingPolicy.intersectionOverUnion($0.boundingBox, reference.boundingBox) > 0.50
                    }
                    if conflict { enterLost(frame, reason: "class_conflict"); return }
                    switch ObjectTrackingPolicy.associate(reference, with: candidates) {
                    case .ambiguous:
                        enterLost(frame, reason: "ambiguous_identity")
                        return
                    case .unique(let match):
                        guard ObjectTrackingPolicy.intersectionOverUnion(reference.boundingBox, match.boundingBox) >= 0.35 else {
                            enterLost(frame, reason: "detector_tracker_disagreement")
                            return
                        }
                        let needsCorrection = ObjectTrackingPolicy.correctionIsNeeded(reference, with: match,
                                                                                     trackingConfidence: trackingConfidence,
                                                                                     lastSeedAt: lastTrackerSeedAt,
                                                                                     capturedAt: frame.capturedAt,
                                                                                     backend: detector.backend)
                        if needsCorrection || pendingCorrection != nil {
                            let correctionFirstFrameID = pendingCorrection?.frameID
                            let correctionFirstCapturedAt = pendingCorrection?.capturedAt
                            guard confirmCorrection(match, candidates: candidates, frame: frame,
                                                    needsCorrection: needsCorrection) else {
                                // Pending evidence keeps motion suspended. It cannot
                                // change the target position, semantic timestamp or
                                // seed time until both fresh sources are confirmed.
                                if state != .tracking { return }
                                break
                            }
                            let correctionStarted = ProcessInfo.processInfo.systemUptime
                            if let deadline = correctionSuspensionDeadline, correctionStarted > deadline {
                                enterLost(frame, reason: "correction_semantic_deadline")
                                return
                            }
                            frame.diagnostics?.recordEvent("tracker_correction_attempt", details: [
                                "frameID": String(frame.id), "label": match.label,
                                "detectorTrackerIoU": String(Double(ObjectTrackingPolicy.intersectionOverUnion(reference.boundingBox, match.boundingBox))),
                                "previousTrackingConfidence": String(trackingConfidence)])
                            trackerPhase = "correction"
                            trackerRan = true
                            // If correction throws, the preceding advance result
                            // must not appear as a successful correction result.
                            trackerObservation = nil
                            // Keep this measured candidate as the recovery reference if
                            // initialization fails. It cannot authorize movement alone.
                            selected = match
                            do {
                                let result = try seedTracker(match, on: frame.pixelBuffer, diagnostics: frame.diagnostics)
                                trackerCorrectionMs = (ProcessInfo.processInfo.systemUptime - correctionStarted) * 1000
                                trackerMs = (trackerMs ?? 0) + (trackerCorrectionMs ?? 0)
                                trackerObservation = result
                                guard isCurrent(frame.token) else { return }
                                let correctionCompletedAt = ProcessInfo.processInfo.systemUptime
                                guard let result, result.confidence.isFinite,
                                      result.confidence >= ObjectTrackingPolicy.minimumTrackingConfidence,
                                      let correctedBox = ObjectTrackingPolicy.validBoundingBox(result.boundingBox),
                                      ObjectTrackingPolicy.isFresh(frame.capturedAt, now: correctionCompletedAt) else {
                                    trackerFailureReason = ObjectTrackingPolicy.isFresh(frame.capturedAt, now: correctionCompletedAt)
                                        ? "correction_unreliable" : "source_frame_expired"
                                    frame.diagnostics?.recordEvent("tracker_correction_rejected", details: [
                                        "frameID": String(frame.id), "reason": trackerFailureReason!,
                                        "sourceAgeMs": String((correctionCompletedAt - frame.capturedAt) * 1000)])
                                    enterLost(frame, reason: "tracker_correction_rejected")
                                    return
                                }
                                if let deadline = correctionSuspensionDeadline, correctionCompletedAt > deadline {
                                    enterLost(frame, reason: "correction_semantic_deadline")
                                    return
                                }
                                // A hold token is never reused for motion. Only this
                                // second, fresh source can start the new generation.
                                if let deadline = correctionSuspensionDeadline {
                                    let heldControlID = workerToken!.controlID.uuidString
                                    guard rotateWorkerControl() else { return }
                                    correctionSuspensionDeadline = nil
                                    frame.diagnostics?.recordEvent("correction_motion_resumed", details: [
                                        "controlID": workerToken!.controlID.uuidString,
                                        "resumedControlID": workerToken!.controlID.uuidString,
                                        "heldControlID": heldControlID,
                                        "selectionID": selectionID.uuidString, "frameID": String(frame.id),
                                        "firstFrameID": correctionFirstFrameID.map { String($0) } ?? "missing",
                                        "firstCapturedAt": correctionFirstCapturedAt.map { String($0) } ?? "missing",
                                        "secondFrameID": String(frame.id), "capturedAt": String(frame.capturedAt),
                                        "originalSemanticDeadline": String(deadline),
                                        "seedCompletedAt": String(correctionCompletedAt),
                                        "sourceAgeMs": String((correctionCompletedAt-frame.capturedAt)*1000)])
                                }
                                selected = ObjectDetection(label: match.label, confidence: match.confidence,
                                                           boundingBox: correctedBox)
                                trackingConfidence = result.confidence
                                lastSemanticAt = frame.capturedAt
                                lastTrackerSeedAt = frame.capturedAt
                                frame.diagnostics?.recordEvent("tracker_correction_applied", details: [
                                    "frameID": String(frame.id), "label": match.label,
                                    "sourceAgeMs": String((correctionCompletedAt - frame.capturedAt) * 1000),
                                    "correctionMs": String(trackerCorrectionMs ?? 0)])
                            } catch {
                                trackerCorrectionMs = (ProcessInfo.processInfo.systemUptime - correctionStarted) * 1000
                                trackerMs = (trackerMs ?? 0) + (trackerCorrectionMs ?? 0)
                                trackerFailureReason = "perform_error"
                                guard isCurrent(frame.token) else { return }
                                frame.diagnostics?.recordEvent("tracker_correction_rejected", details: [
                                    "frameID": String(frame.id), "reason": "perform_error",
                                    "message": error.localizedDescription])
                                enterLost(frame, reason: "tracker_correction_error")
                                return
                            }
                        } else {
                            lastSemanticAt = frame.capturedAt
                            selected = ObjectDetection(label: match.label, confidence: match.confidence, boundingBox: reference.boundingBox)
                        }
                    case .missing:
                        clearPendingCorrection(frame, reason: "detector_miss")
                        if lowConfidenceRequiresDetection {
                            // Old semantics cannot authorize a weakening tracker
                            // when this same source supplies no matching detection.
                            enterLost(frame, reason: "low_confidence_detector_miss")
                            return
                        }
                        // A reliable tracker's miss keeps only its original lease.
                    }
                }
            } catch {
                detectorMs = (ProcessInfo.processInfo.systemUptime - detectorStarted) * 1000
                guard isCurrent(frame.token) else { return }
                clearPendingCorrection(frame, reason: "detector_error")
                clearAppearanceConfirmation(frame, reason: "detector_error")
                consecutiveDetectionErrors += 1
                frame.diagnostics?.recordEvent("detector_error", details: ["message": error.localizedDescription])
                if consecutiveDetectionErrors >= 3 {
                    failSession(frame.token.sessionID, message: error.localizedDescription)
                } else if state == .tracking {
                    enterLost(frame, reason: "detector_error")
                } else {
                    // Snapshot.error is fatal to the UI owner. Transient
                    // errors stay in diagnostics until the bounded retry fails.
                    _ = emit(frame, shouldMove: false)
                }
                return
            }
        }

        let now = ProcessInfo.processInfo.systemUptime
        if state == .tracking {
            if let deadline = correctionSuspensionDeadline {
                // No tracker confidence or historical position is authorized
                // in this branch. The original semantic deadline still bounds
                // the stationary pair, including cadence-limited source frames.
                guard ObjectTrackingPolicy.isFresh(frame.capturedAt, now: now), now <= deadline else {
                    enterLost(frame, reason: "position_or_semantics_expired")
                    return
                }
                guard pendingCorrection != nil else {
                    enterLost(frame, reason: "correction_identity_unconfirmed")
                    return
                }
                _ = emit(frame, shouldMove: false)
                return
            }
            guard ObjectTrackingPolicy.mayMove(positionAt: frame.capturedAt, semanticAt: lastSemanticAt,
                                                now: now, trackingConfidence: trackingConfidence) else {
                enterLost(frame, reason: "position_or_semantics_expired")
                return
            }
            movementPublished = emit(frame, shouldMove: true)
        } else {
            _ = emit(frame, shouldMove: false)
        }
    }

    /// A candidate is identity history only: the first observation was fresh
    /// when recorded; the second must be a later fresh source frame within the
    /// bounded pair interval. Only the second frame may seed/publish a position.
    private func confirmCorrection(_ match: ObjectDetection, candidates: [ObjectDetection],
                                   frame: Frame, needsCorrection: Bool) -> Bool {
        guard ObjectTrackingPolicy.isFresh(frame.capturedAt, now: ProcessInfo.processInfo.systemUptime) else {
            enterLost(frame, reason: "correction_candidate_expired")
            return false
        }
        if let previous = pendingCorrection {
            guard frame.id != previous.frameID, frame.capturedAt > previous.capturedAt else {
                clearPendingCorrection(frame, reason: "non_increasing_source_frame")
                return false
            }
            if frame.capturedAt - previous.capturedAt > ObjectTrackingPolicy.correctionConfirmationLifetime {
                clearPendingCorrection(frame, reason: "confirmation_pair_expired")
            } else {
                switch ObjectTrackingPolicy.associate(previous.detection, with: candidates) {
                case .ambiguous:
                    enterLost(frame, reason: "ambiguous_correction_identity")
                    return false
                case .missing:
                    clearPendingCorrection(frame, reason: "correction_candidate_changed")
                case .unique(let previousMatch):
                    guard previousMatch.label == match.label, previousMatch.boundingBox == match.boundingBox else {
                        enterLost(frame, reason: "inconsistent_correction_identity")
                        return false
                    }
                    if ObjectTrackingPolicy.intersectionOverUnion(previous.detection.boundingBox, match.boundingBox)
                        >= ObjectTrackingPolicy.correctionConfirmationMinimumIoU {
                        if ObjectTrackingPolicy.correctionSeedIsDue(lastSeedAt: lastTrackerSeedAt,
                                                                  capturedAt: frame.capturedAt) {
                            frame.diagnostics?.recordEvent("tracker_correction_confirmed", details: [
                                "firstFrameID": String(previous.frameID), "secondFrameID": String(frame.id),
                                "sourceIntervalMs": String((frame.capturedAt - previous.capturedAt) * 1000)])
                            pendingCorrection = nil
                            return true
                        }
                        clearPendingCorrection(frame, reason: "correction_seed_throttled")
                    } else {
                        clearPendingCorrection(frame, reason: "correction_candidate_changed")
                    }
                }
            }
        }
        if correctionSuspensionDeadline != nil {
            enterLost(frame, reason: "correction_confirmation_interrupted")
            return false
        }
        if needsCorrection {
            pendingCorrection = CorrectionCandidate(detection: match, frameID: frame.id, capturedAt: frame.capturedAt)
            frame.diagnostics?.recordEvent("tracker_correction_pending", details: [
                "frameID": String(frame.id), "label": match.label,
                "semanticRenewed": "false"])
            suspendCorrectionMotion(frame)
        }
        return false
    }

    private func suspendCorrectionMotion(_ frame: Frame) {
        guard correctionSuspensionDeadline == nil, pendingCorrection != nil else { return }
        let deadline = lastSemanticAt + ObjectTrackingPolicy.semanticLifetime
        guard ObjectTrackingPolicy.isFresh(lastSemanticAt, now: ProcessInfo.processInfo.systemUptime,
                                           lifetime: ObjectTrackingPolicy.semanticLifetime) else {
            enterLost(frame, reason: "correction_semantic_deadline")
            return
        }
        // Explicit transfer of only the first candidate to a new stationary
        // control generation. Admission discards every pre-rotation queued frame.
        let previousControlID = workerToken?.controlID.uuidString ?? "missing"
        // This event timestamp marks the suspension decision immediately before
        // the atomic rotation; submit() enforces the exact later admission time.
        let suspendedAt = ProcessInfo.processInfo.systemUptime
        guard rotateWorkerControl(), let heldToken = workerToken else { return }
        correctionSuspensionDeadline = deadline
        let heldSelection = selectionID
        frame.diagnostics?.recordEvent("correction_motion_suspended", details: [
            "controlID": heldToken.controlID.uuidString, "selectionID": heldSelection.uuidString,
            "previousControlID": previousControlID, "suspendedAt": String(suspendedAt),
            "firstFrameID": String(frame.id), "firstCapturedAt": String(frame.capturedAt),
            "lastSemanticAt": String(lastSemanticAt), "semanticDeadline": String(deadline),
            "semanticRenewed": "false", "pendingIdentityOnly": "true"])
        worker.asyncAfter(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime)) { [weak self] in
            guard let self, self.isCurrent(heldToken), self.workerToken == heldToken,
                  self.selectionID == heldSelection, self.correctionSuspensionDeadline == deadline else { return }
            // If execution is delayed, enterLost retains the original deadline
            // as lostAt. No position is authorized during this waiting period.
            self.enterLost(frame, reason: "correction_semantic_deadline_without_new_frame")
        }
    }

    private func clearPendingCorrection(_ frame: Frame, reason: String) {
        guard let previous = pendingCorrection else { return }
        pendingCorrection = nil
        frame.diagnostics?.recordEvent("tracker_correction_pending_cleared", details: [
            "firstFrameID": String(previous.frameID), "frameID": String(frame.id), "reason": reason])
    }

    private var hasAppearanceTemplate: Bool {
        !appearanceDisabled && appearanceTemplate?.selectionID == selectionID
    }

    private var recoveryWindow: TimeInterval {
        hasAppearanceTemplate ? ObjectTrackingPolicy.appearanceRecoveryWindow : ObjectTrackingPolicy.recoveryWindow
    }

    /// Pay the OS model's first-use cost before displaying a selectable object.
    /// This full-frame feature is discarded unconditionally. It cannot become
    /// a template, count as confirmation, renew semantics, or authorize motion.
    private func warmAppearanceRuntimeIfNeeded(_ frame: Frame) -> Bool {
        guard appearanceWarmupEnabled, state == .searching,
              appearanceWarmupAttemptedSession != frame.token.sessionID else { return false }
        appearanceWarmupAttemptedSession = frame.token.sessionID
        let started = ProcessInfo.processInfo.systemUptime
        var details = ["sessionID": frame.token.sessionID.uuidString,
            "controlID": frame.token.controlID.uuidString, "frameID": String(frame.id),
            "capturedAt": String(frame.capturedAt), "startedAt": String(started),
            "requestedRevision": "2", "fixedCrop": "[0,0,1,1]", "discarded": "true",
            "providerKind": appearanceProviderKind,
            "nextSourcePolicy": "captured_after_warmup_completion"]
        frame.diagnostics?.updateManifest(["appearanceWarmupStatus": "attempted"])
        frame.diagnostics?.recordEvent("appearance_warmup_started", details: details)
        do {
            let feature = try currentAppearanceFeature(frame.pixelBuffer, CGRect(x: 0, y: 0, width: 1, height: 1))
            details["actualRevision"] = String(feature.revision)
            guard feature.revision == 2 else {
                throw NSError(domain: "ObjectTracking.Appearance", code: 6,
                              userInfo: [NSLocalizedDescriptionKey: "Warmup feature revision mismatch"])
            }
            details["status"] = isCurrent(frame.token) ? "succeeded_discarded" : "completed_after_invalidation_discarded"
            frame.diagnostics?.updateManifest(["appearanceWarmupStatus": details["status"]!,
                "appearanceWarmupRevisionApplied": feature.revision,
                "appearanceFeatureRevisionApplied": feature.revision])
        } catch {
            // Old work may finish after stop/restart. Only its own still-active
            // session may inherit this fallback; selection resets cannot undo it.
            if isSessionCurrent(frame.token.sessionID) {
                appearanceWarmupFailedSession = frame.token.sessionID
                appearanceDisabled = true
            }
            details["status"] = "failed_discarded"
            details["reason"] = error.localizedDescription
            frame.diagnostics?.updateManifest(["appearanceWarmupStatus": "failed_discarded",
                                               "appearanceWarmupFallbackWindowSeconds": ObjectTrackingPolicy.recoveryWindow])
        }
        let ended = ProcessInfo.processInfo.systemUptime
        // Worker state is serial. A queued selection/control reset preserves
        // this session boundary; a new session clears it in resetWorker.
        appearanceWarmupCompletedAt = ended
        frameAppearanceWarmupMs = (ended-started)*1000
        details["endedAt"] = String(ended)
        details["warmupMs"] = String(frameAppearanceWarmupMs!)
        details["sourceAgeMs"] = String((ended-frame.capturedAt)*1000)
        details["sourceFreshAtCompletion"] = String(ObjectTrackingPolicy.isFresh(frame.capturedAt, now: ended))
        frame.diagnostics?.updateManifest(["appearanceWarmupCompletedAt": ended,
                                            "appearanceWarmupMs": frameAppearanceWarmupMs!])
        frame.diagnostics?.recordEvent("appearance_warmup_finished", details: details)
        frame.diagnostics?.recordDrop("appearance_warmup_frame_discarded", frameID: frame.id)
        return true
    }

    private static let appearanceImageContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .cacheIntermediates: false])

    // All uses the system-selected device. Injected providers and the other
    // detector backends retain their original CPU contract. Both template and
    // candidates use the same mode for the whole active detector session.
    private func currentAppearanceFeature(_ buffer: CVPixelBuffer, _ box: CGRect) throws -> ObjectTrackingAppearanceFeature {
        if appearanceProviderKind == "vision_feature_print", detector?.backend == .coreMLAll {
            return try Self.makeAppearanceFeature(buffer, box, usesCPUOnly: false)
        }
        return try appearanceProvider(buffer, box)
    }

    static func makeAppearanceFeature(_ buffer: CVPixelBuffer, _ box: CGRect) throws -> ObjectTrackingAppearanceFeature {
        try makeAppearanceFeature(buffer, box, usesCPUOnly: true)
    }

    private static func makeAppearanceFeature(_ buffer: CVPixelBuffer, _ box: CGRect,
                                              usesCPUOnly: Bool) throws -> ObjectTrackingAppearanceFeature {
        guard #available(iOS 17.0, macOS 14.0, *),
              VNGenerateImageFeaturePrintRequest.supportedRevisions.contains(2) else {
            throw NSError(domain: "ObjectTracking.Appearance", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Feature print revision 2 unavailable"])
        }
        let width = Double(CVPixelBufferGetWidth(buffer)), height = Double(CVPixelBufferGetHeight(buffer))
        let image = CIImage(cvPixelBuffer: buffer)
        guard let raster = appearanceImageContext.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: height),
                                                                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw NSError(domain: "ObjectTracking.Appearance", code: 3)
        }
        // Identical pixel rule to the frozen component probes. The rectangle
        // comes only from the current model result, never a GT or tracker box.
        let x0 = max(0, floor(Double(box.minX) * width)), x1 = min(width, ceil(Double(box.maxX) * width))
        let y0 = max(0, floor((1 - Double(box.maxY)) * height)), y1 = min(height, ceil((1 - Double(box.minY)) * height))
        guard x1 > x0, y1 > y0,
              let crop = raster.cropping(to: CGRect(x: x0, y: y0, width: x1-x0, height: y1-y0)) else {
            throw NSError(domain: "ObjectTracking.Appearance", code: 4)
        }
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        request.imageCropAndScaleOption = .scaleFill
        request.usesCPUOnly = usesCPUOnly
        try VNImageRequestHandler(cgImage: crop, orientation: .up).perform([request])
        guard let observation = request.results?.first, observation.requestRevision == 2 else {
            throw NSError(domain: "ObjectTracking.Appearance", code: 5)
        }
        return VisionTrackingAppearanceFeature(observation: observation)
    }

    private func disableAppearance(_ frame: Frame, reason: String) {
        appearanceDisabled = true
        appearanceTemplate = nil
        appearanceRecoveryCandidate = nil
        if state == .temporarilyLost { confirmationCount = 0 }
        var details = ["reason": reason, "effectiveWindowSeconds": String(recoveryWindow),
                       "frameID": String(frame.id)]
        if let lostAt {
            details["lostAt"] = String(lostAt)
            details["effectiveDeadlineHostTime"] = String(lostAt + recoveryWindow)
        }
        frame.diagnostics?.recordEvent("appearance_unavailable", details: details)
        if state == .temporarilyLost, let lostAt,
           ProcessInfo.processInfo.systemUptime - lostAt > recoveryWindow {
            returnToSearching(frame, reason: "appearance_unavailable_recovery_expired")
        }
    }

    private func extractAppearance(_ match: ObjectDetection, frame: Frame, role: String)
        -> (feature: ObjectTrackingAppearanceFeature, milliseconds: Double)? {
        guard isCurrent(frame.token), ObjectTrackingPolicy.isFresh(frame.capturedAt, now: ProcessInfo.processInfo.systemUptime) else { return nil }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let feature = try currentAppearanceFeature(frame.pixelBuffer, match.boundingBox)
            let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
            frameAppearanceMs += milliseconds
            guard isCurrent(frame.token) else { return nil }
            guard feature.revision == 2 else {
                disableAppearance(frame, reason: "unexpected_feature_revision")
                return nil
            }
            frame.diagnostics?.updateManifest(["appearanceFeatureRevisionApplied": feature.revision])
            frameAppearanceOperations.append(["role": role, "featureMs": milliseconds, "revision": feature.revision])
            return (feature, milliseconds)
        } catch {
            frameAppearanceMs += (ProcessInfo.processInfo.systemUptime - started) * 1000
            guard isCurrent(frame.token) else { return nil }
            disableAppearance(frame, reason: error.localizedDescription)
            return nil
        }
    }

    private func appearanceMatches(_ match: ObjectDetection, frame: Frame, role: String) -> Bool {
        guard hasAppearanceTemplate, let template = appearanceTemplate,
              match.label == template.label,
              let candidate = extractAppearance(match, frame: frame, role: role),
              isCurrent(frame.token), template.selectionID == selectionID else { return false }
        do {
            let distanceStarted = ProcessInfo.processInfo.systemUptime
            let distance = try template.feature.distance(to: candidate.feature)
            let now = ProcessInfo.processInfo.systemUptime
            let distanceMs = (now-distanceStarted)*1000
            frameAppearanceMs += distanceMs
            guard distance.isFinite, distance >= 0 else {
                disableAppearance(frame, reason: "invalid_feature_distance")
                return false
            }
            let fresh = ObjectTrackingPolicy.isFresh(frame.capturedAt, now: now)
            let accepted = fresh && distance <= ObjectTrackingPolicy.appearanceDistanceThreshold
            let operation: [String: Any] = ["role": role, "templateFrameID": template.frameID,
                "distance": distance, "accepted": accepted, "featureMs": candidate.milliseconds,
                "distanceMs": distanceMs,
                "sourceAgeMs": (now-frame.capturedAt)*1000, "fresh": fresh]
            frameAppearanceOperations.append(operation)
            frame.diagnostics?.recordEvent("appearance_candidate_checked", details: [
                "role": role, "frameID": String(frame.id), "templateFrameID": String(template.frameID),
                "selectionID": template.selectionID.uuidString, "distance": String(distance),
                "accepted": String(accepted), "fresh": String(fresh),
                "featureMs": String(candidate.milliseconds), "distanceMs": String(distanceMs),
                "sourceAgeMs": String((now-frame.capturedAt)*1000)])
            return accepted
        } catch {
            disableAppearance(frame, reason: error.localizedDescription)
            return false
        }
    }

    private func clearAppearanceConfirmation(_ frame: Frame, reason: String) {
        if let previous = appearanceRecoveryCandidate {
            frame.diagnostics?.recordEvent("appearance_recovery_confirmation_cleared", details: [
                "firstFrameID": String(previous.frameID), "frameID": String(frame.id), "reason": reason])
        }
        appearanceRecoveryCandidate = nil
        confirmationCount = 0
    }

    private func appearanceConfirmationMatch(_ frame: Frame) -> ObjectDetection? {
        guard hasAppearanceTemplate, let template = appearanceTemplate else { return nil }
        let recovering = state == .temporarilyLost
        let role = recovering ? "recovery" : "initial_retry"
        let origin = recovering ? lostAt! : selectionStartedAt
        let window = recovering ? recoveryWindow : ObjectTrackingPolicy.selectionLifetime
        let matches = candidates.filter { $0.label == template.label }
        guard matches.count <= 1 else {
            returnToSearching(frame, reason: "ambiguous_appearance_identity")
            return nil
        }
        guard let match = matches.first else {
            clearAppearanceConfirmation(frame, reason: "missing_same_class_candidate")
            return nil
        }
        if candidates.contains(where: { $0.label != template.label
            && ObjectTrackingPolicy.intersectionOverUnion($0.boundingBox, match.boundingBox) > 0.50 }) {
            clearAppearanceConfirmation(frame, reason: "class_conflict")
            return nil
        }
        guard appearanceMatches(match, frame: frame, role: role), isCurrent(frame.token), hasAppearanceTemplate else {
            clearAppearanceConfirmation(frame, reason: "appearance_rejected_or_stale")
            // A cached template fixes identity across a cold initialization. If
            // that evidence becomes unavailable, a new selection is necessary;
            // geometric retries must not seed a different instance instead.
            if !recovering, appearanceDisabled, isCurrent(frame.token) {
                returnToSearching(frame, reason: "initial_identity_evidence_unavailable")
            }
            return nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - origin <= window else {
            returnToSearching(frame, reason: recovering ? "recovery_window_expired" : "selection_confirmation_expired")
            return nil
        }
        if let previous = appearanceRecoveryCandidate,
           frame.id == previous.frameID || frame.capturedAt <= previous.capturedAt {
            clearAppearanceConfirmation(frame, reason: "non_increasing_source_frame")
            return nil
        }
        if let previous = appearanceRecoveryCandidate,
           frame.id != previous.frameID, frame.capturedAt > previous.capturedAt,
           frame.capturedAt - previous.capturedAt <= ObjectTrackingPolicy.correctionConfirmationLifetime,
           ObjectTrackingPolicy.intersectionOverUnion(previous.detection.boundingBox, match.boundingBox)
               >= ObjectTrackingPolicy.correctionConfirmationMinimumIoU {
            confirmationCount = 2
            appearanceRecoveryCandidate = nil
            var details = [
                "firstFrameID": String(previous.frameID), "secondFrameID": String(frame.id),
                "templateFrameID": String(template.frameID), "selectionID": selectionID.uuidString, "role": role,
                "elapsedSeconds": String(now-origin),
                "sourceIntervalMs": String((frame.capturedAt-previous.capturedAt)*1000)]
            if recovering { details["lostAt"] = String(origin) }
            else { details["selectionStartedAt"] = String(selectionStartedAt) }
            frame.diagnostics?.recordEvent(recovering ? "appearance_recovery_confirmed" : "appearance_initial_retry_confirmed", details: details)
            return match
        }
        clearAppearanceConfirmation(frame, reason: "new_confirmation_pair")
        appearanceRecoveryCandidate = CorrectionCandidate(detection: match, frameID: frame.id, capturedAt: frame.capturedAt)
        confirmationCount = 1
        var details = ["frameID": String(frame.id), "capturedAt": String(frame.capturedAt), "role": role]
        if recovering { details["lostAt"] = String(origin) }
        frame.diagnostics?.recordEvent("appearance_recovery_pending", details: details)
        return nil
    }

    private func retryConfirmationWithFreshFrames(_ frame: Frame, reason: String) {
        releaseTracker()
        clearAppearanceConfirmation(frame, reason: reason)
        lastSemanticAt = 0
        lastDetectionAt = -.infinity
        frame.diagnostics?.recordEvent("tracker_seed_retry", details: ["reason": reason,
            "frameID": String(frame.id), "sourceAgeMs": String((ProcessInfo.processInfo.systemUptime-frame.capturedAt)*1000),
            "confirmationCount": "0", "deadlinePreserved": "true"])
        _ = emit(frame, shouldMove: false)
    }

    private func prepareInitialAppearanceTemplate(_ match: ObjectDetection, frame: Frame) -> Bool {
        guard state == .confirming, !hasAppearanceTemplate, !appearanceDisabled else { return true }
        let feature = extractAppearance(match, frame: frame, role: "template")
        guard isCurrent(frame.token) else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard now-selectionStartedAt <= ObjectTrackingPolicy.selectionLifetime else {
            returnToSearching(frame, reason: "selection_confirmation_expired")
            return false
        }
        if let feature {
            appearanceTemplate = AppearanceTemplate(feature: feature.feature, selectionID: selectionID,
                frameID: frame.id, capturedAt: frame.capturedAt, label: match.label)
            frame.diagnostics?.recordEvent("appearance_template_created", details: [
                "selectionID": selectionID.uuidString, "templateFrameID": String(frame.id),
                "capturedAt": String(frame.capturedAt), "label": match.label,
                "boundingBox": "[\(match.boundingBox.minX),\(match.boundingBox.minY),\(match.boundingBox.width),\(match.boundingBox.height)]",
                "featureMs": String(feature.milliseconds), "revision": String(feature.feature.revision)])
        }
        // A late but originally fresh template is identity history only. No
        // count, source position, or movement survives; the deadline is unchanged.
        guard ObjectTrackingPolicy.isFresh(frame.capturedAt, now: now) else {
            retryConfirmationWithFreshFrames(frame, reason: "appearance_template_source_expired")
            return false
        }
        return true
    }

    private func seedTracker(_ detection: ObjectDetection, on pixelBuffer: CVPixelBuffer,
                             diagnostics: ObjectTrackingDiagnostics?) throws -> VNDetectedObjectObservation? {
        releaseTracker()
        guard VNTrackObjectRequest.supportedRevisions.contains(trackerRevision) else {
            throw NSError(domain: "ObjectTracking.Vision", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: ObjectTrackingLocalized("Vision does not support tracking revision %@. No fallback was used.", String(describing: trackerRevision))])
        }
        let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: detection.boundingBox))
        request.revision = trackerRevision
        // Vision revision 2 ignores trackingLevel. Retain the request value for
        // revision 1 comparisons and record its effective meaning explicitly.
        request.trackingLevel = .accurate
        request.usesCPUOnly = trackerUsesCPUOnly
        trackingRequest = request
        // Keep a late/cancelled seed's evidence in its source frame's session.
        diagnostics?.updateManifest(["trackerRevisionApplied": request.revision])
        // Detection and initial tracker perform use the exact same source image.
        return try advanceTracker(pixelBuffer)
    }

    private func advanceTracker(_ pixelBuffer: CVPixelBuffer) throws -> VNDetectedObjectObservation? {
        guard let request = trackingRequest else { return nil }
        try trackerPerformer(sequenceHandler, request, pixelBuffer)
        guard let observation = request.results?.first as? VNDetectedObjectObservation else { return nil }
        // Feeding a fabricated/cropped copy back would allocate another tracker.
        request.inputObservation = observation
        return observation
    }

    private func releaseTracker() {
        trackingRequest?.isLastFrame = true
        trackingRequest?.cancel()
        trackingRequest = nil
        sequenceHandler = VNSequenceRequestHandler()
    }

    private func resetWorker(token: Token?, state: ObjectTrackingState) {
        releaseTracker()
        if token?.sessionID != workerToken?.sessionID {
            appearanceWarmupAttemptedSession = nil
            appearanceWarmupFailedSession = nil
            appearanceWarmupCompletedAt = 0
        }
        workerToken = token
        self.state = state
        candidates = []
        candidatesCapturedAt = 0
        selected = nil
        confirmationCount = 0
        selectionStartedAt = 0
        lostAt = nil
        lastDetectionAt = -.infinity
        lastSemanticAt = 0
        lastTrackerSeedAt = -.infinity
        pendingCorrection = nil
        correctionSuspensionDeadline = nil
        selectionID = UUID()
        appearanceTemplate = nil
        appearanceDisabled = token != nil && appearanceWarmupFailedSession == token?.sessionID
        appearanceRecoveryCandidate = nil
        consecutiveDetectionErrors = 0
    }

    private func enterLost(_ frame: Frame, reason: String) {
        guard state == .tracking, rotateWorkerControl() else { return }
        clearPendingCorrection(frame, reason: reason)
        releaseTracker()
        state = .temporarilyLost
        let now = ProcessInfo.processInfo.systemUptime
        lostAt = min(now, correctionSuspensionDeadline ?? now)
        correctionSuspensionDeadline = nil
        lastDetectionAt = -.infinity
        confirmationCount = 0
        appearanceRecoveryCandidate = nil
        frame.diagnostics?.recordEvent("target_lost", details: ["reason": reason,
            "controlID": workerToken!.controlID.uuidString, "selectionID": selectionID.uuidString,
            "lostAt": String(lostAt!), "windowSeconds": String(recoveryWindow),
            "deadlineHostTime": String(lostAt! + recoveryWindow),
            "hasAppearanceTemplate": String(hasAppearanceTemplate)])
        _ = emit(frame, shouldMove: false)
    }

    private func returnToSearching(_ frame: Frame, reason: String) {
        guard rotateWorkerControl() else { return }
        clearPendingCorrection(frame, reason: reason)
        releaseTracker()
        state = .searching
        correctionSuspensionDeadline = nil
        selected = nil
        confirmationCount = 0
        lostAt = nil
        lastSemanticAt = 0
        selectionID = UUID()
        appearanceTemplate = nil
        appearanceRecoveryCandidate = nil
        frame.diagnostics?.recordEvent("selection_required", details: ["reason": reason])
        _ = emit(frame, shouldMove: false)
    }

    /// Every hold and every recovery gets a fresh authorization token.
    private func rotateWorkerControl() -> Bool {
        guard let previous = workerToken else { return false }
        lock.lock()
        guard active, token == previous else { lock.unlock(); return false }
        token = Token(sessionID: previous.sessionID, controlID: UUID())
        admissionStartedAt = ProcessInfo.processInfo.systemUptime
        workerToken = token
        latestFrame = nil
        lock.unlock()
        return true
    }

    private func emit(_ frame: Frame, shouldMove: Bool, error: String? = nil) -> Bool {
        guard let current = workerToken, isCurrent(current) else { return false }
        return publish(ObjectTrackingSnapshot(state: correctionSuspensionDeadline == nil ? state : .temporarilyLost, sessionID: current.sessionID,
                                              controlID: current.controlID, frameID: frame.id,
                                              capturedAt: frame.capturedAt, geometryID: frame.geometryID,
                                              candidates: candidates, candidatesCapturedAt: candidatesCapturedAt,
                                              selectedDetection: correctionSuspensionDeadline == nil ? selected : nil, shouldMove: shouldMove,
                                              semanticAt: lastSemanticAt, error: error))
    }

    private func emptySnapshot(state: ObjectTrackingState, token: Token,
                               geometry: UInt64 = 0, error: String? = nil) -> ObjectTrackingSnapshot {
        ObjectTrackingSnapshot(state: state, sessionID: token.sessionID, controlID: token.controlID,
                               frameID: 0, capturedAt: ProcessInfo.processInfo.systemUptime,
                               geometryID: geometry, candidates: [], candidatesCapturedAt: 0,
                               selectedDetection: nil, shouldMove: false, semanticAt: 0, error: error)
    }

    @discardableResult
    private func publish(_ snapshot: ObjectTrackingSnapshot) -> Bool {
        // Keep discovery incapable of granting motion even if a later state
        // transition accidentally reaches one of the semantic tracker paths.
        guard mode == .semanticTracking || (!snapshot.shouldMove && snapshot.selectedDetection == nil) else { return false }
        lock.lock()
        guard token.sessionID == snapshot.sessionID, token.controlID == snapshot.controlID else {
            lock.unlock(); return false
        }
        var authorizedSnapshot = snapshot
        authorizedSnapshot.controlLease = mode == .semanticTracking ? controlLease : nil
        latestSnapshot = authorizedSnapshot
        pendingUISnapshot = authorizedSnapshot
        let shouldSchedule = !uiDeliveryScheduled
        uiDeliveryScheduled = true
        lock.unlock()
        if Thread.isMainThread {
            deliverLatestSnapshot()
        } else if shouldSchedule {
            DispatchQueue.main.async { [weak self] in self?.deliverLatestSnapshot() }
        }
        return true
    }

    private func deliverLatestSnapshot() {
        lock.lock()
        let snapshot = pendingUISnapshot
        pendingUISnapshot = nil
        uiDeliveryScheduled = false
        let current = token
        let logger = diagnostics
        lock.unlock()
        guard let snapshot, snapshot.sessionID == current.sessionID,
              snapshot.controlID == current.controlID else { return }
        // Linearize synchronous consumption with worker control rotation. A
        // second unlocked check still leaves a check-to-callback race; keeping
        // this recursive lock through onUpdate orders the entire callback before
        // any concurrent invalidation, or drops it if invalidation won first.
        // Reentrant main-thread stop/expiry is allowed; worker work stays async.
        lock.lock()
        defer { lock.unlock() }
        guard token == current else { return }
        cancelDeliveredMotionExpiry()
        let now = ProcessInfo.processInfo.systemUptime
        if snapshot.shouldMove, !snapshot.isMotionValid(at: now) {
            rejectExpiredMotion(snapshot, event: "motion_rejected_at_delivery", now: now)
            return
        }
        if snapshot.shouldMove {
            armDeliveredMotionExpiry(snapshot)
            logger?.recordEvent("motion_delivered", details: motionDeadlineDetails(snapshot, now: now,
                                                                                  delivered: true))
        }
        logger?.recordUIConsumption(frameID: snapshot.frameID, capturedAt: snapshot.capturedAt,
                                    hostTime: now)
        onUpdate(snapshot)
    }

    private func cancelDeliveredMotionExpiry() {
        deliveryExpiryWorkItem?.cancel()
        deliveryExpiryWorkItem = nil
        deliveredMotion = nil
    }

    private func armDeliveredMotionExpiry(_ snapshot: ObjectTrackingSnapshot) {
        guard let deadline = snapshot.motionExpiresAt else { return }
        let expected = Token(sessionID: snapshot.sessionID, controlID: snapshot.controlID)
        deliveredMotion = (expected, snapshot.frameID)
        let work = DispatchWorkItem { [weak self] in
            guard let self, let delivered = self.deliveredMotion,
                  delivered.token == expected, delivered.frameID == snapshot.frameID,
                  self.isCurrent(expected) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now <= deadline {
                self.armDeliveredMotionExpiry(snapshot)
                return
            }
            self.cancelDeliveredMotionExpiry()
            self.rejectExpiredMotion(snapshot, event: "motion_expired_after_delivery", now: now)
        }
        deliveryExpiryWorkItem = work
        motionExpiryScheduler(work, deadline)
    }

    private func motionDeadlineDetails(_ snapshot: ObjectTrackingSnapshot, now: TimeInterval,
                                       delivered: Bool) -> [String: String] {
        ["frameID": String(snapshot.frameID), "sessionID": snapshot.sessionID.uuidString,
         "controlID": snapshot.controlID.uuidString, "capturedAt": String(snapshot.capturedAt),
         "semanticAt": String(snapshot.semanticAt),
         "motionExpiresAt": snapshot.motionExpiresAt.map { String($0) } ?? "invalid",
         "hostTime": String(now), "analysisShouldMove": String(snapshot.shouldMove),
         "deliveredShouldMove": String(delivered)]
    }

    /// A cutoff and its token check are one admission transaction. A newly
    /// published frame/control wins over an obsolete delivery timer.
    private func rejectExpiredMotion(_ snapshot: ObjectTrackingSnapshot, event: String, now: TimeInterval,
                                     boundary: String = "coordinator_delivery") {
        let expected = Token(sessionID: snapshot.sessionID, controlID: snapshot.controlID)
        let semanticDeadline = snapshot.semanticAt + ObjectTrackingPolicy.semanticLifetime
        let positionDeadline = snapshot.capturedAt + ObjectTrackingPolicy.positionLifetime
        let semanticFirst = snapshot.semanticAt.isFinite && snapshot.semanticAt > 0
            && snapshot.capturedAt.isFinite && snapshot.capturedAt > 0
            && semanticDeadline.isFinite && semanticDeadline < positionDeadline
        var details = motionDeadlineDetails(snapshot, now: now, delivered: false)
        details["boundary"] = boundary
        details["reason"] = semanticFirst ? "semantic_deadline" : "position_or_invalid_deadline"
        let logger: ObjectTrackingDiagnostics?
        lock.lock(); logger = diagnostics; lock.unlock()
        var appliedDetails = details
        appliedDetails["appliedToCurrentControl"] = "true"
        let recordApplied: () -> Void = { logger?.recordEvent(event, details: appliedDetails) }
        let applied: Bool
        if semanticFirst {
            applied = holdExpiredSemantics(snapshot, expected: expected, lostOrigin: semanticDeadline,
                                           beforePublish: recordApplied)
        } else {
            applied = invalidateControl(reason: "expired_ui_motion_authorization", expected: expected,
                                        sourceFrameID: snapshot.frameID, beforePublish: recordApplied)
        }
        if !applied {
            details["appliedToCurrentControl"] = "false"
            logger?.recordEvent(event, details: details)
            // A newer worker publication may have won the lock. Consume it now
            // rather than letting an old timer revoke or outlive its position.
            deliverLatestSnapshot()
        }
    }

    private func holdExpiredSemantics(_ snapshot: ObjectTrackingSnapshot, expected: Token,
                                      lostOrigin: TimeInterval, beforePublish: () -> Void) -> Bool {
        lock.lock()
        guard active, token == expected, latestSnapshot?.frameID == snapshot.frameID else {
            lock.unlock(); return false
        }
        token = Token(sessionID: expected.sessionID, controlID: UUID())
        let heldToken = token
        admissionStartedAt = ProcessInfo.processInfo.systemUptime
        latestFrame = nil
        let logger = diagnostics
        lock.unlock()
        beforePublish()
        // Queue the worker transition before publishing the hold, so an onUpdate
        // callback cannot admit a new-token frame ahead of this transition.
        worker.async { [weak self] in
            guard let self, self.isCurrent(heldToken), self.workerToken == expected else { return }
            self.workerToken = heldToken
            self.pendingCorrection = nil
            self.correctionSuspensionDeadline = nil
            self.appearanceRecoveryCandidate = nil
            self.releaseTracker()
            self.state = .temporarilyLost
            self.lostAt = lostOrigin
            self.confirmationCount = 0
            self.lastDetectionAt = -.infinity
            logger?.recordEvent("target_lost", details: ["reason": "semantic_deadline_at_consumer",
                "controlID": heldToken.controlID.uuidString, "selectionID": self.selectionID.uuidString,
                "lostAt": String(lostOrigin), "windowSeconds": String(self.recoveryWindow),
                "deadlineHostTime": String(lostOrigin + self.recoveryWindow),
                "hasAppearanceTemplate": String(self.hasAppearanceTemplate)])
        }
        publish(ObjectTrackingSnapshot(state: .temporarilyLost, sessionID: heldToken.sessionID,
            controlID: heldToken.controlID, frameID: snapshot.frameID, capturedAt: snapshot.capturedAt,
            geometryID: snapshot.geometryID, candidates: snapshot.candidates,
            candidatesCapturedAt: snapshot.candidatesCapturedAt, selectedDetection: snapshot.selectedDetection,
            shouldMove: false, semanticAt: snapshot.semanticAt, error: nil))
        return true
    }

    private func failSession(_ sessionID: UUID, message: String) {
        lock.lock()
        guard active, token.sessionID == sessionID else { lock.unlock(); return }
        token = Token(sessionID: sessionID, controlID: UUID())
        let failedToken = token
        active = false
        latestFrame = nil
        let logger = diagnostics
        lock.unlock()
        resetWorker(token: nil, state: .idle)
        detector = nil
        logger?.recordEvent("error", details: ["message": message])
        publish(emptySnapshot(state: .idle, token: failedToken, error: message))
        logger?.finish(reason: "error")
    }

    private func isCurrent(_ expected: Token) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active && token == expected
    }

    private func isSessionCurrent(_ sessionID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active && token.sessionID == sessionID
    }

    private func currentToken(for sessionID: UUID) -> Token? {
        lock.lock(); defer { lock.unlock() }
        return active && token.sessionID == sessionID ? token : nil
    }

    private func withDiagnostics(_ action: (ObjectTrackingDiagnostics) -> Void) {
        lock.lock(); let logger = diagnostics; lock.unlock()
        if let logger { action(logger) }
    }

    private static func detectionJSON(_ detection: ObjectDetection) -> [String: Any] {
        ["label": detection.label, "confidence": detection.confidence,
         "boundingBox": [detection.boundingBox.minX, detection.boundingBox.minY,
                         detection.boundingBox.width, detection.boundingBox.height]]
    }
}
