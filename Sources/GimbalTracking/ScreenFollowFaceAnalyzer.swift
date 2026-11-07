import Foundation
import Vision
import CoreGraphics
import CoreML

/// Confined to the Vision worker queue. Detection validates a live image tracker;
/// a validation pass preserves a healthy sequence or corrects measurable drift.
final class ScreenFollowFaceAnalyzer {
    struct Result {
        let faces: [ScreenFollowRect]
        let usedTracking: Bool
        let decision: String
        let details: String
        let detectedFaceCount: Int
        let resetsTarget: Bool
        let backgroundValidationMS: Double?
    }

    private let detector: ScreenFollowFaceDetector
    private let detectionOverride: ((CGImage) throws -> [ScreenFollowRect])?
    private let timeSource: () -> TimeInterval
    private let asyncValidation: ScreenFollowValidationWorker?
    private let detectsVerticalMotionEveryFrame: Bool
    private var trackerGeneration: UInt64 = 0
    private var sequence = VNSequenceRequestHandler()
    private var request: VNTrackObjectRequest?
    private var context: String?
    private var lastValidationAt: TimeInterval?
    private var lastValidationAttemptAt: TimeInterval?
    private var validationMisses = 0
    private var lastFrameAt: TimeInterval?
    private var lastValidationReference: ScreenFollowRect?
    private var previousTrackedBox: ScreenFollowRect?
    private var verticalValidationUntil: TimeInterval?

    init(timeSource: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         asyncValidation: ScreenFollowValidationWorker? = nil,
         prefersNeuralEngine: Bool = false,
         detectsVerticalMotionEveryFrame: Bool = false,
         detectionOverride: ((CGImage) throws -> [ScreenFollowRect])? = nil) {
        self.detectionOverride = detectionOverride
        self.timeSource = timeSource
        self.asyncValidation = asyncValidation
        self.detectsVerticalMotionEveryFrame = detectsVerticalMotionEveryFrame
        self.detector = ScreenFollowFaceDetector(prefersNeuralEngine: prefersNeuralEngine)
    }

    private func releaseTracker() {
        trackerGeneration &+= 1
        asyncValidation?.cancel()
        request?.isLastFrame = true
        request?.cancel()
        request = nil
        sequence = VNSequenceRequestHandler()
    }

    func reset() {
        releaseTracker()
        lastValidationAt = nil
        lastValidationAttemptAt = nil
        validationMisses = 0
        lastFrameAt = nil
        lastValidationReference = nil
        previousTrackedBox = nil
        verticalValidationUntil = nil
    }

    /// Check sooner while vertical motion can take the tracker away from a face.
    /// Keep the short cadence through a brief plateau or successful correction;
    /// neither an in-flight check nor this window extends identity freshness.
    private func validationCadence(for rect: ScreenFollowRect, at capturedAt: TimeInterval)
        -> (interval: TimeInterval, trigger: String) {
        let movedVertically = [previousTrackedBox, lastValidationReference].compactMap { $0 }.contains { reference in
            abs(rect.centerY - reference.centerY) >= max(0.025, min(rect.height, reference.height) * 0.10)
        }
        // A newly acquired tracker can remain at a displaced Y while losing the
        // face. Do not wait for that same tracker to report motion before checking
        // again. This is the controller's 160/2000 pitch release displacement;
        // it uses the current image and never carries an old identity over reset.
        let verticallyDisplaced = abs(rect.centerY - 0.5) >= 0.08
        previousTrackedBox = rect
        if movedVertically || verticallyDisplaced { verticalValidationUntil = capturedAt + 0.75 }
        if capturedAt < (verticalValidationUntil ?? -.infinity) {
            return (0.20, movedVertically ? "vertical_motion" : verticallyDisplaced ? "vertical_offset" : "vertical_settle")
        }
        return (0.45, "periodic")
    }

