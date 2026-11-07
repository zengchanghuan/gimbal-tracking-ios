import CoreGraphics
import CoreVideo
import Foundation

func ObjectTrackingLocalized(_ key: String, _ arguments: CVarArg...) -> String {
    let language = UserDefaults.standard.string(forKey: "kk_app_language") ?? Bundle.main.preferredLocalizations.first ?? "en"
    let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    let english = Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
    let value = bundle.localizedString(forKey: key, value: english?.localizedString(forKey: key, value: key, table: nil) ?? key, table: nil)
    return arguments.isEmpty ? value : String(format: value, locale: Locale(identifier: language), arguments: arguments)
}

/// Shared by snapshots and queued transport writes. Revocation and the final
/// write are one transaction; a detached boolean check is never sufficient.
/// Lock order is Coordinator -> lease. The body must only submit the transport
/// write, never invoke a delegate, diagnostics, or re-enter the Coordinator.
final class ObjectTrackingControlLease: Equatable {
    let sessionID: UUID
    let controlID: UUID
    private let lock = NSLock()
    private var valid = true

    init(sessionID: UUID, controlID: UUID) {
        self.sessionID = sessionID
        self.controlID = controlID
    }

    static func == (lhs: ObjectTrackingControlLease, rhs: ObjectTrackingControlLease) -> Bool { lhs === rhs }

    func revoke() {
        lock.lock(); defer { lock.unlock() }
        valid = false
    }

    @discardableResult
    func withValidAuthorization(sessionID: UUID, controlID: UUID, expiresAt: TimeInterval,
                                _ write: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard valid, self.sessionID == sessionID, self.controlID == controlID,
              expiresAt.isFinite, expiresAt >= ProcessInfo.processInfo.systemUptime else { return false }
        write()
        return true
    }

    func isValid(sessionID: UUID, controlID: UUID, expiresAt: TimeInterval) -> Bool {
        withValidAuthorization(sessionID: sessionID, controlID: controlID, expiresAt: expiresAt) {}
    }
}

enum ObjectDetectionBackend: String, CaseIterable, Codable {
    case mediaPipeCPU
    case mediaPipeGPU
    case coreMLCPU
    case coreMLAll

    var displayName: String {
        switch self {
        case .mediaPipeCPU: return "MediaPipe · CPU"
        case .mediaPipeGPU: return "MediaPipe · GPU"
        case .coreMLCPU: return "Core ML · CPU"
        case .coreMLAll: return ObjectTrackingLocalized("Core ML · Automatic Acceleration")
        }
    }
}

struct ObjectDetection {
    let label: String
    let confidence: Float
    /// Normalized to the physical pixel buffer, with origin at its lower-left.
    /// No preview rotation or mirroring is applied by a detector.
    let boundingBox: CGRect
}

/// Instances are owned and called by one serial inference queue. Video timestamps
/// must be nonnegative and strictly increasing within the instance's lifetime.
protocol ObjectDetecting {
    var modelIdentifier: String { get }
    var backend: ObjectDetectionBackend { get }
    func detect(pixelBuffer: CVPixelBuffer, timestampMilliseconds: Int) throws -> [ObjectDetection]
}

/// The frozen benchmark stays on its original six classes. Discovery only
/// broadens the existing model output; it does not add unseen model classes.
enum ObjectDetectionLabelPolicy: String {
    case benchmarkSixClasses
    case allModelLabels

