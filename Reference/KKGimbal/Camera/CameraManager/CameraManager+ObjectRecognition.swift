import AVFoundation
import UIKit
import Vision
import CoreImage
import ImageIO
import CryptoKit

final class CMPhysicalObjectUnavailableWholeObservation: VNDetectedObjectObservation {
    override var confidence: VNConfidence { 0 }
}

/// Explicit quality travels separately from display-only Vision observations.
struct CMPhysicalObjectMeasurement {
    var rect: CGRect
    var previousRect: CGRect
    let quality: Float
    var source: String
    var patchDiagnostics: [String: Any] = [:]
    var isHeldObservation = false
    var supportsCenterRecovery = false
    var recoveredOriginalTemplate = false
    var recoveredVerifiedIdentity = false
    var recoveredPhotoReference = false
    var photoConfirmationStartedAt: TimeInterval?
}

/// One capture-queue session per user selection. Neither a Vision proposal
/// nor a recovered box can replace the first captured reference photo.
final class CMPhysicalObjectPhotoSession {
    static let enabled = !ProcessInfo.processInfo.arguments.contains("-KKPhysicalFollowLegacy")
    let requestIdentity: ObjectIdentifier
    private let photo: CMPhysicalObjectPhotoReference?
    private let nano: CMNanoTrackTracker?
    private let independentSearchEnabled: Bool
    private var lastOutput: CGRect
    private(set) var nanoSeedRect: CGRect?
    var hasNanoTemplate: Bool { nano != nil }
    var movingAppearanceKind: String? { nano?.movingAppearanceKind }
    var initializationDiagnostics: [String: Any] {
        var result: [String: Any] = ["initialization_only": true,
            "uses_foreground_continuity": usesLocalForeground, "nano_template": hasNanoTemplate,
            "moving_appearance": movingAppearanceKind ?? "photo_fallback",
            "independent_search_enabled": independentSearchEnabled && hasNanoTemplate,
            "moving_initialization": nano?.movingInitializationDiagnostics ??
                ["attempted": false, "accepted": false, "reason": "nano_template_unavailable"]]
        if let box = nanoSeedRect {
            result["nano_seed_bbox"] = [box.minX, box.minY, box.width, box.height]
        }
        return result
    }
    var usesLocalForeground: Bool { foreground != nil }
    private var lastRect: CGRect
    private var foreground: ForegroundTrack?
    private var originalAppearance: CMPhysicalObjectPartsSession.Appearance?
    private var colorBands: [(CGRect, CMPhysicalObjectPartsSession.Appearance)] = []
    private var lastToken: TimeInterval?
    private var weakSince: TimeInterval?
    private var lastMeasuredAt: TimeInterval?
    private var movingVotes: [(rect: CGRect, time: TimeInterval)] = []
    private(set) var independentlyTracksMovement = false
    private var movingSearch = false
    private var searchBoundary: TimeInterval?
    var needsVisionProposal: Bool { !independentlyTracksMovement && originalAppearance == nil }

    // This sequence is separate from the camera's request identity. Retiring a
    // lost local tracker cannot cancel the user's selection or replace the photo.
    private final class ForegroundTrack {
        let parts: CMPhysicalObjectPartsSession
        private let whole: VNTrackObjectRequest
        private let handler = VNSequenceRequestHandler()

        init(buffer: CVPixelBuffer, rect: CGRect) {
            parts = CMPhysicalObjectPartsSession(seed: rect)
            whole = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: rect))
            whole.revision = VNTrackObjectRequestRevision2
            whole.trackingLevel = .accurate
            _ = measure(buffer, initializationOnly: true)
        }

        func measure(_ buffer: CVPixelBuffer, initializationOnly: Bool = false) -> CMPhysicalObjectMeasurement {
            let current = parts.wholeObservation(request: whole, handler: handler, pixels: buffer)
            let result = parts.measure(pixels: buffer, full: current, initializationOnly: initializationOnly)
            if !(current is CMPhysicalObjectUnavailableWholeObservation) { whole.inputObservation = current }
            return result
        }

        deinit { whole.cancel() }
    }

    init(request: VNTrackObjectRequest, buffer: CVPixelBuffer, selection: CGRect,
         useNano: Bool = !ProcessInfo.processInfo.arguments.contains("-KKPhysicalFollowPhotoOnly"),
         independent: Bool = true) {
        requestIdentity = ObjectIdentifier(request)
        independentSearchEnabled = independent
        if let refined = CMPhysicalObjectForegroundSelection.refine(buffer, selection: selection),
           let reference = CMPhysicalObjectPhotoReference(pixelBuffer: buffer, selection: refined.rect) {
            // Remove the desk and adjacent objects from a loose manual box.
            photo = reference
            lastRect = refined.rect
            let track = ForegroundTrack(buffer: buffer, rect: refined.rect)
            originalAppearance = track.parts.appearance(pixels: buffer, rect: refined.rect)
            if originalAppearance != nil {
                foreground = track
                for index in 0..<3 {
                    let start = CGFloat(index) / 3
                    let band = refined.rect.height >= refined.rect.width
                        ? CGRect(x: 0, y: start, width: 1, height: 1.0/3)
                        : CGRect(x: start, y: 0, width: 1.0/3, height: 1)
                    if let signature = track.parts.appearance(pixels: buffer, rect: Self.project(band, into: refined.rect)),
                       signature.colorful >= 0.2 { colorBands.append((band, signature)) }
                }
            }
        } else {
            lastRect = selection
            photo = CMPhysicalObjectPhotoReference(pixelBuffer: buffer, selection: selection)
        }
        lastOutput = lastRect
        if useNano, let photo {
            // A loose selection can contain a hand or clothing. If foreground
            // extraction failed, the two unique original landmarks may still isolate the subject.
            let landmarks = photo.landmarkSeedRect
            let seed = originalAppearance == nil && !landmarks.isNull ? landmarks : lastRect
            nano = CMNanoTrackTracker(pixelBuffer: buffer, selection: seed)
            nanoSeedRect = seed // Record the attempted seed even when model initialization fails.
            if independent, nano?.enableIndependentTracking(buffer, selection: seed) == true {
                independentlyTracksMovement = true
                foreground = nil
            }
        } else { nano = nil }
    }

    var isAvailable: Bool { photo != nil }
    var unavailableVisionObservation: VNDetectedObjectObservation {
        CMPhysicalObjectUnavailableWholeObservation(boundingBox: lastRect)
    }

    func beginSearch(after boundary: TimeInterval? = nil) {
        if let boundary, boundary.isFinite { searchBoundary = max(searchBoundary ?? boundary, boundary) }
        movingSearch = independentlyTracksMovement
        foreground = nil
        weakSince = nil
        lastMeasuredAt = nil
        movingVotes.removeAll(keepingCapacity: true)
        photo?.beginSearch()
    }

    private func hold(_ reason: String) -> CMPhysicalObjectMeasurement {
        CMPhysicalObjectMeasurement(rect: lastRect, previousRect: lastRect, quality: 0.3,
            source: "photo_reference_hold", patchDiagnostics: ["reason": reason], isHeldObservation: true)
    }

    private static func project(_ band: CGRect, into box: CGRect) -> CGRect {
        CGRect(x: box.minX + band.minX * box.width, y: box.minY + band.minY * box.height,
               width: band.width * box.width, height: band.height * box.height)
    }

    private func appearanceAgrees(_ original: CMPhysicalObjectPartsSession.Appearance,
                                  local: CMPhysicalObjectMeasurement, buffer: CVPixelBuffer,
                                  parts: CMPhysicalObjectPartsSession) -> Bool {
        guard let current = parts.appearance(pixels: buffer, rect: local.rect) else { return false }
        if original.allowsContinuity(with: current) { return true }
        // On a partly transparent or hand-held object, a depth change alters
        // how much of the whole box belongs to the background. Require a
        // geometric consensus plus a surviving colorful region of the original.
        guard local.source == "foreground_parts_consensus", original.similarity(to: current) >= 0.60 else { return false }
        return colorBands.contains { band, signature in
            guard let sample = parts.appearance(pixels: buffer, rect: Self.project(band, into: local.rect)) else { return false }
            return signature.allowsContinuity(with: sample)
        }
    }

    private func movingPartsMeasurement(_ pixels: CVPixelBuffer, at time: TimeInterval) -> CMPhysicalObjectMeasurement? {
        guard let match = photo?.movingParts(pixels) else {
            movingVotes.removeAll(keepingCapacity: true)
            return nil
        }
        guard match["ambiguous"] as? Bool != true else {
            beginSearch()
            return hold("ambiguous_moving_parts")
        }
        guard let b = match["bbox"] as? [Double], b.count == 4, b.allSatisfy({ $0.isFinite }),
              b[2] > 0, b[3] > 0, let score = match["score"] as? Double, (0...1).contains(score) else {
            movingVotes.removeAll(keepingCapacity: true)
            return nil
        }
        let rect = CGRect(x: b[0], y: b[1], width: b[2], height: b[3])
        let continuous = lastMeasuredAt.map { time - $0 <= 0.24 } == true
            && CMPhysicalObjectPartsSession.continuous(rect, with: lastRect)
        if let last = movingVotes.last {
            // The target is allowed to move between independent global matches.
            // Reject implausible jumps or changes in scale even with similar parts.
            let scale = rect.width * rect.height / (last.rect.width * last.rect.height)
            if time - last.time > 0.25 || !(0.60...1.67).contains(scale)
                || abs(rect.midX - last.rect.midX) > max(0.035, 0.85 * last.rect.width)
                || abs(rect.midY - last.rect.midY) > max(0.035, 0.85 * last.rect.height) {
                movingVotes.removeAll(keepingCapacity: true)
            }
        }
        // Weaker, spatially continuous observations cannot count as global votes.
        if score >= 0.70 {
            movingVotes.append((rect,time))
            if movingVotes.count > 3 { movingVotes.removeFirst() }
        } else { movingVotes.removeAll(keepingCapacity: true) }
        // While this independent route gathers votes the original-photo route
        // must still see every frame, including its own third recovery vote.
        guard continuous || movingVotes.count == 3 else { return nil }
        let previous = lastRect
        lastRect = rect
        lastMeasuredAt = time
        if !continuous, originalAppearance != nil, photo?.matchesColorCue(pixels, rect: rect) == true {
            foreground = ForegroundTrack(buffer: pixels, rect: rect)
            weakSince = nil
        }
        // The whole-photo fallback cannot use its old local box after a moving
        // landmark takes over. Only current pixels may re-establish either route.
        photo?.beginSearch()
        return CMPhysicalObjectMeasurement(rect: rect, previousRect: previous, quality: continuous ? Float(score) : 0.95,
            source: continuous ? "original_moving_parts" : "recovered_original_moving_parts",
            patchDiagnostics: ["landmark_score":score,"confirmation_count":movingVotes.count],
            recoveredPhotoReference: !continuous, photoConfirmationStartedAt: continuous ? nil : movingVotes.first?.time)
    }

    func approveMovingFrame(at time: TimeInterval) {
        if independentlyTracksMovement { nano?.approveMovingFrame(at: time) }
    }

    private func measureMovement(in buffer: CVPixelBuffer, at time: TimeInterval,
                                 nano: CMNanoTrackTracker) -> CMPhysicalObjectMeasurement {
        if let weakSince, time-weakSince >= 0.4 { movingSearch = true }
        let evidence = nano.movingObservation(buffer, searching: movingSearch, frameTime: time)
        func paused(_ reason: String) -> CMPhysicalObjectMeasurement {
            var measurement = hold(reason)
            measurement.patchDiagnostics.merge(evidence) { _, value in value }
            return measurement
        }
        guard let box = evidence["bbox"] as? [Double], box.count == 4,
              box.allSatisfy({ $0.isFinite }), let score = evidence["detail_score"] as? Double, score.isFinite else {
            movingVotes.removeAll(keepingCapacity: true)
            if weakSince == nil { weakSince = time }
            return paused(evidence["ambiguous"] as? Bool == true ? "ambiguous_moving_print" : "unverified_moving_print")
        }
        let rect = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
        let previous = lastOutput
        if !movingSearch && !CMPhysicalObjectPartsSession.continuous(rect, with: previous) {
            // A large jump needs a new, stronger search vote on a later frame.
            beginSearch()
            return paused("moving_position_jump")
        }
        let recovering = movingSearch
        var first: TimeInterval?
        if recovering {
            if let vote = movingVotes.last, time-vote.time > 0.30 ||
                !CMPhysicalObjectPartsSession.continuous(rect, with: vote.rect) {
                movingVotes.removeAll(keepingCapacity: true)
            }
            movingVotes.append((rect,time))
            guard movingVotes.count == 3 else { return paused("confirming_moving_print") }
            first = movingVotes.first?.time
            movingVotes.removeAll(keepingCapacity: true)
            // Start the next local search on the newly verified subject.
            // Keep the first-frame NanoTrack template and appearance identity.
            nano.acceptVerifiedRect(rect)
            movingSearch = false
        }
        weakSince = nil
        lastRect = rect
        lastOutput = rect
        lastMeasuredAt = time
        return CMPhysicalObjectMeasurement(rect: rect, previousRect: previous, quality: recovering ? 0.95 : Float(score),
            source: recovering ? "moving_print_recovered" : "moving_print_tracking", patchDiagnostics: evidence,
            recoveredPhotoReference: recovering, photoConfirmationStartedAt: first)
    }

    func measure(buffer: CVPixelBuffer, vision: VNDetectedObjectObservation,
                 capturedAt: TimeInterval?) -> CMPhysicalObjectMeasurement {
        guard let capturedAt, capturedAt.isFinite, lastToken.map({ capturedAt > $0 }) ?? true else {
            beginSearch()
            return hold("non_monotonic_frame")
        }
        if let previousTime = lastToken, capturedAt - previousTime > 0.4 { beginSearch() }
        lastToken = capturedAt
        if let searchBoundary, capturedAt < searchBoundary { return hold("before_search_boundary") }
        if independentlyTracksMovement, let nano { return measureMovement(in: buffer, at: capturedAt, nano: nano) }
        let proposal = nano?.candidate(in: buffer, advanceSearch: independentSearchEnabled) ?? .null
        var measurement = measurePhoto(buffer: buffer, vision: vision, time: capturedAt, proposal: proposal)
        guard let nano else { return measurement }
        let photoRect = measurement.rect
        let photoPrevious = measurement.previousRect
        measurement.previousRect = lastOutput
        measurement.patchDiagnostics["nano_score"] = nano.confidence
        measurement.patchDiagnostics["nano_search_advanced"] = independentSearchEnabled && !proposal.isNull
        if !proposal.isNull {
            measurement.patchDiagnostics["nano_bbox"] = [proposal.minX, proposal.minY, proposal.width, proposal.height]
        }
        // The frozen-photo route alone decides identity, holds and reentry. The
        // network can improve geometry only when both measurements locate the same object.
        if measurement.isHeldObservation {
            measurement.rect = lastOutput
            return measurement
        }
        // Two original landmarks directly measure extent as well as position.
        // Keep that geometry when both are visible; the network helps single/local measurements.
        if !measurement.recoveredPhotoReference, measurement.source != "original_moving_parts", !proposal.isNull,
           Self.coversSameSubject(proposal, photoRect),
           photo?.matchesColorCue(buffer, rect: proposal) == true {
            measurement.rect = proposal
            measurement.source = "nanotrack_" + measurement.source
        }
        // Local photo parts can cover only the label while the network measures
        // the bottle. On handoff, confine the output to current image evidence
        // and the existing motion limits. Never bridge a held or discontinuous photo.
        if !measurement.recoveredPhotoReference, lastOutput != photoPrevious || measurement.rect != photoRect,
           CMPhysicalObjectPartsSession.continuous(photoRect, with: photoPrevious) {
            let rect = Self.transitionGeometry(measurement.rect, confirmedBy: photoRect, from: lastOutput)
            if rect != measurement.rect {
                measurement.rect = rect
                measurement.patchDiagnostics["nano_geometry_transition"] = true
            }
        }
        lastOutput = measurement.rect
        nano.acceptVerifiedRect(lastOutput)
        return measurement
    }

    private static func coversSameSubject(_ candidate: CGRect, _ photo: CGRect) -> Bool {
        let overlap = candidate.intersection(photo)
        guard !overlap.isNull, photo.contains(CGPoint(x: candidate.midX, y: candidate.midY)),
              candidate.contains(CGPoint(x: photo.midX, y: photo.midY)) else { return false }
        let shared = overlap.width * overlap.height
        let union = photo.width * photo.height + candidate.width * candidate.height - shared
        return shared >= union / 3
    }

    private static func transitionGeometry(_ rect: CGRect, confirmedBy photo: CGRect, from previous: CGRect) -> CGRect {
        let ratio = (rect.width * rect.height) / (previous.width * previous.height)
        guard ratio.isFinite, ratio > 0 else { return rect }
        let scale = sqrt(min(1.55, max(0.65, ratio)) / ratio)
        let w = rect.width * scale, h = rect.height * scale
        // The center must still be inside both current observations. If no such
        // center is continuous, pass the original measurement to the safety gate.
        let shared = rect.intersection(photo)
        let dx = 0.95 * max(0.04, previous.width * 0.5), dy = 0.95 * max(0.04, previous.height * 0.5)
        let left = max(shared.minX, previous.midX-dx), right = min(shared.maxX, previous.midX+dx)
        let bottom = max(shared.minY, previous.midY-dy), top = min(shared.maxY, previous.midY+dy)
        guard !shared.isNull, left <= right, bottom <= top else { return rect }
        let x = min(right, max(left, rect.midX)), y = min(top, max(bottom, rect.midY))
        if scale == 1 && x == rect.midX && y == rect.midY { return rect }
        let framed = CGRect(x: x-w/2, y: y-h/2, width: w, height: h)
        return CGRect(x: 0, y: 0, width: 1, height: 1).contains(framed) ? framed : rect
    }

    private func measurePhoto(buffer: CVPixelBuffer, vision: VNDetectedObjectObservation,
                              time capturedAt: TimeInterval, proposal: CGRect) -> CMPhysicalObjectMeasurement {
        let previous = lastRect
        if let foreground, let originalAppearance {
            let local = foreground.measure(buffer)
            if !local.isHeldObservation, local.quality >= 0.5,
               CMPhysicalObjectPartsSession.continuous(local.rect, with: previous),
               photo?.matchesColorCue(buffer, rect: local.rect) == true,
               appearanceAgrees(originalAppearance, local: local, buffer: buffer, parts: foreground.parts) {
                weakSince = nil
                lastRect = local.rect
                lastMeasuredAt = capturedAt
                movingVotes.removeAll(keepingCapacity: true)
                return CMPhysicalObjectMeasurement(rect: local.rect, previousRect: previous, quality: local.quality,
                    source: "photo_local_" + local.source, patchDiagnostics: local.patchDiagnostics)
            }
            // Start fresh, independent photo votes on the first local miss.
            // A brief local recovery can still win; no held box authorizes motion.
            if let weakSince {
                if capturedAt - weakSince >= 0.20 { self.foreground = nil }
            } else {
                weakSince = capturedAt
                photo?.beginSearch()
            }
        }
        if let measured = movingPartsMeasurement(buffer, at: capturedAt) { return measured }
        var result: [String: Any] = ["reason": "missing_photo_or_frame_time"]
        if let photo {
            result = photo.measure(buffer, proposal: proposal.isNull ? vision.boundingBox : proposal,
                                   confidence: proposal.isNull ? vision.confidence : (nano?.confidence ?? 0),
                                   frameToken: capturedAt,
                                   allowSearchProposal: independentSearchEnabled && !proposal.isNull)
        }
        let recovered = result["recovered_original_template"] as? Bool == true
        if result["accepted"] as? Bool == true,
           let box = result["bbox"] as? [Double], box.count == 4, box.allSatisfy({ $0.isFinite }),
           box[2] > 0, box[3] > 0,
           let quality = result["quality"] as? Double, quality.isFinite,
           quality >= (recovered ? 0.9 : 0.5), quality <= 1 {
            let rect = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
            if originalAppearance != nil, !recovered || photo?.matchesColorCue(buffer, rect: rect) != true {
                beginSearch()
                return hold("missing_original_foreground_cue")
            }
            lastRect = rect
            lastMeasuredAt = capturedAt
            movingVotes.removeAll(keepingCapacity: true)
            if recovered, originalAppearance != nil {
                // Only a verified three-frame match to the original can seed
                // new local parts. The original appearance remains immutable.
                foreground = ForegroundTrack(buffer: buffer, rect: rect)
                weakSince = nil
            }
            return CMPhysicalObjectMeasurement(rect: rect, previousRect: previous, quality: Float(quality),
                source: recovered ? "photo_reference_recovered" : "photo_reference_match",
                patchDiagnostics: result, recoveredPhotoReference: recovered,
                photoConfirmationStartedAt: result["confirmation_started_at"] as? Double)
        }
        return CMPhysicalObjectMeasurement(rect: previous, previousRect: previous, quality: 0.3,
            source: "photo_reference_hold", patchDiagnostics: result, isHeldObservation: true)
    }
}

/// Owned exclusively by dataOutputQueue and tied to one explicit user request.
final class CMPhysicalObjectPatchSession {
    let requestIdentity: ObjectIdentifier
    private var tracker: CMPhysicalObjectPatchTracker?
    private var lastRect: CGRect
    private var hasMatch = false

    init(request: VNTrackObjectRequest, buffer: CVPixelBuffer, selection: CGRect) {
        requestIdentity = ObjectIdentifier(request)
        lastRect = selection
        tracker = CMPhysicalObjectPatchTracker(pixelBuffer: buffer, selection: selection)
    }

    var unavailableVisionObservation: VNDetectedObjectObservation? {
        guard hasMatch, tracker?.supportsCenterRecovery == true else { return nil }
        return CMPhysicalObjectUnavailableWholeObservation(boundingBox: lastRect)
    }

    var canRecoverFrozen: Bool { hasMatch && tracker?.supportsCenterRecovery == true }

    func resetFrozenRecoveryConfirmation() { tracker?.resetFrozenRecoveryConfirmation() }

    func recoverFrozen(buffer: CVPixelBuffer, frameToken: TimeInterval) -> CMPhysicalObjectMeasurement {
        let previous = lastRect
        let startedAt = ProcessInfo.processInfo.systemUptime
        var result = tracker?.recoverFrozenPixelBuffer(buffer, frameToken: frameToken) ?? ["accepted": false]
        result["perform_ms"] = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        if result["accepted"] as? Bool == true, result["recovered_original_template"] as? Bool == true,
           let box = result["bbox"] as? [Double], box.count == 4,
           let score = result["score"] as? Double, score.isFinite, score >= 0.9 {
            lastRect = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
            return CMPhysicalObjectMeasurement(rect: lastRect, previousRect: previous, quality: Float(score),
                source: "original_template_recovery", patchDiagnostics: ["center_recovery": result],
                supportsCenterRecovery: true, recoveredOriginalTemplate: true)
        }
        return CMPhysicalObjectMeasurement(rect: previous, previousRect: previous, quality: 0.3,
            source: "patch_unconfirmed_hold", patchDiagnostics: ["center_recovery": result],
            isHeldObservation: true, supportsCenterRecovery: canRecoverFrozen)
    }

    func measure(buffer: CVPixelBuffer, vision: VNDetectedObjectObservation) -> CMPhysicalObjectMeasurement {
        let previous = lastRect
        var diagnostics: [String: Any] = ["reason": "template_unavailable"]
        if let tracker {
            let startedAt = ProcessInfo.processInfo.systemUptime
            let result = tracker.trackPixelBuffer(buffer, referenceRect: vision.boundingBox,
                                                  referenceConfidence: vision.confidence)
            diagnostics = result
            diagnostics["perform_ms"] = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
            let nativeSource = result["measurement_source"] as? String
            let foregroundFeatures = nativeSource == "foreground_features"
            let foregroundColor = nativeSource == "foreground_color_shape"
            if result["accepted"] as? Bool == true,
               let box = result["bbox"] as? [Double], box.count == 4,
               let score = result["score"] as? Double, score.isFinite,
               score >= (foregroundFeatures ? 0.9 : (foregroundColor ? 0.72 : 0.8)) {
                lastRect = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
                hasMatch = true
                return CMPhysicalObjectMeasurement(rect: lastRect, previousRect: previous,
                    quality: Float(score), source: foregroundFeatures ? "foreground_features" : (foregroundColor
                        ? "foreground_color_shape" : ((result["template_updates"] as? Int ?? 0) > 0
                            ? "appearance_patch_multiscale" : "fixed_patch_multiscale")), patchDiagnostics: diagnostics)
            }
            if hasMatch {
                let supportsRecovery = tracker.supportsCenterRecovery
                if supportsRecovery {
                    let recovered = tracker.recoverPixelBuffer(buffer)
                    diagnostics["center_recovery"] = recovered
                    diagnostics["perform_ms"] = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
                    if recovered["accepted"] as? Bool == true,
                       recovered["recovered_original_template"] as? Bool == true,
                       let box = recovered["bbox"] as? [Double], box.count == 4,
                       let score = recovered["score"] as? Double, score.isFinite, score >= 0.9 {
                        lastRect = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
                        return CMPhysicalObjectMeasurement(rect: lastRect, previousRect: previous,
                            quality: Float(score), source: "original_template_recovery", patchDiagnostics: diagnostics,
                            supportsCenterRecovery: true, recoveredOriginalTemplate: true)
                    }
                }
                // A held rectangle contains no current position evidence. It
                // only keeps the bounded stopped-observation window alive.
                return CMPhysicalObjectMeasurement(rect: previous, previousRect: previous,
                    quality: 0.3, source: "patch_unconfirmed_hold", patchDiagnostics: diagnostics,
                    isHeldObservation: true, supportsCenterRecovery: supportsRecovery)
            }
            // A textureless/ambiguous selection keeps its original Vision route.
            // Do not silently acquire a patch on a later, different frame.
            self.tracker = nil
        }
        lastRect = vision.boundingBox
        return CMPhysicalObjectMeasurement(rect: lastRect, previousRect: previous,
            quality: vision.confidence, source: "vision", patchDiagnostics: diagnostics)
    }
}

#if DEBUG
/// Main-thread acknowledgements are consumed at the next capture boundary,
/// independently of scheduling fairness between AVCapture and dispatch blocks.
final class CMPhysicalObjectRecoveryMailbox {
    enum Payload {
        case search(String)
        case commit(CVPixelBuffer, CGRect, TimeInterval)
        case reject(TimeInterval)
        case cancelLocal(CGRect, TimeInterval, UInt64)
        case reliable(CVPixelBuffer, CMPhysicalObjectMeasurement, TimeInterval)
        case invalidate
    }
    struct Command {
        let sequence: UInt64
        let requestedAt: TimeInterval
        let payload: Payload
    }
    private let lock = NSLock()
    private var request: VNTrackObjectRequest?
    private var sequence: UInt64 = 0
    private var searchGeneration: UInt64?
    private var controls: [Command] = []
    private var learning: [Command] = []

    func enqueue(_ payload: Payload, request: VNTrackObjectRequest,
                 requestedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        defer { lock.unlock() }
        if self.request !== request {
            controls.removeAll()
            learning.removeAll()
            searchGeneration = nil
            self.request = request
        }
        sequence &+= 1
        let command = Command(sequence: sequence, requestedAt: requestedAt, payload: payload)
        switch payload {
        case .search:
            // A new loss supersedes an unapplied older recovery and all learning.
            controls = [command]
            learning.removeAll()
            searchGeneration = command.sequence
        case .cancelLocal(_, _, let generation):
            guard generation == searchGeneration else { return }
            controls = [command]
            learning.removeAll()
        case .commit(_, _, let token), .reject(let token):
            guard !controls.contains(where: {
                switch $0.payload {
                case .commit(_, _, let queued), .reject(let queued): return queued > token
                default: return false
                }
            }) else { return }
            controls.removeAll {
                switch $0.payload { case .commit, .reject: return true; default: return false }
            }
            controls.append(command) // At most one search and one proposal decision.
        case .invalidate:
            learning = [command]
        case .reliable:
            if learning.contains(where: {
                if case .reliable = $0.payload { return true }
                return false
            }) {
                // Never count callbacks separated by a dropped acknowledgement
                // as consecutive evidence. Retain only one camera buffer so the
                // capture pool can deliver the next callback that drains us.
                learning = [Command(sequence: sequence - 1, requestedAt: requestedAt, payload: .invalidate)]
            }
            learning.append(command)
        }
    }

    func take(request: VNTrackObjectRequest) -> [Command] {
        lock.lock()
        defer { lock.unlock() }
        guard self.request === request else { return [] }
        let result = (controls + learning).sorted { $0.sequence < $1.sequence }
        controls.removeAll()
        learning.removeAll()
        return result
    }

    func currentSearchGeneration(request: VNTrackObjectRequest) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return self.request === request ? searchGeneration : nil
    }

    func clear(request: VNTrackObjectRequest) {
        lock.lock()
        defer { lock.unlock() }
        guard self.request === request else { return }
        controls.removeAll()
        learning.removeAll()
        self.request = nil
        searchGeneration = nil
    }
}

/// Capture-queue owned identity recovery for one explicit user request.
/// The caller acknowledges only main-thread Safety-approved fresh measurements.
/// Backend geometry/canonical identity checks remain required for gallery adds.
final class CMPhysicalObjectRecoverySession {
    let requestIdentity: ObjectIdentifier
    private let identity: CMPhysicalObjectReacquirer
    private(set) var isSearching = false
    private(set) var hasResumedTracking = false
    private(set) var lastLearningDiagnostics: [String: Any]?
    private(set) var nativeHistoryAddCount = 0
    private var lastRect: CGRect
    private var lastRectAt: TimeInterval?
    private var lastMeasuredAt: TimeInterval?
    private var lastReliableObservationAt: TimeInterval?
    private var lastLearningRect: CGRect?
    private var reliableLearningFrames = 0
    private var lastCacheAttemptAt: TimeInterval?
    private struct TrustedView {
        let buffer: CVPixelBuffer
        let rect: CGRect
        let capturedAt: TimeInterval
    }
    private var trustedViews: [TrustedView] = []
    private var warmingViews: [TrustedView] = []
    var cachedHistoryCount: Int { trustedViews.count }
    var pendingHistoryCount: Int { warmingViews.count }