    func analyze(_ image: CGImage, capturedAt: TimeInterval, now: TimeInterval,
                 context: String, confirmedTarget: ScreenFollowRect?) throws -> Result {
        guard capturedAt.isFinite, now.isFinite, now >= capturedAt else {
            reset(); throw ScreenFollowError.message(ScreenFollowLocalized("Invalid Screen Frame Timestamp"))
        }
        let startedAt = timeSource()
        var reason = "no_tracker"
        if self.context != context {
            reset(); self.context = context; reason = "new_context"
        } else if lastFrameAt.map({ capturedAt <= $0 || capturedAt - $0 > 0.5 }) == true {
            reset(); reason = "frame_gap"
        }
        lastFrameAt = capturedAt
        var tracked: ScreenFollowRect?
        var trackerWasClipped = false
        var confidence: Float?
        var observedBox: ScreenFollowRect?
        var rawTrackedBox: ScreenFollowRect?
        var overlap: Double?
        var detectorBoxes = "none"
        var clippedDetections = 0
        var correction = "none"
        var backgroundValidationMS: Double?
        var backgroundDecision = "none"
        var backgroundCompletion = "none"
        var backgroundCompute = "none"
        var backgroundDetails = "none"
        var validationInterval: TimeInterval = 0.45
        var validationTrigger = "periodic"
        var directVerticalDetection = detectsVerticalMotionEveryFrame && confirmedTarget != nil
            && capturedAt < (verticalValidationUntil ?? -.infinity)
        if directVerticalDetection {
            validationInterval = 0
            validationTrigger = "vertical_active"
        }
        var needsCurrentDetection = false
        var backgroundIdentityConflict = false

        func validationIsFresh() -> Bool {
            guard let validated = lastValidationAt else { return false }
            let completedAt = now + timeSource() - startedAt
            return capturedAt >= validated && capturedAt - validated <= 0.75 && completedAt - validated <= 0.75
        }
        func result(_ faces: [ScreenFollowRect], tracking: Bool, decision: String,
                    detected: Int = 0, resetsTarget: Bool = false) -> Result {
            let confidenceText = confidence.map { String(format: "%.2f", $0) } ?? "none"
            let overlapText = overlap.map { String(format: "%.2f", $0) } ?? "none"
            let box = observedBox?.diagnosticBox ?? "none"
            let reference = confirmedTarget?.diagnosticBox ?? "none"
            let age = lastValidationAt.map { Int((capturedAt - $0) * 1000) } ?? -1
            return Result(faces: faces, usedTracking: tracking, decision: decision,
                          details: "fallback=\(reason) confidence=\(confidenceText) overlap=\(overlapText) box=\(box) reference=\(reference) detectorBoxes=\(detectorBoxes) trackerRaw=\(rawTrackedBox?.diagnosticBox ?? "none") detectorClipped=\(clippedDetections) correction=\(correction) visionMode=\(directVerticalDetection ? "vertical_face" : "tracker_validation") validationAgeMS=\(age) validationIntervalMS=\(Int(validationInterval * 1000)) validationTrigger=\(validationTrigger) misses=\(validationMisses) backgroundValidation=\(backgroundDecision) backgroundCompletion=\(backgroundCompletion) detectorCompute=\(detectionOverride == nil ? detector.computeDescription : "fixture") backgroundCompute=\(backgroundCompute) backgroundDetails=\(backgroundDetails)",
                          detectedFaceCount: detected, resetsTarget: resetsTarget,
                          backgroundValidationMS: backgroundValidationMS)
        }

        if let completed = asyncValidation?.takeCompleted() {
            backgroundValidationMS = completed.elapsedMS
            backgroundCompute = completed.computeDescription
            let input = completed.input
            backgroundDetails = "source backgroundCapturedMS=\(Int(input.capturedAt * 1000)) backgroundReference=\(input.reference.diagnosticBox) backgroundTrigger=\(input.validationTrigger) backgroundIntervalMS=\(Int(input.validationInterval * 1000)) backgroundElapsedMS=\(String(format: "%.2f", completed.elapsedMS))"
            if case .success(let detected) = completed.result {
                let matching = detected.compactMap(\.visibleFace).filter { $0.overlap(with: input.reference) >= 0.08 }
                backgroundDetails += " backgroundBoxes=\(detected.isEmpty ? "none" : detected.prefix(3).map(\.diagnosticBox).joined(separator: ";")) backgroundMatches=\(matching.count)"
                if matching.count == 1, let face = matching.first {
                    backgroundDetails += String(format: " backgroundOverlap=%.3f backgroundDelta=%.3f,%.3f backgroundScale=%.3f,%.3f",
                                                face.overlap(with: input.reference), face.centerX - input.reference.centerX,
                                                face.centerY - input.reference.centerY, face.width / input.reference.width,
                                                face.height / input.reference.height)
                }
            } else { backgroundDetails += " backgroundBoxes=error backgroundMatches=0" }
            // Delayed detection validates only its original image and tracker.
            // It cannot replace the box observed in the image being processed now.
            if input.context == context, input.generation == trackerGeneration,
               request != nil, confirmedTarget != nil,
               input.capturedAt <= capturedAt, now - input.capturedAt <= 0.75,
               input.capturedAt > (lastValidationAt ?? -.infinity) {
                switch completed.result {
                case .success(let detected):
                    let matching = detected.compactMap(\.visibleFace).filter { $0.overlap(with: input.reference) >= 0.08 }
                    if matching.count == 1, let face = matching.first,
                       !face.needsTrackingCorrection(from: input.reference) {
                        lastValidationAt = input.capturedAt
                        lastValidationAttemptAt = input.capturedAt
                        lastValidationReference = input.reference
                        validationMisses = 0
                        backgroundDecision = "accepted"
                    } else {
                        // A correction, conflict or miss needs a fresh same-image
                        // detection. Never reseed this image with an older box.
                        // An unresolved validation cannot earn another miss grace.
                        needsCurrentDetection = true
                        validationMisses = max(1, validationMisses)
                        if !detected.isEmpty {
                            // A known conflict on the validation image cannot be
                            // erased by a matching face in a later image. Keep
                            // the same two-frame reacquisition as synchronous
                            // validation, using a fresh current-image candidate.
                            backgroundIdentityConflict = matching.count != 1
                                || matching.first.map { !$0.canCorrectTracking(input.reference) } == true
                        }
                        backgroundDecision = detected.isEmpty ? "redetect_miss"
                            : backgroundIdentityConflict ? "redetect_identity_conflict" : "redetect_geometry"
                    }
                case .failure:
                    needsCurrentDetection = true
                    validationMisses = max(1, validationMisses)
                    backgroundDecision = "redetect_error"
                }
            } else { backgroundDecision = "discarded" }
            backgroundCompletion = backgroundDecision
        }

        // Consume any completed validation above before switching pipelines: a
        // known identity conflict must still stop and require fresh confirmation.
        if !directVerticalDetection, let request, let confirmedTarget,
           !backgroundIdentityConflict, validationIsFresh() {
            do {
                try sequence.perform([request], on: image, orientation: .up)
                if let observation = request.results?.first as? VNDetectedObjectObservation {
                    let raw = Self.rect(observation.boundingBox)
                    rawTrackedBox = raw
                    confidence = observation.confidence; observedBox = raw
                    if !observation.confidence.isFinite || observation.confidence < 0.7 { reason = "tracker_low_confidence" }
                    else if let rect = raw.visibleFace, rect.isContinuous(with: confirmedTarget) {
                        observedBox = rect
                        overlap = rect.overlap(with: confirmedTarget)
                        let clipped = raw != rect
                        trackerWasClipped = clipped
                        if clipped {
                            // A user-created observation starts a new tracker on the
                            // next perform. Rebuild below on this same image instead
                            // of learning the next frame at an old clipped position.
                            releaseTracker()
                        } else { request.inputObservation = observation }
                        tracked = rect
                        (validationInterval, validationTrigger) = validationCadence(for: rect, at: capturedAt)
                        directVerticalDetection = detectsVerticalMotionEveryFrame && validationInterval == 0.20
                        if directVerticalDetection { validationInterval = 0 }
                        let needsValidation: Bool
                        if directVerticalDetection || clipped || needsCurrentDetection { needsValidation = true }
                        else if validationMisses > 0 {
                            validationInterval = 0.12
                            validationTrigger = "miss_retry"
                            needsValidation = capturedAt - (lastValidationAttemptAt ?? 0) >= 0.12
                        } else { needsValidation = capturedAt - (lastValidationAt ?? 0) >= validationInterval }
                        if !needsValidation, validationIsFresh() {
                            reason = "none"
                            return result([rect], tracking: true,
                                          decision: backgroundDecision == "accepted" ? "validated_async" : "tracking")
                        }
                        if !directVerticalDetection, !clipped, !needsCurrentDetection, validationMisses == 0,
                           let asyncValidation, validationIsFresh() {
                            if asyncValidation.start(image, input: .init(generation: trackerGeneration,
                                                                         context: context, capturedAt: capturedAt,
                                                                         reference: rect, validationTrigger: validationTrigger,
                                                                         validationInterval: validationInterval)) {
                                lastValidationAttemptAt = capturedAt
                                backgroundDecision = "started"
                            }
                            reason = "periodic_validation_pending"
                            return result([rect], tracking: true, decision: "tracking_validation_pending")
                        }
                        reason = directVerticalDetection ? "vertical_current_frame" : needsCurrentDetection ? backgroundDecision
                            : validationIsFresh() ? (clipped ? "tracker_clipped" : "periodic_validation") : "validation_expired"
                    } else { reason = raw.visibleFace == nil ? "tracker_invalid_box" : "tracker_mismatch" }
                } else { reason = "tracker_no_result" }
            } catch { reason = "tracker_error_\((error as NSError).code)" }
        } else if request != nil {
            reason = backgroundIdentityConflict ? backgroundDecision
                : directVerticalDetection ? "vertical_current_frame"
                : confirmedTarget == nil ? "confirmation_required" : "validation_expired"
        }

        // Invalid trackers are released; a healthy current-image observation stays
        // available while the detector checks that it still corresponds to a face.
        if tracked == nil { releaseTracker() }
        asyncValidation?.cancel()
        lastValidationAttemptAt = capturedAt
        let faces: [ScreenFollowRect]
        if let detectionOverride { faces = try detectionOverride(image) }
        else { faces = try detector.perform(image) }
        let valid = faces.compactMap(\.visibleFace)
        clippedDetections = faces.filter { original in
            original.visibleFace.map { $0 != original } ?? false
        }.count
        detectorBoxes = faces.prefix(3).map(\.diagnosticBox).joined(separator: ";")
        func restartAcquisition() -> Result {
            // This detector result is a fresh first observation, never permission
            // to keep moving with the old identity. The main process resets the
            // controller before observing it; another consistent frame is required.
            let candidate = faces.count == 1 && valid.count == 1 ? valid : []
            reset(); lastFrameAt = capturedAt
            if let first = candidate.first { observedBox = first }
            return result(candidate, tracking: false, decision: "identity_conflict",
                          detected: faces.count, resetsTarget: true)
        }
        if backgroundIdentityConflict { return restartAcquisition() }
        let reference = tracked ?? confirmedTarget
        let selected: ScreenFollowRect?
        if let reference {
            let matching = valid.filter { tracked != nil ? $0.overlap(with: reference) >= 0.08 : $0.isContinuous(with: reference) }
            // Ambiguous same-image faces cannot silently inherit an old identity.
            selected = matching.count == 1 ? matching.first : nil
        } else { selected = valid.count == 1 ? valid.first : nil }

        if let selected {
            if let tracked, selected.needsTrackingCorrection(from: tracked), !selected.canCorrectTracking(tracked) {
                reason = "correction_identity_uncertain"
                return restartAcquisition()
            }
            // A same-image correction is another vertical-motion observation.
            // releaseTracker intentionally preserves this short checking window.
            (validationInterval, validationTrigger) = validationCadence(for: selected, at: capturedAt)
            lastValidationAt = capturedAt
            lastValidationReference = selected
            validationMisses = 0
            directVerticalDetection = detectsVerticalMotionEveryFrame && validationInterval == 0.20
            if directVerticalDetection {
                // During vertical activity, associate consecutive current-image
                // face detections instead of steering from a generic object
                // tracker that may freeze Y with confidence 1. Entering from a
                // live tracker still passes the same-image correction gate above.
                if let tracked {
                    correction = String(format: "%.3f,%.3f", selected.centerX - tracked.centerX, selected.centerY - tracked.centerY)
                }
                if request != nil { releaseTracker() }
                observedBox = selected
                reason = "vertical_current_frame"
                validationInterval = 0 // Every admitted current frame, not a 200 ms poll.
                return result([selected], tracking: false, decision: "detected_vertical", detected: faces.count)
            }
            if let tracked, !trackerWasClipped, !selected.needsTrackingCorrection(from: tracked) {
                // Small detector variation should not rebuild a healthy sequence.
                return result([tracked], tracking: false, decision: "validated", detected: faces.count)
            }
            let correcting = tracked != nil
            if let tracked {
                correction = String(format: "%.3f,%.3f", selected.centerX - tracked.centerX, selected.centerY - tracked.centerY)
                releaseTracker()
            }
            observedBox = selected
            let tracker = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: Self.visionBox(selected)))
            tracker.revision = VNTrackObjectRequestRevision1
            tracker.trackingLevel = .fast
            tracker.usesCPUOnly = true
            request = tracker
            do {
                // Seed from the image that produced the face observation.
                try sequence.perform([tracker], on: image, orientation: .up)
                if let observation = tracker.results?.first as? VNDetectedObjectObservation {
                    confidence = observation.confidence
                    let rawSeed = Self.rect(observation.boundingBox)
                    if observation.confidence.isFinite, observation.confidence >= 0.7,
                       let seeded = rawSeed.visibleFace {
                        guard seeded == rawSeed else {
                            // An out-of-bounds observation cannot be carried forward.
                            // The current detector result is usable; reacquire next frame.
                            releaseTracker()
                            return result([selected], tracking: false, decision: "seed_clipped", detected: faces.count)
                        }
                        // Preserve the tracker identity and the appearance learned
                        // from this image. Recreating the observation would restart
                        // on the next image at the previous image's coordinates.
                        tracker.inputObservation = observation
                        return result([selected], tracking: false, decision: correcting ? "corrected" : "detected", detected: faces.count)
                    }
                }
                releaseTracker()
                return result([selected], tracking: false, decision: correcting ? "corrected_seed_low_confidence" : "seed_low_confidence", detected: faces.count)
            } catch {
                releaseTracker()
                return result([selected], tracking: false, decision: "\(correcting ? "corrected_" : "")seed_error_\((error as NSError).code)", detected: faces.count)
            }
        }

        if !directVerticalDetection, faces.isEmpty, let tracked, validationMisses == 0, validationIsFresh() {
            validationMisses = 1
            return result([tracked], tracking: false, decision: "detector_miss_grace", detected: faces.count)
        }
        let decision = valid.isEmpty ? (faces.isEmpty ? "no_face" : "invalid_face_box")
            : reference == nil ? "ambiguous_faces" : "identity_conflict"
        if decision == "identity_conflict" { return restartAcquisition() }
        reset()
        lastFrameAt = capturedAt
        return result(reference == nil ? valid : [], tracking: false, decision: decision,
                      detected: faces.count, resetsTarget: decision == "identity_conflict")
    }

    private static func rect(_ box: CGRect) -> ScreenFollowRect {
        ScreenFollowRect(x: box.minX, y: box.minY, width: box.width, height: box.height)
    }

    private static func visionBox(_ rect: ScreenFollowRect) -> CGRect {
        // Same inset used by native object tracking to avoid Vision Code=9 at 0/1.
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
            .intersection(CGRect(x: 0.001, y: 0.001, width: 0.998, height: 0.998))
    }
}


