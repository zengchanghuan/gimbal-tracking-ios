import Foundation
import CoreGraphics

enum ObjectTrackingState: String, Codable {
    case idle, loading, searching, confirming, tracking, temporarilyLost, paused
}

/// Backend-independent policy. All times use ProcessInfo.systemUptime.
/// These are initial operating limits, not measured detector accuracy claims.
enum ObjectTrackingPolicy {
    static let detectionInterval: TimeInterval = 0.25
    static let confirmationInterval: TimeInterval = 0.12
    static let correctionConfirmationInterval: TimeInterval = 0.03
    static let positionLifetime: TimeInterval = 0.25
    static let semanticLifetime: TimeInterval = 0.75
    static let recoveryWindow: TimeInterval = 0.50
    static let selectionLifetime: TimeInterval = 0.75
    static let minimumDetectionConfidence: Float = 0.35
    static let minimumTrackingConfidence: Float = 0.50
    static let correctionTrackingConfidenceTrigger: Float = 0.75
    static let confirmationsRequired = 2
    // Refresh semantics before their deadline, rather than waiting for the
    // next ordinary detector tick to fall beyond that deadline.
    static let semanticRefreshLeadTime: TimeInterval = 0.25
    static let correctionMinimumInterval: TimeInterval = 0.25
    static let correctionMaximumInterval: TimeInterval = 1.0
    // This bounds two historical identity observations, not motion freshness.
    // Applied positions must still come from a frame no older than 250ms.
    static let correctionConfirmationLifetime: TimeInterval = 0.35
    static let correctionConfirmationMinimumIoU: CGFloat = 0.65
    // This is a stationary identity search window, available only with the
    // original fixed appearance template. It never authorizes old positions
    // or extends the ordinary tracking semantic lifetime.
    static let appearanceRecoveryWindow: TimeInterval = 3.0
    // Frozen before the same-class negative probe; feature distance is not a
    // probability, and these component results do not establish production FAR.
    static let appearanceDistanceThreshold: Float = 0.70

    enum Association {
        case missing
        case unique(ObjectDetection)
        case ambiguous
    }

    static func isFresh(_ capturedAt: TimeInterval, now: TimeInterval,
                        lifetime: TimeInterval = positionLifetime) -> Bool {
        capturedAt.isFinite && now.isFinite && capturedAt <= now
            && now - capturedAt <= lifetime
    }

    static func validBoundingBox(_ box: CGRect) -> CGRect? {
        guard box.minX.isFinite, box.minY.isFinite,
              box.width.isFinite, box.height.isFinite,
              box.width > 0, box.height > 0 else { return nil }
        let clipped = box.intersection(CGRect(x: 0.001, y: 0.001, width: 0.998, height: 0.998))
        guard !clipped.isNull, clipped.width >= 0.01, clipped.height >= 0.01 else { return nil }
        return clipped
    }