    /// Own small copied pixels, never the camera pool's original buffers.
    /// Dimensions match CMTrackingGray's <=640px OpenCV resize. Normalized
    /// rectangles therefore keep the original selected coordinate system.
    private enum TrustedPixelCopy {
        static let context = CIContext(options: [.cacheIntermediates: false,
            .workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
            let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
            guard width > 0, height > 0 else { return nil }
            let scale = min(1, 640.0 / Double(max(width, height)))
            let targetWidth = max(1, Int((Double(width) * scale).rounded(.toNearestOrEven)))
            let targetHeight = max(1, Int((Double(height) * scale).rounded(.toNearestOrEven)))
            var allocated: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, targetWidth, targetHeight, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &allocated) == kCVReturnSuccess,
                let copied = allocated else { return nil }
            let sourceImage = CIImage(cvPixelBuffer: source)
            let scaleX: CGFloat = CGFloat(targetWidth) / CGFloat(width)
            let scaleY: CGFloat = CGFloat(targetHeight) / CGFloat(height)
            let transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
            let image = sourceImage.transformed(by: transform)
            context.render(image, to: copied, bounds: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight), colorSpace: nil)
            return copied
        }
    }
    private var resumedRequest: VNTrackObjectRequest?
    private var resumedHandler: VNSequenceRequestHandler?
    private var resumedParts: CMPhysicalObjectPartsSession?

    private struct Proposal {
        let buffer: CVPixelBuffer
        let rect: CGRect
        let capturedAt: TimeInterval
    }
    private var proposal: Proposal?

    init?(request: VNTrackObjectRequest, buffer: CVPixelBuffer, selection: CGRect) {
        guard let identity = CMPhysicalObjectReacquirer(pixelBuffer: buffer, selection: selection) else { return nil }
        requestIdentity = ObjectIdentifier(request)
        self.identity = identity
        lastRect = selection
    }

    var unavailableObservation: VNDetectedObjectObservation {
        CMPhysicalObjectUnavailableWholeObservation(boundingBox: lastRect)
    }

    /// Call for every intervening weak, rejected, stale, or non-ready frame.
    /// Otherwise three selected callbacks could be mistaken for consecutive ones.
    func invalidateReliableSequence() {
        reliableLearningFrames = 0
        lastLearningRect = nil
    }

    /// Only main-thread Safety-approved and capture-age-approved frames reach
    /// this callback. Identity/request checks must also precede its queue hop.
    func observeReliable(measurement: CMPhysicalObjectMeasurement, buffer: CVPixelBuffer,
                         capturedAt: TimeInterval) {
        guard !isSearching, proposal == nil, capturedAt.isFinite,
              lastReliableObservationAt.map({ capturedAt > $0 }) ?? true else {
            invalidateReliableSequence()
            return
        }
        lastReliableObservationAt = capturedAt
        guard !measurement.isHeldObservation, measurement.quality.isFinite, measurement.quality >= 0.5,
              Self.validNormalizedBox(measurement.rect) else {
            invalidateReliableSequence()
            return
        }
        // A delayed acknowledgement cannot rewind a newer child measurement.
        if lastRectAt.map({ capturedAt >= $0 }) ?? true {
            lastRect = measurement.rect
            lastRectAt = capturedAt
        }
        guard !measurement.recoveredOriginalTemplate, !measurement.recoveredVerifiedIdentity,
              Self.strongLearningEvidence(measurement),
              Self.continuous(measurement.rect, with: lastLearningRect ?? measurement.previousRect) else {
            invalidateReliableSequence()
            return
        }
        lastLearningRect = measurement.rect
        reliableLearningFrames = min(3, reliableLearningFrames + 1)
        guard reliableLearningFrames >= 3,
              lastCacheAttemptAt.map({ capturedAt - $0 >= 0.12 }) ?? true else { return }
        lastCacheAttemptAt = capturedAt
        let copyStartedAt = ProcessInfo.processInfo.systemUptime
        guard let copied = TrustedPixelCopy.copy(buffer) else {
            lastLearningDiagnostics = ["reason": "trusted_history_copy_failed", "history_count": trustedViews.count,
                "captured_at": capturedAt, "native_learning_performed": false]
            return
        }
        trustedViews.append(TrustedView(buffer: copied, rect: measurement.rect, capturedAt: capturedAt))
        if trustedViews.count > 7 { trustedViews.removeFirst() }
        lastLearningDiagnostics = ["reason": "trusted_history_cached", "history_count": trustedViews.count,
            "captured_at": capturedAt, "native_learning_performed": false,
            "copy_ms": (ProcessInfo.processInfo.systemUptime - copyStartedAt) * 1000,
            "cached_width": CVPixelBufferGetWidth(copied), "cached_height": CVPixelBufferGetHeight(copied)]
    }

    func beginSearch() {
        guard !isSearching else { return } // Repeated watchdog ticks preserve a pending proposal.
        retireResumedTracking()
        proposal = nil
        invalidateReliableSequence()
        identity.resetSearchConfirmation()
        warmingViews = trustedViews
        trustedViews.removeAll(keepingCapacity: true)
        isSearching = true
    }

    /// A fresh original-template result already accepted by main may cancel
    /// a pending search transition. Unaccepted search/HOLD samples cannot
    /// veto it merely because their capture time is newer. The mailbox owns
    /// the request/search-generation check; this owns reliable-position order.
    @discardableResult
    func cancelSearchForLocalRecovery(rect: CGRect, capturedAt: TimeInterval) -> Bool {
        guard !hasResumedTracking, capturedAt.isFinite, Self.validNormalizedBox(rect),
              lastRectAt.map({ capturedAt >= $0 }) ?? true else { return false }
        proposal = nil
        identity.resetSearchConfirmation()
        warmingViews.removeAll(keepingCapacity: true)
        trustedViews.removeAll(keepingCapacity: true)
        invalidateReliableSequence()
        lastRect = rect
        lastRectAt = capturedAt
        lastMeasuredAt = max(lastMeasuredAt ?? capturedAt, capturedAt)
        isSearching = false
        lastLearningDiagnostics = ["reason": "local_original_template_resumed", "captured_at": capturedAt,
            "native_learning_performed": false, "history_count": 0]
        return true
    }

    func observation(buffer: CVPixelBuffer) -> VNDetectedObjectObservation? {
        if isSearching { return CMPhysicalObjectUnavailableWholeObservation(boundingBox: lastRect) }
        guard hasResumedTracking else { return nil }
        return independentWholeObservation(buffer: buffer)
    }

    func measure(buffer: CVPixelBuffer, observation: VNDetectedObjectObservation,
                 capturedAt: TimeInterval) -> CMPhysicalObjectMeasurement {
        guard capturedAt.isFinite, lastMeasuredAt.map({ capturedAt > $0 }) ?? true else {
            identity.resetSearchConfirmation()
            return hold(source: "verified_identity_invalid_frame_hold", diagnostics: ["reason": "nonmonotonic_capture_time"])
        }
        lastMeasuredAt = capturedAt
        if isSearching {
            guard proposal == nil else { return hold(source: "verified_identity_pending_hold", diagnostics: [:]) }
            if !warmingViews.isEmpty {
                // Only previously authorized copies enter the identity model.
                // Import at most one per fresh callback; its historical pixels
                // cannot count as a current confirmation or drive the gimbal.
                let trusted = warmingViews.removeFirst()
                nativeHistoryAddCount += 1
                var diagnostics = identity.addTrustedPixelBuffer(trusted.buffer, rect: trusted.rect)
                diagnostics["history_captured_at"] = trusted.capturedAt
                diagnostics["history_remaining"] = warmingViews.count
                diagnostics["captured_at"] = capturedAt
                diagnostics["native_learning_performed"] = true
                diagnostics["warmup_reason"] = "importing_trusted_history"
                lastLearningDiagnostics = diagnostics
                identity.resetSearchConfirmation()
                return hold(source: "verified_identity_history_warmup_hold", diagnostics: diagnostics)
            }
            let result = identity.findPixelBuffer(buffer, frameToken: capturedAt)
            guard result["accepted"] as? Bool == true,
                  result["recovered_verified_identity"] as? Bool == true,
                  let coordinates = result["bbox"] as? [Double], coordinates.count == 4,
                  let quality = result["quality"] as? Double, quality.isFinite, quality >= 0.9 else {
                return hold(source: "verified_identity_search_hold", diagnostics: result)
            }
            let rect = CGRect(x: coordinates[0], y: coordinates[1], width: coordinates[2], height: coordinates[3])
            guard Self.validNormalizedBox(rect) else {
                identity.resetSearchConfirmation()
                return hold(source: "verified_identity_invalid_candidate_hold", diagnostics: result)
            }
            proposal = Proposal(buffer: buffer, rect: rect, capturedAt: capturedAt)
            return CMPhysicalObjectMeasurement(rect: rect, previousRect: lastRect,
                quality: Float(quality), source: "verified_identity_recovery_proposal", patchDiagnostics: result,
                recoveredVerifiedIdentity: true)
        }
        guard hasResumedTracking, let resumedParts else {
            return hold(source: "verified_identity_inactive_hold", diagnostics: [:])
        }
        let measured = resumedParts.measure(pixels: buffer, full: observation)
        guard !measured.isHeldObservation, measured.quality.isFinite, measured.quality >= 0.5,
              Self.validNormalizedBox(measured.rect), Self.continuous(measured.rect, with: lastRect) else {
            return hold(source: "verified_identity_parts_unconfirmed_hold", diagnostics: measured.patchDiagnostics)
        }
        let previous = lastRect
        lastRect = measured.rect
        lastRectAt = capturedAt
        return CMPhysicalObjectMeasurement(rect: measured.rect, previousRect: previous,
            quality: measured.quality, source: "verified_identity_resume_" + measured.source,
            patchDiagnostics: measured.patchDiagnostics)
    }

    /// Safety has already checked age/request/identity on the main thread.
    /// Seeding is not a new output position: never reapply an age deadline here
    /// after Safety accepted the proposal, which would desynchronize the states.
    /// Always use the retained proposal pixels, never a later caller image.
    @discardableResult
    func commitRecovery(buffer _: CVPixelBuffer, rect: CGRect, capturedAt: TimeInterval) -> Bool {
        guard isSearching, let accepted = proposal, capturedAt == accepted.capturedAt,
              rect.equalTo(accepted.rect) else { return false }
        retireResumedTracking()
        let child = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: accepted.rect))
        child.revision = VNTrackObjectRequestRevision2
        child.trackingLevel = .accurate
        resumedRequest = child
        resumedHandler = VNSequenceRequestHandler()
        let parts = CMPhysicalObjectPartsSession(seed: accepted.rect)
        resumedParts = parts
        let full = independentWholeObservation(buffer: accepted.buffer)
        _ = parts.measure(pixels: accepted.buffer, full: full, initializationOnly: true)
        lastRect = accepted.rect
        lastRectAt = accepted.capturedAt
        proposal = nil
        invalidateReliableSequence()
        identity.resetSearchConfirmation()
        hasResumedTracking = true
        isSearching = false
        return true
    }

    func rejectRecovery(capturedAt: TimeInterval) {
        guard isSearching, proposal?.capturedAt == capturedAt else { return }
        proposal = nil
        identity.resetSearchConfirmation()
    }

    private func independentWholeObservation(buffer: CVPixelBuffer) -> VNDetectedObjectObservation {
        guard let request = resumedRequest, let handler = resumedHandler, let parts = resumedParts else {
            return CMPhysicalObjectUnavailableWholeObservation(boundingBox: lastRect)
        }
        // This helper may retire its failed whole stream. That request belongs
        // solely to this session; the user's original request is only an ID.
        let whole = parts.wholeObservation(request: request, handler: handler, pixels: buffer)
        if !(whole is CMPhysicalObjectUnavailableWholeObservation) { request.inputObservation = whole }
        return whole
    }

    private func retireResumedTracking() {
        if let request = resumedRequest, !request.isLastFrame {
            request.isLastFrame = true
            request.cancel()
        }
        resumedRequest = nil
        resumedHandler = nil
        resumedParts = nil
        hasResumedTracking = false
    }

    private func hold(source: String, diagnostics: [String: Any]) -> CMPhysicalObjectMeasurement {
        CMPhysicalObjectMeasurement(rect: lastRect, previousRect: lastRect, quality: 0.3,
            source: source, patchDiagnostics: diagnostics, isHeldObservation: true)
    }

    private static func strongLearningEvidence(_ measurement: CMPhysicalObjectMeasurement) -> Bool {
        var source = measurement.source
        for prefix in ["verified_identity_resume_", "snapshot_parts_shadow_", "snapshot_parts_"] {
            if source.hasPrefix(prefix) { source.removeFirst(prefix.count); break }
        }
        switch source {
        case "fixed_patch_multiscale", "appearance_patch_multiscale":
            guard measurement.patchDiagnostics["accepted"] as? Bool == true, measurement.quality >= 0.95,
                  let margin = measurement.patchDiagnostics["margin"] as? Double else { return false }
            return margin.isFinite && margin >= 0.12
        case "foreground_color_shape":
            guard measurement.patchDiagnostics["accepted"] as? Bool == true, measurement.quality >= 0.85,
                  let margin = measurement.patchDiagnostics["margin"] as? Double else { return false }
            return margin.isFinite && margin >= 0.15
        case "foreground_features":
            return measurement.patchDiagnostics["accepted"] as? Bool == true && measurement.quality >= 0.95
        case "foreground_instance_vision", "foreground_whole_with_visible_part":
            return measurement.quality >= 0.9
        case "foreground_confirmed_part":
            guard measurement.quality >= 0.8,
                  let similarities = measurement.patchDiagnostics["appearance_similarity"] as? [String: Any] else { return false }
            let support = Set(measurement.patchDiagnostics["support"] as? [String] ?? []).subtracting(["full"])
            return support.contains { name in
                guard let similarity = similarities[name] as? NSNumber else { return false }
                return similarity.doubleValue.isFinite && similarity.doubleValue >= 0.85
            }
        case "foreground_parts_consensus":
            guard measurement.quality >= 0.8 else { return false }
            let support = Set(measurement.patchDiagnostics["support"] as? [String] ?? []).subtracting(["full"])
            let observations = measurement.patchDiagnostics["parts"] as? [[String: Any]] ?? []
            return Set(observations.compactMap { value -> String? in
                guard let name = value["name"] as? String, name != "full", support.contains(name),
                      let quality = value["confidence"] as? NSNumber,
                      quality.doubleValue.isFinite, quality.doubleValue >= 0.75 else { return nil }
                return name
            }).count >= 2
        default:
            return false
        }
    }

    private static func validNormalizedBox(_ rect: CGRect) -> Bool {
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite }),
              (0.002...1).contains(rect.size.width), (0.002...1).contains(rect.size.height),
              (0...1).contains(rect.midX), (0...1).contains(rect.midY) else { return false }
        let visible = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return !visible.isNull && visible.width * visible.height >= rect.width * rect.height * (0.85 - 1e-9)
    }

    private static func continuous(_ rect: CGRect, with previous: CGRect) -> Bool {
        validNormalizedBox(previous) && CMPhysicalObjectPartsSession.continuous(rect, with: previous)
    }

    deinit { retireResumedTracking() }
}
#endif

#if DEBUG
/// Opt-in experiment, confined to dataOutputQueue and one explicit request.
/// Native texture remains authoritative while fixed parts observe the same
/// current pixels. Only previously corroborated parts can bridge a later HOLD.
final class CMPhysicalObjectSnapshotPartsSession {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-KKPhysicalFollowTrustedSnapshotParts")
    let requestIdentity: ObjectIdentifier
    private let native: CMPhysicalObjectPatchSession
    private var parts: CMPhysicalObjectPartsSession?
    private var followingParts = false
    private var shadowCorroboratedFrames = 0
    private var trustedNativeFrames = 0
    private var lastDeliveredRect: CGRect
    private var lastCapturedAt: TimeInterval?
    private var seedDiagnostics: [String: Any] = [:]

    init(request: VNTrackObjectRequest, native: CMPhysicalObjectPatchSession, selection: CGRect) {
        requestIdentity = ObjectIdentifier(request)
        precondition(native.requestIdentity == requestIdentity)
        self.native = native
        lastDeliveredRect = selection
    }

    // A warm shadow must not bypass the main Vision/native observation route.
    var usesParts: Bool { followingParts && parts != nil }
    var unavailableVisionObservation: VNDetectedObjectObservation? {
        guard usesParts || native.unavailableVisionObservation != nil else { return nil }
        return CMPhysicalObjectUnavailableWholeObservation(boundingBox: lastDeliveredRect)
    }

    func measure(buffer: CVPixelBuffer, vision: VNDetectedObjectObservation,
                 capturedAt: TimeInterval) -> CMPhysicalObjectMeasurement {
        guard capturedAt.isFinite, lastCapturedAt.map({ capturedAt > $0 }) ?? true else {
            trustedNativeFrames = 0
            shadowCorroboratedFrames = 0
            native.resetFrozenRecoveryConfirmation()
            return hold(source: "snapshot_parts_shadow_invalid_frame_hold",
                        diagnostics: ["reason": "nonmonotonic_capture_time"])
        }
        lastCapturedAt = capturedAt
        if usesParts { return measureActiveParts(buffer: buffer, capturedAt: capturedAt) }

        let measured = native.measure(buffer: buffer, vision: vision)
        if measured.recoveredOriginalTemplate { return recovered(measured) }
        if !measured.isHeldObservation, measured.quality.isFinite, measured.quality >= 0.5 {
            native.resetFrozenRecoveryConfirmation()
            observeShadowOrSeed(buffer: buffer, capturedAt: capturedAt, nativeMeasurement: measured)
            var output = measured
            output.patchDiagnostics["shadow_parts_present"] = parts != nil
            output.patchDiagnostics["shadow_corroborated_frames"] = shadowCorroboratedFrames
            output.patchDiagnostics["shadow_native_seed_streak"] = trustedNativeFrames
            return deliver(output)
        }

        trustedNativeFrames = 0
        if let parts {
            let priorConfirmations = shadowCorroboratedFrames
            let current = parts.measure(pixels: buffer,
                full: CMPhysicalObjectUnavailableWholeObservation(boundingBox: lastDeliveredRect))
            var diagnostics = partDiagnostics(current, capturedAt: capturedAt)
            diagnostics["shadow_prior_corroborated_frames"] = priorConfirmations
            if measured.isHeldObservation, native.canRecoverFrozen, priorConfirmations >= 3,
               Self.corroborated(current), Self.mutuallyContinuous(current.rect, lastDeliveredRect) {
                followingParts = true
                shadowCorroboratedFrames = 0
                native.resetFrozenRecoveryConfirmation()
                // Establish Safety's stopped confirmation state before a later
                // parts position or original-template recovery can be delivered.
                return hold(source: "snapshot_parts_shadow_handoff_hold", diagnostics: diagnostics)
            }
            retireParts()
        }
        // No model may be created or reseeded on uncertain pixels. The original
        // native route retains its existing thresholds and recovery behavior.
        return deliver(measured)
    }

    private func observeShadowOrSeed(buffer: CVPixelBuffer, capturedAt: TimeInterval,
                                     nativeMeasurement: CMPhysicalObjectMeasurement) {
        guard Self.isTexture(nativeMeasurement), native.canRecoverFrozen else {
            retireParts()
            return
        }
        if let parts {
            let shadow = parts.measure(pixels: buffer,
                full: CMPhysicalObjectUnavailableWholeObservation(boundingBox: nativeMeasurement.rect))
            if Self.corroborated(shadow), Self.sameFrameAgreement(shadow.rect, nativeMeasurement.rect) {
                shadowCorroboratedFrames = min(3, shadowCorroboratedFrames + 1)
            } else {
                // Even a strong native frame cannot reseed in this retirement
                // frame. Three new trusted native frames are required again.
                retireParts()
            }
            return
        }
        guard nativeMeasurement.patchDiagnostics["accepted"] as? Bool == true,
              nativeMeasurement.quality >= 0.95,
              let margin = nativeMeasurement.patchDiagnostics["margin"] as? Double,
              margin.isFinite, margin >= 0.12,
              Self.continuous(nativeMeasurement.rect, with: lastDeliveredRect),
              Self.sufficientlyVisible(nativeMeasurement.rect) else {
            trustedNativeFrames = 0
            return
        }
        trustedNativeFrames += 1
        guard trustedNativeFrames >= 3 else { return }
        let seeded = CMPhysicalObjectPartsSession(seed: nativeMeasurement.rect)
        _ = seeded.measure(pixels: buffer,
            full: CMPhysicalObjectUnavailableWholeObservation(boundingBox: nativeMeasurement.rect), initializationOnly: true)
        parts = seeded
        trustedNativeFrames = 0
        shadowCorroboratedFrames = 0 // Initialization is never a current vote.
        seedDiagnostics = ["shadow_seed_captured_at": capturedAt,
            "shadow_seed_score": nativeMeasurement.quality, "shadow_seed_margin": margin,
            "shadow_seed_bbox": [nativeMeasurement.rect.minX, nativeMeasurement.rect.minY,
                                  nativeMeasurement.rect.width, nativeMeasurement.rect.height].map(Double.init)]
    }

    private func measureActiveParts(buffer: CVPixelBuffer, capturedAt: TimeInterval) -> CMPhysicalObjectMeasurement {
        var searchedFrozen = false
        defer { if !searchedFrozen { native.resetFrozenRecoveryConfirmation() } }
        guard let parts else { return hold(source: "snapshot_parts_shadow_missing_hold", diagnostics: [:]) }
        let measured = parts.measure(pixels: buffer,
            full: CMPhysicalObjectUnavailableWholeObservation(boundingBox: lastDeliveredRect))
        var diagnostics = partDiagnostics(measured, capturedAt: capturedAt)
        if !measured.isHeldObservation, measured.quality.isFinite, measured.quality >= 0.5,
           Self.continuous(measured.rect, with: lastDeliveredRect) {
            return deliver(CMPhysicalObjectMeasurement(rect: measured.rect, previousRect: lastDeliveredRect,
                quality: measured.quality, source: "snapshot_parts_shadow_" + measured.source,
                patchDiagnostics: diagnostics, supportsCenterRecovery: native.canRecoverFrozen))
        }
        if native.canRecoverFrozen {
            let frozen = native.recoverFrozen(buffer: buffer, frameToken: capturedAt)
            searchedFrozen = true
            if frozen.recoveredOriginalTemplate { return recovered(frozen) }
            diagnostics["frozen_recovery"] = frozen.patchDiagnostics
        }
        return hold(source: "snapshot_parts_shadow_unconfirmed_hold", diagnostics: diagnostics)
    }

    private func partDiagnostics(_ measured: CMPhysicalObjectMeasurement, capturedAt: TimeInterval) -> [String: Any] {
        var result = measured.patchDiagnostics
        for (key, value) in seedDiagnostics { result[key] = value }
        result["parts_source"] = measured.source
        result["parts_captured_at"] = capturedAt
        return result
    }

    private func retireParts() {
        parts = nil
        followingParts = false
        shadowCorroboratedFrames = 0
        trustedNativeFrames = 0
        seedDiagnostics = [:]
    }

    private func recovered(_ measured: CMPhysicalObjectMeasurement) -> CMPhysicalObjectMeasurement {
        retireParts()
        return deliver(CMPhysicalObjectMeasurement(rect: measured.rect, previousRect: lastDeliveredRect,
            quality: measured.quality, source: "snapshot_parts_shadow_original_template_recovery",
            patchDiagnostics: measured.patchDiagnostics, supportsCenterRecovery: measured.supportsCenterRecovery,
            recoveredOriginalTemplate: true))
    }

    private func deliver(_ measured: CMPhysicalObjectMeasurement) -> CMPhysicalObjectMeasurement {
        if measured.isHeldObservation {
            return hold(source: "snapshot_parts_shadow_" + measured.source, diagnostics: measured.patchDiagnostics)
        }
        let previous = lastDeliveredRect
        if measured.quality.isFinite, measured.quality >= 0.5 { lastDeliveredRect = measured.rect }
        return CMPhysicalObjectMeasurement(rect: measured.rect, previousRect: previous,
            quality: measured.quality, source: measured.source, patchDiagnostics: measured.patchDiagnostics,
            supportsCenterRecovery: measured.supportsCenterRecovery,
            recoveredOriginalTemplate: measured.recoveredOriginalTemplate)
    }

    private func hold(source: String, diagnostics: [String: Any]) -> CMPhysicalObjectMeasurement {
        CMPhysicalObjectMeasurement(rect: lastDeliveredRect, previousRect: lastDeliveredRect,
            quality: 0.3, source: source, patchDiagnostics: diagnostics,
            isHeldObservation: true, supportsCenterRecovery: native.canRecoverFrozen)
    }

    private static func isTexture(_ measured: CMPhysicalObjectMeasurement) -> Bool {
        measured.source == "fixed_patch_multiscale" || measured.source == "appearance_patch_multiscale"
    }

    private static func corroborated(_ measured: CMPhysicalObjectMeasurement) -> Bool {
        guard !measured.isHeldObservation, measured.quality.isFinite, measured.quality >= 0.75 else { return false }
        let support = Set(measured.patchDiagnostics["support"] as? [String] ?? []).subtracting(["full"])
        let observations = measured.patchDiagnostics["parts"] as? [[String: Any]] ?? []
        let realNames = Set(observations.compactMap { value -> String? in
            guard let name = value["name"] as? String, name != "full", support.contains(name),
                  let confidence = value["confidence"] as? NSNumber,
                  confidence.doubleValue.isFinite, confidence.doubleValue >= 0.5 else { return nil }
            return name
        })
        return realNames.count >= 2
    }

    private static func mutuallyContinuous(_ first: CGRect, _ second: CGRect) -> Bool {
        continuous(first, with: second) && continuous(second, with: first)
    }

    private static func sameFrameAgreement(_ first: CGRect, _ second: CGRect) -> Bool {
        guard mutuallyContinuous(first, second) else { return false }
        let widthRatio = first.width / second.width, heightRatio = first.height / second.height
        // Same pixels require geometric agreement, not the wider inter-frame
        // motion allowance. Its 0.04 floor could match disjoint small objects.
        return (2.0 / 3.0...1.5).contains(widthRatio) && (2.0 / 3.0...1.5).contains(heightRatio)
            && abs(first.midX - second.midX) <= max(first.width, second.width) * 0.2
            && abs(first.midY - second.midY) <= max(first.height, second.height) * 0.2
    }

    private static func continuous(_ rect: CGRect, with previous: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite })
            && rect.width >= 0.002 && rect.height >= 0.002
            && CMPhysicalObjectPartsSession.continuous(rect, with: previous)
    }

    private static func sufficientlyVisible(_ rect: CGRect) -> Bool {
        let visible = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return !visible.isNull && visible.width * visible.height >= rect.width * rect.height * (0.85 - 1e-9)
    }
}
#endif

/// Refine the explicit selection once; never search
/// the rest of the scene or acquire a replacement object after tracking starts.
enum CMPhysicalObjectForegroundSelection {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-KKPhysicalFollowForegroundSelection")

    static func refine(_ pixels: CVPixelBuffer, selection: CGRect) -> (rect: CGRect, diagnostics: [String: Any])? {
        guard #available(iOS 17.0, *) else { return nil }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let source = CIImage(cvPixelBuffer: pixels)
            let scale = min(1, 640 / max(source.extent.width, source.extent.height))
            let image = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let selected = CGRect(x: selection.minX * image.extent.width, y: selection.minY * image.extent.height,
                width: selection.width * image.extent.width, height: selection.height * image.extent.height)
            for expansion in [CGFloat(0.2), CGFloat(0.5)] {
                let completingSelection = expansion > 0.2
                let crop = selected.insetBy(dx: -selected.width * expansion, dy: -selected.height * expansion)
                    .integral.intersection(image.extent)
                guard crop.width >= 16, crop.height >= 16 else { return nil }
                let cropped = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                let handler = VNImageRequestHandler(ciImage: cropped, orientation: .up)
                let request = VNGenerateForegroundInstanceMaskRequest()
                try handler.perform([request])
                guard let observation = request.results?.first,
                      (1...4).contains(observation.allInstances.count) else { continue }
                var candidates: [(rect: CGRect, area: Int)] = []
                for instance in observation.allInstances {
                    let mask = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler)
                    guard CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent32Float else { continue }
                    CVPixelBufferLockBaseAddress(mask, .readOnly)
                    defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
                    let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask)
                    let stride = CVPixelBufferGetBytesPerRow(mask)
                    guard let base = CVPixelBufferGetBaseAddress(mask) else { continue }
                    var minX = width, minY = height, maxX = -1, maxY = -1, area = 0, inside = 0, centerHits = 0
                    for y in 0..<height {
                        let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
                        for x in 0..<width where row[x] >= 0.7 {
                            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                            area += 1
                            if selected.contains(CGPoint(x: crop.minX + CGFloat(x) + 0.5,
                                                         y: crop.minY + CGFloat(height - 1 - y) + 0.5)) { inside += 1 }
                            if abs(crop.minX + CGFloat(x) + 0.5 - selected.midX) <= 1.5,
                               abs(crop.minY + CGFloat(height - 1 - y) + 0.5 - selected.midY) <= 1.5 { centerHits += 1 }
                        }
                    }
                    guard area >= 64, Double(inside) >= Double(area) * (completingSelection ? 0.5 : 0.9),
                          !completingSelection || centerHits >= 5,
                          maxX >= minX, maxY >= minY else { continue }
                    // A slightly incomplete manual box may be completed only in
                    // this bounded second crop. Never accept a cut-off instance.
                    if completingSelection && (minX < 2 || minY < 2 || maxX >= width - 2 || maxY >= height - 2) { continue }
                    let rect = CGRect(x: crop.minX + CGFloat(minX), y: crop.minY + CGFloat(height - 1 - maxY),
                                      width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
                    guard rect.width >= selected.width * 0.3, rect.height >= selected.height * 0.3,
                          rect.width <= selected.width * (completingSelection ? 1.5 : 1.05),
                          rect.height <= selected.height * (completingSelection ? 1.5 : 1.05),
                          rect.width * rect.height >= selected.width * selected.height * 0.15,
                          Double(area) >= Double(rect.width * rect.height) * 0.3,
                          (completingSelection || (abs(rect.midX - selected.midX) <= selected.width * 0.35 &&
                           abs(rect.midY - selected.midY) <= selected.height * 0.35)) else { continue }
                    candidates.append((rect, area))
                }
                candidates.sort { $0.area > $1.area }
                guard let best = candidates.first,
                      candidates.count == 1 || Double(candidates[1].area) <= Double(best.area) * 0.5 else { continue }
                let box = CGRect(x: best.rect.minX / image.extent.width, y: best.rect.minY / image.extent.height,
                                 width: best.rect.width / image.extent.width, height: best.rect.height / image.extent.height)
                return (box, ["refinement_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000,
                    "refined_bbox": [box.minX, box.minY, box.width, box.height].map { Double($0) },
                    "foreground_pixels": best.area, "eligible_instances": candidates.count,
                    "selection_completed": completingSelection])
            }
            kkLog("event=physical_selection_refinement_declined reason=no_unique_bounded_instance selection=\(selection)")
            return nil
        } catch {
            kkLog("event=physical_selection_refinement_declined error=\(error)")
            return nil
        }
    }
}