/// Runs at most one face validation without touching analyzer or controller state.
/// Cancellation keeps an outstanding job in its slot until its scheduled work
/// runs or its detector finishes, so repeated resets cannot build a work backlog.
final class ScreenFollowValidationWorker {
    struct Input {
        let generation: UInt64
        let context: String
        let capturedAt: TimeInterval
        let reference: ScreenFollowRect
        let validationTrigger: String
        let validationInterval: TimeInterval

        init(generation: UInt64, context: String, capturedAt: TimeInterval, reference: ScreenFollowRect,
             validationTrigger: String = "periodic", validationInterval: TimeInterval = 0.45) {
            self.generation = generation
            self.context = context
            self.capturedAt = capturedAt
            self.reference = reference
            self.validationTrigger = validationTrigger
            self.validationInterval = validationInterval
        }
    }

    struct Completion {
        let input: Input
        let result: Swift.Result<[ScreenFollowRect], Error>
        let elapsedMS: Double
        let computeDescription: String
    }

    private final class Job {
        let input: Input
        var started = false
        var cancelled = false
        var completion: Completion?

        init(input: Input) { self.input = input }
    }

    private let lock = NSLock()
    private var activeJob: Job?
    private let detect: (CGImage) throws -> [ScreenFollowRect]
    private let describeCompute: () -> String
    private let schedule: (@escaping () -> Void) -> Void
    private let clock: () -> TimeInterval

