import CoreGraphics
import CoreVideo
import Foundation

/// Normalized image coordinates with a lower-left origin, before preview mirroring.
public struct TrackingBox: Equatable {
    public let rect: CGRect
    public init(_ rect: CGRect) { self.rect = rect }
    fileprivate var screenRect: ScreenFollowRect {
        ScreenFollowRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}

/// Controller output in the original gimbal's command units, not degrees or rad/s.
public struct FollowCommand: Equatable {
    public let yaw: Int
    public let pitch: Int
    public static let hold = FollowCommand(yaw: 0, pitch: 0)
    public init(yaw: Int, pitch: Int) { self.yaw = yaw; self.pitch = pitch }

    /// The original D1 wire format. Other hardware requires a transport adapter.
    public func encodedD1Packet() -> Data {
        GimbalTrackingPacket.encode(.init(yaw: yaw, pitch: pitch))
    }
}

/// Stateful controller; use from one serial queue. All timestamps use system uptime.
/// A host must independently expire pending writes and send hold when frames stop.
public struct FollowController {
    private var controller = ScreenFollowController()
    public init() {}
    public var hasConfirmedTarget: Bool { controller.hasConfirmedTarget }
    public var trackingReference: TrackingBox? {
        controller.trackingReference.map { TrackingBox(CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)) }
    }
    public mutating func reset() { controller.reset() }

    /// nil means a duplicate/out-of-order frame was ignored; hold revokes movement.
    /// Supply detections from the current image only. Never repeat a stale box.
    public mutating func observe(boxes: [TrackingBox], frameID: UInt64,
                                 capturedAt: TimeInterval, now: TimeInterval,
                                 yawSign: Double = 1, pitchSign: Double = 1) -> FollowCommand? {
        controller.observe(faces: boxes.map(\.screenRect), frameID: frameID,
                           capturedAt: capturedAt, now: now, yawSign: yawSign,
                           pitchSign: pitchSign).map { FollowCommand(yaw: $0.yaw, pitch: $0.pitch) }
    }
}

public struct FaceTrackingResult {
    public let boxes: [TrackingBox]
    public let usedTracking: Bool
    public let resetsTarget: Bool
    public let decision: String
}

/// Apple Vision detection plus sequence tracking. Own this on a serial worker queue.
/// This API performs image analysis only and does not acquire the camera or move hardware.
public final class FaceTracker {
    private let analyzer: ScreenFollowFaceAnalyzer
    public init(prefersNeuralEngine: Bool = false) {
        analyzer = ScreenFollowFaceAnalyzer(prefersNeuralEngine: prefersNeuralEngine)
    }
    public func reset() { analyzer.reset() }
    /// Change context when camera, orientation, crop or tracking session changes.
    public func analyze(_ image: CGImage, capturedAt: TimeInterval, now: TimeInterval,
                        context: String, confirmedTarget: TrackingBox? = nil) throws -> FaceTrackingResult {
        let result = try analyzer.analyze(image, capturedAt: capturedAt, now: now,
                                          context: context, confirmedTarget: confirmedTarget?.screenRect)
        return FaceTrackingResult(boxes: result.faces.map {
            TrackingBox(CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height))
        }, usedTracking: result.usedTracking, resetsTarget: result.resetsTarget, decision: result.decision)
    }
}

public struct LabeledDetection {
    public let label: String
    public let confidence: Float
    public let box: TrackingBox
}

/// Optional YOLOv3 Core ML discovery. Add the documented model to the host bundle first.
public final class ObjectDetector {
    private let detector: CoreMLObjectDetector
    public init(cpuOnly: Bool = false, bundle: Bundle = .main) throws {
        detector = try CoreMLObjectDetector(backend: cpuOnly ? .coreMLCPU : .coreMLAll,
                                             bundle: bundle, labelPolicy: .allModelLabels)
    }
    /// BGRA, orientation .up, and strictly increasing nonnegative timestamps are required.
    public func detect(pixelBuffer: CVPixelBuffer, timestampMilliseconds: Int) throws -> [LabeledDetection] {
        try detector.detect(pixelBuffer: pixelBuffer, timestampMilliseconds: timestampMilliseconds).map {
            LabeledDetection(label: $0.label, confidence: $0.confidence, box: TrackingBox($0.boundingBox))
        }
    }
}