/// Independent, fixed-identity parts of the initial foreground.
/// Parts are never reseeded on a later image. A surviving part can maintain an
/// already corroborated identity only with an independent frozen appearance
/// match; it cannot initialize tracking. Unconfirmed holds never authorize motion.
final class CMPhysicalObjectPartsSession {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-KKPhysicalFollowPartConsensus")
    struct Observation {
        let name: String
        let fraction: CGRect
        let rect: CGRect
        let confidence: Float
    }
    private final class Part {
        let name: String
        let fraction: CGRect
        let request: VNTrackObjectRequest
        let handler = VNSequenceRequestHandler()
        var active = true
        var referenceAppearance: Appearance?
        var attemptedReference = false
        var confirmations = 0
        init(name: String, fraction: CGRect, seed: CGRect) {
            self.name = name
            self.fraction = fraction
            request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox:
                CGRect(x: seed.minX + fraction.minX * seed.width, y: seed.minY + fraction.minY * seed.height,
                       width: seed.width * fraction.width, height: seed.height * fraction.height)))
            request.revision = VNTrackObjectRequestRevision2
        }
        func stop() { active = false; request.isLastFrame = true; request.cancel() }
        deinit { stop() }
    }
    let seed: CGRect
    private var lastRect: CGRect
    private var parts: [Part]
    private var usedPartSupport = false
    private var hasDeliveredMeasurement = false
    private var wholeFailure: String?
    private let appearanceContext = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])
    var confirmedPartCount: Int { parts.filter { $0.confirmations >= 6 }.count }

    struct Appearance {
        let bins: [Float]
        let colorful: Float
        func similarity(to other: Appearance) -> Float {
            zip(bins, other.bins).reduce(Float(0)) { $0 + sqrt($1.0 * $1.1) }
        }

        // A scale-independent veto for a local measurement, never a search
        // criterion. A plain wall or wrong-colored object cannot inherit a
        // colorful target just because Vision's box remains continuous.
        func allowsContinuity(with other: Appearance) -> Bool {
            guard similarity(to: other) >= 0.60 else { return false }
            guard colorful >= 0.10 else { return true }
            var common: Float = 0
            for hue in 0..<12 {
                let i = 2 * hue
                common += min(bins[i] + bins[i + 1], other.bins[i] + other.bins[i + 1])
            }
            return common >= 0.28 * colorful
        }
    }
    func appearance(pixels: CVPixelBuffer, rect: CGRect) -> Appearance? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let source = CIImage(cvPixelBuffer: pixels)
        let crop = CGRect(x: rect.minX * source.extent.width, y: rect.minY * source.extent.height,
            width: rect.width * source.extent.width, height: rect.height * source.extent.height)
        let visible = crop.intersection(source.extent)
        guard !visible.isNull, visible.width * visible.height >= crop.width * crop.height * 0.85 else { return nil }
        let image = source.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: 24 / crop.width, y: 24 / crop.height))
        var bytes = [UInt8](repeating: 0, count: 24 * 24 * 4)
        bytes.withUnsafeMutableBytes {
            appearanceContext.render(image, toBitmap: $0.baseAddress!, rowBytes: 24 * 4,
                bounds: CGRect(x: 0, y: 0, width: 24, height: 24), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        var bins = [Float](repeating: 0, count: 28), colorful: Float = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let r = Float(bytes[i]) / 255, g = Float(bytes[i + 1]) / 255, b = Float(bytes[i + 2]) / 255
            let high = max(r, max(g, b)), low = min(r, min(g, b)), delta = high - low
            let saturation = high > 0 ? delta / high : 0
            let bin: Int
            if saturation < 0.2 { bin = 24 + min(3, Int(high * 4)) }
            else {
                var hue = high == r ? (g - b) / delta : (high == g ? 2 + (b - r) / delta : 4 + (r - g) / delta)
                if hue < 0 { hue += 6 }
                bin = min(11, Int(hue * 2)) * 2 + (saturation >= 0.55 ? 1 : 0)
                colorful += 1
            }
            bins[bin] += 1 / Float(24 * 24)
        }
        return Appearance(bins: bins, colorful: colorful / Float(24 * 24))
    }

    static func permitsSinglePart(confirmedFrames: Int, confidence: Float, similarity: Float, colorful: Float) -> Bool {
        confirmedFrames >= 6 && confidence.isFinite && confidence >= 0.75 &&
            similarity.isFinite && similarity >= 0.75 && colorful.isFinite && colorful >= 0.2
    }
    static func continuous(_ box: CGRect, with previous: CGRect) -> Bool {
        guard previous.width > 0, previous.height > 0, box.width > 0, box.height > 0 else { return false }
        let ratio = box.width * box.height / (previous.width * previous.height)
        return ratio.isFinite && (0.5...2).contains(ratio) &&
            abs(box.midX - previous.midX) <= max(0.04, previous.width * 0.5) &&
            abs(box.midY - previous.midY) <= max(0.04, previous.height * 0.5)
    }
    init(seed: CGRect) {
        self.seed = seed
        lastRect = seed
        parts = [
            Part(name: "top", fraction: CGRect(x: 0.1, y: 0.7, width: 0.8, height: 0.3), seed: seed),
            Part(name: "middle", fraction: CGRect(x: 0.05, y: 0.35, width: 0.9, height: 0.3), seed: seed),
            Part(name: "bottom", fraction: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.3), seed: seed),
            Part(name: "upper_detail", fraction: CGRect(x: 0.2, y: 0.86, width: 0.6, height: 0.14), seed: seed),
            Part(name: "lower_detail", fraction: CGRect(x: 0.1, y: 0.15, width: 0.8, height: 0.3), seed: seed)
        ]
    }
    func wholeObservation(request: VNTrackObjectRequest, handler: VNSequenceRequestHandler,
                          pixels: CVPixelBuffer) -> VNDetectedObjectObservation {
        if wholeFailure == nil {
            do {
                try handler.perform([request], on: pixels)
                if let observation = request.results?.first as? VNDetectedObjectObservation,
                   observation.boundingBox.width > 0, observation.boundingBox.height > 0,
                   [observation.boundingBox.minX, observation.boundingBox.minY,
                    observation.boundingBox.width, observation.boundingBox.height].allSatisfy({ $0.isFinite }) {
                    return observation
                }
                wholeFailure = "empty_or_invalid_whole_box"
            } catch { wholeFailure = error.localizedDescription }
            // Keep the identity token, but retire this failed Vision stream.
            // Existing parts still measure fresh pixels; no tracker is reseeded.
            request.isLastFrame = true
            request.cancel()
        }
        return CMPhysicalObjectUnavailableWholeObservation(boundingBox: lastRect)
    }
    func measure(pixels: CVPixelBuffer, full: VNDetectedObjectObservation, lastFrame: Bool = false,
                 initializationOnly: Bool = false) -> CMPhysicalObjectMeasurement {
        var observations = [Observation(name: "full", fraction: CGRect(x: 0, y: 0, width: 1, height: 1),
            rect: full.boundingBox, confidence: full.confidence)]
        var errors: [String] = []
        for part in parts where part.active {
            do {
                if !part.attemptedReference {
                    part.attemptedReference = true
                    part.referenceAppearance = appearance(pixels: pixels, rect: part.request.inputObservation.boundingBox)
                }
                part.request.isLastFrame = lastFrame
                try part.handler.perform([part.request], on: pixels, orientation: .up)
                guard let result = part.request.results?.first as? VNDetectedObjectObservation,
                      result.confidence > 0, result.boundingBox.width > 0, result.boundingBox.height > 0 else {
                    part.stop(); continue
                }
                part.request.inputObservation = result
                observations.append(Observation(name: part.name, fraction: part.fraction,
                    rect: result.boundingBox, confidence: result.confidence))
            } catch {
                errors.append(part.name + ":" + String(describing: error))
                part.stop()
            }
        }
        let previous = lastRect
        var fused = Self.fuse(seed: seed, observations: observations)
        var similarities: [String: Float] = [:]
        var discardedSource: String?
        if let candidate = fused,
           (hasDeliveredMeasurement && !Self.continuous(candidate.rect, with: previous)) ||
            (usedPartSupport && candidate.source == "foreground_instance_vision" && candidate.quality < 0.75) {
            discardedSource = candidate.source
            fused = nil
        }
        if fused == nil {
            var bridges: [(rect: CGRect, quality: Float, source: String, support: [String])] = []
            for part in parts where part.active && part.confirmations >= 6 {
                guard let observation = observations.first(where: { $0.name == part.name }),
                      observation.confidence >= 0.75,
                      let projection = Self.project(seed: seed, observation: observation),
                      Self.continuous(projection.rect, with: previous),
                      let reference = part.referenceAppearance,
                      let current = appearance(pixels: pixels, rect: observation.rect) else { continue }
                let similarity = reference.similarity(to: current)
                similarities[part.name] = similarity
                guard Self.permitsSinglePart(confirmedFrames: part.confirmations,
                    confidence: observation.confidence, similarity: similarity, colorful: reference.colorful) else { continue }
                // A different, strong current part must not contradict this
                // identity. Weak/lost whole-object boxes are not such evidence.
                let contradicted = observations.contains { other in
                    guard other.name != part.name, other.confidence >= 0.75 else { return false }
                    if other.name == "full" {
                        let overlap = other.rect.intersection(projection.rect)
                        return overlap.isNull || overlap.width * overlap.height <
                            min(other.rect.width * other.rect.height, projection.rect.width * projection.rect.height) * 0.5
                    }
                    guard
                          let otherProjection = Self.project(seed: seed, observation: other) else { return false }
                    let disagrees = abs(otherProjection.rect.midX - projection.rect.midX) > max(otherProjection.rect.width, projection.rect.width) * 0.5 ||
                        abs(otherProjection.rect.midY - projection.rect.midY) > max(otherProjection.rect.height, projection.rect.height) * 0.35
                    guard disagrees else { return false }
                    // A native tracker can confidently drift onto a different
                    // surface. Only its original appearance can make that
                    // conflicting part evidence against a verified survivor.
                    guard let otherPart = parts.first(where: { $0.name == other.name }),
                          let reference = otherPart.referenceAppearance,
                          let current = appearance(pixels: pixels, rect: other.rect) else { return true }
                    let otherSimilarity = reference.similarity(to: current)
                    similarities[other.name] = otherSimilarity
                    return otherSimilarity >= 0.75
                }
                guard !contradicted else { continue }
                bridges.append((projection.rect, min(observation.confidence, similarity), "foreground_confirmed_part", [part.name]))
            }
            bridges.sort { $0.quality > $1.quality }
            fused = bridges.first
        }
        if let accepted = fused {
            if accepted.source != "foreground_instance_vision" { usedPartSupport = true }
            // Only an independent whole-object measurement or a multi-part
            // consensus can establish trust; a part never confirms itself.
            if accepted.quality >= 0.75 && accepted.source != "foreground_confirmed_part" {
                for part in parts where part.active {
                    guard let observation = observations.first(where: { $0.name == part.name }),
                          observation.confidence >= 0.75,
                          let projected = Self.project(seed: seed, observation: observation),
                          abs(projected.rect.midX - accepted.rect.midX) <= accepted.rect.width * 0.35,
                          abs(projected.rect.midY - accepted.rect.midY) <= accepted.rect.height * 0.35 else {
                        if part.confirmations < 6 { part.confirmations = 0 }
                        continue
                    }
                    part.confirmations = min(6, part.confirmations + 1)
                }
            }
        }
        let box = fused?.rect ?? previous
        let quality = fused?.quality ?? 0.3
        if quality >= 0.5 { lastRect = box }
        // Initialization is never a previously delivered control position.
        let deliveredPrevious = hasDeliveredMeasurement ? previous : box
        if !initializationOnly { hasDeliveredMeasurement = true }
        return CMPhysicalObjectMeasurement(rect: box, previousRect: deliveredPrevious, quality: quality,
            source: fused?.source ?? "foreground_parts_unconfirmed", patchDiagnostics: [
                "support": fused?.support ?? [], "part_errors": errors,
                "whole_failure": wholeFailure ?? "none",
                "appearance_similarity": similarities, "confirmed_parts": parts.filter { $0.confirmations >= 6 }.map { $0.name },
                "discarded_source": discardedSource ?? "none",
                "parts": observations.map { ["name": $0.name, "confidence": $0.confidence,
                    "bbox": [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height].map { Double($0) }] }
            ], isHeldObservation: fused == nil)
    }
    static func project(seed: CGRect, observation obs: Observation,
                        maximumAspectChange: CGFloat = 1.8) -> (rect: CGRect, scale: CGFloat)? {
        let f = obs.fraction, b = obs.rect
        guard seed.width > 0, seed.height > 0, obs.confidence.isFinite, obs.confidence >= 0.5,
              [b.minX, b.minY, b.width, b.height, f.minX, f.minY, f.width, f.height].allSatisfy({ $0.isFinite }),
              b.width > 0, b.height > 0, f.width > 0, f.height > 0 else { return nil }
        let sx = b.width / (seed.width * f.width), sy = b.height / (seed.height * f.height)
        guard min(sx, sy) >= 0.4, max(sx, sy) <= 2.5,
              max(sx / sy, sy / sx) <= maximumAspectChange else { return nil }
        let scale = sqrt(sx * sy), width = seed.width * scale, height = seed.height * scale
        return (CGRect(x: b.midX - f.midX * width, y: b.midY - f.midY * height, width: width, height: height), scale)
    }
    static func fuse(seed: CGRect, observations: [Observation]) -> (rect: CGRect, quality: Float, source: String, support: [String])? {
        struct Candidate {
            let raw: Observation
            let center: CGPoint
            let scale: CGFloat
            let size: CGSize
        }
        guard seed.width > 0, seed.height > 0 else { return nil }
        let candidates = observations.compactMap { obs -> Candidate? in
            // Local boxes can stretch during perspective/partial occlusion.
            // This wider model is usable only with another agreeing part;
            // single-part authority retains the stricter projection above.
            guard let projected = project(seed: seed, observation: obs,
                maximumAspectChange: obs.name == "full" ? 1.8 : 2.5) else { return nil }
            return Candidate(raw: obs, center: CGPoint(x: projected.rect.midX, y: projected.rect.midY),
                scale: projected.scale, size: projected.rect.size)
        }
        let full = candidates.first { $0.raw.name == "full" }
        if let full, full.raw.confidence >= 0.75 {
            return (full.raw.rect, full.raw.confidence, "foreground_instance_vision", ["full"])
        }
        func agrees(_ a: Candidate, _ b: Candidate) -> Bool {
            abs(a.center.x - b.center.x) <= max(a.size.width, b.size.width) * 0.5 &&
            abs(a.center.y - b.center.y) <= max(a.size.height, b.size.height) * 0.35 &&
            max(a.scale / b.scale, b.scale / a.scale) <= 1.6
        }
        var groups: [[Candidate]] = []
        for mask in 0..<(1 << candidates.count) where mask.nonzeroBitCount >= 2 {
            let group = candidates.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            guard group.allSatisfy({ a in group.allSatisfy { b in agrees(a, b) } }) else { continue }
            groups.append(group)
        }
        groups.sort { $0.reduce(Float(0)) { $0 + $1.raw.confidence } > $1.reduce(Float(0)) { $0 + $1.raw.confidence } }
        if let best = groups.first {
            let quality = best.reduce(Float(0)) { $0 + $1.raw.confidence } / Float(best.count)
            guard quality >= 0.6 else { return nil }
            // Two disjoint, comparably strong groups are ambiguous. The
            // previous location must not break a tie between moving objects.
            let names = Set(best.map { $0.raw.name })
            if groups.dropFirst().contains(where: { group in
                Set(group.map { $0.raw.name }).isDisjoint(with: names) &&
                group.reduce(Float(0)) { $0 + $1.raw.confidence } / Float(group.count) >= quality - 0.1
            }) { return nil }
            let mass = best.reduce(CGFloat(0)) { $0 + CGFloat($1.raw.confidence * $1.raw.confidence) }
            func mean(_ get: (Candidate) -> CGFloat) -> CGFloat {
                best.reduce(CGFloat(0)) { $0 + get($1) * CGFloat($1.raw.confidence * $1.raw.confidence) } / mass
            }
            let width = mean { $0.size.width }, height = mean { $0.size.height }
            let box = CGRect(x: mean { $0.center.x } - width / 2, y: mean { $0.center.y } - height / 2,
                             width: width, height: height)
            return (box, quality, "foreground_parts_consensus", best.map { $0.raw.name })
        }
        if let full { return (full.raw.rect, full.raw.confidence, "foreground_instance_vision", ["full"]) }
        // A genuine viewpoint change can violate the rigid part-scale model.
        // Keep a strong whole-object observation only when a distinct, usable
        // current-frame part is still well inside it. Do not turn this into a
        // low-confidence fallback or extrapolate from a lone part.
        if let whole = observations.first(where: { $0.name == "full" && $0.confidence.isFinite && $0.confidence >= 0.75 }),
           whole.rect.width > 0, whole.rect.height > 0,
           [whole.rect.minX, whole.rect.minY, whole.rect.width, whole.rect.height].allSatisfy({ $0.isFinite }),
           let detail = observations.first(where: { part in
               guard part.name != "full", part.confidence.isFinite, part.confidence >= 0.65,
                     part.rect.width > 0, part.rect.height > 0,
                     [part.rect.minX, part.rect.minY, part.rect.width, part.rect.height].allSatisfy({ $0.isFinite }) else { return false }
               let area = part.rect.width * part.rect.height
               let overlap = part.rect.intersection(whole.rect)
               return !overlap.isNull && overlap.width * overlap.height >= area * 0.85 &&
                   area >= whole.rect.width * whole.rect.height * 0.08 &&
                   area <= whole.rect.width * whole.rect.height * 0.8
           }) {
            return (whole.rect, min(whole.confidence, detail.confidence), "foreground_whole_with_visible_part", ["full", detail.name])
        }
        return nil
    }
}

#if DEBUG
/// Replays saved failure JPEGs through both native tracker revisions. Uses the
/// same recorded first box once; never uses later boxes to correct the tracker.
final class CMPhysicalObjectScaleProbe {
    final class RecordedObservation: VNDetectedObjectObservation {
        var recordedConfidence: Float = 0
        override var confidence: VNConfidence { recordedConfidence }
    }