    init(prefersNeuralEngine: Bool = false,
         detect: ((CGImage) throws -> [ScreenFollowRect])? = nil,
         schedule: ((@escaping () -> Void) -> Void)? = nil,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        if let detect {
            self.detect = detect
            self.describeCompute = { "fixture" }
        } else {
            // One detector belongs to this serial worker for its lifetime. It is
            // never shared with the analyzer, and setup/fallback happens once.
            let detector = ScreenFollowFaceDetector(prefersNeuralEngine: prefersNeuralEngine)
            self.detect = { try detector.perform($0) }
            self.describeCompute = { detector.computeDescription }
        }
        if let schedule {
            self.schedule = schedule
        } else {
            let queue = DispatchQueue(label: "com.example.screenfollow.validation", qos: .userInitiated)
            self.schedule = { operation in queue.async(execute: DispatchWorkItem(block: operation)) }
        }
        self.clock = clock
    }

    func start(_ image: CGImage, input: Input) -> Bool {
        lock.lock()
        guard activeJob == nil else { lock.unlock(); return false }
        let job = Job(input: input)
        activeJob = job
        lock.unlock()

        // An injected scheduler may execute immediately or reenter this worker.
        // Retaining image here also keeps the original validation pixels alive.
        schedule { [self, job, image] in execute(image, job: job) }
        return true
    }