    func accepts(_ label: String) -> Bool {
        switch self {
        case .benchmarkSixClasses: return ObjectDetectionDefaults.allowedLabels.contains(label)
        case .allModelLabels: return !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

enum ObjectDetectorFactory {
    static func make(backend: ObjectDetectionBackend,
                     labelPolicy: ObjectDetectionLabelPolicy = .benchmarkSixClasses) throws -> ObjectDetecting {
        switch backend {
        case .mediaPipeCPU, .mediaPipeGPU:
            #if canImport(MediaPipeTasksVision)
            return try MediaPipeObjectDetector(backend: backend, labelPolicy: labelPolicy)
            #else
            throw ObjectDetectionError.unsupportedBackend(backend)
            #endif
        case .coreMLCPU, .coreMLAll:
            return try CoreMLObjectDetector(backend: backend, labelPolicy: labelPolicy)
        }
    }
}

/// Fixed, reviewed model pairs. The benchmark can explicitly select the old
/// pair in its own Info.plist; ordinary product builds use the quality pair.
/// Thresholds, supported categories and downstream tracking are unchanged.
enum ObjectDetectionModels {
    static let usesBaseline = Bundle.main.object(forInfoDictionaryKey: "ObjectDetectionModelPreset") as? String == "baseline"
    static let preset = usesBaseline ? "baseline" : "quality"
    static let mediaPipeResource = usesBaseline ? "efficientdet_lite0_float32" : "efficientdet_lite2_float32"
    static let coreMLResource = usesBaseline ? "YOLOv3TinyFP16" : "YOLOv3FP16"
    static let mediaPipeSHA256 = usesBaseline
        ? "40338edf5ec70d43e318b0a716a84d4564cd1802759a7a07170c7e43796dbf58"
        : "ad2abbf2b4e10585e15176fd7b5ef03c28dda959ae26fc142549fdd1814db91d"
    static let coreMLSHA256 = usesBaseline
        ? "73406178d0f5793d0d5d1e38274acd146a744c2245c9b63a11998a5015925dda"
        : "276afae53da362e25ad21c827f8a929a8512254b1343433d970e725a0de57d8f"
    static let mediaPipeIdentifier = (usesBaseline ? "efficientdet-lite0-float32-v1:" : "efficientdet-lite2-float32-v1:") + mediaPipeSHA256
    static let coreMLIdentifier = (usesBaseline ? "apple-yolov3-tiny-fp16-v2:" : "apple-yolov3-fp16-v2:") + coreMLSHA256

    static func coreMLUsesAspectFit(for backend: ObjectDetectionBackend) -> Bool {
        backend == .coreMLAll && !usesBaseline
    }

    static func preprocessingDescription(for backend: ObjectDetectionBackend) -> String {
        switch backend {
        case .mediaPipeCPU, .mediaPipeGPU:
            return "MediaPipe native preprocessing"
        case .coreMLCPU, .coreMLAll:
            return coreMLUsesAspectFit(for: backend)
                ? "Vision scaleFit 416x416; aspect preserved; system padding"
                : "Vision scaleFill 416x416"
        }
    }
}

/// Product-comparison defaults, not calibrated accuracy claims. Both models use
/// the same six-label contract; their native preprocessing/NMS remain different.
enum ObjectDetectionDefaults {
    static let labels = ["cup", "bottle", "cell phone", "cat", "dog", "car"]
    static let allowedLabels = Set(labels)
    static let scoreThreshold: Float = 0.35
    static let maximumResults = 20
    static let coreMLNMSIoUThreshold = 0.45

    static func normalizedBox(_ box: CGRect) -> CGRect? {
        guard box.origin.x.isFinite, box.origin.y.isFinite,
              box.width.isFinite, box.height.isFinite,
              box.width > 0, box.height > 0 else { return nil }
        let clipped = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        return clipped
    }

    static func filtered(_ detections: [ObjectDetection],
                         labelPolicy: ObjectDetectionLabelPolicy = .benchmarkSixClasses) -> [ObjectDetection] {
        Array(detections.filter {
            labelPolicy.accepts($0.label) && $0.confidence.isFinite &&
                $0.confidence >= scoreThreshold && $0.confidence <= 1
        }.sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            if $0.label != $1.label { return $0.label < $1.label }
            if $0.boundingBox.minX != $1.boundingBox.minX {
                return $0.boundingBox.minX < $1.boundingBox.minX
            }
            return $0.boundingBox.minY < $1.boundingBox.minY
        }.prefix(maximumResults))
    }
}

enum ObjectDetectionError: LocalizedError {
    case missingModel(String)
    case unsupportedBackend(ObjectDetectionBackend)
    case unsupportedPixelFormat(OSType)
    case gpuUnavailable(String)
    case invalidTimestamp(previous: Int, received: Int)
    case invalidModel(String)
    case unexpectedResults(String)

    var errorDescription: String? {
        switch self {
        case .missingModel(let name): return ObjectTrackingLocalized("Object detection model not found: %@", String(describing: name))
        case .unsupportedBackend(let backend): return ObjectTrackingLocalized("Model does not support backend: %@", String(describing: backend.displayName))
        case .unsupportedPixelFormat(let format): return ObjectTrackingLocalized("Object detection requires BGRA. Current format: %@", String(describing: format))
        case .gpuUnavailable(let reason): return ObjectTrackingLocalized("MediaPipe GPU unavailable: %@", String(describing: reason))
        case .invalidTimestamp(let previous, let received):
            return ObjectTrackingLocalized("Object timestamps must increase: %@, previous %@", String(describing: received), String(describing: previous))
        case .invalidModel(let detail): return ObjectTrackingLocalized("Incompatible object detection model: %@", String(describing: detail))
        case .unexpectedResults(let detail): return ObjectTrackingLocalized("Incompatible object detection output: %@", String(describing: detail))
        }
    }
}

enum ObjectDetectionResources {
    static func url(name: String, extension fileExtension: String, bundle: Bundle = .main) throws -> URL {
        // Xcode's ordinary resource build phase flattens these resources. Also
        // support a folder reference in local harnesses without scanning disk.
        for directory: String? in [nil, "ObjectTracking/Resources", "Resources"] {
            if let url = bundle.url(forResource: name, withExtension: fileExtension,
                                    subdirectory: directory) { return url }
        }
        throw ObjectDetectionError.missingModel("\(name).\(fileExtension)")
    }

    static func validate(pixelBuffer: CVPixelBuffer, timestamp: Int, previousTimestamp: Int) throws {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            throw ObjectDetectionError.unsupportedPixelFormat(CVPixelBufferGetPixelFormatType(pixelBuffer))
        }
        guard timestamp >= 0, timestamp > previousTimestamp else {
            throw ObjectDetectionError.invalidTimestamp(previous: previousTimestamp, received: timestamp)
        }
    }
}