    private static func negativeChecks() -> [String: Bool] {
        func pixels(_ kind: Int, _ size: Int = 384) -> CVPixelBuffer {
            var value: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA, nil, &value)
            let buffer = value!
            CVPixelBufferLockBaseAddress(buffer, [])
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            var random: UInt32 = kind == 3 ? 8729 : 193
            for y in 0..<size { for x in 0..<size {
                random = random &* 1664525 &+ 1013904223
                let v: UInt8 = kind == 0 ? 180 : (kind == 1 ? (((x / 8 + y / 8) % 2 == 0) ? 32 : 224) : UInt8(random >> 24))
                let p = y * stride + x * 4
                let changed = (kind == 4 && (x + y) % 29 == 0) || (kind == 5 && (175..<178).contains(x)) || (kind == 6 && (175..<180).contains(x))
                let value = changed ? 255 - v : v
                bytes[p] = value; bytes[p + 1] = value; bytes[p + 2] = value; bytes[p + 3] = 255
            }}
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return buffer
        }
        let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let blank = pixels(0), periodic = pixels(1), unique = pixels(2), unrelated = pixels(3)
        let tracker = CMPhysicalObjectPatchTracker(pixelBuffer: unique, selection: box)
        let duplicate = CMPhysicalObjectPatchTracker(pixelBuffer: periodic, selection: box)
        let raw = VNDetectedObjectObservation(boundingBox: box)
        let request = VNTrackObjectRequest(detectedObjectObservation: raw)
        let session = CMPhysicalObjectPatchSession(request: request, buffer: unique, selection: box)
        let measured = session.measure(buffer: unique, vision: raw)
        let held = session.measure(buffer: blank, vision: raw)
        let staticTracker = CMPhysicalObjectPatchTracker(pixelBuffer: unique, selection: box)!
        let staticStable = (0..<20).allSatisfy { _ in
            let result = staticTracker.trackPixelBuffer(unique, referenceRect: box, referenceConfidence: 0.95)
            return result["accepted"] as? Bool == true && result["template_updates"] as? Int == 0
        }
        let changed = pixels(4)
        func refreshCheck(reference: CGRect = box, confidence: Float = 0.95, target: CVPixelBuffer = changed, warmupConfidence: Float = 0.95) -> [String: Any] {
            let adaptive = CMPhysicalObjectPatchTracker(pixelBuffer: unique, selection: box)!
            for _ in 0..<2 { _ = adaptive.trackPixelBuffer(unique, referenceRect: box, referenceConfidence: warmupConfidence) }
            return adaptive.trackPixelBuffer(target, referenceRect: reference, referenceConfidence: confidence)
        }
        let refreshed = refreshCheck()
        let disagreement = refreshCheck(reference: box.offsetBy(dx: 0.3, dy: 0))
        let weakReference = refreshCheck(confidence: 0.49)
        let sustainedWeakReference = refreshCheck(confidence: 0.55, warmupConfidence: 0.55)
        let usableReference = refreshCheck(confidence: 0.55, warmupConfidence: 0.65)
        let missing = refreshCheck(target: blank)
        let wrongTarget = refreshCheck(target: unrelated)
        let unchanged = refreshCheck(target: unique)
        func featureCheck(target: CVPixelBuffer = changed, reference: CGRect = box,
                          confidence: Float = 0.1, warmupConfidence: Float = 0.95) -> [String: Any] {
            let tracker = CMPhysicalObjectPatchTracker(pixelBuffer: unique, selection: box)!
            for _ in 0..<5 {
                _ = tracker.trackPixelBuffer(unique, referenceRect: box, referenceConfidence: warmupConfidence)
            }
            return tracker.trackPixelBuffer(target, referenceRect: reference, referenceConfidence: confidence)
        }
        let featureBridge = featureCheck()
        let untrustedFeatures = featureCheck(warmupConfidence: 0.1)
        let conflictingFeatures = featureCheck(reference: box.offsetBy(dx: 0.3, dy: 0), confidence: 0.95)
        let missingFeatures = featureCheck(target: blank)
        let unrelatedFeatures = featureCheck(target: unrelated)
        let changedSurface = pixels(5)
        let supportedSurfaceChange = featureCheck(target: changedSurface)
        let unsupportedSurfaceChange = featureCheck(target: changedSurface, warmupConfidence: 0.1)
        // Vision can keep a slightly offset box on the same object. Existing
        // local correspondences must survive that offset, while the separate
        // strong-disagreement test still rejects a different location.
        let overlappingReference = featureCheck(reference: box.offsetBy(dx: 0.06, dy: 0), confidence: 0.95)
        let earlyChangeTracker = CMPhysicalObjectPatchTracker(pixelBuffer: unique, selection: box)!
        for _ in 0..<2 { _ = earlyChangeTracker.trackPixelBuffer(unique, referenceRect: box, referenceConfidence: 0.95) }
        let earlyChange = earlyChangeTracker.trackPixelBuffer(changedSurface, referenceRect: box, referenceConfidence: 0.95)
        let earlyRecovery = earlyChangeTracker.trackPixelBuffer(changedSurface, referenceRect: box, referenceConfidence: 0.95)
        let weakerEarlyChange = refreshCheck(confidence: 0.65, target: changedSurface, warmupConfidence: 0.65)
        let largerSurfaceChange = pixels(6)
        let jointlySupportedChange = featureCheck(target: largerSurfaceChange, confidence: 0.95)
        let featureOnlyLargerChange = featureCheck(target: largerSurfaceChange)
        func acquisitionChange(_ initialConfidence: Float) -> [String: Any] {
            let tracker = CMPhysicalObjectPatchTracker(pixelBuffer: unique, selection: box)!
            _ = tracker.trackPixelBuffer(unique, referenceRect: box, referenceConfidence: initialConfidence)
            return tracker.trackPixelBuffer(largerSurfaceChange, referenceRect: box, referenceConfidence: 0.95)
        }
        let strongAcquisition = acquisitionChange(0.95)
        let weakAcquisition = acquisitionChange(0.7)
        let detailBox = box.insetBy(dx: 0.055, dy: 0.055)
        let containedDetail = featureCheck(reference: detailBox, confidence: 0.95)
        let untrustedDetail = featureCheck(reference: detailBox, confidence: 0.95, warmupConfidence: 0.1)
        let outsideDetail = featureCheck(reference: CGRect(x: box.maxX - 0.04, y: box.midY - 0.04,
            width: 0.08, height: 0.08), confidence: 0.95)
        let tinyDetail = featureCheck(reference: box.insetBy(dx: 0.09, dy: 0.09), confidence: 0.95)
        // Known gradual deformation with deliberately weak Vision: local
        // correspondences must survive appearance change, not just translation.
        let gradualTracker = CMPhysicalObjectPatchTracker(pixelBuffer: unique, selection: box)!
        for _ in 0..<5 { _ = gradualTracker.trackPixelBuffer(unique, referenceRect: box, referenceConfidence: 0.95) }
        let deformationContext = CIContext(options: [.cacheIntermediates: false])
        var gradualPassed = true
        var gradualResult: [String: Any] = [:]
        for step in 1...40 {
            var warped: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 384, 384, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &warped)
            guard let warped else { gradualPassed = false; break }
            let scale = 1 + Double(step) * 0.003
            let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: 1, tx: 192 * (1 - scale), ty: 0)
            deformationContext.render(CIImage(cvPixelBuffer: unique).transformed(by: transform), to: warped)
            gradualResult = gradualTracker.trackPixelBuffer(warped, referenceRect: box, referenceConfidence: 0.1)
            let measuredBox = gradualResult["bbox"] as? [Double] ?? []
            gradualPassed = gradualPassed && gradualResult["accepted"] as? Bool == true && measuredBox.count == 4 &&
                abs(measuredBox[0] + measuredBox[2] / 2 - 0.5) < 0.015 &&
                abs(measuredBox[1] + measuredBox[3] / 2 - 0.5) < 0.015
        }
        let vanishedAfterMotion = gradualTracker.trackPixelBuffer(blank, referenceRect: box, referenceConfidence: 0.1)
        // Known geometric ground truth over an approach/retreat cycle; checking
        // only acceptance would miss a tracker that silently keeps old size.
        let depthSource = CIImage(cvPixelBuffer: unique).applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.7])
        func depthFrame(_ scale: Double) -> CVPixelBuffer {
            var allocated: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 384, 384, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &allocated)
            let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                tx: 192 * (1 - scale), ty: 192 * (1 - scale))
            deformationContext.render(depthSource.transformed(by: transform), to: allocated!)
            return allocated!
        }
        let depthTracker = CMPhysicalObjectPatchTracker(pixelBuffer: depthFrame(1), selection: box)!
        var depthCyclePassed = true
        var reportedDepthFailure = false
        for step in 0...100 {
            let scale = 1 + Double(step <= 50 ? step : 100 - step) * 0.024
            let expected = CGRect(x: 0.5 - 0.1 * scale, y: 0.5 - 0.1 * scale, width: 0.2 * scale, height: 0.2 * scale)
            let result = depthTracker.trackPixelBuffer(depthFrame(scale), referenceRect: expected, referenceConfidence: 0.95)
            let values = result["bbox"] as? [Double] ?? []
            let stepPassed = result["accepted"] as? Bool == true && values.count == 4 &&
                abs(values[0] + values[2] / 2 - 0.5) < 0.015 && abs(values[1] + values[3] / 2 - 0.5) < 0.015 &&
                abs(values[2] / expected.width - 1) < 0.1 && abs(values[3] / expected.height - 1) < 0.1
            if !stepPassed && !reportedDepthFailure {
                print("KK_DEPTH_CYCLE_FIRST_FAILURE step=\(step) expectedScale=\(scale) result=\(result)")
                reportedDepthFailure = true
            }
            depthCyclePassed = depthCyclePassed && stepPassed
        }
        func colorScene(offset: Int = 0, hidden: Bool = false, duplicate: Bool = false,
                        background: UInt8 = 170, reflection: Int = 0,
                        occluded: Bool = false, horizontal: Bool = false) -> CVPixelBuffer {
            let buffer = pixels(0)
            CVPixelBufferLockBaseAddress(buffer, [])
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<384 { for x in 0..<384 {
                let target = horizontal
                    ? (175..<209).contains(y) && (157 + offset..<227 + offset).contains(x)
                    : (157..<227).contains(y) && (175 + offset..<209 + offset).contains(x)
                let gap = reflection == 1 ? (170..<195).contains(y) && x < 192 + offset
                    : reflection == 2 && (195..<220).contains(y) && x > 192 + offset
                let colored = !hidden && ((target && !gap && (!occluded || x < 185 + offset)) ||
                    (duplicate && (157..<227).contains(y) && (213..<247).contains(x)))
                let p = y * stride + x * 4
                bytes[p] = colored ? 210 : background
                bytes[p+1] = colored ? 80 : background
                bytes[p+2] = colored ? 20 : background
                bytes[p+3] = 255
            }}
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return buffer
        }
        let colorBox = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
        let colorSeed = colorScene()
        func colorCheck(_ frame: CVPixelBuffer) -> [String: Any] {
            let tracker = CMPhysicalObjectPatchTracker(pixelBuffer: colorSeed, selection: colorBox)!
            _ = tracker.trackPixelBuffer(colorSeed, referenceRect: colorBox, referenceConfidence: 0.95)
            return tracker.trackPixelBuffer(frame, referenceRect: colorBox, referenceConfidence: 0.1)
        }
        func nv12(_ source: CVPixelBuffer) -> CVPixelBuffer? {
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 384, 384,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
                &buffer) == kCVReturnSuccess, let buffer else { return nil }
            CIContext(options: [.cacheIntermediates: false]).render(CIImage(cvPixelBuffer: source), to: buffer)
            return buffer
        }
        var nv12Passed = false
        if let seed = nv12(colorSeed), let moved = nv12(colorScene(offset: 18, background: 75)),
           let tracker = CMPhysicalObjectPatchTracker(pixelBuffer: seed, selection: colorBox) {
            _ = tracker.trackPixelBuffer(seed, referenceRect: colorBox, referenceConfidence: 0.95)
            let output = tracker.trackPixelBuffer(moved, referenceRect: colorBox, referenceConfidence: 0.1)
            let rect = output["bbox"] as? [Double] ?? []
            nv12Passed = output["accepted"] as? Bool == true && output["measurement_source"] as? String == "foreground_color_shape" && rect.count == 4 && abs(rect[0] - (0.35 + 18.0/384)) < 0.015
        }
        let movedColor = colorCheck(colorScene(offset: 18, background: 75))
        let hiddenColor = colorCheck(colorScene(hidden: true))
        let duplicatedColor = colorCheck(colorScene(duplicate: true))
        let occludedColor = colorCheck(colorScene(occluded: true))
        let wrongShape = colorCheck(colorScene(horizontal: true))
        let reflectionSeed = colorScene(reflection: 1)
        let reflectionTracker = CMPhysicalObjectPatchTracker(pixelBuffer: reflectionSeed, selection: colorBox)!
        _ = reflectionTracker.trackPixelBuffer(reflectionSeed, referenceRect: colorBox, referenceConfidence: 0.95)
        let reflectionMoved = reflectionTracker.trackPixelBuffer(colorScene(offset: 18, background: 75, reflection: 2),
            referenceRect: colorBox, referenceConfidence: 0.1)
        let reflectionBox = reflectionMoved["bbox"] as? [Double] ?? []
        let movedBox = movedColor["bbox"] as? [Double] ?? []
        let centerRecoveryChecks: [String: Bool] = {
            let context = CIContext(options: [.cacheIntermediates: false])
            let extent = CGRect(x: 0, y: 0, width: 384, height: 384)
            let background = CIImage(cvPixelBuffer: blank)
            let tile = CIImage(cvPixelBuffer: unique).cropped(to: CGRect(x: 144, y: 144, width: 96, height: 96))
            func recoveryFrame(_ offsets: [CGFloat]) -> CVPixelBuffer {
                var image = background
                for offset in offsets {
                    image = tile.transformed(by: CGAffineTransform(translationX: offset, y: 0)).composited(over: image)
                }
                var result: CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault, 384, 384, kCVPixelFormatType_32BGRA,
                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result)
                context.render(image.cropped(to: extent), to: result!)
                return result!
            }
            let leftBox = box.offsetBy(dx: -128.0 / 384, dy: 0)
            let leftSeed = recoveryFrame([-128])
            func seededRecoveryTracker() -> CMPhysicalObjectPatchTracker {
                let tracker = CMPhysicalObjectPatchTracker(pixelBuffer: leftSeed, selection: leftBox)!
                _ = tracker.trackPixelBuffer(leftSeed, referenceRect: leftBox, referenceConfidence: 0.1)
                return tracker
            }
            func nearCenter(_ result: [String: Any]) -> Bool {
                let values = result["bbox"] as? [Double] ?? []
                return values.count == 4 && abs(values[0] + values[2] / 2 - 0.5) < 0.015 &&
                    abs(values[1] + values[3] / 2 - 0.5) < 0.015
            }
            let neverAccepted = CMPhysicalObjectPatchTracker(pixelBuffer: leftSeed, selection: leftBox)!
            let unsupportedBeforeLock = !neverAccepted.supportsCenterRecovery &&
                neverAccepted.recoverPixelBuffer(recoveryFrame([0]))["accepted"] as? Bool == false
            let recoveredTracker = seededRecoveryTracker()
            var positive: [[String: Any]] = []
            var localRemainedRejected = true
            var sameObservationCannotConfirm = true
            for step in 0..<3 {
                let returned = recoveryFrame([0]) // distinct frame buffers, same known target
                let local = recoveredTracker.trackPixelBuffer(returned, referenceRect: box, referenceConfidence: 0.1)
                let window = local["search_window"] as? [Int] ?? []
                localRemainedRejected = localRemainedRejected && local["accepted"] as? Bool == false &&
                    local["template_updates"] as? Int == 0 && window.count == 4 && window[0] < 100
                let candidate = recoveredTracker.recoverPixelBuffer(returned)
                positive.append(candidate)
                if step == 0 {
                    for _ in 0..<3 {
                        let repeated = recoveredTracker.recoverPixelBuffer(returned)
                        sameObservationCannotConfirm = sameObservationCannotConfirm &&
                            repeated["accepted"] as? Bool == false &&
                            repeated["reason"] as? String == "center_recovery_duplicate_observation" &&
                            repeated["recovery_confirmations"] as? Int == 1
                    }
                }
            }
            let continuation = recoveredTracker.trackPixelBuffer(recoveryFrame([0]), referenceRect: box, referenceConfidence: 0.1)
            let firstTwoHeld = positive.prefix(2).allSatisfy {
                $0["accepted"] as? Bool == false && $0["reason"] as? String == "center_recovery_confirming" &&
                    $0["recovered_original_template"] == nil && $0["template_updates"] as? Int == 0
            }
            let third = positive.last ?? [:]
            let confirmed = third["accepted"] as? Bool == true && third["recovered_original_template"] as? Bool == true &&
                third["recovery_confirmations"] as? Int == 3 && third["template_updates"] as? Int == 0 &&
                (third["score"] as? Double ?? 0) >= 0.9 && (third["margin"] as? Double ?? 0) >= 0.12 && nearCenter(third)
            let negativeTracker = seededRecoveryTracker()
            func rejectedRecovery(_ buffer: CVPixelBuffer) -> Bool {
                _ = negativeTracker.trackPixelBuffer(buffer, referenceRect: box, referenceConfidence: 0.1)
                let candidate = negativeTracker.recoverPixelBuffer(buffer)
                return candidate["accepted"] as? Bool == false && candidate["recovered_original_template"] == nil &&
                    candidate["recovery_confirmations"] as? Int == 0
            }
            let missingRejected = (0..<3).allSatisfy { _ in rejectedRecovery(recoveryFrame([])) }
            // Second copy is outside the permitted center region. It must still compete.
            let duplicatesRejected = (0..<3).allSatisfy { _ in rejectedRecovery(recoveryFrame([0, 110])) }
            let unrelatedRejected = rejectedRecovery(pixels(3))
            let resetTracker = seededRecoveryTracker()
            func resetStep(_ offsets: [CGFloat]) -> [String: Any] {
                let frame = recoveryFrame(offsets)
                _ = resetTracker.trackPixelBuffer(frame, referenceRect: box, referenceConfidence: 0.1)
                return resetTracker.recoverPixelBuffer(frame)
            }
            let beforeGap = resetStep([0])
            let gap = resetStep([])
            let afterGap = (0..<3).map { _ in resetStep([0]) }
            let weakResetsStreak = beforeGap["recovery_confirmations"] as? Int == 1 &&
                gap["recovery_confirmations"] as? Int == 0 &&
                afterGap[0]["recovery_confirmations"] as? Int == 1 && afterGap[0]["accepted"] as? Bool == false &&
                afterGap[1]["recovery_confirmations"] as? Int == 2 && afterGap[1]["accepted"] as? Bool == false &&
                afterGap[2]["accepted"] as? Bool == true && afterGap[2]["template_updates"] as? Int == 0
            let colorTracker = CMPhysicalObjectPatchTracker(pixelBuffer: colorSeed, selection: colorBox)!
            _ = colorTracker.trackPixelBuffer(colorSeed, referenceRect: colorBox, referenceConfidence: 0.95)
            _ = colorTracker.trackPixelBuffer(blank, referenceRect: colorBox, referenceConfidence: 0.1)
            let colorUnsupported = !colorTracker.supportsCenterRecovery &&
                colorTracker.recoverPixelBuffer(colorSeed)["accepted"] as? Bool == false
            let frozenTracker = seededRecoveryTracker()
            var frozenOutputs: [[String: Any]] = []
            var frozenDuplicatesRejected = true
            for step in 0..<3 {
                let frame = recoveryFrame([0])
                let token = 100 + Double(step) * 0.1
                frozenOutputs.append(frozenTracker.recoverFrozenPixelBuffer(frame, frameToken: token))
                let duplicate = frozenTracker.recoverFrozenPixelBuffer(frame, frameToken: token)
                frozenDuplicatesRejected = frozenDuplicatesRejected && duplicate["accepted"] as? Bool == false
            }
            let frozenRecoveryPassed = frozenOutputs[0]["accepted"] as? Bool == false &&
                frozenOutputs[1]["accepted"] as? Bool == false &&
                frozenOutputs[2]["recovered_original_template"] as? Bool == true &&
                frozenOutputs.allSatisfy { $0["template_updates"] as? Int == 0 }
            let interruptedFrozenTracker = seededRecoveryTracker()
            let interruptedFirst = interruptedFrozenTracker.recoverFrozenPixelBuffer(recoveryFrame([0]), frameToken: 200)
            interruptedFrozenTracker.resetFrozenRecoveryConfirmation()
            let interruptedSecond = interruptedFrozenTracker.recoverFrozenPixelBuffer(recoveryFrame([0]), frameToken: 200.1)
            interruptedFrozenTracker.resetFrozenRecoveryConfirmation()
            let afterPartsGap = (0..<3).map { step in
                interruptedFrozenTracker.recoverFrozenPixelBuffer(recoveryFrame([0]), frameToken: 200.2 + Double(step) * 0.1)
            }
            let skippedPartsBreakFrozenStreak = interruptedFirst["recovery_confirmations"] as? Int == 1 &&
                interruptedSecond["recovery_confirmations"] as? Int == 1 &&
                afterPartsGap[0]["recovery_confirmations"] as? Int == 1 &&
                afterPartsGap[1]["accepted"] as? Bool == false && afterPartsGap[2]["accepted"] as? Bool == true &&
                afterPartsGap.allSatisfy { $0["template_updates"] as? Int == 0 }
            print("KK_CENTER_RECOVERY_NATIVE positive=\(positive) continuation=\(continuation) missing=\(missingRejected) duplicate=\(duplicatesRejected)")
            return [
                "center_recovery_requires_previously_accepted_texture": unsupportedBeforeLock,
                "center_recovery_cannot_move_or_train_before_third_frame": localRemainedRejected && firstTwoHeld,
                "center_recovery_repeated_observation_cannot_confirm": sameObservationCannotConfirm,
                "center_recovery_confirms_original_texture_after_three_frames": confirmed,
                "center_recovery_continues_at_new_center_without_template_update": continuation["accepted"] as? Bool == true && nearCenter(continuation) && continuation["template_updates"] as? Int == 0,
                "center_recovery_rejects_missing_target": missingRejected,
                "center_recovery_full_image_competitor_blocks_central_candidate": duplicatesRejected,
                "center_recovery_rejects_unrelated_scene": unrelatedRejected,
                "center_recovery_weak_frame_resets_confirmation_without_training": weakResetsStreak,
                "center_recovery_cannot_downgrade_color_identity_to_texture": colorUnsupported,
                "frozen_recovery_advances_only_fresh_frames_without_tracking_or_learning": frozenRecoveryPassed && frozenDuplicatesRejected,
                "parts_bridge_skips_break_frozen_recovery_confirmation_without_learning": skippedPartsBreakFrozenStreak
            ]
        }()

        return [
            "strong_first_pair_maintains_selection_before_control_confirmation": strongAcquisition["accepted"] as? Bool == true && strongAcquisition["bootstrap_refresh_authorized"] as? Bool == true && strongAcquisition["template_refreshed"] as? Bool == true && (strongAcquisition["anchor_count"] as? Int ?? -1) == 0,
            "weak_first_pair_cannot_bootstrap_appearance": weakAcquisition["bootstrap_refresh_authorized"] as? Bool == false && weakAcquisition["template_updates"] as? Int == 0,
            "approach_retreat_cycle_preserves_position_and_scale": depthCyclePassed,
            "contained_vision_detail_does_not_veto_existing_features": containedDetail["reference_agrees"] as? Bool == false && containedDetail["reference_overlaps"] as? Bool == false && containedDetail["reference_is_contained_detail"] as? Bool == true && containedDetail["template_refreshed"] as? Bool == true,
            "contained_detail_cannot_initialize_untrusted_features": untrustedDetail["reference_is_contained_detail"] as? Bool == true && (untrustedDetail["anchor_count"] as? Int ?? -1) == 0 && untrustedDetail["template_updates"] as? Int == 0,
            "partly_outside_detail_still_blocks_feature_refresh": outsideDetail["reference_is_contained_detail"] as? Bool == false && outsideDetail["template_updates"] as? Int == 0,
            "tiny_detail_cannot_suppress_conflict": tinyDetail["reference_is_contained_detail"] as? Bool == false && tinyDetail["template_updates"] as? Int == 0,
            "vision_and_features_refresh_accepted_surface_before_loss": jointlySupportedChange["accepted"] as? Bool == true && (jointlySupportedChange["score"] as? Double ?? 1) < 0.85 && jointlySupportedChange["feature_refresh_authorized"] as? Bool == true && jointlySupportedChange["template_refreshed"] as? Bool == true,
            "feature_only_support_keeps_stricter_refresh_floor": featureOnlyLargerChange["accepted"] as? Bool == true && featureOnlyLargerChange["feature_refresh_authorized"] as? Bool == false && featureOnlyLargerChange["template_updates"] as? Int == 0,
            "overlapping_vision_offset_preserves_feature_support": overlappingReference["reference_agrees"] as? Bool == false && overlappingReference["reference_overlaps"] as? Bool == true && overlappingReference["template_refreshed"] as? Bool == true,
            "strong_vision_can_refresh_moderate_change_before_feature_bootstrap": earlyChange["accepted"] as? Bool == true && (earlyChange["score"] as? Double ?? 1) < 0.9 && (earlyChange["anchor_count"] as? Int ?? 0) >= 12 && earlyChange["reference_refresh_authorized"] as? Bool == true && earlyChange["template_refreshed"] as? Bool == true,
            "early_refresh_does_not_repeat_on_unchanged_surface": earlyRecovery["accepted"] as? Bool == true && (earlyRecovery["score"] as? Double ?? 0) >= 0.98 && earlyRecovery["template_updates"] as? Int == 1,
            "ordinary_vision_confidence_cannot_refresh_moderate_change_alone": weakerEarlyChange["reference_refresh_authorized"] as? Bool == false && weakerEarlyChange["template_updates"] as? Int == 0,
            "feature_refresh_handles_supported_surface_change": supportedSurfaceChange["accepted"] as? Bool == true && supportedSurfaceChange["feature_refresh_authorized"] as? Bool == true && supportedSurfaceChange["template_refreshed"] as? Bool == true && (supportedSurfaceChange["score"] as? Double ?? 1) < 0.9,
            "surface_change_without_feature_support_cannot_refresh": unsupportedSurfaceChange["feature_refresh_authorized"] as? Bool == false && unsupportedSurfaceChange["template_updates"] as? Int == 0,
            "feature_tracks_gradual_viewpoint_change": gradualPassed && (gradualResult["template_updates"] as? Int ?? 0) >= 5 && (gradualResult["anchor_count"] as? Int ?? 0) >= 8,
            "feature_motion_still_rejects_disappearance": vanishedAfterMotion["accepted"] as? Bool == false && vanishedAfterMotion["feature_reference_confirmed"] as? Bool == false,
            "feature_consensus_bridges_weak_vision": featureBridge["accepted"] as? Bool == true && featureBridge["feature_reference_confirmed"] as? Bool == true && featureBridge["template_refreshed"] as? Bool == true,
            "feature_reference_requires_trusted_initialization": untrustedFeatures["anchor_count"] as? Int == 0 && untrustedFeatures["template_updates"] as? Int == 0,
            "feature_reference_cannot_override_strong_disagreement": conflictingFeatures["feature_reference_confirmed"] as? Bool == false && conflictingFeatures["template_updates"] as? Int == 0,
            "feature_reference_blocks_missing_target": missingFeatures["accepted"] as? Bool == false && missingFeatures["template_updates"] as? Int == 0,
            "feature_reference_blocks_unrelated_target": unrelatedFeatures["accepted"] as? Bool == false && unrelatedFeatures["template_updates"] as? Int == 0,
            "foreground_tracks_changing_reflection_gaps": reflectionMoved["accepted"] as? Bool == true && reflectionMoved["measurement_source"] as? String == "foreground_color_shape" && reflectionBox.count == 4 && abs(reflectionBox[0] - (0.35 + 18.0/384)) < 0.015,
            "foreground_rejects_major_occlusion": occludedColor["accepted"] as? Bool == false,
            "foreground_rejects_incompatible_silhouette": wrongShape["accepted"] as? Bool == false,
            "foreground_tracks_nv12_camera_format": nv12Passed,
            "foreground_tracks_motion_with_changed_background": movedColor["accepted"] as? Bool == true && movedColor["measurement_source"] as? String == "foreground_color_shape" && movedBox.count == 4 && abs(movedBox[0] - (0.35 + 18.0/384)) < 0.015,
            "foreground_does_not_fall_back_after_disappearance": hiddenColor["accepted"] as? Bool == false && hiddenColor["measurement_source"] as? String == "foreground_color_shape",
            "foreground_rejects_two_matching_targets": duplicatedColor["accepted"] as? Bool == false,
            "static_texture_stays_locked_without_refresh": staticStable,
            "appearance_refresh_requires_strong_match_and_agreement": refreshed["accepted"] as? Bool == true && refreshed["template_updates"] as? Int == 1,
            "appearance_refresh_blocks_disagreeing_reference": disagreement["template_updates"] as? Int == 0,
            "appearance_refresh_requires_reference_mean": sustainedWeakReference["template_updates"] as? Int == 0,
            "appearance_refresh_accepts_consistent_usable_reference": usableReference["template_updates"] as? Int == 1,
            "appearance_refresh_blocks_weak_reference": weakReference["template_updates"] as? Int == 0,
            "appearance_refresh_blocks_missing_target": missing["accepted"] as? Bool == false && missing["template_updates"] as? Int == 0,
            "appearance_refresh_blocks_unrelated_target": wrongTarget["accepted"] as? Bool == false && wrongTarget["template_updates"] as? Int == 0,
            "appearance_refresh_skips_identical_texture": unchanged["template_updates"] as? Int == 0,
            "native_session_consumes_match": measured.source == "fixed_patch_multiscale" && measured.quality >= 0.8,
            "native_session_blocks_missing_texture": held.source == "patch_unconfirmed_hold" && held.quality < 0.5,
            "blank_selection_declines_patch": CMPhysicalObjectPatchTracker(pixelBuffer: blank, selection: box) == nil,
            "unique_texture_accepts": tracker?.trackPixelBuffer(unique)["accepted"] as? Bool == true,
            "occluded_texture_rejects": tracker?.trackPixelBuffer(blank)["accepted"] as? Bool == false,
            "unrelated_scene_rejects": tracker?.trackPixelBuffer(unrelated)["accepted"] as? Bool == false,
            "duplicate_pattern_rejects": duplicate?.trackPixelBuffer(periodic)["accepted"] as? Bool == false,
            "geometry_change_rejects": tracker?.trackPixelBuffer(pixels(2, 256))["accepted"] as? Bool == false,
            "tiny_selection_declines_patch": CMPhysicalObjectPatchTracker(pixelBuffer: unique,
                selection: CGRect(x: 0.4, y: 0.4, width: 0.01, height: 0.01)) == nil
        ].merging(centerRecoveryChecks) { existing, _ in existing }
    }

    private static func foregroundVisionChecks(pixels: CVPixelBuffer, box: CGRect, context: CIContext, usesParts: Bool = false) throws -> [String: Bool] {
        let image = CIImage(cvPixelBuffer: pixels)
        guard let original = context.createCGImage(image, from: image.extent) else {
            throw NSError(domain: "ForegroundVisionChecks", code: 1)
        }
        let blank = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: image.extent)
        let coverRect = CGRect(x: box.minX * image.extent.width, y: box.minY * image.extent.height,
            width: box.width * image.extent.width, height: box.height * image.extent.height)
            .insetBy(dx: -box.width * image.extent.width * 0.3, dy: -box.height * image.extent.height * 0.3)
        let covered = blank.cropped(to: coverRect).composited(over: image)
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: image.extent)
        func buffer(_ image: CIImage) -> CVPixelBuffer {
            var pixels: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, Int(image.extent.width), Int(image.extent.height),
                kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
            context.render(image, to: pixels!)
            return pixels!
        }
        let originalPixels = buffer(image)
        var checks: [String: Bool] = [:]
        for (name, altered) in [("blank", blank), ("covered_target", covered), ("unrelated_noise", noise)] {
            let passed: Bool = try autoreleasepool {
                let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box))
                request.revision = VNTrackObjectRequestRevision2
                let handler = VNSequenceRequestHandler()
                let parts = usesParts ? CMPhysicalObjectPartsSession(seed: box) : nil
                defer { request.cancel() }
                for _ in 0..<(usesParts ? 8 : 3) {
                    try handler.perform([request], on: original, orientation: .up)
                    request.inputObservation = request.results!.first as! VNDetectedObjectObservation
                    _ = parts?.measure(pixels: originalPixels, full: request.inputObservation)
                }
                if let parts, parts.confirmedPartCount == 0 { return false }
                request.isLastFrame = true
                try handler.perform([request], on: context.createCGImage(altered, from: image.extent)!, orientation: .up)
                guard let observation = request.results?.first as? VNDetectedObjectObservation else { return true }
                return (parts?.measure(pixels: buffer(altered), full: observation, lastFrame: true).quality ?? observation.confidence) < 0.5
            }
            checks["foreground_vision_\(name)_withdraws_confidence"] = passed
        }
        var selections = 0
        for _ in 0..<30 {
            try autoreleasepool {
                let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box))
                request.revision = VNTrackObjectRequestRevision2
                let handler = VNSequenceRequestHandler()
                let parts = usesParts ? CMPhysicalObjectPartsSession(seed: box) : nil
                try handler.perform([request], on: original, orientation: .up)
                if let observation = request.results?.first as? VNDetectedObjectObservation {
                    _ = parts?.measure(pixels: originalPixels, full: observation, lastFrame: true)
                }
                request.isLastFrame = true
                request.cancel() // Same cancellation boundary as manual reselection.
                selections += 1
            }
        }
        checks["foreground_vision_30_reselections_do_not_exhaust_trackers"] = selections == 30
        return checks
    }

    /// Continue the exact successful image session with fresh absent-target
    /// frames. This tests the established bridge, not a newly seeded tracker.
    static func snapshotLossChecks(session: CMPhysicalObjectSnapshotPartsSession,
                                   pixels: CVPixelBuffer, last: [String: Any]) -> [String: Bool] {
        // In-memory probe rows contain CGFloat coordinates; accept their
        // numeric representation before JSON serialization as well.
        guard let box = last["bbox"] as? [CGFloat], box.count == 4,
              let capturedAt = last["captured_at"] as? Double else { return ["snapshot_loss_input_valid": false] }
        let rect = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
        var allocated: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels),
                                  kCVPixelFormatType_32BGRA, nil, &allocated) == kCVReturnSuccess,
              let absent = allocated else { return ["snapshot_loss_allocation": false] }
        var results: [String: Bool] = [:]
        for (stage, noise) in [false, true].enumerated() {
            CVPixelBufferLockBaseAddress(absent, [])
            let base = CVPixelBufferGetBaseAddress(absent)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(absent)
            var random: UInt32 = 8779
            for y in 0..<CVPixelBufferGetHeight(absent) { for x in 0..<CVPixelBufferGetWidth(absent) {
                random = random &* 1664525 &+ 1013904223
                let v = noise ? UInt8(random >> 24) : UInt8(128)
                let offset = y * stride + x * 4
                base[offset] = v; base[offset + 1] = v; base[offset + 2] = v; base[offset + 3] = 255
            }}
            CVPixelBufferUnlockBaseAddress(absent, [])
            var held = true
            for frame in 0..<6 {
                let measured = session.measure(buffer: absent,
                    vision: CMPhysicalObjectUnavailableWholeObservation(boundingBox: rect),
                    capturedAt: capturedAt + Double(stage * 6 + frame + 1) * 0.04)
                held = held && measured.isHeldObservation && measured.quality < 0.5 &&
                    !measured.recoveredOriginalTemplate && measured.rect.equalTo(rect) && measured.previousRect.equalTo(rect)
            }
            results[noise ? "established_snapshot_rejects_unrelated_texture_without_reseed" : "established_snapshot_rejects_six_missing_frames"] = held
        }
        return results
    }

    /// Synthetic image evidence only: never append these frames to recorded replay rows.
    static func reacquirerChecks(pixels: CVPixelBuffer, selection: CGRect, context: CIContext) -> [String: Bool] {
        guard let identity = CMPhysicalObjectReacquirer(pixelBuffer: pixels, selection: selection) else {
            return ["reacquirer_initial_identity_available": false]
        }
        let image = CIImage(cvPixelBuffer: pixels), extent = CIImage(cvPixelBuffer: pixels).extent
        let count = identity.templateCount
        var token = 10.0
        var checks = ["reacquirer_initial_identity_available": count == 1]
        func result(_ frame: CVPixelBuffer, at supplied: Double? = nil) -> [String: Any] {
            if supplied == nil { token += 0.04 }
            return identity.findPixelBuffer(frame, frameToken: supplied ?? token)
        }
        func accepted(_ value: [String: Any]) -> Bool {
            value["accepted"] as? Bool == true && value["recovered_verified_identity"] as? Bool == true &&
                ((value["quality"] as? NSNumber)?.doubleValue ?? 0) >= 0.9
        }
        func rejected(_ value: [String: Any]) -> Bool {
            value["accepted"] as? Bool != true && value["recovered_verified_identity"] as? Bool != true
        }
        func thirdOnly(_ frame: CVPixelBuffer) -> Bool {
            let first = result(frame), second = result(frame), third = result(frame)
            return rejected(first) && rejected(second) && accepted(third)
        }
        checks["reacquirer_original_requires_three_fresh_frames"] = thirdOnly(pixels)
        identity.resetSearchConfirmation()
        token += 0.04
        let repeated = (0..<3).map { _ in result(pixels, at: token) }
        checks["reacquirer_repeated_token_never_confirms"] = repeated.allSatisfy(rejected) &&
            repeated.dropFirst().allSatisfy { $0["reason"] as? String == "non_monotonic_frame" }
        identity.resetSearchConfirmation()
        let beforeReset = [result(pixels), result(pixels)]
        identity.resetSearchConfirmation()
        checks["reacquirer_reset_requires_three_new_frames"] = beforeReset.allSatisfy(rejected) && thirdOnly(pixels)
        func buffer(_ contents: CIImage) -> CVPixelBuffer? {
            var output: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, Int(extent.width), Int(extent.height),
                kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &output) == kCVReturnSuccess,
                let output else { return nil }
            context.render(contents.cropped(to: extent), to: output)
            return output
        }
        let blank = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage?.cropped(to: extent) else {
            checks["reacquirer_test_images_available"] = false; return checks
        }
        let roi = CGRect(x: selection.minX * extent.width, y: selection.minY * extent.height,
            width: selection.width * extent.width, height: selection.height * extent.height).integral.intersection(extent)
        guard !roi.isEmpty, extent.width > 48, extent.height > 40 else {
            checks["reacquirer_test_images_available"] = false; return checks
        }
        let scale = min(1, (extent.width / 2 - 24) / roi.width, (extent.height - 40) / roi.height)
        let crop = image.cropped(to: roi).transformed(by: CGAffineTransform(translationX: -roi.minX, y: -roi.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        func placed(_ x: CGFloat) -> CIImage {
            crop.transformed(by: CGAffineTransform(translationX: x.rounded(), y: ((extent.height - crop.extent.height) / 2).rounded()))
        }
        let single = placed((extent.width - crop.extent.width) / 2).composited(over: blank)
        let duplicate = placed(12).composited(over: placed(extent.width - crop.extent.width - 12).composited(over: blank))
        for (name, contents, frames) in [("blank", blank, 6), ("noise", noise, 6), ("duplicate", duplicate, 3), ("single", single, 3)] {
            guard let frame = buffer(contents) else { checks["reacquirer_\(name)_allocated"] = false; continue }
            identity.resetSearchConfirmation()
            let observed = (0..<frames).map { _ in result(frame) }
            checks["reacquirer_\(name)_\(frames)_frames"] = name == "single"
                ? observed.prefix(2).allSatisfy(rejected) && accepted(observed[2]) : observed.allSatisfy(rejected)
            checks["reacquirer_\(name)_preserves_identity_count"] = identity.templateCount == count
        }
        checks["reacquirer_search_never_adds_templates"] = identity.templateCount == count
        return checks
    }

    /// Recorded, Safety-approved measurements train identity before loss.
    /// Search and every frame after a recovered identity run the actual new
    /// session/Vision path. This is not a replay of the old tracker algorithm.
    final class AutomaticRecoveryReplay {
        let session: CMPhysicalObjectRecoverySession
        var safety = CMPhysicalObjectFollowSafety(recoveryEnabled: true)
        var previous: CGRect
        let decisions: [[String: Any]]
        var beganSearch = false
        var firstSearchAt: TimeInterval?
        var recoveryCount = 0

        init(request: VNTrackObjectRequest, pixels: CVPixelBuffer, selection: CGRect,
             decisions: [[String: Any]]) throws {
            guard let session = CMPhysicalObjectRecoverySession(request: request, buffer: pixels, selection: selection) else {
                throw NSError(domain: "AutomaticRecoveryInitialIdentityUnavailable", code: 1)
            }
            self.session = session; previous = selection; self.decisions = decisions
        }

        func measure(pixels: CVPixelBuffer, frame: [String: Any]) -> [String: Any] {
            let capturedAt = frame["captured_at"] as! Double
            let recordedBox = frame["bbox"] as! [Double]
            let source = frame["quality_source"] as? String ?? "vision"
            let recorded = CMPhysicalObjectMeasurement(
                rect: CGRect(x: recordedBox[0], y: recordedBox[1], width: recordedBox[2], height: recordedBox[3]),
                previousRect: previous, quality: (frame["confidence"] as? NSNumber)?.floatValue ?? 0,
                source: source, patchDiagnostics: frame["patch_diagnostics"] as? [String: Any] ?? [:],
                isHeldObservation: source.contains("unconfirmed") || source.hasSuffix("_hold"))
            let initial = source == "foreground_selection_initialization"
            if initial {
                return ["bbox": recordedBox, "confidence": recorded.quality,
                    "quality_source": source, "initialization_only": true,
                    "is_held": false, "searching_original_target": false, "ready": false]
            }
            var measured: CMPhysicalObjectMeasurement
            var inputMode = "recorded_pre_loss_tracking_measurement"
            if session.isSearching || session.hasResumedTracking {
                let observation = session.observation(buffer: pixels) ?? CMPhysicalObjectUnavailableWholeObservation(boundingBox: previous)
                measured = session.measure(buffer: pixels, observation: observation, capturedAt: capturedAt)
                inputMode = "actual_recovery_and_resumed_vision"
            } else { measured = recorded }
            let wasSearching = safety.searchingOriginalTarget
            let reason = safety.observe(rect: measured.rect, previousRect: measured.previousRect,
                confidence: measured.quality, capturedAt: capturedAt,
                isHeldObservation: measured.isHeldObservation,
                supportsCenterRecovery: measured.supportsCenterRecovery,
                recoveredOriginalTemplate: measured.recoveredOriginalTemplate,
                recoveredVerifiedIdentity: measured.recoveredVerifiedIdentity)
            // Safety can enter search internally while returning nil at its
            // ordinary confirmation deadline. Mirror that transition even
            // when the current row has no terminal rejection.
            if !wasSearching && safety.searchingOriginalTarget {
                session.beginSearch(); beganSearch = true
                if firstSearchAt == nil { firstSearchAt = capturedAt }
            }
            if let reason {
                session.invalidateReliableSequence()
                if measured.recoveredVerifiedIdentity { session.rejectRecovery(capturedAt: capturedAt) }
                let recoverable = ["low_confidence", "invalid_box", "invalid_held_observation", "box_position_jump", "box_scale_jump",
                    "confidence_recovery_identity_jump",
                    "confidence_recovery_timeout", "original_target_return_timeout",
                    "frame_reentry_timeout", "frame_reentry_confidence_timeout"]
                if recoverable.contains(reason), safety.beginOriginalTargetSearch() {
                    session.beginSearch(); beganSearch = true
                    if firstSearchAt == nil { firstSearchAt = capturedAt }
                }
            } else if wasSearching && !safety.searchingOriginalTarget && measured.recoveredVerifiedIdentity {
                if session.commitRecovery(buffer: pixels, rect: measured.rect, capturedAt: capturedAt) { recoveryCount += 1 }
            } else if wasSearching && !safety.searchingOriginalTarget && measured.recoveredOriginalTemplate {
                _ = session.cancelSearchForLocalRecovery(rect: measured.rect, capturedAt: capturedAt)
            } else if safety.ready {
                let decision = decisions.first { value in
                    guard let at = value["captured_at"] as? Double else { return false }
                    return abs(at - capturedAt) < 0.000001
                }
                let recordedReady = decision?["ready"] as? Bool == true && decision?["rejection"] as? String == nil
                if inputMode != "recorded_pre_loss_tracking_measurement" || recordedReady {
                    session.observeReliable(measurement: measured, buffer: pixels, capturedAt: capturedAt)
                } else { session.invalidateReliableSequence() }
            } else { session.invalidateReliableSequence() }
            previous = measured.rect
            var diagnostics = measured.patchDiagnostics
            if let learning = session.lastLearningDiagnostics { diagnostics["latest_identity_learning"] = learning }
            var result: [String: Any] = ["bbox": [measured.rect.minX, measured.rect.minY, measured.rect.width, measured.rect.height].map(Double.init),
                "confidence": measured.quality, "quality_source": measured.source,
                "is_held": measured.isHeldObservation, "center_recovery": measured.supportsCenterRecovery,
                "recovered_original_template": measured.recoveredOriginalTemplate,
                "recovered_verified_identity": measured.recoveredVerifiedIdentity,
                "patch_diagnostics": diagnostics, "ready": safety.ready,
                "searching_original_target": safety.searchingOriginalTarget,
                "actual_recovery_count": recoveryCount, "reference_source": inputMode,
                "replay_scope": "mixed_recorded_pre_loss_actual_recovery",
                "accepted": !measured.isHeldObservation && measured.quality >= 0.5]
            if let reason { result["safety_rejection"] = reason }
            return result
        }
    }

    /// Strict image pipeline: only the manual first-frame selection (and an
    /// explicitly recorded initial segmentation) is supplied by the trace.
    /// All later measurements, Safety readiness and gallery eligibility are
    /// recomputed. Main-thread acknowledgements are modeled synchronously;
    /// this does not emulate camera queues, BLE, dropped frames or motors.
    final class AutomaticRecoveryPipeline {
        let request: VNTrackObjectRequest
        let recovery: CMPhysicalObjectRecoverySession?
        let selection: CGRect
        let initializationDiagnostics: [String: Any]
        private var handler = VNSequenceRequestHandler()
        private var native: CMPhysicalObjectPatchSession?
        private var snapshot: CMPhysicalObjectSnapshotPartsSession?
        private var parts: CMPhysicalObjectPartsSession?
        private var initializesForeground: Bool
        private var safety: CMPhysicalObjectFollowSafety
        private var previous: CGRect
        private var terminalReason: String?
        private var recoveryCount = 0
        private var firstSearchAt: TimeInterval?
        private var beforeSearchReliableCallbacks = 0
        private var beforeSearchNativeAddCount = 0
        private var beforeSearchCacheCopies = 0

        init(request: VNTrackObjectRequest, pixels: CVPixelBuffer,
             manual: [Double], first: [String: Any]) throws {
            guard manual.count == 4, manual.allSatisfy({ $0.isFinite }) else {
                throw NSError(domain: "AutomaticRecoveryPipelineManualSelectionMissing", code: 1)
            }
            self.request = request
            let manualRect = CGRect(x: manual[0], y: manual[1], width: manual[2], height: manual[3])
            let recorded = (first["patch_diagnostics"] as? [String: Any])?["refined_bbox"] as? [Double]
            let refined: (rect: CGRect, diagnostics: [String: Any])?
            if first["quality_source"] as? String == "foreground_selection_initialization",
               let recorded, recorded.count == 4, recorded.allSatisfy({ $0.isFinite }) {
                refined = (CGRect(x: recorded[0], y: recorded[1], width: recorded[2], height: recorded[3]),
                    ["refined_bbox": recorded, "replay_initialization": "recorded_initial_selection_refinement_only"])
            } else if let computed = CMPhysicalObjectForegroundSelection.refine(pixels, selection: manualRect) {
                var diagnostics = computed.diagnostics
                diagnostics["replay_initialization"] = "recomputed_refinement_on_first_saved_image"
                refined = (computed.rect, diagnostics)
            } else { refined = nil }
            selection = refined?.rect ?? manualRect
            previous = selection
            initializesForeground = refined != nil
            initializationDiagnostics = refined?.diagnostics ?? ["declined": true,
                "fallback": "native_with_trusted_snapshot_parts", "replay_initialization": "manual_first_saved_image"]
            request.revision = refined == nil ? VNTrackObjectRequestRevision1 : VNTrackObjectRequestRevision2
            request.trackingLevel = .accurate
            request.inputObservation = VNDetectedObjectObservation(boundingBox: selection)
            recovery = CMPhysicalObjectRecoverySession(request: request, buffer: pixels, selection: selection)
            safety = CMPhysicalObjectFollowSafety(recoveryEnabled: recovery != nil)
            if refined != nil { parts = CMPhysicalObjectPartsSession(seed: selection) }
        }

        private func normalMeasurement(pixels: CVPixelBuffer, capturedAt: TimeInterval)
            throws -> (CMPhysicalObjectMeasurement, VNDetectedObjectObservation) {
            let observation: VNDetectedObjectObservation
            if let snapshot, snapshot.usesParts {
                observation = snapshot.unavailableVisionObservation ?? CMPhysicalObjectUnavailableWholeObservation(boundingBox: previous)
            } else if let parts {
                observation = parts.wholeObservation(request: request, handler: handler, pixels: pixels)
            } else {
                do {
                    try handler.perform([request], on: pixels, orientation: .up)
                    guard let current = request.results?.first as? VNDetectedObjectObservation else {
                        throw NSError(domain: "AutomaticRecoveryPipelineEmptyVision", code: 1)
                    }
                    observation = current
                } catch {
                    guard let unavailable = recovery?.unavailableObservation ?? native?.unavailableVisionObservation else { throw error }
                    observation = unavailable
                }
            }
            let measured: CMPhysicalObjectMeasurement
            if let parts {
                measured = parts.measure(pixels: pixels, full: observation)
            } else {
                if native == nil {
                    let seeded = CMPhysicalObjectPatchSession(request: request, buffer: pixels, selection: previous)
                    native = seeded
                    snapshot = CMPhysicalObjectSnapshotPartsSession(request: request, native: seeded, selection: previous)
                }
                measured = snapshot!.measure(buffer: pixels, vision: observation, capturedAt: capturedAt)
            }
            // Match the runtime feedback rule; a retired full Vision stream is
            // not re-performed after parts or independent recovery takes over.
            if measured.recoveredOriginalTemplate {
                handler = VNSequenceRequestHandler()
                request.inputObservation = VNDetectedObjectObservation(boundingBox: measured.rect)
            } else if !(observation is CMPhysicalObjectUnavailableWholeObservation) {
                request.inputObservation = observation
            }
            return (measured, observation)
        }

        func measure(pixels: CVPixelBuffer, capturedAt: TimeInterval) throws -> [String: Any] {
            let start = ProcessInfo.processInfo.systemUptime
            if let terminalReason {
                return ["bbox": [previous.minX, previous.minY, previous.width, previous.height].map(Double.init),
                    "confidence": 0, "quality_source": "pipeline_terminated", "accepted": false, "ready": false,
                    "is_held": true, "searching_original_target": false, "pipeline_terminal_reason": terminalReason,
                    "normal_processing_ms": 0, "recovery_processing_ms": 0, "learning_processing_ms": 0]
            }
            if initializesForeground {
                initializesForeground = false
                try handler.perform([request], on: pixels, orientation: .up)
                guard let first = request.results?.first as? VNDetectedObjectObservation else {
                    throw NSError(domain: "AutomaticRecoveryForegroundInitialization", code: 1)
                }
                request.inputObservation = first
                _ = parts?.measure(pixels: pixels, full: first, initializationOnly: true)
                return ["bbox": [first.boundingBox.minX, first.boundingBox.minY, first.boundingBox.width, first.boundingBox.height].map(Double.init),
                    "confidence": first.confidence, "quality_source": "foreground_selection_initialization",
                    "initialization_only": true, "accepted": false, "is_held": false, "ready": false,
                    "searching_original_target": false, "initial_identity_available": recovery != nil,
                    "reference_source": "regenerated_initial_vision", "patch_diagnostics": initializationDiagnostics,
                    "normal_processing_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                    "recovery_processing_ms": 0, "learning_processing_ms": 0,
                    "before_search_learning_native": false]
            }
            let inRecoveryRoute = recovery.map { $0.isSearching || $0.hasResumedTracking } ?? false
            let measured: CMPhysicalObjectMeasurement
            let observation: VNDetectedObjectObservation
            if let recovery, inRecoveryRoute {
                observation = recovery.observation(buffer: pixels) ?? recovery.unavailableObservation
                measured = recovery.measure(buffer: pixels, observation: observation, capturedAt: capturedAt)
            } else {
                (measured, observation) = try normalMeasurement(pixels: pixels, capturedAt: capturedAt)
            }
            let trackingMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let wasSearching = safety.searchingOriginalTarget
            let priorTimeout = safety.confirmationTimeoutReason(at: capturedAt)
            var reason = safety.observe(rect: measured.rect, previousRect: measured.previousRect,
                confidence: measured.quality, capturedAt: capturedAt, isHeldObservation: measured.isHeldObservation,
                supportsCenterRecovery: measured.supportsCenterRecovery, recoveredOriginalTemplate: measured.recoveredOriginalTemplate,
                recoveredVerifiedIdentity: measured.recoveredVerifiedIdentity)
            // A genuine geometry/identity rejection follows the same recoverable
            // loss policy as the manager. A short HOLD itself never starts search.
            let recoverable = ["low_confidence", "invalid_box", "invalid_held_observation", "box_scale_jump", "box_position_jump",
                "confidence_recovery_identity_jump", "confidence_recovery_timeout", "frame_reentry_timeout",
                "frame_reentry_confidence_timeout", "original_target_return_timeout", "empty_vision_result"]
            if let failure = reason, !safety.searchingOriginalTarget,
               !recoverable.contains(failure) || !safety.beginOriginalTargetSearch() {
                terminalReason = failure
            }
            var transition: String?
            if !wasSearching && safety.searchingOriginalTarget {
                recovery?.beginSearch()
                if firstSearchAt == nil { firstSearchAt = capturedAt }
                transition = priorTimeout ?? reason ?? "safety_confirmation_timeout"
            }
            var acknowledged = false
            if wasSearching && !safety.searchingOriginalTarget && measured.recoveredVerifiedIdentity {
                acknowledged = recovery?.commitRecovery(buffer: pixels, rect: measured.rect, capturedAt: capturedAt) == true
                if acknowledged { recoveryCount += 1 } else {
                    terminalReason = "recovery_acknowledgement_failed"
                    reason = terminalReason
                }
            } else if wasSearching && !safety.searchingOriginalTarget && measured.recoveredOriginalTemplate {
                acknowledged = recovery?.cancelSearchForLocalRecovery(rect: measured.rect, capturedAt: capturedAt) == true
                if !acknowledged { terminalReason = "local_recovery_acknowledgement_failed"; reason = terminalReason }
            } else if measured.recoveredVerifiedIdentity && reason != nil {
                recovery?.rejectRecovery(capturedAt: capturedAt)
            }
            let learningStart = ProcessInfo.processInfo.systemUptime
            let acknowledgementMS = (learningStart - start) * 1000 - trackingMS
            var reliableCallback = false
            if reason == nil, terminalReason == nil, safety.ready, !measured.recoveredVerifiedIdentity {
                reliableCallback = recovery != nil
                recovery?.observeReliable(measurement: measured, buffer: pixels, capturedAt: capturedAt)
                if firstSearchAt == nil, recovery != nil {
                    beforeSearchReliableCallbacks += 1
                    if let learning = recovery?.lastLearningDiagnostics,
                       let at = learning["captured_at"] as? Double, at == capturedAt {
                        if learning["reason"] as? String == "trusted_history_cached" { beforeSearchCacheCopies += 1 }
                    }
                }
            } else { recovery?.invalidateReliableSequence() }
            let learningMS = (ProcessInfo.processInfo.systemUptime - learningStart) * 1000
            if firstSearchAt == nil { beforeSearchNativeAddCount = recovery?.nativeHistoryAddCount ?? 0 }
            previous = measured.rect
            var diagnostics = measured.patchDiagnostics
            if let learning = recovery?.lastLearningDiagnostics { diagnostics["latest_identity_learning"] = learning }
            var result: [String: Any] = ["bbox": [measured.rect.minX, measured.rect.minY, measured.rect.width, measured.rect.height].map(Double.init),
                "vision_bbox": [observation.boundingBox.minX, observation.boundingBox.minY, observation.boundingBox.width, observation.boundingBox.height].map(Double.init),
                "vision_confidence": observation.confidence, "confidence": measured.quality, "quality_source": measured.source,
                "is_held": measured.isHeldObservation, "accepted": !measured.isHeldObservation && measured.quality >= 0.5,
                "ready": terminalReason == nil && safety.ready, "searching_original_target": safety.searchingOriginalTarget,
                "session_searching": recovery?.isSearching ?? false, "actual_recovery_count": recoveryCount,
                "recovery_acknowledged": acknowledged, "center_recovery": measured.supportsCenterRecovery,
                "recovered_original_template": measured.recoveredOriginalTemplate, "recovered_verified_identity": measured.recoveredVerifiedIdentity,
                "initial_identity_available": recovery != nil, "patch_diagnostics": diagnostics,
                "reference_source": inRecoveryRoute ? "actual_recovery_and_resumed_vision" : "regenerated_normal_vision_and_measurement",
                "replay_scope": "strict_recomputed_image_pipeline_synchronous_main_ack_no_camera_or_motor",
                "normal_processing_ms": inRecoveryRoute ? 0 : trackingMS, "recovery_processing_ms": inRecoveryRoute ? trackingMS : 0,
                "learning_processing_ms": learningMS, "safety_and_acknowledgement_ms": acknowledgementMS,
                "reliable_learning_callback": reliableCallback,
                "before_search_reliable_callbacks": beforeSearchReliableCallbacks, "before_search_cache_copies": beforeSearchCacheCopies,
                "before_search_learning_native": beforeSearchNativeAddCount > 0,
                "before_search_native_history_add_count": beforeSearchNativeAddCount,
                "native_history_add_count": recovery?.nativeHistoryAddCount ?? 0,
                "native_learning_evidence": "session_counter_incremented_at_actual_native_add_call",
                "capture_age_model": "recorded_capture_time_for_safety_windows_no_camera_queue_age_simulation"]
            if let transition { result["search_started_reason"] = transition }
            if let firstSearchAt { result["first_search_captured_at"] = firstSearchAt }
            if let reason { result["safety_rejection"] = reason }
            if let terminalReason { result["pipeline_terminal_reason"] = terminalReason }
            return result
        }
    }

    /// Synchronous fixture replay using the same photo session, capture sequence,
    /// and motion eligibility checks as the live camera. The seed never drives.
    final class PhotoReplay {
        let request: VNTrackObjectRequest
        let session: CMPhysicalObjectPhotoSession
        var handler = VNSequenceRequestHandler()
        var safety: CMPhysicalObjectFollowSafety
        var terminal: String?

        init(request: VNTrackObjectRequest, pixels: CVPixelBuffer, rect: CGRect, useNano: Bool, independent: Bool) {
            self.request = request
            request.inputObservation = VNDetectedObjectObservation(boundingBox: rect)
            session = CMPhysicalObjectPhotoSession(request: request, buffer: pixels, selection: rect, useNano: useNano, independent: independent)
            safety = CMPhysicalObjectFollowSafety(recoveryEnabled: true, photoReferenceSelection: rect)
            if !session.isAvailable { terminal = "photo_reference_unavailable" }
        }

        func row(pixels: CVPixelBuffer, time: TimeInterval, seed: Bool) -> [String: Any] {
            var observation = session.unavailableVisionObservation
            if terminal == nil, session.needsVisionProposal {
                do {
                    try handler.perform([request], on: pixels)
                    if let result = request.results?.first as? VNDetectedObjectObservation { observation = result }
                } catch { /* Photo search can proceed without a Vision proposal. */ }
            }
            var measured = CMPhysicalObjectMeasurement(rect: observation.boundingBox, previousRect: observation.boundingBox,
                quality: 0, source: seed ? "photo_reference_capture" : "pipeline_terminated", isHeldObservation: true)
            var reason: String?
            if terminal == nil && !seed {
                measured = session.measure(buffer: pixels, vision: observation, capturedAt: time)
                let searching = safety.searchingOriginalTarget
                reason = safety.observe(rect: measured.rect, previousRect: measured.previousRect, confidence: measured.quality,
                    capturedAt: time, isHeldObservation: measured.isHeldObservation,
                    recoveredPhotoReference: measured.recoveredPhotoReference,
                    photoConfirmationStartedAt: measured.photoConfirmationStartedAt)
                if let reason, !safety.searchingOriginalTarget {
                    let recoverable = ["low_confidence", "invalid_box", "invalid_held_observation", "box_scale_jump",
                        "box_position_jump", "confidence_recovery_identity_jump", "confidence_recovery_timeout",
                        "frame_reentry_timeout", "frame_reentry_confidence_timeout", "original_target_return_timeout"]
                    if !recoverable.contains(reason) || !safety.beginOriginalTargetSearch() { terminal = reason }
                }
                if (!searching && safety.searchingOriginalTarget) || (reason != nil && measured.recoveredPhotoReference) {
                    safety.requireFreshPhotoConfirmation(after: time)
                    session.beginSearch(after: time)
                }
                if reason == nil && terminal == nil && safety.ready && !measured.isHeldObservation {
                    session.approveMovingFrame(at: time)
                }
            }
            if measured.recoveredPhotoReference {
                handler = VNSequenceRequestHandler()
                request.inputObservation = VNDetectedObjectObservation(boundingBox: measured.rect)
            } else if !(observation is CMPhysicalObjectUnavailableWholeObservation) { request.inputObservation = observation }
            let accepted = !seed && !measured.isHeldObservation && measured.quality >= 0.5
            var result: [String: Any] = ["bbox": [measured.rect.minX, measured.rect.minY, measured.rect.width, measured.rect.height],
                "confidence": measured.quality, "quality_source": measured.source, "accepted": accepted,
                "ready": accepted && terminal == nil && reason == nil && safety.ready, "is_held": measured.isHeldObservation,
                "searching_original_target": safety.searchingOriginalTarget, "initialization_only": seed,
                "initial_identity_available": session.isAvailable, "nano_template": session.hasNanoTemplate, "patch_diagnostics": measured.patchDiagnostics,
                "recovered_photo_reference": measured.recoveredPhotoReference && reason == nil && terminal == nil]
            if seed { result.merge(session.initializationDiagnostics) { _, value in value } }
            if let reason { result["safety_rejection"] = reason }
            if let terminal { result["pipeline_terminal_reason"] = terminal }
            return result
        }
    }

    static func run(root: URL, output: URL) throws -> [String: Any] {
        // Keep batches below iOS's launch watchdog. This DEBUG-only selector
        // splits the same fixtures; it never changes frames or tracker settings.
        let arguments = ProcessInfo.processInfo.arguments
        let selectedFolders: Set<String>? = arguments.firstIndex(of: "-KKPhysicalFollowProbeFolders").flatMap {
            $0 + 1 < arguments.count ? Set(arguments[$0 + 1].split(separator: ",").map(String.init)) : nil
        }
        let selectedVariants: Set<String>? = arguments.firstIndex(of: "-KKPhysicalFollowProbeVariants").flatMap {
            $0 + 1 < arguments.count ? Set(arguments[$0 + 1].split(separator: ",").map(String.init)) : nil
        }
        let rounds = arguments.firstIndex(of: "-KKPhysicalFollowProbeRounds").flatMap {
            $0 + 1 < arguments.count ? Int(arguments[$0 + 1]) : nil
        } ?? 3
        guard (1...3).contains(rounds) else { throw NSError(domain: "PhysicalScaleProbe", code: 5) }
        let folders = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("CMFollow-") }
            .filter { selectedFolders?.contains($0.lastPathComponent) ?? true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var runs: [[String: Any]] = []
        let context = CIContext(options: [.cacheIntermediates: false])
        for round in 0..<rounds {
            for folder in folders {
                let traceData = try Data(contentsOf: folder.appendingPathComponent("trace.json"))
                let trace = try JSONSerialization.jsonObject(with: traceData) as! [String: Any]
                let frames = trace["images"] as! [[String: Any]]
                guard let first = frames.first, let seed = first["bbox"] as? [Double], seed.count == 4 else { continue }
                var variants = round % 2 == 0 ? ["v1_accurate", "patch", "adaptive_patch", "v2"] : ["v2", "adaptive_patch", "patch", "v1_accurate"]
                if selectedVariants?.contains("recorded_reference_patch") == true { variants.append("recorded_reference_patch") }
                if selectedVariants?.contains("center_recovery_session") == true { variants.append("center_recovery_session") }
                if selectedVariants?.contains("foreground_selection_v2") == true { variants.append("foreground_selection_v2") }
                if selectedVariants?.contains("foreground_parts_v2") == true { variants.append("foreground_parts_v2") }
                if selectedVariants?.contains("foreground_parts_auto") == true { variants.append("foreground_parts_auto") }
                if selectedVariants?.contains("manual_parts_v2") == true { variants.append("manual_parts_v2") }
                if selectedVariants?.contains("trusted_snapshot_parts") == true { variants.append("trusted_snapshot_parts") }
                if selectedVariants?.contains("trusted_snapshot_recorded") == true { variants.append("trusted_snapshot_recorded") }
                if selectedVariants?.contains("recorded_native_session") == true { variants.append("recorded_native_session") }
                if selectedVariants?.contains("automatic_recovery_replay") == true { variants.append("automatic_recovery_replay") }
                if selectedVariants?.contains("automatic_recovery_pipeline") == true { variants.append("automatic_recovery_pipeline") }
                let photoVariant = "photo_reference_pipeline"
                let nanoVariant = "nanotrack_photo_pipeline"
                let independentVariant = "nanotrack_independent_pipeline"
                for candidate in [photoVariant, nanoVariant, independentVariant] where selectedVariants?.contains(candidate) == true {
                    variants.append(candidate)
                }
                // In a paired run neither tracker can see prior recorded boxes.
                // Alternate A/B order across rounds for timing comparisons.
                let photoPair = selectedVariants?.contains(photoVariant) == true || selectedVariants?.contains(nanoVariant) == true
                if photoPair, round % 2 == 1 { variants.reverse() }
                for variant in variants.filter({ selectedVariants?.contains($0) ?? true }) {
                    let usesPhoto = variant == photoVariant || variant == nanoVariant || variant == independentVariant
                    let usesForeground = variant == "foreground_selection_v2" || variant == "foreground_parts_v2" || variant == "foreground_parts_auto" || variant == "manual_parts_v2"
                    // A tail window can start many seconds after selection.
                    // Applying the original manual coordinates to it creates
                    // a different target, not a replay of initialization.
                    if (usesForeground || usesPhoto || variant == "trusted_snapshot_parts" || variant == "trusted_snapshot_recorded" || variant == "recorded_native_session" || variant == "automatic_recovery_replay" || variant == "automatic_recovery_pipeline"), trace["tail_includes_first_observation"] as? Bool != true {
                        throw NSError(domain: "ForegroundReplayRequiresSelectionFrame", code: 8)
                    }
                    let revision = (variant == "v2" || usesForeground) ? 2 : 1
                    let run: [String: Any] = try autoreleasepool {
                        let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(
                            boundingBox: CGRect(x: seed[0], y: seed[1], width: seed[2], height: seed[3])))
                        request.revision = revision
                        request.trackingLevel = variant == "v1_fast" ? .fast : .accurate
                        var handler = VNSequenceRequestHandler()
                        var automaticRecovery: AutomaticRecoveryReplay?
                        var automaticPipeline: AutomaticRecoveryPipeline?
                        var photoReplay: PhotoReplay?
                        var automaticCheckPixels: CVPixelBuffer?
                        var automaticCheckSelection: CGRect?
                        var snapshotSession: CMPhysicalObjectSnapshotPartsSession?
                        var patchTracker: CMPhysicalObjectPatchTracker?
                        var partsSession: CMPhysicalObjectPartsSession?
                        var legacySession: CMPhysicalObjectPatchSession?
                        var refinementDiagnostics: [String: Any] = [:]
                        var lastPixels: CVPixelBuffer?
                        var foregroundCheckPixels: CVPixelBuffer?
                        var foregroundCheckBox: CGRect?
                        defer { request.isLastFrame = true; request.cancel() }
                        var rows: [[String: Any]] = []
                        for (index, frame) in frames.enumerated() {
                            let row: [String: Any] = try autoreleasepool {
                                let bytes = try Data(contentsOf: folder.appendingPathComponent(frame["file"] as! String))
                                guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                                    throw NSError(domain: "PhysicalScaleProbe", code: 1)
                                }
                                var allocated: CVPixelBuffer?
                                guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
                                    kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:],
                                        kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
                                    &allocated) == kCVReturnSuccess, let pixels = allocated else {
                                    throw NSError(domain: "PhysicalScaleProbe", code: 3)
                                }
                                context.render(CIImage(cgImage: image), to: pixels)
                                if index == frames.count - 1 { lastPixels = pixels }
                                request.isLastFrame = variant != "automatic_recovery_pipeline" && !usesPhoto && index == frames.count - 1
                                let start = ProcessInfo.processInfo.systemUptime
                                if usesPhoto {
                                    guard let time = frame["captured_at"] as? Double else { throw NSError(domain: "PhotoFixtureTime", code: 1) }
                                    if index == 0 {
                                        guard let m = trace["selection_bbox"] as? [Double], m.count == 4 else {
                                            throw NSError(domain: "PhotoFixtureSelection", code: 1)
                                        }
                                        photoReplay = PhotoReplay(request: request, pixels: pixels,
                                            rect: CGRect(x: m[0], y: m[1], width: m[2], height: m[3]), useNano: variant != photoVariant, independent: variant == independentVariant)
                                    }
                                    var row = photoReplay!.row(pixels: pixels, time: time, seed: index == 0)
                                    row["perform_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
                                    row["index"] = index; row["file"] = frame["file"]; row["captured_at"] = time
                                    row["sha256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                                    row["thermal_state"] = ProcessInfo.processInfo.thermalState.rawValue
                                    return row
                                }
                                if variant == "automatic_recovery_pipeline" {
                                    var initializationMS = 0.0
                                    if index == 0 {
                                        guard let manual = trace["selection_bbox"] as? [Double], manual.count == 4 else {
                                            throw NSError(domain: "AutomaticRecoveryPipelineManualSelectionMissing", code: 2)
                                        }
                                        let pipeline = try AutomaticRecoveryPipeline(request: request, pixels: pixels,
                                            manual: manual, first: photoPair ? [:] : frame)
                                        automaticPipeline = pipeline
                                        initializationMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
                                        refinementDiagnostics = pipeline.initializationDiagnostics
                                        refinementDiagnostics["foreground_selection_enabled"] = true
                                        refinementDiagnostics["part_consensus_enabled"] = true
                                        refinementDiagnostics["trusted_snapshot_parts_enabled"] = true
                                        if pipeline.recovery != nil {
                                            automaticCheckPixels = pixels; automaticCheckSelection = pipeline.selection
                                        }
                                    }
                                    var row = try automaticPipeline!.measure(pixels: pixels, capturedAt: frame["captured_at"] as! Double)
                                    row["perform_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
                                    row["index"] = index; row["file"] = frame["file"]!; row["captured_at"] = frame["captured_at"]!
                                    row["sha256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                                    row["thermal_state"] = ProcessInfo.processInfo.thermalState.rawValue
                                    row["initialization_processing_ms"] = initializationMS
                                    return row
                                }
                                if variant == "automatic_recovery_replay" {
                                    if index == 0 {
                                        let manual = trace["selection_bbox"] as? [Double] ?? seed
                                        let chosen = frame["quality_source"] as? String == "foreground_selection_initialization" ? seed : manual
                                        let selection = CGRect(x: chosen[0], y: chosen[1], width: chosen[2], height: chosen[3])
                                        automaticRecovery = try AutomaticRecoveryReplay(request: request, pixels: pixels, selection: selection,
                                            decisions: trace["decisions"] as? [[String: Any]] ?? [])
                                        automaticCheckPixels = pixels; automaticCheckSelection = selection
                                    }
                                    var row = automaticRecovery!.measure(pixels: pixels, frame: frame)
                                    row["index"] = index; row["file"] = frame["file"]!; row["captured_at"] = frame["captured_at"]!
                                    row["sha256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                                    row["perform_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
                                    row["thermal_state"] = ProcessInfo.processInfo.thermalState.rawValue
                                    return row
                                }
                                if usesForeground, index == 0 {
                                    let manual = trace["selection_bbox"] as? [Double] ?? seed
                                    let selection = CGRect(x: manual[0], y: manual[1], width: manual[2], height: manual[3])
                                    let recorded = (frame["patch_diagnostics"] as? [String: Any])?["refined_bbox"] as? [Double]
                                    let recordedInitialization: (rect: CGRect, diagnostics: [String: Any])?
                                    if variant == "foreground_parts_auto", frame["quality_source"] as? String == "foreground_selection_initialization",
                                       let recorded, recorded.count == 4 {
                                        // The first-frame refinement is observed initial state,
                                        // not a later tracking answer. JPEG encoding can change
                                        // segmentation, so preserve the actual camera decision.
                                        recordedInitialization = (CGRect(x: recorded[0], y: recorded[1], width: recorded[2], height: recorded[3]),
                                            ["refined_bbox": recorded, "replay_initialization": "recorded_selection_frame"])
                                    } else { recordedInitialization = nil }
                                    if variant == "manual_parts_v2" {
                                        // Explicit replay comparison only: fixed parts of
                                        // the original manual selection, without refinement.
                                        request.inputObservation = VNDetectedObjectObservation(boundingBox: selection)
                                        partsSession = CMPhysicalObjectPartsSession(seed: selection)
                                        refinementDiagnostics = ["manual_parts_probe": true]
                                    } else if let refined = recordedInitialization ?? CMPhysicalObjectForegroundSelection.refine(pixels, selection: selection) {
                                        request.inputObservation = VNDetectedObjectObservation(boundingBox: refined.rect)
                                        refinementDiagnostics = refined.diagnostics
                                        if variant != "foreground_selection_v2" { partsSession = CMPhysicalObjectPartsSession(seed: refined.rect) }
                                    } else if variant == "foreground_parts_auto" {
                                        request.revision = VNTrackObjectRequestRevision1
                                        request.inputObservation = VNDetectedObjectObservation(boundingBox: selection)
                                        legacySession = CMPhysicalObjectPatchSession(request: request, buffer: pixels, selection: selection)
                                        refinementDiagnostics = ["declined": true, "fallback": "legacy_patch"]
                                    } else {
                                        throw NSError(domain: "PhysicalScaleProbeNoUniqueForeground", code: 7)
                                    }
                                    if legacySession == nil {
                                        foregroundCheckPixels = pixels
                                        foregroundCheckBox = request.inputObservation.boundingBox
                                    }
                                }
                                if variant == "trusted_snapshot_parts" || variant == "trusted_snapshot_recorded" || variant == "recorded_native_session" {
                                    let recordedInput = variant != "trusted_snapshot_parts"
                                    let nativeOnly = variant == "recorded_native_session"
                                    let selectionArray = trace["selection_bbox"] as? [Double] ?? seed
                                    let selection = CGRect(x: selectionArray[0], y: selectionArray[1], width: selectionArray[2], height: selectionArray[3])
                                    if index == 0 {
                                        request.inputObservation = VNDetectedObjectObservation(boundingBox: selection)
                                        let native = CMPhysicalObjectPatchSession(request: request, buffer: pixels, selection: selection)
                                        legacySession = native
                                        snapshotSession = CMPhysicalObjectSnapshotPartsSession(request: request, native: native, selection: selection)
                                    }
                                    let observation: VNDetectedObjectObservation
                                    if !nativeOnly && snapshotSession!.usesParts {
                                        observation = snapshotSession!.unavailableVisionObservation!
                                    } else if recordedInput {
                                        // Independent recorded Vision INPUT only; never the
                                        // accepted/held native output or any later annotation.
                                        guard let box = frame["vision_bbox"] as? [Double], box.count == 4,
                                              let confidence = frame["vision_confidence"] as? Double else {
                                            throw NSError(domain: "SnapshotRecordedVisionMissing", code: 1)
                                        }
                                        let recorded = RecordedObservation(boundingBox: CGRect(x: box[0], y: box[1], width: box[2], height: box[3]))
                                        recorded.recordedConfidence = Float(confidence)
                                        observation = recorded
                                    } else {
                                        do {
                                            try handler.perform([request], on: pixels, orientation: .up)
                                            guard let result = request.results?.first as? VNDetectedObjectObservation else {
                                                throw NSError(domain: "SnapshotPartsReplay", code: 1)
                                            }
                                            observation = result
                                        } catch {
                                            guard let unavailable = snapshotSession!.unavailableVisionObservation else { throw error }
                                            observation = unavailable
                                        }
                                    }
                                    let measured = nativeOnly ? legacySession!.measure(buffer: pixels, vision: observation) :
                                        snapshotSession!.measure(buffer: pixels, vision: observation, capturedAt: frame["captured_at"] as! Double)
                                    if measured.recoveredOriginalTemplate {
                                        handler = VNSequenceRequestHandler()
                                        request.inputObservation = VNDetectedObjectObservation(boundingBox: measured.rect)
                                    } else if !(observation is CMPhysicalObjectUnavailableWholeObservation) {
                                        request.inputObservation = observation
                                    }
                                    return ["index": index, "file": frame["file"]!, "captured_at": frame["captured_at"]!,
                                        "bbox": [measured.rect.minX, measured.rect.minY, measured.rect.width, measured.rect.height],
                                        "confidence": measured.quality, "accepted": !measured.isHeldObservation && measured.quality >= 0.5,
                                        "is_held": measured.isHeldObservation, "center_recovery": measured.supportsCenterRecovery,
                                        "recovered_original_template": measured.recoveredOriginalTemplate,
                                        "quality_source": measured.source, "patch_diagnostics": measured.patchDiagnostics,
                                        "reference_source": observation is CMPhysicalObjectUnavailableWholeObservation ? "unavailable_zero_confidence" : (recordedInput ? "recorded_vision_input" : "regenerated_vision"),
                                        "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                                        "perform_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                                        "thermal_state": ProcessInfo.processInfo.thermalState.rawValue]
                                }
                                if variant == "center_recovery_session" {
                                    let selection = CGRect(x: seed[0], y: seed[1], width: seed[2], height: seed[3])
                                    if index == 0 {
                                        legacySession = CMPhysicalObjectPatchSession(request: request, buffer: pixels, selection: selection)
                                    }
                                    // Controlled image test: no later coordinates or
                                    // Vision confidence can help the frozen identity.
                                    let measured = legacySession!.measure(buffer: pixels,
                                        vision: CMPhysicalObjectUnavailableWholeObservation(boundingBox: selection))
                                    return ["index": index, "file": frame["file"]!, "captured_at": frame["captured_at"]!,
                                        "bbox": [measured.rect.minX, measured.rect.minY, measured.rect.width, measured.rect.height],
                                        "confidence": measured.quality, "accepted": !measured.isHeldObservation && measured.quality >= 0.5,
                                        "is_held": measured.isHeldObservation, "center_recovery": measured.supportsCenterRecovery,
                                        "recovered_original_template": measured.recoveredOriginalTemplate,
                                        "quality_source": measured.source, "patch_diagnostics": measured.patchDiagnostics,
                                        "reference_source": "unavailable_zero_confidence",
                                        "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                                        "perform_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                                        "thermal_state": ProcessInfo.processInfo.thermalState.rawValue]
                                }
                                if variant == "patch" || variant == "adaptive_patch" || variant == "recorded_reference_patch" {
                                    if index == 0 {
                                        patchTracker = CMPhysicalObjectPatchTracker(pixelBuffer: pixels,
                                            selection: CGRect(x: seed[0], y: seed[1], width: seed[2], height: seed[3]))
                                    }
                                    var measurement: [String: Any]
                                    if variant == "recorded_reference_patch" {
                                        // Reuse the independently recorded Vision INPUT,
                                        // never a later accepted/held patch box as an answer.
                                        guard let box = frame["vision_bbox"] as? [Double], box.count == 4,
                                              let confidence = frame["vision_confidence"] as? Double else {
                                            throw NSError(domain: "PhysicalScaleProbe", code: 6)
                                        }
                                        measurement = patchTracker?.trackPixelBuffer(pixels,
                                            referenceRect: CGRect(x: box[0], y: box[1], width: box[2], height: box[3]),
                                            referenceConfidence: Float(confidence)) ?? ["accepted": false]
                                        measurement["vision_bbox"] = box
                                        measurement["vision_confidence"] = confidence
                                        measurement["reference_source"] = "recorded_vision_input"
                                    } else if variant == "adaptive_patch" {
                                        try handler.perform([request], on: pixels, orientation: .up)
                                        guard let observation = request.results?.first as? VNDetectedObjectObservation else {
                                            throw NSError(domain: "PhysicalScaleProbe", code: 4)
                                        }
                                        request.inputObservation = observation
                                        measurement = patchTracker?.trackPixelBuffer(pixels,
                                            referenceRect: observation.boundingBox, referenceConfidence: observation.confidence) ?? ["accepted": false]
                                        let box = observation.boundingBox
                                        measurement["vision_bbox"] = [box.minX, box.minY, box.width, box.height]
                                        measurement["vision_confidence"] = observation.confidence
                                    } else {
                                        measurement = patchTracker?.trackPixelBuffer(pixels) ?? ["accepted": false]
                                    }
                                    measurement["index"] = index
                                    measurement["captured_at"] = frame["captured_at"]!
                                    measurement["file"] = frame["file"]!
                                    measurement["sha256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                                    measurement["perform_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
                                    measurement["thermal_state"] = ProcessInfo.processInfo.thermalState.rawValue
                                    return measurement
                                }
                                let observation: VNDetectedObjectObservation
                                if let partsSession {
                                    observation = partsSession.wholeObservation(request: request, handler: handler, pixels: pixels)
                                } else {
                                    try handler.perform([request], on: pixels, orientation: .up)
                                    guard let result = request.results?.first as? VNDetectedObjectObservation else {
                                        throw NSError(domain: "PhysicalScaleProbe", code: 2)
                                    }
                                    observation = result
                                }
                                let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                                request.inputObservation = observation
                                let parts = partsSession?.measure(pixels: pixels, full: observation, lastFrame: index == frames.count - 1,
                                    initializationOnly: frame["quality_source"] as? String == "foreground_selection_initialization") ??
                                    legacySession?.measure(buffer: pixels, vision: observation)
                                let box = parts?.rect ?? observation.boundingBox
                                return ["index": index, "file": frame["file"]!, "captured_at": frame["captured_at"]!,
                                    "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                                    "bbox": [box.minX, box.minY, box.width, box.height].map { Double($0) },
                                    "confidence": parts?.quality ?? observation.confidence, "perform_ms": parts == nil ? ms : (ProcessInfo.processInfo.systemUptime - start) * 1000,
                                    "quality_source": parts?.source ?? "foreground_instance_vision",
                                    "initialization_only": frame["quality_source"] as? String == "foreground_selection_initialization",
                                    "parts_diagnostics": parts?.patchDiagnostics ?? [:],
                                    "thermal_state": ProcessInfo.processInfo.thermalState.rawValue]
                            }
                            rows.append(row)
                        }
                        var featureChecks: [String: Bool] = [:]
                        if let pixels = automaticCheckPixels, let selection = automaticCheckSelection {
                            featureChecks.merge(reacquirerChecks(pixels: pixels, selection: selection, context: context)) { _, new in new }
                        }
                        if usesForeground && legacySession == nil {
                            guard let pixels = foregroundCheckPixels, let box = foregroundCheckBox else {
                                throw NSError(domain: "ForegroundVisionChecks", code: 2)
                            }
                            // These are independent disappearance/reselection
                            // checks after eight confirmation frames. Initialize
                            // them from the actual selection image, not a fused
                            // box that may include occluded regions at the end.
                            featureChecks = try foregroundVisionChecks(pixels: pixels, box: box, context: context,
                                usesParts: partsSession != nil)
                        }
                        if let snapshotSession, snapshotSession.usesParts,
                           let pixels = lastPixels, let last = rows.last,
                           let quality = last["confidence"] as? Float, quality >= 0.5 {
                            featureChecks.merge(snapshotLossChecks(session: snapshotSession, pixels: pixels, last: last)) { _, new in new }
                        }
                        // Exercise the real locked feature tracker AFTER the
                        // unmodified replay, without changing any recorded row.
                        if (variant == "adaptive_patch" || variant == "recorded_reference_patch"), let patchTracker, let pixels = lastPixels,
                           rows.contains(where: { $0["measurement_source"] as? String == "foreground_features" }),
                           let lastBox = rows.last?["bbox"] as? [Double], lastBox.count == 4 {
                            let last = CGRect(x: lastBox[0], y: lastBox[1], width: lastBox[2], height: lastBox[3])
                            func altered(_ noise: Bool) -> CVPixelBuffer {
                                var allocated: CVPixelBuffer?
                                CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels),
                                    kCVPixelFormatType_32BGRA, nil, &allocated)
                                let value = allocated!
                                CVPixelBufferLockBaseAddress(value, [])
                                let data = CVPixelBufferGetBaseAddress(value)!.assumingMemoryBound(to: UInt8.self)
                                let stride = CVPixelBufferGetBytesPerRow(value)
                                var random: UInt32 = 8779
                                for y in 0..<CVPixelBufferGetHeight(value) { for x in 0..<CVPixelBufferGetWidth(value) {
                                    random = random &* 1664525 &+ 1013904223
                                    let v: UInt8 = noise ? UInt8(random >> 24) : 128
                                    let p = y * stride + x * 4
                                    data[p] = v; data[p+1] = v; data[p+2] = v; data[p+3] = 255
                                }}
                                CVPixelBufferUnlockBaseAddress(value, [])
                                return value
                            }
                            let hidden = patchTracker.trackPixelBuffer(altered(false), referenceRect: last, referenceConfidence: 1)
                            featureChecks["missing_target_rejects_without_background_fallback"] = hidden["accepted"] as? Bool == false &&
                                hidden["measurement_source"] as? String == "foreground_features"
                            let unrelated = patchTracker.trackPixelBuffer(altered(true), referenceRect: last, referenceConfidence: 1)
                            featureChecks["unrelated_texture_rejects_without_new_points"] = unrelated["accepted"] as? Bool == false &&
                                unrelated["measurement_source"] as? String == "foreground_features"
                            let occludedPixels = altered(false)
                            let image = CIImage(cvPixelBuffer: pixels)
                            let region = CGRect(x: last.minX * image.extent.width, y: last.minY * image.extent.height,
                                width: last.width * image.extent.width, height: last.height * image.extent.height)
                            let cover = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: region)
                            context.render(cover.composited(over: image), to: occludedPixels)
                            let occluded = patchTracker.trackPixelBuffer(occludedPixels, referenceRect: last, referenceConfidence: 1)
                            featureChecks["covered_selection_preserves_surrounding_background_but_rejects"] = occluded["accepted"] as? Bool == false &&
                                occluded["measurement_source"] as? String == "foreground_features"
                            let conflict = patchTracker.trackPixelBuffer(pixels, referenceRect: last.offsetBy(dx: 2, dy: 0), referenceConfidence: 0.95)
                            featureChecks["conflicting_strong_reference_rejects"] = conflict["accepted"] as? Bool == false
                            let same = patchTracker.trackPixelBuffer(pixels, referenceRect: last, referenceConfidence: 0.95)
                            let sameBox = same["bbox"] as? [Double] ?? []
                            featureChecks["rejected_frames_do_not_replace_feature_identity"] = same["accepted"] as? Bool == true &&
                                same["measurement_source"] as? String == "foreground_features" && sameBox.count == 4 &&
                                zip(sameBox, lastBox).allSatisfy { abs($0 - $1) < 0.015 }
                        }
                        return ["folder": folder.lastPathComponent, "saved_at_utc": trace["saved_at_utc"]!,
                            "round": round, "revision": request.revision, "variant": variant,
                            "seed_bbox": automaticPipeline.map { [$0.selection.minX, $0.selection.minY, $0.selection.width, $0.selection.height].map(Double.init) } ?? seed,
                            "manual_selection_bbox": trace["selection_bbox"] ?? seed, "rows": rows,
                            "selection_refinement": refinementDiagnostics,
                            "feature_route_check_seed": (usesForeground || automaticCheckPixels != nil) ? "initial_selection_frame" : "last_replay_frame",
                            "feature_route_checks": featureChecks]
                    }
                    runs.append(run)
                }
            }
        }
        let negatives = negativeChecks()
        let featureChecksPassed = runs.allSatisfy {
            ($0["feature_route_checks"] as? [String: Bool] ?? [:]).values.allSatisfy { $0 }
        }
        let result: [String: Any] = ["success": !runs.isEmpty && negatives.values.allSatisfy { $0 } && featureChecksPassed, "runs": runs,
            "negative_checks": negatives,
            "scope": "BGRA decoded from saved images. The automatic recovery, photo and NanoTrack comparison supplies only the same manual first box, pixels and times; baseline recomputes its own first refinement. Synchronous acknowledgements; no camera, BLE, main-queue delays or real-time frame drops. Outside a photo comparison, automatic_recovery_pipeline permits a recorded first refinement, and automatic_recovery_replay uses recorded pre-loss measurements.",
            "created_at_utc": ISO8601DateFormatter().string(from: Date()),
            "os": ProcessInfo.processInfo.operatingSystemVersionString]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            .write(to: output.appendingPathComponent("result.json"), options: .atomic)
        return result
    }

    static func runDeviceGateIfRequested() -> Bool {
        guard ProcessInfo.processInfo.arguments.contains("-KKPhysicalFollowScaleProbe") else { return false }
        if ProcessInfo.processInfo.arguments.contains("-KKPhysicalFollowAsyncProbe") { return true }
        executeDeviceGate()
    }

    private static var asyncGateStarted = false
    static func startAsyncDeviceGate() {
        guard !asyncGateStarted else { return }
        asyncGateStarted = true
        DispatchQueue.global(qos: .userInitiated).async { executeDeviceGate() }
    }

    private static func executeDeviceGate() -> Never {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        do {
            let folder = ProcessInfo.processInfo.arguments.contains("-KKPhysicalFollowFixtureReplay")
                ? "PhysicalObjectScaleProbeFixtures" : "PhysicalObjectFollowDiagnostics"
            let result = try run(root: caches.appendingPathComponent(folder),
                output: caches.appendingPathComponent("PhysicalObjectScaleProbeResults"))
            print("KK_PHYSICAL_SCALE_PROBE_RESULT success=\(result["success"]!) runs=\((result["runs"] as! [[String: Any]]).count)")
            exit(result["success"] as? Bool == true ? 0 : 1)
        } catch {
            print("KK_PHYSICAL_SCALE_PROBE_FAILED \(error)")
            exit(1)
        }
    }
}