    func takeCompleted() -> Completion? {
        lock.lock()
        defer { lock.unlock() }
        guard let job = activeJob, let completion = job.completion else { return nil }
        activeJob = nil
        return completion
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard let job = activeJob else { return }
        job.cancelled = true
        // A finished result can be discarded now. Running or scheduled work
        // releases its own slot after observing the cancellation.
        if job.completion != nil { activeJob = nil }
    }

    private func execute(_ image: CGImage, job: Job) {
        lock.lock()
        guard activeJob === job, !job.started else { lock.unlock(); return }
        job.started = true
        if job.cancelled {
            activeJob = nil
            lock.unlock()
            return
        }
        lock.unlock()

        let startedAt = clock()
        let result: Swift.Result<[ScreenFollowRect], Error> = Swift.Result {
            try autoreleasepool { try detect(image) }
        }
        let elapsedMS = max(0, clock() - startedAt) * 1000
        let completion = Completion(input: job.input, result: result, elapsedMS: elapsedMS,
                                    computeDescription: describeCompute())

        lock.lock()
        defer { lock.unlock() }
        guard activeJob === job else { return }
        if job.cancelled { activeJob = nil }
        else { job.completion = completion }
    }
}


/// One instance belongs to one serial Vision worker. Labels describe explicit
/// request configuration, not measurements of which hardware executed a kernel.
final class ScreenFollowFaceDetector {
    enum DeviceKind: Equatable {
        case cpu, neuralEngine, gpu, other
    }