    static func reliable(_ detections: [ObjectDetection]) -> [ObjectDetection] {
        detections.compactMap { detection in
            guard detection.confidence.isFinite,
                  detection.confidence >= minimumDetectionConfidence,
                  detection.confidence <= 1,
                  !detection.label.isEmpty,
                  let box = validBoundingBox(detection.boundingBox) else { return nil }
            return ObjectDetection(label: detection.label, confidence: detection.confidence,
                                   boundingBox: box)
        }
    }

    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let area = intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - area
        return union > 0 ? area / union : 0
    }

    /// A click chooses the smallest containing box, except effectively
    /// indistinguishable overlapping boxes, which require a clearer selection.
    static func candidate(at point: CGPoint, in candidates: [ObjectDetection]) -> ObjectDetection? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let hits = reliable(candidates).filter { $0.boundingBox.contains(point) }.sorted {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }
        guard let first = hits.first else { return nil }
        if hits.count > 1 {
            let a = first.boundingBox
            let b = hits[1].boundingBox
            let ratio = b.width * b.height / (a.width * a.height)
            if ratio < 1.20, intersectionOverUnion(a, b) > 0.50 { return nil }
        }
        return first
    }

    static func isCompatible(_ candidate: ObjectDetection, with reference: ObjectDetection) -> Bool {
        guard candidate.label == reference.label,
              let a = validBoundingBox(candidate.boundingBox),
              let b = validBoundingBox(reference.boundingBox) else { return false }
        let ratio = a.width * a.height / (b.width * b.height)
        guard ratio >= 0.40, ratio <= 2.50 else { return false }
        let dx = abs(a.midX - b.midX)
        let dy = abs(a.midY - b.midY)
        guard dx <= max(0.06, max(a.width, b.width) * 0.65),
              dy <= max(0.06, max(a.height, b.height) * 0.65) else { return false }
        return intersectionOverUnion(a, b) >= 0.12
            || (dx <= 0.035 && dy <= 0.035)
    }

    /// Do not pick the highest score when two instances are plausible.
    static func associate(_ reference: ObjectDetection, with candidates: [ObjectDetection]) -> Association {
        let compatible = reliable(candidates).filter { isCompatible($0, with: reference) }
        if compatible.count > 1 { return .ambiguous }
        if let only = compatible.first { return .unique(only) }
        return .missing
    }

    static func detectionIsDue(state: ObjectTrackingState, lastDetectionAt: TimeInterval,
                               capturedAt: TimeInterval, semanticAt: TimeInterval = 0,
                               hasPendingCorrection: Bool = false, backend: ObjectDetectionBackend? = nil) -> Bool {
        let semanticRefreshDue = state == .tracking
            && capturedAt - semanticAt >= semanticLifetime - semanticRefreshLeadTime
        let interval = state == .tracking && hasPendingCorrection && backend == .coreMLAll
            ? correctionConfirmationInterval
            : ((state == .confirming || state == .temporarilyLost || semanticRefreshDue || (state == .tracking && hasPendingCorrection))
                ? confirmationInterval : detectionInterval)
        return capturedAt - lastDetectionAt >= interval
    }

    /// A still-valid but weakening tracker must obtain current-frame semantic
    /// evidence. The existing correction threshold is not a movement threshold:
    /// a unique match still requires the ordinary two-frame correction hold.
    static func requiresDetectorConfirmation(trackingConfidence: Float) -> Bool {
        trackingConfidence.isFinite && trackingConfidence >= minimumTrackingConfidence
            && trackingConfidence < correctionTrackingConfidenceTrigger
    }

    /// Called only after a unique detector association. Do not repeatedly
    /// rebuild a stable tracker, or correct toward a disagreeing detection.
    /// Core ML All keeps a strongly agreeing tracker after a unique current
    /// detection; time alone does not force a new seed. Weak confidence and
    /// geometric discrepancy retain the original two-source hold path.
    static func correctionIsNeeded(_ reference: ObjectDetection, with detection: ObjectDetection,
                                   trackingConfidence: Float, lastSeedAt: TimeInterval,
                                   capturedAt: TimeInterval, backend: ObjectDetectionBackend? = nil) -> Bool {
        guard isCompatible(detection, with: reference),
              trackingConfidence.isFinite,
              trackingConfidence >= minimumTrackingConfidence else { return false }
        let overlap = intersectionOverUnion(reference.boundingBox, detection.boundingBox)
        return overlap >= 0.35 && (overlap < 0.85 || trackingConfidence < correctionTrackingConfidenceTrigger
            || (backend != .coreMLAll && capturedAt - lastSeedAt >= correctionMaximumInterval))
    }

    static func correctionSeedIsDue(lastSeedAt: TimeInterval, capturedAt: TimeInterval) -> Bool {
        capturedAt - lastSeedAt >= correctionMinimumInterval
    }

    static func mayMove(positionAt: TimeInterval, semanticAt: TimeInterval, now: TimeInterval,
                        trackingConfidence: Float) -> Bool {
        trackingConfidence.isFinite && trackingConfidence >= minimumTrackingConfidence
            && isFresh(positionAt, now: now)
            && isFresh(semanticAt, now: now, lifetime: semanticLifetime)
    }
}