/// Bounded local failure evidence. One image job at a time; no camera-buffer
/// queue, inference, control output, or writes until an actual follow failure.
final class CMPhysicalObjectFollowRecorder {
    static func runDeviceGateIfRequested() -> Bool {
        guard ProcessInfo.processInfo.arguments.contains("-KKPhysicalFollowRecorderGate") else { return false }
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhysicalObjectFollowRecorderSelfTest", isDirectory: true)
        var buffer: CVPixelBuffer?
        let created = CVPixelBufferCreate(kCFAllocatorDefault, 800, 600, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &buffer) == kCVReturnSuccess
        var result: [String: Any] = ["success": false, "scope": "synthetic pixels, native device codec; no camera or BLE"]
        if created, let buffer {
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 128, CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let identity = NSObject()
            let recorder = CMPhysicalObjectFollowRecorder(requestIdentity: ObjectIdentifier(identity),
                selection: CGRect(x: 0.2, y: 0.3, width: 0.1, height: 0.2), outputRoot: root)
            let done = DispatchSemaphore(value: 0)
            let now = ProcessInfo.processInfo.systemUptime
            recorder.recordImage(buffer, capturedAt: now, rect: recorder.selection, confidence: 0.48)
            recorder.save(reason: "synthetic_encoder_self_test") { folder in
                if let folder, let data = try? Data(contentsOf: folder.appendingPathComponent("trace.json")),
                   let trace = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let images = trace["images"] as? [[String: Any]], let first = images.first,
                   let name = first["file"] as? String,
                   let source = CGImageSourceCreateWithURL(folder.appendingPathComponent(name) as CFURL, nil),
                   let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    result["success"] = images.count == 1 && image.width == 640 && image.height == 480
                    result["image_count"] = images.count
                    result["width"] = image.width
                    result["height"] = image.height
                    result["encode_ms"] = first["encode_ms"]
                }
                done.signal()
            }
            if done.wait(timeout: .now() + 5) == .timedOut { result["error"] = "timeout" }
        }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? data.write(to: root.appendingPathComponent("result.json"), options: .atomic)
            print("KK_PHYSICAL_FOLLOW_RECORDER_RESULT=" + (String(data: data, encoding: .utf8) ?? "{}"))
        }
        exit(result["success"] as? Bool == true ? 0 : 1)
    }

    let requestIdentity: ObjectIdentifier
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "physical-follow.failure-evidence", qos: .utility)
    private lazy var context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
    private let root: URL
    private let selection: CGRect
    private let captureFullSession: Bool
    private let keepsSessionHistory: Bool
    private var closed = false
    private var imageInFlight = false
    private var lastImageAt: TimeInterval = -.infinity
    private var lastOfferedImageAt: TimeInterval = -.infinity
    private var imageAttempts = 0
    private var busyImageDrops = 0
    private var rateLimitedImages = 0
    // Only accessed on queue.
    private var images: [(time: TimeInterval, data: Data, metadata: [String: Any])] = []
    private var firstImage: (time: TimeInterval, data: Data, metadata: [String: Any])?
    private var decisions: [(time: TimeInterval, metadata: [String: Any])] = []
    private var imageBytes = 0
    private var evictedImages = 0
    private var encodingFailures = 0

    init(requestIdentity: ObjectIdentifier, selection: CGRect, outputRoot: URL? = nil,
         captureFullSession: Bool? = nil) {
        self.requestIdentity = requestIdentity
        self.selection = selection
        let arguments = ProcessInfo.processInfo.arguments
        self.captureFullSession = captureFullSession ?? arguments.contains("-KKPhysicalFollowFullSessionCapture")
        self.keepsSessionHistory = self.captureFullSession || arguments.contains("-KKPhysicalFollowSampledSessionCapture")
        self.root = outputRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhysicalObjectFollowDiagnostics", isDirectory: true)
    }

    private static func number(_ value: Double) -> Any { value.isFinite ? value as Any : NSNull() }
    private static func box(_ rect: CGRect) -> [Any] {
        [rect.minX, rect.minY, rect.width, rect.height].map { number(Double($0)) }
    }

    func recordImage(_ buffer: CVPixelBuffer, capturedAt: TimeInterval, rect: CGRect, confidence: Float,
                     source: String = "vision", visionRect: CGRect? = nil, visionConfidence: Float? = nil,
                     patchDiagnostics: [String: Any] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, capturedAt.isFinite, capturedAt > lastOfferedImageAt else { return }
        lastOfferedImageAt = capturedAt
        imageAttempts += 1
        guard !imageInFlight else { busyImageDrops += 1; return }
        guard capturedAt - lastImageAt >= (captureFullSession ? 0 : 0.1) else { rateLimitedImages += 1; return }
        imageInFlight = true
        lastImageAt = capturedAt
        queue.async { [self] in
            defer { lock.lock(); imageInFlight = false; lock.unlock() }
            autoreleasepool {
                var encoded = false
                defer { if !encoded { encodingFailures += 1 } }
                let startedAt = ProcessInfo.processInfo.systemUptime
                let imageSource = CIImage(cvPixelBuffer: buffer)
                let scale = min(1, 640 / max(imageSource.extent.width, imageSource.extent.height))
                let scaled = imageSource.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                guard let cgImage = context.createCGImage(scaled, from: scaled.extent.integral) else { return }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return }
                CGImageDestinationAddImage(destination, cgImage,
                    [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { return }
                let metadata: [String: Any] = ["captured_at": capturedAt, "bbox": Self.box(rect),
                    "confidence": Self.number(Double(confidence)), "width": cgImage.width, "height": cgImage.height,
                    "patch_diagnostics": patchDiagnostics,
                    "quality_source": source, "vision_bbox": Self.box(visionRect ?? rect),
                    "vision_confidence": Self.number(Double(visionConfidence ?? confidence)),
                    "source_width": CVPixelBufferGetWidth(buffer), "source_height": CVPixelBufferGetHeight(buffer),
                    "encode_ms": (ProcessInfo.processInfo.systemUptime - startedAt) * 1000]
                let sample = (time: capturedAt, data: data as Data, metadata: metadata)
                // Keep the first measured frame as well as the bounded tail.
                // A tail can begin after drift; never mistake it for selection.
                if firstImage == nil { firstImage = sample }
                images.append(sample)
                imageBytes += sample.data.count
                // Explicit wireless-debug mode keeps acquisition history at
                // the delivered processing cadence. Never queue buffers to
                // achieve it; report skipped frames instead. Bound memory even
                // when the operator waits before moving the target.
                let retention: TimeInterval = keepsSessionHistory ? 30 : 2
                let limit = captureFullSession ? 900 : (keepsSessionHistory ? 300 : 24)
                while let oldest = images.first,
                      oldest.time < capturedAt - retention || images.count > limit || imageBytes > 48 * 1024 * 1024 {
                    imageBytes -= images.removeFirst().data.count
                    evictedImages += 1
                }
                encoded = true
            }
        }
    }

    func recordDecision(capturedAt: TimeInterval, consumedAt: TimeInterval, rect: CGRect,
                        previous: CGRect, confidence: Float, ready: Bool, confirming: Bool,
                        reference: CGRect, geometry: String, reason: String?, source: String = "vision",
                        visionRect: CGRect? = nil, visionConfidence: Float? = nil,
                        patchDiagnostics: [String: Any] = [:], commandChannelReady: Bool? = nil,
                        awaitingFrameReentry: Bool = false, awaitingFrameReentryMatch: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, capturedAt.isFinite else { return }
        let metadata: [String: Any] = ["captured_at": capturedAt, "consumed_at": Self.number(consumedAt),
            "age_ms": Self.number((consumedAt - capturedAt) * 1000), "bbox": Self.box(rect),
            "previous_bbox": Self.box(previous), "confidence": Self.number(Double(confidence)),
            "patch_diagnostics": patchDiagnostics,
            "quality_source": source, "vision_bbox": Self.box(visionRect ?? rect),
            "vision_confidence": Self.number(Double(visionConfidence ?? confidence)),
            "ready": ready, "confirming": confirming, "awaiting_frame_reentry": awaitingFrameReentry,
            "awaiting_frame_reentry_match": awaitingFrameReentryMatch,
            "recovery_reference": Self.box(reference),
            "command_channel_ready": commandChannelReady as Any? ?? NSNull(),
            "geometry": geometry, "rejection": reason as Any? ?? NSNull()]
        queue.async { [self] in
            decisions.append((capturedAt, metadata))
            decisions.removeAll { $0.time < capturedAt - (keepsSessionHistory ? 30 : 3) }
            let limit = keepsSessionHistory ? 1800 : 180
            if decisions.count > limit { decisions.removeFirst(decisions.count - limit) }
        }
    }

    func discard() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    func save(reason: String, closing: Bool = true, completion: ((URL?) -> Void)? = nil) {
        lock.lock()
        guard !closed else { lock.unlock(); completion?(nil); return }
        closed = closing
        let failedAt = ProcessInfo.processInfo.systemUptime
        let attempts = imageAttempts, busyDrops = busyImageDrops, rateLimited = rateLimitedImages
        queue.async { [self] in
            let folder = root.appendingPathComponent("CMFollow-" + UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var imageRecords: [[String: Any]] = []
                for (index, sample) in images.enumerated() {
                    let name = String(format: "frame-%03d.jpg", index)
                    try sample.data.write(to: folder.appendingPathComponent(name), options: .atomic)
                    var metadata = sample.metadata
                    metadata["file"] = name
                    imageRecords.append(metadata)
                }
                var payload: [String: Any] = ["schema": 3, "debug_only": true,
                    "saved_at_utc": ISO8601DateFormatter().string(from: Date()), "failed_at": failedAt,
                    "failure_reason": reason, "selection_bbox": Self.box(selection),
                    "coordinates": "upright image, normalized lower-left bbox; JPEG is unannotated",
                    "images": imageRecords, "decisions": decisions.map { $0.metadata },
                    "capture_mode": captureFullSession ? "full_session" : (keepsSessionHistory ? "sampled_session" : "failure_tail"),
                    "capture_stats": ["offered_images": attempts, "busy_drops": busyDrops,
                        "rate_limited_images": rateLimited, "encoding_failures": encodingFailures,
                        "evicted_images": evictedImages, "retained_image_bytes": imageBytes,
                        "complete_from_first_observation": captureFullSession && attempts > 0 &&
                            attempts == images.count && busyDrops == 0 && encodingFailures == 0 && evictedImages == 0]]
                if let firstImage {
                    let name = "first-observation.jpg"
                    try firstImage.data.write(to: folder.appendingPathComponent(name), options: .atomic)
                    var metadata = firstImage.metadata
                    metadata["file"] = name
                    payload["first_observation"] = metadata
                    payload["tail_includes_first_observation"] = images.first?.time == firstImage.time
                }
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                try data.write(to: folder.appendingPathComponent("trace.json"), options: .atomic)
                // This directory is exclusively owned by this bounded debug cache.
                let folders = try FileManager.default.contentsOfDirectory(at: root,
                    includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey])
                    .filter { $0.lastPathComponent != folder.lastPathComponent && $0.lastPathComponent.hasPrefix("CMFollow-") &&
                        (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                    .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
                        > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
                for old in folders.dropFirst(2) { try? FileManager.default.removeItem(at: old) }
                kkLog("event=physical_follow_record_saved folder=\(folder.lastPathComponent) images=\(images.count) decisions=\(decisions.count) reason=\(reason)")
                completion?(folder)
            } catch {
                kkLog("event=physical_follow_record_failed error=\(error)")
                completion?(nil)
            }
        }
        lock.unlock()
    }
}
#endif

/// Fresh rectangles can still drift onto background; gate them before motion.
struct CMPhysicalObjectFollowSafety {
    private let recoveryEnabled: Bool
    private let hasPhotoReferenceSelection: Bool
    private(set) var photoRecoveryBoundary: TimeInterval?
    private(set) var searchingOriginalTarget = false
    private var reliableFrameCount = 0
    private var lastCapturedAt: TimeInterval?
    private var lastReliableRect: CGRect?
    private var lastReliableCapturedAt: TimeInterval?
    private var reliableVelocity = CGPoint.zero
    private var uncertainSince: TimeInterval?
    private var processingGapSince: TimeInterval?
    private var originalTargetReturnSince: TimeInterval?
    private var recoveryConfidences: [Float] = []
    private var frameReentrySince: TimeInterval?
    private var frameReentryCount = 0
    private var frameReentryWeakSince: TimeInterval?
    private var frameReentryStrongCount = 0
    var awaitingFrameReentry: Bool { frameReentrySince != nil }
    var awaitingFrameReentryMatch: Bool { awaitingFrameReentry && frameReentryWeakSince != nil }
    var awaitingOriginalTargetReturn: Bool { originalTargetReturnSince != nil }
    var confirmingTarget: Bool { searchingOriginalTarget || uncertainSince != nil || awaitingFrameReentry || awaitingOriginalTargetReturn }
    var ready: Bool { reliableFrameCount >= 3 && !confirmingTarget }
    private(set) var heldX = true
    private(set) var heldY = true
    private(set) var motionPauseReason: String?
    var motionPaused: Bool { motionPauseReason != nil }
    private var centeredSince: TimeInterval?
    private var centeredSamples = 0
    private struct Progress {
        var startedAt: TimeInterval
        var reference: Int
        var direction: Int
    }
    private var progressX: Progress?
    private var progressY: Progress?

    init(recoveryEnabled: Bool = false, photoReferenceSelection: CGRect? = nil) {
        self.recoveryEnabled = recoveryEnabled
        hasPhotoReferenceSelection = photoReferenceSelection != nil
        // The explicit selection is an identity anchor even if the object
        // disappears before the third frame. It never counts as a motion sample.
        lastReliableRect = photoReferenceSelection
    }

    func confirmationTimeoutReason(at time: TimeInterval) -> String? {
        guard !searchingOriginalTarget else { return nil }
        if let started = frameReentrySince, time - started >= 1.5 { return "frame_reentry_timeout" }
        if let started = originalTargetReturnSince {
            return time - started >= 1.5 ? "original_target_return_timeout" : nil
        }
        if let started = uncertainSince, time - started >= 0.45 { return "confidence_recovery_timeout" }
        if let started = frameReentryWeakSince, time - started >= 0.45 { return "frame_reentry_confidence_timeout" }
        return nil
    }

    func confirmationExpired(at time: TimeInterval) -> Bool {
        confirmationTimeoutReason(at: time) != nil
    }

    /// Let an existing parts tracker bridge a short missing match before
    /// replacing it with full-frame identity search. Repeated HOLDs do not
    /// renew this grace period, including transitions between wait states.
    func partRecoverySearchDue(at time: TimeInterval) -> Bool {
        guard time.isFinite else { return false }
        if searchingOriginalTarget { return true }
        guard let started = [uncertainSince, originalTargetReturnSince, frameReentryWeakSince]
            .compactMap({ $0 }).min() else { return false }
        let elapsed = time - started
        return elapsed.isFinite && elapsed >= 0.12
    }

    mutating func requireFreshPhotoConfirmation(after time: TimeInterval) {
        guard hasPhotoReferenceSelection, time.isFinite else { return }
        photoRecoveryBoundary = max(photoRecoveryBoundary ?? time, time)
    }

    /// A late pipeline result withdraws motion without declaring image identity
    /// lost. Retain local trackers and require three new, post-gap observations.
    @discardableResult
    mutating func beginProcessingGapHold(at time: TimeInterval) -> Bool {
        guard recoveryEnabled, time.isFinite, lastReliableRect != nil, !confirmingTarget else { return false }
        requireFreshPhotoConfirmation(after: time)
        processingGapSince = time
        uncertainSince = time
        reliableFrameCount = 0
        recoveryConfidences.removeAll(keepingCapacity: true)
        resetRecoveredControlBaseline()
        return true
    }

    /// Returns only a terminal reason. Opt-in sessions with a confirmed anchor
    /// instead retain that identity in a stopped search phase. The caller owns
    /// motor/UI effects and must compare searchingOriginalTarget before/after.
    mutating func handleConfirmationTimeout(at time: TimeInterval) -> String? {
        guard time.isFinite, let reason = confirmationTimeoutReason(at: time) else { return nil }
        guard beginOriginalTargetSearch() else { return reason }
        return nil
    }

    @discardableResult
    mutating func beginOriginalTargetSearch() -> Bool {
        guard recoveryEnabled, lastReliableRect != nil, !searchingOriginalTarget else { return false }
        searchingOriginalTarget = true
        processingGapSince = nil
        reliableFrameCount = 0
        uncertainSince = nil
        originalTargetReturnSince = nil
        frameReentrySince = nil
        frameReentryWeakSince = nil
        frameReentryCount = 0
        frameReentryStrongCount = 0
        recoveryConfidences.removeAll(keepingCapacity: true)
        resetRecoveredControlBaseline()
        return true
    }

    private mutating func resetRecoveredControlBaseline() {
        reliableVelocity = .zero
        heldX = true
        heldY = true
        motionPauseReason = nil
        progressX = nil
        progressY = nil
        centeredSince = nil
        centeredSamples = 0
    }

    private mutating func acceptSearchedIdentity(rect: CGRect, capturedAt: TimeInterval) {
        searchingOriginalTarget = false
        processingGapSince = nil
        uncertainSince = nil
        originalTargetReturnSince = nil
        frameReentrySince = nil
        frameReentryWeakSince = nil
        frameReentryCount = 0
        frameReentryStrongCount = 0
        recoveryConfidences.removeAll(keepingCapacity: true)
        lastCapturedAt = capturedAt
        lastReliableRect = rect
        lastReliableCapturedAt = capturedAt
        reliableFrameCount = 3
        resetRecoveredControlBaseline()
    }

    private mutating func observeOriginalSearch(rect: CGRect, confidence: Float, capturedAt: TimeInterval,
                                               isHeldObservation: Bool, supportsCenterRecovery: Bool,
                                               recoveredOriginalTemplate: Bool, recoveredVerifiedIdentity: Bool) -> String? {
        // Fresh rejected candidates still consume their frame token; neither
        // their positions nor ordinary high scores can replace the old anchor.
        lastCapturedAt = capturedAt
        guard recoveredVerifiedIdentity || recoveredOriginalTemplate else { return nil }
        let reason = recoveredVerifiedIdentity ? "invalid_verified_identity_recovery" : "invalid_original_target_recovery"
        guard !isHeldObservation, !(recoveredVerifiedIdentity && recoveredOriginalTemplate),
              confidence.isFinite, confidence >= 0.9, let anchor = lastReliableRect,
              [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite }),
              rect.size.width >= 0.002, rect.size.height >= 0.002,
              (0...1).contains(rect.midX), (0...1).contains(rect.midY) else { return reason }
        let visible = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !visible.isNull,
              visible.width * visible.height >= rect.width * rect.height * (0.85 - 1e-9) else { return reason }
        if recoveredVerifiedIdentity {
            // This separate tag already represents three independent complete
            // identity confirmations. Depth change may exceed the old anchor's
            // relative scale gate, but normalized current geometry stays bounded.
            guard rect.width <= 1, rect.height <= 1 else { return reason }
        } else {
            // The older frozen-template center bridge retains its narrower
            // center/scale contract, even after the short wait has expired.
            guard supportsCenterRecovery,
                  (0.25...0.75).contains(rect.midX), (0.25...0.75).contains(rect.midY),
                  (0.5...2).contains(rect.width * rect.height / (anchor.width * anchor.height)) else { return reason }
        }
        acceptSearchedIdentity(rect: rect, capturedAt: capturedAt)
        return nil
    }

    /// Motion estimates only bound recovery association; never send a predicted
    /// rectangle to the overlay, Vision, or motor controller.
    func confidenceRecoveryReference(at time: TimeInterval) -> CGRect? {
        guard let anchor = lastReliableRect, let capturedAt = lastReliableCapturedAt else { return nil }
        if searchingOriginalTarget || awaitingFrameReentry || awaitingOriginalTargetReturn { return anchor }
        let elapsed = min(0.45, max(0, time - capturedAt))
        let dx = max(-0.25, min(0.25, reliableVelocity.x * elapsed))
        let dy = max(-0.25, min(0.25, reliableVelocity.y * elapsed))
        return anchor.offsetBy(dx: dx, dy: dy)
    }

    private mutating func recordReliable(rect: CGRect, confidence: Float, capturedAt: TimeInterval) {
        if let previous = lastReliableRect, let previousTime = lastReliableCapturedAt {
            let elapsed = capturedAt - previousTime
            if elapsed > 0.15 {
                reliableVelocity = .zero
            } else if elapsed >= 0.005, confidence >= 0.6 {
                let vx = max(-1, min(1, (rect.midX - previous.midX) / elapsed))
                let vy = max(-1, min(1, (rect.midY - previous.midY) / elapsed))
                reliableVelocity.x = 0.5 * reliableVelocity.x + 0.5 * vx
                reliableVelocity.y = 0.5 * reliableVelocity.y + 0.5 * vy
            }
        }
        lastReliableRect = rect
        lastReliableCapturedAt = capturedAt
    }

    mutating func observe(rect: CGRect, previousRect: CGRect, confidence: Float,
                          capturedAt: TimeInterval, isHeldObservation: Bool = false,
                          supportsCenterRecovery: Bool = false, recoveredOriginalTemplate: Bool = false,
                          recoveredVerifiedIdentity: Bool = false,
                          recoveredPhotoReference: Bool = false, photoConfirmationStartedAt: TimeInterval? = nil) -> String? {
        guard capturedAt.isFinite,
              lastCapturedAt.map({ capturedAt > $0 }) ?? true else { return "nonmonotonic_frame" }
        if let processingGapSince, capturedAt < processingGapSince {
            lastCapturedAt = capturedAt
            return nil // Queued pre-gap images cannot count toward resumption.
        }
        if recoveredPhotoReference {
            // A full-frame photo match represents three independent, unique
            // observations. It can arrive before the normal timeout expires.
            guard hasPhotoReferenceSelection, recoveryEnabled,
                  !recoveredVerifiedIdentity, !recoveredOriginalTemplate else { return "invalid_photo_recovery" }
            guard let first = photoConfirmationStartedAt, first.isFinite, first < capturedAt,
                  photoRecoveryBoundary.map({ first >= $0 }) ?? true else {
                return "photo_recovery_before_barrier"
            }
            return observeOriginalSearch(rect: rect, confidence: confidence, capturedAt: capturedAt,
                isHeldObservation: isHeldObservation, supportsCenterRecovery: false,
                recoveredOriginalTemplate: false, recoveredVerifiedIdentity: true)
        }
        if recoveryEnabled {
            if let reason = handleConfirmationTimeout(at: capturedAt) { return reason }
            if searchingOriginalTarget {
                return observeOriginalSearch(rect: rect, confidence: confidence, capturedAt: capturedAt,
                    isHeldObservation: isHeldObservation, supportsCenterRecovery: supportsCenterRecovery,
                    recoveredOriginalTemplate: recoveredOriginalTemplate, recoveredVerifiedIdentity: recoveredVerifiedIdentity)
            }
        }
        guard !recoveredVerifiedIdentity else { return "invalid_verified_identity_recovery" }
        guard confidence.isFinite, confidence >= 0.2 else { return "low_confidence" }
        guard !isHeldObservation || (confidence < 0.5 && rect.equalTo(previousRect) && !recoveredOriginalTemplate)
        else { return "invalid_held_observation" }
        var visibleFractions: [CGFloat] = []
        for box in [rect, previousRect] {
            guard box.minX.isFinite, box.minY.isFinite,
                  box.width.isFinite, box.height.isFinite,
                  box.size.width >= 0.002, box.size.height >= 0.002 else { return "invalid_box" }
            let visible = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !visible.isNull, (0...1).contains(box.midX), (0...1).contains(box.midY) else { return "invalid_box" }
            visibleFractions.append(visible.width * visible.height / (box.width * box.height))
        }
        // Intersection arithmetic must not misclassify an exact 50%/85% edge
        // because of a floating-point rounding unit.
        let visibilityEpsilon: CGFloat = 1e-9
        let partiallyVisible = visibleFractions[0] < 0.85 - visibilityEpsilon
        // A previously confirmed target may remain under observation at an
        // edge, but must stop driving. The partial previous box is legal only
        // after that hold was established, including the first return frame.
        guard visibleFractions[0] >= 0.5 - visibilityEpsilon,
              visibleFractions[1] >= (awaitingFrameReentry ? 0.5 : 0.85) - visibilityEpsilon,
              !partiallyVisible || awaitingFrameReentry || (ready && confidence >= 0.75)
        else { return "invalid_box" }
        if let reason = confirmationTimeoutReason(at: capturedAt) { return reason }
        if recoveredOriginalTemplate {
            // Only the native matcher's three fresh, spatially unique matches
            // to the frozen original identity may bridge a discontinuity.
            guard awaitingOriginalTargetReturn, supportsCenterRecovery, confidence >= 0.9,
                  let anchor = lastReliableRect,
                  (0.25...0.75).contains(rect.midX), (0.25...0.75).contains(rect.midY),
                  visibleFractions[0] >= 0.85 - visibilityEpsilon,
                  (0.5...2).contains(rect.width * rect.height / (anchor.width * anchor.height))
            else { return "invalid_original_target_recovery" }
            originalTargetReturnSince = nil
            uncertainSince = nil
            frameReentrySince = nil
            frameReentryWeakSince = nil
            frameReentryCount = 0
            frameReentryStrongCount = 0
            recoveryConfidences.removeAll(keepingCapacity: true)
            lastCapturedAt = capturedAt
            lastReliableRect = rect
            lastReliableCapturedAt = capturedAt
            reliableVelocity = .zero
            reliableFrameCount = 3
            return nil
        }
        if isHeldObservation && supportsCenterRecovery && !awaitingOriginalTargetReturn {
            guard lastReliableRect != nil else { return "low_confidence" }
            // This deadline starts at the first missing match, never at the
            // latest candidate. Motors stay stopped for the entire search.
            originalTargetReturnSince = uncertainSince ?? frameReentryWeakSince ?? capturedAt
            reliableFrameCount = 0
            recoveryConfidences.removeAll(keepingCapacity: true)
            progressX = nil
            progressY = nil
            centeredSince = nil
            centeredSamples = 0
        }
        if isHeldObservation && awaitingOriginalTargetReturn {
            lastCapturedAt = capturedAt
            recoveryConfidences.removeAll(keepingCapacity: true)
            frameReentryCount = 0
            frameReentryStrongCount = 0
            return nil
        }
        let areaRatio = (rect.width * rect.height) / (previousRect.width * previousRect.height)
        guard (0.5...2.0).contains(areaRatio) else { return "box_scale_jump" }
        guard abs(rect.midX - previousRect.midX) <= max(0.04, previousRect.width * 0.5),
              abs(rect.midY - previousRect.midY) <= max(0.04, previousRect.height * 0.5)
        else { return "box_position_jump" }
        if partiallyVisible && !awaitingFrameReentry {
            frameReentrySince = capturedAt
            frameReentryCount = 0
            frameReentryWeakSince = nil
            frameReentryStrongCount = 0
            reliableFrameCount = 0
            reliableVelocity = .zero
            progressX = nil
            progressY = nil
            centeredSince = nil
            centeredSamples = 0
        }
        if awaitingFrameReentry {
            if let reason = confirmationTimeoutReason(at: capturedAt) { return reason }
            guard let anchor = lastReliableRect else { return "low_confidence" }
            let anchorAreaRatio = rect.width * rect.height / (anchor.width * anchor.height)
            guard isHeldObservation || ((0.5...2).contains(anchorAreaRatio) &&
                  abs(rect.midX - anchor.midX) <= max(0.10, anchor.width * 1.5) &&
                  abs(rect.midY - anchor.midY) <= max(0.10, anchor.height * 1.5))
            else { return "frame_reentry_identity_jump" }
            lastCapturedAt = capturedAt
            if confidence < 0.75 {
                // A short ambiguous match may interrupt the edge return. It
                // cannot refresh identity or count a held box as visible
                // recovery, and repeated weak frames never renew this clock.
                if frameReentryWeakSince == nil { frameReentryWeakSince = capturedAt }
                frameReentryStrongCount = 0
                frameReentryCount = 0
                return nil
            }
            if awaitingFrameReentryMatch {
                frameReentryStrongCount += 1
                if frameReentryStrongCount >= 3 {
                    frameReentryWeakSince = nil
                    frameReentryStrongCount = 0
                }
            }
            frameReentryCount = partiallyVisible ? 0 : frameReentryCount + 1
            if frameReentryCount >= 3 && !awaitingFrameReentryMatch {
                frameReentrySince = nil
                frameReentryCount = 0
                frameReentryWeakSince = nil
                frameReentryStrongCount = 0
                originalTargetReturnSince = nil
                uncertainSince = nil
                reliableFrameCount = 3
                lastReliableRect = rect
                lastReliableCapturedAt = capturedAt
                reliableVelocity = .zero
            }
            return nil
        }
        if confidence < 0.5, !confirmingTarget {
            // Only an already confirmed user selection gets a short recovery
            // window. Keep the same Vision tracker, but never drive from an
            // uncertain observation or move the reliable anchor onto background.
            guard lastReliableRect != nil else { return "low_confidence" }
            if capturedAt - (lastReliableCapturedAt ?? capturedAt) > 0.15 {
                reliableVelocity = .zero
            }
            uncertainSince = capturedAt
            reliableFrameCount = 0
            recoveryConfidences.removeAll(keepingCapacity: true)
            progressX = nil
            progressY = nil
            centeredSince = nil
            centeredSamples = 0
        }
        if confirmingTarget {
            if let reason = confirmationTimeoutReason(at: capturedAt) { return reason }
            if isHeldObservation {
                lastCapturedAt = capturedAt
                recoveryConfidences.removeAll(keepingCapacity: true)
                return nil
            }
            guard let anchor = lastReliableRect,
                  let expected = confidenceRecoveryReference(at: capturedAt) else { return "low_confidence" }
            let anchorAreaRatio = rect.width * rect.height / (anchor.width * anchor.height)
            guard (0.5...2).contains(anchorAreaRatio),
                  abs(rect.midX - expected.midX) <= max(0.10, anchor.width * 1.5),
                  abs(rect.midY - expected.midY) <= max(0.10, anchor.height * 1.5)
            else { return "confidence_recovery_identity_jump" }
            lastCapturedAt = capturedAt
            // Require three continuous usable observations and strong aggregate
            // evidence. A single 0.5...0.6 sample is valid during normal tracking;
            // it must not erase an otherwise reliable recovery under camera motion.
            // Below 0.5 still withdraws motion and resets the entire streak. The
            // Frozen association bounds and the original absolute deadline apply.
            if confidence >= 0.5 {
                recoveryConfidences.append(confidence)
                if recoveryConfidences.count > 3 { recoveryConfidences.removeFirst() }
            } else {
                recoveryConfidences.removeAll(keepingCapacity: true)
            }
            if recoveryConfidences.count == 3,
               recoveryConfidences.reduce(0, +) / 3 >= 0.6 {
                reliableFrameCount = 3
                processingGapSince = nil
                uncertainSince = nil
                originalTargetReturnSince = nil
                lastReliableRect = rect
                lastReliableCapturedAt = capturedAt
                reliableVelocity = .zero
                recoveryConfidences.removeAll(keepingCapacity: true)
            }
            return nil
        }
        lastCapturedAt = capturedAt
        reliableFrameCount += 1
        if ready { recordReliable(rect: rect, confidence: confidence, capturedAt: capturedAt) }
        return nil
    }

    /// Stop on sustained divergence/stall; never reverse automatically. Only
    /// count time when that axis was commanded and its BLE channel is ready.
    mutating func control(rawX: Int, rawY: Int, at: TimeInterval,
                          commandedX: Bool, commandedY: Bool) -> String? {
        if searchingOriginalTarget {
            heldX = true
            heldY = true
            return nil
        }
        heldX = heldX ? abs(rawX) < 150 : abs(rawX) <= 110
        heldY = heldY ? abs(rawY) < 190 : abs(rawY) <= 130
        if motionPaused {
            // Keep the same Vision request alive during a motor hold. Only a
            // reliable, centered target sustained across frames can re-arm it;
            // never search for, select, or switch to another target here.
            if abs(rawX) <= 110, abs(rawY) <= 130 {
                if centeredSince == nil { centeredSince = at }
                centeredSamples += 1
                if centeredSamples >= 3, at - (centeredSince ?? at) >= 0.15 {
                    motionPauseReason = nil
                    progressX = nil
                    progressY = nil
                    centeredSince = nil
                    centeredSamples = 0
                }
            } else {
                centeredSince = nil
                centeredSamples = 0
            }
            return nil
        }
        func update(_ progress: inout Progress?, raw: Int, held: Bool, commanded: Bool) -> String? {
            guard !held, commanded else { progress = nil; return nil }
            let magnitude = abs(raw)
            let direction = raw < 0 ? -1 : 1
            guard let previous = progress, previous.direction == direction else {
                progress = Progress(startedAt: at, reference: magnitude, direction: direction)
                return nil
            }
            if magnitude <= previous.reference - 35 {
                progress = Progress(startedAt: at, reference: magnitude, direction: direction)
                return nil
            }
            let elapsed = at - previous.startedAt
            // Ordinary moving targets can temporarily increase center error.
            // Small errors alone are not evidence of tracking/servo failure.
            // Retain the response window so a genuinely diverging loop is
            // stopped as soon as it reaches the outer 20% error boundary.
            if elapsed >= 2, magnitude >= 400, magnitude >= previous.reference + 60 { return "diverging" }
            if elapsed >= 4, magnitude >= 400 { return "not_converging" }
            return nil
        }
        if let reason = update(&progressX, raw: rawX, held: heldX, commanded: commandedX) {
            motionPauseReason = "yaw_" + reason
            return motionPauseReason
        }
        if let reason = update(&progressY, raw: rawY, held: heldY, commanded: commandedY) {
            motionPauseReason = "pitch_" + reason
            return motionPauseReason
        }
        return nil
    }
}