    /// A complete assignment is required: never leave a stage to automatic/GPU
    /// selection. CPU support on every stage also preserves a safe fallback.
    static func neuralEnginePlan(stages: [String: [DeviceKind]],
                                 mainStage: String) -> [String: DeviceKind]? {
        guard let main = stages[mainStage], main.contains(.neuralEngine),
              stages.values.allSatisfy({ $0.contains(.cpu) }) else { return nil }
        return stages.mapValues { _ in .cpu }.merging([mainStage: .neuralEngine]) { _, new in new }
    }

    private let prefersNeuralEngine: Bool
    private let requestFactory: () -> VNDetectFaceRectanglesRequest
    private let configureNeuralEngineOverride: ((VNDetectFaceRectanglesRequest) throws -> Bool)?
    private let performRequestOverride: ((VNDetectFaceRectanglesRequest, CGImage) throws -> [ScreenFollowRect])?
    private var request: VNDetectFaceRectanglesRequest?
    private var usingNeuralEngine = false
    private(set) var computeDescription = "cpu"

    // The optional hooks allow deterministic configuration/failure tests without
    // requiring a Neural Engine or substituting another detection algorithm.
    init(prefersNeuralEngine: Bool = false,
         requestFactory: @escaping () -> VNDetectFaceRectanglesRequest = { VNDetectFaceRectanglesRequest() },
         configureNeuralEngine: ((VNDetectFaceRectanglesRequest) throws -> Bool)? = nil,
         performRequest: ((VNDetectFaceRectanglesRequest, CGImage) throws -> [ScreenFollowRect])? = nil) {
        self.prefersNeuralEngine = prefersNeuralEngine
        self.requestFactory = requestFactory
        self.configureNeuralEngineOverride = configureNeuralEngine
        self.performRequestOverride = performRequest
    }