extension CameraManager {
    /// One replacement is allowed only after three native frozen-template
    /// confirmations. Ordinary frames feed back the actual Vision observation.
    func applyObjectTrackingFeedback(observation: VNDetectedObjectObservation,
                                     measurement: CMPhysicalObjectMeasurement?, request: VNTrackObjectRequest) {
        guard currentTrackingRequest === request else { return }
        if let measurement, measurement.recoveredOriginalTemplate || measurement.recoveredPhotoReference {
            // Release the old sequence's tracker state before starting this
            // measured position. Repeated returns must not accumulate trackers.
            // The explicit user request and native frozen identity stay intact.
            sequenceHandler = VNSequenceRequestHandler()
            request.inputObservation = VNDetectedObjectObservation(boundingBox: measurement.rect)
        } else if !(observation is CMPhysicalObjectUnavailableWholeObservation) {
            request.inputObservation = observation
        }
    }

    func performObjectTrackingObservation(buffer: CVPixelBuffer, request: VNTrackObjectRequest) throws -> VNDetectedObjectObservation? {
        if usesPhysicalObjectPhotoReference, isPhysicalObjectTrackingActive,
           let photo = physicalObjectPhotoSession, photo.requestIdentity == ObjectIdentifier(request) {
            guard photo.needsVisionProposal else { return photo.unavailableVisionObservation }
            // Vision only proposes geometry. A missing proposal still allows
            // the frozen photo to find its own target in the current pixels.
            do {
                try sequenceHandler.perform([request], on: buffer)
                return request.results?.first as? VNDetectedObjectObservation ?? photo.unavailableVisionObservation
            } catch { return photo.unavailableVisionObservation }
        }
        #if DEBUG
        if isPhysicalObjectTrackingActive,
           let recovery = physicalObjectRecoverySession,
           recovery.requestIdentity == ObjectIdentifier(request),
           recovery.isSearching || recovery.hasResumedTracking {
            return recovery.observation(buffer: buffer)
        }
        if isPhysicalObjectTrackingActive,
           let snapshot = physicalObjectSnapshotPartsSession,
           snapshot.requestIdentity == ObjectIdentifier(request), snapshot.usesParts {
            return snapshot.unavailableVisionObservation
        }
        if isPhysicalObjectTrackingActive,
           physicalObjectForegroundSelectionRequest == ObjectIdentifier(request),
           let parts = physicalObjectForegroundPartsSession {
            return parts.wholeObservation(request: request, handler: sequenceHandler, pixels: buffer)
        }
        #endif
        do {
            try sequenceHandler.perform([request], on: buffer)
        } catch {
            #if DEBUG
            if isPhysicalObjectTrackingActive,
               let recovery = physicalObjectRecoverySession,
               recovery.requestIdentity == ObjectIdentifier(request) {
                return recovery.unavailableObservation
            }
            #endif
            // A missing Vision reference cannot cancel the independently
            // established native identity before its stopped return window.
            guard isPhysicalObjectTrackingActive,
                  let session = physicalObjectPatchSession, session.requestIdentity == ObjectIdentifier(request),
                  let unavailable = session.unavailableVisionObservation else { throw error }
            return unavailable
        }
        if let observation = request.results?.first as? VNDetectedObjectObservation { return observation }
        #if DEBUG
        if isPhysicalObjectTrackingActive,
           let recovery = physicalObjectRecoverySession,
           recovery.requestIdentity == ObjectIdentifier(request) { return recovery.unavailableObservation }
        #endif
        if isPhysicalObjectTrackingActive,
           let session = physicalObjectPatchSession, session.requestIdentity == ObjectIdentifier(request) {
            return session.unavailableVisionObservation
        }
        return nil
    }

    func preparePhysicalObjectRecoveryIdentity(buffer: CVPixelBuffer, request: VNTrackObjectRequest, selection: CGRect) {
        #if DEBUG
        if physicalObjectAutoRecoveryEnabled,
           physicalObjectRecoveryPreparedRequest != ObjectIdentifier(request) {
            physicalObjectRecoveryPreparedRequest = ObjectIdentifier(request)
            physicalObjectRecoverySession = CMPhysicalObjectRecoverySession(request: request,
                buffer: buffer, selection: selection)
            if physicalObjectRecoverySession == nil {
                DispatchQueue.main.async { [weak self, request] in
                    guard let self, self.currentTrackingRequest === request else { return }
                    self.physicalObjectFollowSafety = CMPhysicalObjectFollowSafety()
                    kkLog("event=physical_follow_recovery_unavailable reason=insufficient_initial_identity")
                }
            }
        }
        #endif
    }

    func preparePhysicalObjectSelectionIfNeeded(buffer: CVPixelBuffer, request: VNTrackObjectRequest,
                                                capturedAt: TimeInterval? = nil) -> Bool {
        if usesPhysicalObjectPhotoReference {
            if physicalObjectPhotoSession?.requestIdentity == ObjectIdentifier(request) { return false }
            // No image older than the release gesture, stale in the camera
            // queue, or without a camera timestamp may become the reference.
            guard let capturedAt, capturedAt.isFinite, capturedAt >= physicalObjectFollowStartedAt,
                  (0...0.25).contains(ProcessInfo.processInfo.systemUptime - capturedAt),
                  currentTrackingRequest === request else { return true }
            let selection = request.inputObservation.boundingBox
            let photo = CMPhysicalObjectPhotoSession(request: request, buffer: buffer, selection: selection)
            physicalObjectPhotoSession = photo
            if photo.isAvailable {
                // Prime the proposal on the exact image used for the reference.
                // A missing Vision result does not invalidate the photo itself.
                if let observation = try? performObjectTrackingObservation(buffer: buffer, request: request) {
                    applyObjectTrackingFeedback(observation: observation, measurement: nil, request: request)
                }
                let seed = photo.unavailableVisionObservation
                recordPhysicalObjectFollowImage(buffer, request: request, capturedAt: capturedAt, observation: seed,
                    measurement: CMPhysicalObjectMeasurement(rect: seed.boundingBox, previousRect: selection, quality: 0,
                        source: "photo_reference_capture", patchDiagnostics: photo.initializationDiagnostics))
            }
            DispatchQueue.main.async { [weak self, request] in
                guard let self, self.currentTrackingRequest === request else { return }
                self.physicalObjectPreparingSelection = false
                if !photo.isAvailable {
                    self.physicalObjectPhotoCaptureFailed = true
                    self.pausePhysicalObjectFollowing(reason: "photo_reference_unavailable")
                }
            }
            return true
        }
        #if DEBUG
        guard CMPhysicalObjectForegroundSelection.enabled else {
            preparePhysicalObjectRecoveryIdentity(buffer: buffer, request: request, selection: request.inputObservation.boundingBox)
            return false
        }
        let identity = ObjectIdentifier(request)
        guard physicalObjectPreparedSelectionRequest !== request else { return false }
        physicalObjectPreparedSelectionRequest = request
        physicalObjectForegroundSelectionRequest = nil
        physicalObjectForegroundSelectionDiagnostics = [:]
        physicalObjectForegroundPartsSession = nil
        let refined = CMPhysicalObjectForegroundSelection.refine(buffer, selection: request.inputObservation.boundingBox)
        guard currentTrackingRequest === request else { return true }
        // Use the same exact selection pixels and bounded refinement as the
        // normal tracker; later boxes cannot redefine this original identity.
        preparePhysicalObjectRecoveryIdentity(buffer: buffer, request: request,
            selection: refined?.rect ?? request.inputObservation.boundingBox)
        if let refined {
            // No Vision perform has run on this request yet, so this starts
            // exactly one tracker rather than replacing a live tracker.
            request.revision = VNTrackObjectRequestRevision2
            request.inputObservation = VNDetectedObjectObservation(boundingBox: refined.rect)
            physicalObjectForegroundSelectionRequest = identity
            physicalObjectForegroundSelectionDiagnostics = refined.diagnostics
            if CMPhysicalObjectPartsSession.enabled {
                physicalObjectForegroundPartsSession = CMPhysicalObjectPartsSession(seed: refined.rect)
            }
            do {
                // Seed appearances on the exact pixels used for segmentation.
                // The next capture may have moved during the model's latency.
                // This observation is initialization only: no UI/control send.
                try sequenceHandler.perform([request], on: buffer)
                guard let first = request.results?.first as? VNDetectedObjectObservation else {
                    throw NSError(domain: "PhysicalForegroundInitialization", code: 1)
                }
                guard currentTrackingRequest === request else { return true }
                request.inputObservation = first
                _ = physicalObjectForegroundPartsSession?.measure(pixels: buffer, full: first, initializationOnly: true)
                physicalObjectForegroundSelectionDiagnostics["initialized_on_selection_frame"] = true
                var initialization = physicalObjectForegroundSelectionDiagnostics
                initialization["initialization_only"] = true
                recordPhysicalObjectFollowImage(buffer, request: request, capturedAt: capturedAt, observation: first,
                    measurement: CMPhysicalObjectMeasurement(rect: first.boundingBox, previousRect: refined.rect,
                        quality: first.confidence, source: "foreground_selection_initialization", patchDiagnostics: initialization))
            } catch {
                kkLog("event=physical_selection_initialization_failed error=\(error)")
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.currentTrackingRequest === request else { return }
                    self.handleObjectTrackingFailure(reason: "foreground_initialization_failed")
                }
                return true
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentTrackingRequest === request else { return }
            self.physicalObjectPreparingSelection = false
            self.physicalObjectFollowStartedAt = ProcessInfo.processInfo.systemUptime
            self.renderPhysicalObjectDiscovery()
        }
        return true
        #else
        return false
        #endif
    }

    func physicalObjectMeasurement(buffer: CVPixelBuffer, request: VNTrackObjectRequest,
                                   observation: VNDetectedObjectObservation, selection: CGRect,
                                   capturedAt: TimeInterval? = nil) -> CMPhysicalObjectMeasurement {
        if usesPhysicalObjectPhotoReference {
            guard let photo = physicalObjectPhotoSession, photo.requestIdentity == ObjectIdentifier(request) else {
                return CMPhysicalObjectMeasurement(rect: selection, previousRect: selection, quality: 0.3,
                    source: "photo_reference_missing", isHeldObservation: true)
            }
            guard let capturedAt, capturedAt.isFinite,
                  (0...0.25).contains(ProcessInfo.processInfo.systemUptime - capturedAt) else {
                // Queued images cannot contribute the first two votes of a
                // later, apparently fresh three-frame identity confirmation.
                photo.beginSearch()
                let anchor = photo.unavailableVisionObservation.boundingBox
                return CMPhysicalObjectMeasurement(rect: anchor, previousRect: anchor, quality: 0.3,
                    source: "photo_reference_stale_frame", isHeldObservation: true)
            }
            return photo.measure(buffer: buffer, vision: observation, capturedAt: capturedAt)
        }
        #if DEBUG
        if let capturedAt, let recovery = physicalObjectRecoverySession,
           recovery.requestIdentity == ObjectIdentifier(request),
           recovery.isSearching || recovery.hasResumedTracking {
            return recovery.measure(buffer: buffer, observation: observation, capturedAt: capturedAt)
        }
        #endif
        return legacyPhysicalObjectMeasurement(buffer: buffer, request: request,
            observation: observation, selection: selection, capturedAt: capturedAt)
    }

    func legacyPhysicalObjectMeasurement(buffer: CVPixelBuffer, request: VNTrackObjectRequest,
                                         observation: VNDetectedObjectObservation, selection: CGRect,
                                         capturedAt: TimeInterval? = nil) -> CMPhysicalObjectMeasurement {
        #if DEBUG
        if physicalObjectForegroundSelectionRequest == ObjectIdentifier(request) {
            var diagnostics = physicalObjectForegroundSelectionDiagnostics
            if let parts = physicalObjectForegroundPartsSession {
                let measured = parts.measure(pixels: buffer, full: observation)
                diagnostics.merge(measured.patchDiagnostics) { _, new in new }
                diagnostics["measurement_source"] = measured.source
                diagnostics["vision_revision"] = 2
                return CMPhysicalObjectMeasurement(rect: measured.rect, previousRect: measured.previousRect,
                    quality: measured.quality, source: measured.source, patchDiagnostics: diagnostics,
                    isHeldObservation: measured.isHeldObservation)
            }
            diagnostics["measurement_source"] = "foreground_instance_vision"
            diagnostics["vision_revision"] = 2
            return CMPhysicalObjectMeasurement(rect: observation.boundingBox, previousRect: selection,
                quality: observation.confidence, source: "foreground_instance_vision", patchDiagnostics: diagnostics)
        }
        #endif
        if physicalObjectPatchSession?.requestIdentity != ObjectIdentifier(request) {
            physicalObjectPatchSession = CMPhysicalObjectPatchSession(request: request, buffer: buffer, selection: selection)
        }
        #if DEBUG
        if CMPhysicalObjectSnapshotPartsSession.enabled, let capturedAt {
            if physicalObjectSnapshotPartsSession?.requestIdentity != ObjectIdentifier(request) {
                physicalObjectSnapshotPartsSession = CMPhysicalObjectSnapshotPartsSession(request: request,
                    native: physicalObjectPatchSession!, selection: selection)
            }
            return physicalObjectSnapshotPartsSession!.measure(buffer: buffer, vision: observation, capturedAt: capturedAt)
        }
        #endif
        return physicalObjectPatchSession!.measure(buffer: buffer, vision: observation)
    }

    func releasePhysicalObjectPatchSession(request: VNTrackObjectRequest?) {
        guard let request else { return }
        let identity = ObjectIdentifier(request)
        physicalObjectStateLock.lock()
        if physicalObjectPhotoSearchRequest?.request === request { physicalObjectPhotoSearchRequest = nil }
        if physicalObjectApprovedMovingFrame?.request === request { physicalObjectApprovedMovingFrame = nil }
        physicalObjectStateLock.unlock()
        #if DEBUG
        physicalObjectRecoveryMailbox.clear(request: request)
        #endif
        dataOutputQueue.async { [weak self, request] in
            guard let self else { return }
            if self.physicalObjectPhotoSession?.requestIdentity == identity { self.physicalObjectPhotoSession = nil }
            if self.physicalObjectPatchSession?.requestIdentity == identity { self.physicalObjectPatchSession = nil }
            #if DEBUG
            if self.physicalObjectRecoverySession?.requestIdentity == identity { self.physicalObjectRecoverySession = nil }
            if self.physicalObjectRecoveryPreparedRequest == identity { self.physicalObjectRecoveryPreparedRequest = nil }
            if self.physicalObjectSnapshotPartsSession?.requestIdentity == identity { self.physicalObjectSnapshotPartsSession = nil }
            if self.physicalObjectPreparedSelectionRequest === request {
                self.physicalObjectPreparedSelectionRequest = nil
                self.physicalObjectForegroundSelectionRequest = nil
                self.physicalObjectForegroundSelectionDiagnostics = [:]
                self.physicalObjectForegroundPartsSession = nil
            }
            #endif
        }
    }

    func startPhysicalObjectFollowRecording() {
        #if DEBUG
        guard let request = currentTrackingRequest else { return }
        let recorder = CMPhysicalObjectFollowRecorder(requestIdentity: ObjectIdentifier(request),
            selection: request.inputObservation.boundingBox)
        physicalObjectStateLock.lock()
        physicalObjectFollowRecorder?.discard()
        physicalObjectFollowRecorder = recorder
        physicalObjectStateLock.unlock()
        #endif
    }

    func discardPhysicalObjectFollowRecording() {
        #if DEBUG
        physicalObjectStateLock.lock()
        let recorder = physicalObjectFollowRecorder
        physicalObjectFollowRecorder = nil
        physicalObjectStateLock.unlock()
        recorder?.discard()
        #endif
    }

    func savePhysicalObjectFollowRecording(reason: String) {
        #if DEBUG
        physicalObjectStateLock.lock()
        let recorder = physicalObjectFollowRecorder
        physicalObjectFollowRecorder = nil
        physicalObjectStateLock.unlock()
        recorder?.save(reason: reason)
        #endif
    }

    func checkpointPhysicalObjectFollowRecording(reason: String) {
        #if DEBUG
        physicalObjectStateLock.lock()
        let recorder = physicalObjectFollowRecorder
        physicalObjectStateLock.unlock()
        recorder?.save(reason: reason, closing: false)
        #endif
    }

    var usesPhysicalObjectPhotoReference: Bool {
        CMPhysicalObjectPhotoSession.enabled
    }

    var physicalObjectAutoRecoveryEnabled: Bool {
        if usesPhysicalObjectPhotoReference { return true }
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-KKPhysicalFollowAutoRecovery")
        #else
        return false
        #endif
    }

    /// Search owns the same explicit selection while all motor output stays off.
    /// The next physical callback applies this command before tracking work.
    func physicalObjectRecoverySearchDidBegin(reason: String = "confirmation_timeout") {
        guard isPhysicalObjectTrackingActive, physicalObjectIsFollowing,
              physicalObjectFollowSafety.searchingOriginalTarget,
              let request = currentTrackingRequest else { return }
        sendTrackingCommand(state: .exit, centerPoint: .zero)
        trackingLayer?.path = nil
        checkpointPhysicalObjectFollowRecording(reason: "automatic_recovery_search_started")
        requestPhysicalObjectIdentitySearch(request: request, reason: reason)
        kkLog("event=physical_follow_recovery_search_requested reason=\(reason) original_identity_retained=true motors_stopped=true")
        renderPhysicalObjectDiscovery()
    }

    func requestPhysicalObjectIdentitySearch(request: VNTrackObjectRequest, reason: String) {
        guard currentTrackingRequest === request else { return }
        if usesPhysicalObjectPhotoReference {
            if reason != "photo_recovery_before_barrier" || physicalObjectFollowSafety.photoRecoveryBoundary == nil {
                physicalObjectFollowSafety.requireFreshPhotoConfirmation(after: ProcessInfo.processInfo.systemUptime)
            }
            guard let boundary = physicalObjectFollowSafety.photoRecoveryBoundary else { return }
            physicalObjectStateLock.lock()
            physicalObjectPhotoSearchRequest = (request,boundary)
            physicalObjectStateLock.unlock()
            return
        }
        #if DEBUG
        physicalObjectRecoveryMailbox.enqueue(.search(reason), request: request)
        #endif
    }

    func physicalObjectRecoverySearchDidFinish() {
        checkpointPhysicalObjectFollowRecording(reason: "automatic_original_target_recovered")
        kkLog("event=physical_follow_recovery_search_finished original_identity_verified=true")
        renderPhysicalObjectDiscovery()
    }

    func commitPhysicalObjectRecoveredIdentity(buffer: CVPixelBuffer, request: VNTrackObjectRequest,
                                               measurement: CMPhysicalObjectMeasurement, capturedAt: TimeInterval) {
        #if DEBUG
        guard currentTrackingRequest === request else { return }
        physicalObjectRecoveryMailbox.enqueue(.commit(buffer, measurement.rect, capturedAt), request: request)
        #endif
    }