    func perform(_ image: CGImage) throws -> [ScreenFollowRect] {
        // Device discovery can be expensive. Do it only on this instance's first
        // worker execution, never while constructing the analyzer on the main queue.
        if request == nil { prepareRequest() }
        guard let request else { preconditionFailure("Face detector request was not prepared") }
        do {
            return try run(request, image: image)
        } catch {
            guard usingNeuralEngine else { throw error }
            // A failed accelerated request may contain partial configuration or
            // execution state. Discard it; retry this exact image once on a clean
            // CPU request, and permanently keep this instance on CPU thereafter.
            let cpu = installCPU(description: "cpu_fallback_perform_\((error as NSError).code)")
            return try run(cpu, image: image)
        }
    }

    private func prepareRequest() {
        guard prefersNeuralEngine else {
            installCPU(description: "cpu")
            return
        }
        guard Self.neuralEngineIsAllowed else {
            installCPU(description: "cpu_fallback_unsupported_os")
            return
        }
        let candidate = requestFactory()
        // Query capabilities without the legacy CPU-only restriction. This
        // candidate is never performed unless every stage has an explicit device.
        candidate.usesCPUOnly = false
        do {
            let configured: Bool
            if let configureNeuralEngineOverride {
                configured = try configureNeuralEngineOverride(candidate)
            } else if #available(iOS 17.0, macOS 14.0, *) {
                configured = try Self.configureNeuralEngine(candidate)
            } else {
                configured = false
            }
            guard configured else {
                installCPU(description: "cpu_fallback_unsupported_stages")
                return
            }
            request = candidate
            usingNeuralEngine = true
            computeDescription = "neuralEngine"
        } catch {
            installCPU(description: "cpu_fallback_config_\((error as NSError).code)")
        }
    }

    @discardableResult
    private func installCPU(description: String) -> VNDetectFaceRectanglesRequest {
        let cpu = requestFactory()
        // A new request has no assignments from an earlier accelerated attempt.
        // usesCPUOnly also covers supported iOS versions predating per-stage APIs.
        cpu.usesCPUOnly = true
        request = cpu
        usingNeuralEngine = false
        computeDescription = description
        return cpu
    }

    private func run(_ request: VNDetectFaceRectanglesRequest,
                     image: CGImage) throws -> [ScreenFollowRect] {
        if let performRequestOverride { return try performRequestOverride(request, image) }
        try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
        return (request.results ?? []).map { observation in
            let box = observation.boundingBox
            return ScreenFollowRect(x: box.minX, y: box.minY, width: box.width, height: box.height)
        }
    }

    private static var neuralEngineIsAllowed: Bool {
        #if os(iOS)
        // iOS 27 introduces a separate background-inference entitlement. This
        // experiment does not request it; retain CPU for that OS and later.
        if #available(iOS 27.0, *) { return false }
        if #available(iOS 17.0, *) { return true }
        return false
        #elseif os(macOS)
        // Host tests must explicitly opt in through prefersNeuralEngine as well.
        if #available(macOS 14.0, *) { return true }
        return false
        #else
        return false
        #endif
    }

    @available(iOS 17.0, macOS 14.0, *)
    private static func configureNeuralEngine(_ request: VNDetectFaceRectanglesRequest) throws -> Bool {
        let supported = try request.supportedComputeStageDevices
        let kinds = Dictionary(uniqueKeysWithValues: supported.map { stage, devices in
            (stage.rawValue, devices.map(deviceKind))
        })
        guard let plan = neuralEnginePlan(stages: kinds, mainStage: VNComputeStage.main.rawValue) else {
            return false
        }
        // Resolve every concrete device before making any assignments. No nil is
        // passed to Vision, including optional/new stages exposed by this request.
        var assignments: [(VNComputeStage, MLComputeDevice)] = []
        for (stage, devices) in supported {
            guard let selectedKind = plan[stage.rawValue],
                  let device = devices.first(where: { deviceKind($0) == selectedKind }) else { return false }
            assignments.append((stage, device))
        }
        for (stage, device) in assignments { request.setComputeDevice(device, for: stage) }
        return true
    }

    @available(iOS 17.0, macOS 14.0, *)
    private static func deviceKind(_ device: MLComputeDevice) -> DeviceKind {
        switch device {
        case .cpu: return .cpu
        case .neuralEngine: return .neuralEngine
        case .gpu: return .gpu
        @unknown default: return .other
        }
    }
}