    func rejectPhysicalObjectRecoveryProposal(request: VNTrackObjectRequest, capturedAt: TimeInterval?) {
        #if DEBUG
        guard currentTrackingRequest === request, let capturedAt else { return }
        physicalObjectRecoveryMailbox.enqueue(.reject(capturedAt), request: request)
        #endif
    }

    func cancelPhysicalObjectRecoveryForLocalReturn(request: VNTrackObjectRequest,
                                                    rect: CGRect, capturedAt: TimeInterval) {
        #if DEBUG
        guard currentTrackingRequest === request,
              let generation = physicalObjectRecoveryMailbox.currentSearchGeneration(request: request) else { return }
        physicalObjectRecoveryMailbox.enqueue(.cancelLocal(rect, capturedAt, generation), request: request)
        #endif
    }

    func recordPhysicalObjectVerifiedAppearance(buffer: CVPixelBuffer, request: VNTrackObjectRequest,
                                               measurement: CMPhysicalObjectMeasurement, capturedAt: TimeInterval) {
        if usesPhysicalObjectPhotoReference {
            guard currentTrackingRequest === request, physicalObjectFollowSafety.ready,
                  measurement.source == "moving_print_tracking" || measurement.source == "moving_print_recovered" else { return }
            physicalObjectStateLock.lock()
            physicalObjectApprovedMovingFrame = (request,capturedAt)
            physicalObjectStateLock.unlock()
            return
        }
        #if DEBUG
        // Only the main-thread, current-request, fresh and Safety-ready result
        // may authorize a new view. Its exact pixels travel with that decision.
        guard !usesPhysicalObjectPhotoReference, currentTrackingRequest === request else { return }
        physicalObjectRecoveryMailbox.enqueue(.reliable(buffer, measurement, capturedAt), request: request)
        #endif
    }

    func invalidatePhysicalObjectRecoveryLearning(request: VNTrackObjectRequest) {
        #if DEBUG
        guard !usesPhysicalObjectPhotoReference, currentTrackingRequest === request else { return }
        physicalObjectRecoveryMailbox.enqueue(.invalidate, request: request)
        #endif
    }

    func drainPhysicalObjectRecoveryCommands(request: VNTrackObjectRequest) {
        if usesPhysicalObjectPhotoReference {
            physicalObjectStateLock.lock()
            let search = physicalObjectPhotoSearchRequest
            let approval = physicalObjectApprovedMovingFrame
            if search?.request === request { physicalObjectPhotoSearchRequest = nil }
            if approval?.request === request { physicalObjectApprovedMovingFrame = nil }
            physicalObjectStateLock.unlock()
            if let session = physicalObjectPhotoSession, session.requestIdentity == ObjectIdentifier(request) {
                if let approval, approval.request === request { session.approveMovingFrame(at: approval.time) }
                if let search, search.request === request { session.beginSearch(after: search.after) }
            }
            return
        }
        #if DEBUG
        guard currentTrackingRequest === request,
              let recovery = physicalObjectRecoverySession,
              recovery.requestIdentity == ObjectIdentifier(request) else { return }
        for command in physicalObjectRecoveryMailbox.take(request: request) {
            guard currentTrackingRequest === request else { return }
            let delayMs = (ProcessInfo.processInfo.systemUptime - command.requestedAt) * 1000
            switch command.payload {
            case .search(let reason):
                recovery.beginSearch()
                kkLog("event=physical_follow_recovery_command_applied command=search reason=\(reason) delayMs=\(delayMs)")
            case .commit(let buffer, let rect, let capturedAt):
                let committed = recovery.commitRecovery(buffer: buffer, rect: rect, capturedAt: capturedAt)
                if committed {
                    physicalObjectPatchSession = nil
                    physicalObjectSnapshotPartsSession = nil
                    physicalObjectForegroundPartsSession = nil
                    physicalObjectForegroundSelectionRequest = nil
                }
                kkLog("event=physical_follow_recovery_command_applied command=commit accepted=\(committed) delayMs=\(delayMs)")
            case .reject(let capturedAt):
                recovery.rejectRecovery(capturedAt: capturedAt)
                kkLog("event=physical_follow_recovery_command_applied command=reject delayMs=\(delayMs)")
            case .cancelLocal(let rect, let capturedAt, let generation):
                guard physicalObjectRecoveryMailbox.currentSearchGeneration(request: request) == generation else { continue }
                let cancelled = recovery.cancelSearchForLocalRecovery(rect: rect, capturedAt: capturedAt)
                kkLog("event=physical_follow_recovery_command_applied command=cancel_local accepted=\(cancelled) delayMs=\(delayMs)")
            case .reliable(let buffer, let measurement, let capturedAt):
                recovery.observeReliable(measurement: measurement, buffer: buffer, capturedAt: capturedAt)
            case .invalidate:
                recovery.invalidateReliableSequence()
            }
        }
        #endif
    }

    func recordPhysicalObjectFollowImage(_ buffer: CVPixelBuffer, request: VNTrackObjectRequest,
                                        capturedAt: TimeInterval?, observation: VNDetectedObjectObservation,
                                        measurement: CMPhysicalObjectMeasurement? = nil) {
        #if DEBUG
        guard let capturedAt else { return }
        physicalObjectStateLock.lock()
        let recorder = physicalObjectFollowRecorder
        physicalObjectStateLock.unlock()
        guard recorder?.requestIdentity == ObjectIdentifier(request) else { return }
        recorder?.recordImage(buffer, capturedAt: capturedAt, rect: measurement?.rect ?? observation.boundingBox,
            confidence: measurement?.quality ?? observation.confidence, source: measurement?.source ?? "vision",
            visionRect: observation.boundingBox, visionConfidence: observation.confidence,
            patchDiagnostics: measurement?.patchDiagnostics ?? [:])
        #endif
    }

    func recordPhysicalObjectFollowDecision(observation: VNDetectedObjectObservation, previous: CGRect,
                                           capturedAt: TimeInterval, geometry: String, reason: String?,
                                           measurement: CMPhysicalObjectMeasurement? = nil) {
        #if DEBUG
        physicalObjectStateLock.lock()
        let recorder = physicalObjectFollowRecorder
        physicalObjectStateLock.unlock()
        recorder?.recordDecision(capturedAt: capturedAt, consumedAt: ProcessInfo.processInfo.systemUptime,
            rect: measurement?.rect ?? observation.boundingBox, previous: previous,
            confidence: measurement?.quality ?? observation.confidence,
            ready: physicalObjectFollowSafety.ready, confirming: physicalObjectFollowSafety.confirmingTarget,
            reference: physicalObjectFollowSafety.confidenceRecoveryReference(at: capturedAt) ?? .zero,
            geometry: geometry, reason: reason, source: measurement?.source ?? "vision",
            visionRect: observation.boundingBox, visionConfidence: observation.confidence,
            patchDiagnostics: measurement?.patchDiagnostics ?? [:],
            commandChannelReady: KKBLEManager.shared.isCommandChannelReady,
            awaitingFrameReentry: physicalObjectFollowSafety.awaitingFrameReentry,
            awaitingFrameReentryMatch: physicalObjectFollowSafety.awaitingFrameReentryMatch)
        #endif
    }

    var canStartPhysicalObjectTracking: Bool {
        (captureMode == .photo || captureMode == .video)
            && !isSwitchingCamera && !isPreparingWheelFunctionCamera
            && !isPanoramaCameraControlLocked && ScreenFollowMainAccess.shared.allowsCamera
            && !FirmwareUpdateManager.mUpdating && !hasPhysicalObjectSecondaryCamera
    }

    private var hasPhysicalObjectSecondaryCamera: Bool {
        guard let secondary = videoInput1 else { return false }
        return session?.inputs.contains(where: { $0 === secondary }) ?? false
    }

    /// Detection is a visual aid. Only an explicit user rectangle starts following.
    @discardableResult
    func startPhysicalObjectTracking() -> Bool {
        precondition(Thread.isMainThread)
        guard canStartPhysicalObjectTracking else { return false }
        stopPhysicalObjectTracking(reason: "restart")
        if isFaceTrackingMode { stopFaceTracking() }
        if currentTrackingRequest != nil { stopTracking() }
        clearTrackingLayer()
        resetTrackingForNewSession()
        resetGestureCounters(reason: "physical_object_started")
        physicalObjectIsFollowing = false
        physicalObjectIsDrawingSelection = false
        physicalObjectNeedsReselection = false
        physicalObjectDiscoveryFailed = false
        physicalObjectPhotoCaptureFailed = false
        physicalObjectHadCommandChannel = KKBLEManager.shared.isCommandChannelReady
        physicalObjectPreviewBounds = previewLayer?.bounds ?? .zero
        physicalObjectLastPositionAt = 0
        physicalObjectLastCameraFrameAt = 0
        physicalObjectLastResultConsumedAt = 0
        physicalObjectFollowStartedAt = 0
        physicalObjectFollowSafety = CMPhysicalObjectFollowSafety(recoveryEnabled: physicalObjectAutoRecoveryEnabled)
        physicalObjectSnapshot = nil
        physicalObjectOverlayExpired = false
        _ = objectTrackingCoordinator
        physicalObjectStateLock.lock()
        physicalObjectTrackingEnabled = true
        physicalObjectDiscoveryEnabled = true
        physicalObjectStateLock.unlock()
        trackingPanGesture.isEnabled = true
        objectTrackingCoordinator.start(backend: physicalObjectBackend)
        objectTrackingCoordinator.recordConfiguration([
            "cameraWorkflow": usesPhysicalObjectPhotoReference ? "manual_box_reference_photo_follow" : "detect_prompt_manual_box_legacy_follow",
            "captureMode": captureMode.rawValue, "lens": String(describing: lensType),
            "detectorControlsMotion": false, "selectionRequiresDetection": false
        ])
        installPhysicalObjectObservers()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.checkPhysicalObjectFreshness()
        }
        physicalObjectWatchdog = timer
        RunLoop.main.add(timer, forMode: .common)
        renderPhysicalObjectDiscovery()
        NotificationCenter.default.post(name: .trackingStateChanged, object: self,
            userInfo: ["isTracking": true, "mode": "physicalObject"])
        return true
    }

    func stopPhysicalObjectTracking(reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stopPhysicalObjectTracking(reason: reason) }
            return
        }
        guard isPhysicalObjectTrackingActive else { return }
        if physicalObjectFollowSafety.searchingOriginalTarget {
            savePhysicalObjectFollowRecording(reason: "search_stopped_" + reason)
        } else { discardPhysicalObjectFollowRecording() }
        physicalObjectStateLock.lock()
        physicalObjectTrackingEnabled = false
        physicalObjectDiscoveryEnabled = false
        physicalObjectStateLock.unlock()
        // Retain ownership through following so every existing camera/lifecycle exit
        // also cancels the legacy request; no physical-object BLE lease is acquired.
        if currentTrackingRequest != nil {
            releaseCurrentObjectTrackingRequest()
            sendTrackingCommand(state: .exit, centerPoint: .zero)
        }
        physicalObjectIsFollowing = false
        physicalObjectIsDrawingSelection = false
        physicalObjectFollowSafety = CMPhysicalObjectFollowSafety(recoveryEnabled: physicalObjectAutoRecoveryEnabled)
        trackingStartPoint = nil
        trackingPanGesture.isEnabled = false
        physicalObjectWatchdog?.invalidate()
        physicalObjectWatchdog = nil
        physicalObjectObservers.forEach(NotificationCenter.default.removeObserver)
        physicalObjectObservers.removeAll()
        objectTrackingCoordinator.stop(reason: reason)
        physicalObjectSnapshot = nil
        physicalObjectLastPositionAt = 0
        physicalObjectLastCameraFrameAt = 0
        physicalObjectLastResultConsumedAt = 0
        physicalObjectLayers.forEach { $0.removeFromSuperlayer() }
        physicalObjectLayers.removeAll()
        clearTrackingLayer()
        resetTrackingForNewSession()
        NotificationCenter.default.post(name: .trackingExited, object: self,
            userInfo: ["mode": "physicalObject", "reason": reason])
    }

    private func installPhysicalObjectObservers() {
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification,
                     AVCaptureSession.wasInterruptedNotification,
                     AVCaptureSession.runtimeErrorNotification] {
            physicalObjectObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.stopPhysicalObjectTracking(reason: "camera_interrupted")
            })
        }
        physicalObjectObservers.append(center.addObserver(forName: .bleStatusChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isPhysicalObjectTrackingActive else { return }
            if KKBLEManager.shared.isCommandChannelReady {
                self.physicalObjectHadCommandChannel = true
                self.renderPhysicalObjectDiscovery()
            } else if self.physicalObjectHadCommandChannel {
                self.stopPhysicalObjectTracking(reason: "ble_disconnected")
            }
        })
    }

    /// A preview-only detection may use arrival time when the capture clock is
    /// unavailable. Legacy motion from this mode requires a mapped capture time.
    func physicalObjectCaptureTime(_ sampleBuffer: CMSampleBuffer, arrivedAt: TimeInterval) -> TimeInterval? {
        guard let clock = session?.masterClock else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let mapped = CMTimeGetSeconds(CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock()))
        guard mapped.isFinite, mapped <= arrivedAt, arrivedAt - mapped < 5 else { return nil }
        return mapped
    }

    func submitPhysicalObjectFrame(_ sampleBuffer: CMSampleBuffer, connection: AVCaptureConnection) {
        guard isPhysicalObjectDiscoveryActive,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let arrival = ProcessInfo.processInfo.systemUptime
        let capturedAt = physicalObjectCaptureTime(sampleBuffer, arrivedAt: arrival) ?? arrival
        let geometry = UInt64(CVPixelBufferGetWidth(buffer)) << 32
            | UInt64(CVPixelBufferGetHeight(buffer)) << 8
            | UInt64(connection.videoOrientation.rawValue) << 1
            | (connection.isVideoMirrored ? 1 : 0)
        objectTrackingCoordinator.submit(pixelBuffer: buffer, capturedAt: capturedAt,
            mediaPTS: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)), geometryID: geometry)
    }

    func consumePhysicalObjectSnapshot(_ snapshot: ObjectTrackingSnapshot) {
        precondition(Thread.isMainThread)
        guard isPhysicalObjectDiscoveryActive,
              snapshot.sessionID == objectTrackingCoordinator.snapshot?.sessionID else { return }
        physicalObjectSnapshot = snapshot
        if snapshot.error != nil {
            // A detector failure must not disable manual selection of an unknown object.
            physicalObjectDiscoveryFailed = true
            stopPhysicalObjectDiscovery(reason: "detector_error_manual_selection_available")
        }
        physicalObjectOverlayExpired = false
        renderPhysicalObjectDiscovery()
    }

    private func stopPhysicalObjectDiscovery(reason: String) {
        physicalObjectStateLock.lock()
        physicalObjectDiscoveryEnabled = false
        physicalObjectStateLock.unlock()
        objectTrackingCoordinator.stop(reason: reason)
        physicalObjectSnapshot = nil
    }

    func beginPhysicalObjectSelection() {
        guard isPhysicalObjectTrackingActive else { return }
        if physicalObjectFollowSafety.searchingOriginalTarget {
            savePhysicalObjectFollowRecording(reason: "search_reselection")
        } else { discardPhysicalObjectFollowRecording() }
        if physicalObjectIsFollowing { physicalObjectNeedsReselection = true }
        // Reframing explicitly withdraws the old target before the finger moves.
        if currentTrackingRequest != nil {
            releaseCurrentObjectTrackingRequest()
            sendTrackingCommand(state: .exit, centerPoint: .zero)
        }
        physicalObjectIsFollowing = false
        physicalObjectIsDrawingSelection = true
        physicalObjectPhotoCaptureFailed = false
        physicalObjectFollowSafety = CMPhysicalObjectFollowSafety(recoveryEnabled: physicalObjectAutoRecoveryEnabled)
        physicalObjectLastPositionAt = 0
        physicalObjectLastCameraFrameAt = 0
        physicalObjectLastResultConsumedAt = 0
        renderPhysicalObjectDiscovery()
    }

    func cancelPhysicalObjectSelection() {
        guard isPhysicalObjectTrackingActive else { return }
        physicalObjectIsDrawingSelection = false
        renderPhysicalObjectDiscovery()
    }

    @discardableResult
    func confirmPhysicalObjectSelection(rect: CGRect) -> Bool {
        precondition(Thread.isMainThread)
        guard isPhysicalObjectTrackingActive, canStartPhysicalObjectTracking,
              let validRect = sanitizedTrackingBoundingBox(rect) else { return false }
        stopPhysicalObjectDiscovery(reason: "manual_box_handoff")
        // Establish the capture boundary before publishing the new request to
        // dataOutputQueue; rejecting only its main-queue callback is too late.
        physicalObjectFollowStartedAt = ProcessInfo.processInfo.systemUptime
        physicalObjectFollowSafety = CMPhysicalObjectFollowSafety(recoveryEnabled: physicalObjectAutoRecoveryEnabled,
            photoReferenceSelection: usesPhysicalObjectPhotoReference ? validRect : nil)
        physicalObjectLastCameraFrameAt = 0
        physicalObjectLastResultConsumedAt = 0
        guard startTracking(rect: validRect, preservingPhysicalObjectMode: true) != nil else {
            physicalObjectFollowStartedAt = 0
            return false
        }
        physicalObjectIsDrawingSelection = false
        physicalObjectIsFollowing = true
        physicalObjectPreparingSelection = usesPhysicalObjectPhotoReference
        #if DEBUG
        physicalObjectPreparingSelection = physicalObjectPreparingSelection || CMPhysicalObjectForegroundSelection.enabled
        #endif
        physicalObjectNeedsReselection = false
        physicalObjectLastPositionAt = 0 // No motion until the first real legacy tracker result.
        physicalObjectLastFollowLogAt = 0
        startPhysicalObjectFollowRecording()
        kkLog("event=physical_follow_selected box=\(validRect) lens=\(lensType) preview=\(previewLayer?.bounds ?? .zero)")
        renderPhysicalObjectDiscovery()
        return true
    }

    func pausePhysicalObjectFollowing(reason: String) {
        guard isPhysicalObjectTrackingActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let pipelineGap = ["legacy_position_expired", "legacy_camera_frame_expired",
            "legacy_result_consumption_expired", "stale_or_unmapped_object_frame"].contains(reason)
        if pipelineGap, physicalObjectAutoRecoveryEnabled, physicalObjectIsFollowing,
           physicalObjectFollowSafety.confirmingTarget || physicalObjectFollowSafety.beginProcessingGapHold(at: now) {
            sendTrackingCommand(state: .exit, centerPoint: .zero)
            kkLog("event=physical_follow_pipeline_hold reason=\(reason) tracker_retained=true positionAgeMs=\((now - physicalObjectLastPositionAt) * 1000) cameraAgeMs=\((now - physicalObjectLastCameraFrameAt) * 1000) consumedAgeMs=\((now - physicalObjectLastResultConsumedAt) * 1000)")
            renderPhysicalObjectDiscovery()
            return
        }
        let recoverableLoss = ["low_confidence", "invalid_box", "invalid_held_observation", "box_scale_jump", "box_position_jump",
            "confidence_recovery_identity_jump", "confidence_recovery_timeout", "frame_reentry_timeout",
            "photo_recovery_before_barrier", "frame_reentry_confidence_timeout", "original_target_return_timeout", "legacy_position_expired",
            "legacy_camera_frame_expired", "legacy_result_consumption_expired", "stale_or_unmapped_object_frame", "empty_vision_result"]
        if recoverableLoss.contains(reason), physicalObjectFollowSafety.beginOriginalTargetSearch() {
            physicalObjectRecoverySearchDidBegin(reason: reason)
            return
        }
        if recoverableLoss.contains(reason), physicalObjectFollowSafety.searchingOriginalTarget {
            sendTrackingCommand(state: .exit, centerPoint: .zero)
            return
        }
        kkLog("event=physical_follow_watchdog_context reason=\(reason) confirming=\(physicalObjectFollowSafety.confirmingTarget) positionAgeMs=\((now - physicalObjectLastPositionAt) * 1000) cameraAgeMs=\((now - physicalObjectLastCameraFrameAt) * 1000) consumedAgeMs=\((now - physicalObjectLastResultConsumedAt) * 1000)")
        releaseCurrentObjectTrackingRequest()
        sendTrackingCommand(state: .exit, centerPoint: .zero)
        savePhysicalObjectFollowRecording(reason: reason)
        physicalObjectIsFollowing = false
        physicalObjectIsDrawingSelection = false
        physicalObjectNeedsReselection = true
        physicalObjectFollowSafety = CMPhysicalObjectFollowSafety(recoveryEnabled: physicalObjectAutoRecoveryEnabled)
        physicalObjectLastPositionAt = 0
        physicalObjectLastCameraFrameAt = 0
        physicalObjectLastResultConsumedAt = 0
        trackingStartPoint = nil
        clearTrackingLayer()
        trackingPanGesture.isEnabled = false // Cancel any incomplete drag.
        trackingPanGesture.isEnabled = true
        kkLog("实物跟随已暂停，请重新框选: \(reason)")
        renderPhysicalObjectDiscovery()
    }

    /// A control hold is not target loss: keep the same live Vision request and
    /// its frame/lifecycle guards while withdrawing all motor movement.
    func holdPhysicalObjectControl(reason: String) {
        guard isPhysicalObjectTrackingActive, physicalObjectIsFollowing else { return }
        sendTrackingCommand(state: .exit, centerPoint: .zero)
        kkLog("event=physical_follow_motor_hold reason=\(reason) tracker_retained=true")
        renderPhysicalObjectDiscovery()
    }

    func physicalObjectControlDidResume() {
        kkLog("event=physical_follow_motor_resumed reason=same_target_centered")
        renderPhysicalObjectDiscovery()
    }

    func holdPhysicalObjectObservation(confidence: Float) {
        guard isPhysicalObjectTrackingActive, physicalObjectIsFollowing else { return }
        sendTrackingCommand(state: .exit, centerPoint: .zero)
        let edge = physicalObjectFollowSafety.awaitingFrameReentry
        let edgeMatch = physicalObjectFollowSafety.awaitingFrameReentryMatch
        let returning = physicalObjectFollowSafety.awaitingOriginalTargetReturn
        let reason = returning ? "original_target_return" : (edgeMatch ? "frame_edge_weak_match" : (edge ? "partial_frame_exit" : "weak_match"))
        kkLog("event=physical_follow_quality_hold reason=\(reason) confidence=\(confidence) tracker_retained=true recoveryWindowMs=\(returning || (edge && !edgeMatch) ? 1500 : 450)")
        renderPhysicalObjectDiscovery()
    }

    func physicalObjectObservationDidRecover() {
        kkLog("event=physical_follow_quality_resumed reason=three_continuous_reliable_original_target_frames")
        renderPhysicalObjectDiscovery()
    }

    func logPhysicalObjectFollowFrame(observation: VNDetectedObjectObservation,
                                     capturedAt: TimeInterval, geometry: String,
                                     measurement: CMPhysicalObjectMeasurement? = nil) {
        guard capturedAt - physicalObjectLastFollowLogAt >= 0.5 else { return }
        physicalObjectLastFollowLogAt = capturedAt
        kkLog("event=physical_follow_frame confidence=\(measurement?.quality ?? observation.confidence) box=\(measurement?.rect ?? observation.boundingBox) source=\(measurement?.source ?? "vision") patch=\(measurement?.patchDiagnostics ?? [:]) visionConfidence=\(observation.confidence) visionBox=\(observation.boundingBox) \(geometry) previewOrientation=\(previewLayer?.connection?.videoOrientation.rawValue ?? -1) previewMirrored=\(previewLayer?.connection?.isVideoMirrored ?? false) ageMs=\((ProcessInfo.processInfo.systemUptime - capturedAt) * 1000)")
    }

    /// Captured timestamps prove the camera is still delivering new images;
    /// queued duplicate, old-request, or stale frames cannot extend this clock.
    func recordPhysicalObjectCameraFrame(capturedAt: TimeInterval, request: VNTrackObjectRequest) {
        precondition(Thread.isMainThread)
        let now = ProcessInfo.processInfo.systemUptime
        guard isPhysicalObjectTrackingActive, physicalObjectIsFollowing,
              currentTrackingRequest === request, capturedAt.isFinite,
              capturedAt >= physicalObjectFollowStartedAt,
              capturedAt > physicalObjectLastCameraFrameAt,
              (0...0.25).contains(now - capturedAt) else { return }
        physicalObjectLastCameraFrameAt = capturedAt
    }

    private func checkPhysicalObjectFreshness(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        precondition(Thread.isMainThread)
        guard isPhysicalObjectTrackingActive else { return }
        guard canStartPhysicalObjectTracking, ProcessInfo.processInfo.thermalState != .critical else {
            stopPhysicalObjectTracking(reason: "unsupported_camera_state")
            return
        }
        if previewLayer?.bounds != physicalObjectPreviewBounds {
            physicalObjectPreviewBounds = previewLayer?.bounds ?? .zero
            if physicalObjectIsFollowing || physicalObjectIsDrawingSelection {
                pausePhysicalObjectFollowing(reason: "preview_geometry_changed")
            } else { renderPhysicalObjectDiscovery() }
        }
        if physicalObjectIsFollowing {
            let wasSearching = physicalObjectFollowSafety.searchingOriginalTarget
            let timeoutReason = physicalObjectFollowSafety.confirmationTimeoutReason(at: now)
            if let reason = physicalObjectFollowSafety.handleConfirmationTimeout(at: now) {
                pausePhysicalObjectFollowing(reason: reason)
            } else if physicalObjectFollowSafety.searchingOriginalTarget {
                if !wasSearching { physicalObjectRecoverySearchDidBegin(reason: timeoutReason ?? "confirmation_timeout") }
                // Search never drives. Keep its identity across a slow search
                // or a capture gap; only fresh results can confirm a return.
            } else if physicalObjectFollowSafety.confirmingTarget {
                // Confirmation already withdrew motor movement. A valid result
                // may take most of the capture-age budget to process, so keep
                // camera delivery and result consumption independently live.
                if now - physicalObjectLastCameraFrameAt > 0.25 {
                    pausePhysicalObjectFollowing(reason: "legacy_camera_frame_expired")
                } else if now - physicalObjectLastResultConsumedAt > 0.25 {
                    pausePhysicalObjectFollowing(reason: "legacy_result_consumption_expired")
                }
            } else if physicalObjectLastPositionAt > 0, now - physicalObjectLastPositionAt > 0.25 {
                pausePhysicalObjectFollowing(reason: "legacy_position_expired")
            } else if physicalObjectLastPositionAt == 0,
                      now - physicalObjectFollowStartedAt > (physicalObjectPreparingSelection ? 3 : 1) {
                pausePhysicalObjectFollowing(reason: "legacy_first_result_timeout")
            }
        }
        if !physicalObjectOverlayExpired, let snapshot = physicalObjectSnapshot,
           ProcessInfo.processInfo.systemUptime - snapshot.candidatesCapturedAt > 0.25 {
            physicalObjectOverlayExpired = true
            renderPhysicalObjectDiscovery()
        }
    }

    private func renderPhysicalObjectDiscovery() {
        physicalObjectLayers.forEach { $0.removeFromSuperlayer() }
        physicalObjectLayers.removeAll()
        guard let preview = previewLayer, let container = embeddingView?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let now = ProcessInfo.processInfo.systemUptime
        let snapshot = physicalObjectSnapshot
        let candidates = snapshot.flatMap { value -> [ObjectDetection]? in
            guard now >= value.candidatesCapturedAt, now - value.candidatesCapturedAt <= 0.25 else { return nil }
            return value.candidates
        } ?? []
        if !physicalObjectIsFollowing && !physicalObjectIsDrawingSelection {
            for object in candidates {
                guard let previewRect = trackingPreviewRect(forVisionBoundingBox: object.boundingBox) else { continue }
                let layer = CAShapeLayer()
                layer.path = UIBezierPath(rect: preview.convert(previewRect, to: container)).cgPath
                layer.strokeColor = UIColor.white.withAlphaComponent(0.65).cgColor
                layer.fillColor = UIColor.clear.cgColor
                layer.lineWidth = 1
                container.addSublayer(layer)
                physicalObjectLayers.append(layer)
            }
        }
        let message: String
        if physicalObjectIsDrawingSelection {
            message = usesPhysicalObjectPhotoReference
                ? KKLocalized("Release to capture a reference photo and follow.", comment: "松手拍下参照图并跟随")
                : KKLocalized("Release to follow the selected object", comment: "松手后跟随框选物品")
        } else if physicalObjectIsFollowing && physicalObjectFollowSafety.searchingOriginalTarget {
            message = KKLocalized("Object lost. Searching for the same object. Movement paused.", comment: "目标丢失，正在寻找原目标，云台已暂停")
        } else if physicalObjectIsFollowing && physicalObjectFollowSafety.awaitingFrameReentry && !physicalObjectFollowSafety.awaitingFrameReentryMatch {
            message = KKLocalized("Object near the edge. Movement paused until it returns.", comment: "目标靠近画面边缘，暂停转动，等待返回")
        } else if physicalObjectIsFollowing && (physicalObjectPreparingSelection || physicalObjectFollowSafety.confirmingTarget) {
            message = KKLocalized("Confirming the selected object. Movement paused briefly.", comment: "正在确认目标，云台暂时停止")
        } else if physicalObjectIsFollowing && physicalObjectFollowSafety.motionPaused {
            message = KKLocalized("Movement paused. Bring the selected object to the center or draw again.", comment: "运动已暂停，将目标移回画面中央可继续，或重新框选")
        } else if physicalObjectIsFollowing {
            message = KKBLEManager.shared.isCommandChannelReady
                ? KKLocalized("Following your selection. Draw again to change target.", comment: "正在跟随，重新框选可更换目标")
                : KKLocalized("Tracking preview. Connect a gimbal for movement.", comment: "目标跟踪预览，连接云台后可随动")
        } else if physicalObjectNeedsReselection && physicalObjectPhotoCaptureFailed {
            message = KKLocalized("No distinctive detail. Draw a tighter box and try again.", comment: "缺少可辨认的细节，请贴紧物品重新框选")
        } else if physicalObjectNeedsReselection {
            message = KKLocalized("Object lost. Draw a box to follow again.", comment: "目标丢失，请重新框选")
        } else if physicalObjectDiscoveryFailed {
            message = KKLocalized("Detection unavailable. Draw a box to follow an object.", comment: "识别暂不可用，仍可手动框选跟随")
        } else if !candidates.isEmpty {
            message = KKLocalized("Object detected. Draw a box around the object to follow.", comment: "发现物品，请框选需要跟随的物品")
        } else {
            message = KKLocalized("Finding objects. You can also draw a box to follow.", comment: "正在寻找物品，也可直接框选跟随")
        }
        let area = preview.convert(preview.bounds, to: container)
        let status = CATextLayer()
        status.contentsScale = UIScreen.main.scale
        status.fontSize = 13
        status.foregroundColor = UIColor.white.cgColor
        status.backgroundColor = UIColor.black.withAlphaComponent(0.65).cgColor
        status.alignmentMode = .center
        status.isWrapped = true
        let modeHint = KKLocalized("Use All Follow mode on your gimbal.", comment: "请将云台切换为全跟随模式")
        let statusText = modeHint + "\n" + message
        status.string = statusText
        let statusWidth = max(0, area.width - 24)
        let textHeight = (statusText as NSString).boundingRect(
            with: CGSize(width: max(1, statusWidth), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: UIFont.systemFont(ofSize: status.fontSize)], context: nil).height
        status.frame = CGRect(x: area.minX + 12, y: area.minY + 12,
                              width: statusWidth, height: max(44, ceil(textHeight) + 16))
        container.addSublayer(status)
        physicalObjectLayers.append(status)
    }
}

extension Notification.Name {
    static let physicalObjectTrackingError = Notification.Name("KKGimbal.PhysicalObjectTrackingError")
}
