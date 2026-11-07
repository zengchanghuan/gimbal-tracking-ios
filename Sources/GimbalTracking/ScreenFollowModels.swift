import Foundation

/// The extension uses the containing app's translations and the language selected
/// before preparing a broadcast. It never falls back to hard-coded Chinese.
func ScreenFollowLocalized(_ key: String, _ arguments: CVarArg...) -> String {
    let isExtension = Bundle.main.bundleURL.pathExtension == "appex"
    let host = isExtension ? (Bundle(url: Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()) ?? .main) : .main
    let selected = isExtension
        ? UserDefaults(suiteName: ScreenFollowConstants.appGroup)?.string(forKey: "screenFollowLanguage")
        : UserDefaults.standard.string(forKey: "kk_app_language")
    let language = selected ?? host.preferredLocalizations.first ?? "en"
    let bundle = host.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? host
    let fallback = host.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
    let value = bundle.localizedString(forKey: key, value: fallback?.localizedString(forKey: key, value: key, table: nil) ?? key, table: nil)
    return arguments.isEmpty ? value : String(format: value, locale: Locale(identifier: language), arguments: arguments)
}

enum ScreenFollowConstants {
    static let appGroup = "group.com.example.GimbalTracking.screenfollow"
    static let extensionBundleID = "com.example.GimbalTracking.Broadcast"
    static let maximumFrameAge: TimeInterval = 0.5
    static let preparationLifetime: TimeInterval = 120
    static let maximumPacketBytes = 512 * 1024
    static let minimumFrameInterval: TimeInterval = 1.0 / 15.0
}

/// Frame-rate admission only. The caller still owns readiness, the single
/// in-flight frame and age checks. Commit only after encoding succeeds and the
/// frame is ready for transport submission; a transport failure ends the session.
struct ScreenFollowFrameCadence {
    private var lastSentAt: TimeInterval?
    private var nextDeadline: TimeInterval?
    private let minimumSpacing: TimeInterval = 0.06
    private let clockTolerance: TimeInterval = 0.000000001

    func isDue(at time: TimeInterval) -> Bool {
        guard time.isFinite, time >= 0 else { return false }
        if let lastSentAt {
            guard time > lastSentAt,
                  time - lastSentAt + clockTolerance >= minimumSpacing else { return false }
        }
        return nextDeadline.map { time + clockTolerance >= $0 } ?? true
    }

    mutating func didSend(at time: TimeInterval) {
        guard isDue(at: time) else { return }
        let anchor = nextDeadline ?? time
        let interval = ScreenFollowConstants.minimumFrameInterval
        // Advance on the existing phase rather than reanchoring to a late
        // callback. Missed slots are discarded; there is no catch-up send loop.
        let slots = floor((max(0, time - anchor) + clockTolerance) / interval) + 1
        let next = anchor + slots * interval
        guard next.isFinite, next > time else { return }
        lastSentAt = time
        nextDeadline = next
    }

    mutating func reset() {
        lastSentAt = nil
        nextDeadline = nil
    }
}

struct ScreenFollowConfiguration: Codable {
    var version = 3
    let sessionID: UUID
    let peripheralID: UUID
    let port: UInt16
    let preparedUptime: TimeInterval

    func canStart(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        version == 3 && port > 0 && now.isFinite && preparedUptime.isFinite
            && now >= preparedUptime && now - preparedUptime <= ScreenFollowConstants.preparationLifetime
    }
}

struct ScreenFollowRect: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var centerX: Double { x + width / 2 }
    var centerY: Double { y + height / 2 }
    var validFace: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0
            && width >= 0.035 && height >= 0.035 && x + width <= 1.001 && y + height <= 1.001
    }
    /// Vision can report a face that extends slightly past the image edge.
    /// Use only its visible pixels; a mostly departed face is not a target.
    var visibleFace: Self? {
        guard [x, y, width, height].allSatisfy(\.isFinite),
              width >= 0.035, height >= 0.035, width <= 1, height <= 1 else { return nil }
        if x >= 0, y >= 0, x + width <= 1, y + height <= 1 { return self }
        let left = max(0, x), bottom = max(0, y)
        let clipped = Self(x: left, y: bottom, width: min(1, x + width) - left,
                           height: min(1, y + height) - bottom)
        guard clipped.validFace, clipped.width * clipped.height >= width * height * 0.65 else { return nil }
        return clipped
    }

    /// A successful face validation must also correct accumulated tracker drift.
    /// Ignore small detector jitter; use the existing controller to limit motion
    /// when a materially different current-image face box reseeds the tracker.
    func needsTrackingCorrection(from tracked: Self) -> Bool {
        guard validFace, tracked.validFace else { return false }
        let widthRatio = width / tracked.width, heightRatio = height / tracked.height
        return abs(centerX - tracked.centerX) >= max(0.025, min(width, tracked.width) * 0.10)
            || abs(centerY - tracked.centerY) >= max(0.025, min(height, tracked.height) * 0.10)
            || widthRatio < 0.8 || widthRatio > 1.25 || heightRatio < 0.8 || heightRatio > 1.25
    }

    func canCorrectTracking(_ tracked: Self) -> Bool {
        guard validFace, tracked.validFace, overlap(with: tracked) >= 0.4 else { return false }
        let widthRatio = width / tracked.width, heightRatio = height / tracked.height
        return abs(centerX - tracked.centerX) <= min(width, tracked.width) * 0.35
            && abs(centerY - tracked.centerY) <= min(height, tracked.height) * 0.35
            && widthRatio >= 0.6 && widthRatio <= 1.67 && heightRatio >= 0.6 && heightRatio <= 1.67
    }
    func overlap(with other: Self) -> Double {
        let intersection = max(0, min(x + width, other.x + other.width) - max(x, other.x))
            * max(0, min(y + height, other.y + other.height) - max(y, other.y))
        return intersection / max(0.000001, width * height + other.width * other.height - intersection)
    }

    // Same bounded continuity rule as the native camera's automatic face target.
    // Small, fast-moving faces may not overlap enough even though their size and
    // center displacement remain consistent with the preceding observation.
    func isContinuous(with reference: Self) -> Bool {
        guard validFace, reference.validFace else { return false }
        if overlap(with: reference) >= 0.08 { return true }
        let ratio = width * height / (reference.width * reference.height)
        return ratio >= 0.55 && ratio <= 1.8
            && abs(centerX - reference.centerX) <= max(0.06, max(width, reference.width) * 0.85)
            && abs(centerY - reference.centerY) <= max(0.08, max(height, reference.height) * 0.90)
    }

    func continuityScore(with reference: Self) -> Double {
        let area = width * height, referenceArea = reference.width * reference.height
        let distance = hypot(centerX - reference.centerX, centerY - reference.centerY)
        return overlap(with: reference) * 4 + min(area, referenceArea) / max(0.000001, max(area, referenceArea)) - distance * 2
    }

    var diagnosticBox: String {
        String(format: "%.3f,%.3f,%.3f,%.3f", x, y, width, height)
    }
}

struct ScreenFollowCommand: Equatable {
    let yaw: Int
    let pitch: Int
    static let hold = Self(yaw: 0, pitch: 0)
}

enum GimbalTrackingPacket {
    static func encode(_ command: ScreenFollowCommand = .hold, exit: Bool = false) -> Data {
        let x = 10000 + (exit ? 0 : min(300, max(-300, command.yaw)))
        let y = 10000 + (exit ? 0 : min(300, max(-300, command.pitch)))
        var bytes: [UInt8] = [0x55, 0x55, 0x07, 0xd1, exit ? 4 : 1,
                             UInt8(x >> 8), UInt8(x & 255), UInt8(y >> 8), UInt8(y & 255)]
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc &<< 1) ^ 0x8d : crc &<< 1 }
        }
        bytes.append(crc)
        return Data(bytes)
    }
}

/// Cumulative source-side counts. Updated under the extension's small stats lock;
/// they diagnose dropped opportunities without buffering any additional image.
struct ScreenFollowSourceCounters: Codable {
    var videoCallbacks = 0
    var admissionBusy = 0
    var notReady = 0
    var inFlightBusy = 0
    var rateLimited = 0
    var encoded = 0
    var encodeExpired = 0
    var sent = 0
    var callbackGapCount = 0
    var totalCallbackGapMS = 0.0
    var maximumCallbackGapMS = 0.0
}

struct ScreenFollowSourceTiming: Codable {
    // Sample PTS is reported independently: do not assume its epoch matches uptime.
    let sourcePTS: TimeInterval?
    let queueStartedAt: TimeInterval
    let encodeStartedAt: TimeInterval
    let encodedAt: TimeInterval
    let counters: ScreenFollowSourceCounters
}

struct ScreenFollowMessage: Codable {
    enum Kind: String, Codable { case hello, frame, ack, pause, resume, stop }
    let kind: Kind
    let sessionID: UUID
    var frameID: UInt64 = 0
    var capturedAt: TimeInterval = 0
    var jpeg: Data? = nil
    var stopReason: String? = nil
    var stopIsError: Bool? = nil
    var sourceTiming: ScreenFollowSourceTiming? = nil
}

enum ScreenFollowError: LocalizedError {
    case message(String)
    case preparationUnavailable
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .preparationUnavailable:
            return ScreenFollowLocalized("Live Tracking is not ready or has expired. Return to Gimbal Tracking, connect the gimbal, then tap Start Live Tracking again.")
        }
    }
}

/// Length prefix is network byte order. Reject oversized data before allocating a frame.
struct ScreenFollowPacketDecoder {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [Data] {
        guard buffer.count + data.count <= ScreenFollowConstants.maximumPacketBytes + 65540 else {
            throw ScreenFollowError.message(ScreenFollowLocalized("Screen Frame Too Large"))
        }
        buffer.append(data)
        var result: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0 && length <= ScreenFollowConstants.maximumPacketBytes else {
                throw ScreenFollowError.message(ScreenFollowLocalized("Invalid Screen Frame Format"))
            }
            guard buffer.count >= 4 + length else { break }
            result.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return result
    }

    static func encode(_ message: ScreenFollowMessage) throws -> Data {
        let body = try JSONEncoder().encode(message)
        guard body.count <= ScreenFollowConstants.maximumPacketBytes else {
            throw ScreenFollowError.message(ScreenFollowLocalized("Screen Frame Too Large"))
        }
        let count = body.count
        var data = Data([UInt8((count >> 24) & 255), UInt8((count >> 16) & 255),
                         UInt8((count >> 8) & 255), UInt8(count & 255)])
        data.append(body)
        return data
    }
}

struct ScreenFollowDiagnostics: Codable {
    var controllerVersion = "pitch-center-handoff-v30"
    var camera = "unset"
    var yawSign = 1.0
    var pitchSign = 1.0
    var broadcastDurationSeconds = 0.0
    var frames = 0
    var analyzedFrames = 0
    var faceDetectionFrames = 0
    var visualTrackingFrames = 0
    var totalDetectionAnalysisMS = 0.0
    var totalTrackingAnalysisMS = 0.0
    // Optional for decoding diagnostics written before asynchronous validation.
    var backgroundValidationResults: Int?
    var totalBackgroundValidationMS: Double?
    var analysisDecisions: [String: Int] = [:]
    var controlDecisions: [String: Int] = [:]
    // Optional so sessions recorded before v25 still decode.
    var pitchStartBoostFrames: Int?
    var targetAcquisitions = 0
    var targetLosses = 0
    var detectedFrames = 0
    var noFaceFrames = 0
    var multipleFaceFrames = 0
    var staleFrames = 0
    var motionCommands = 0
    var submittedMotion = 0
    var submittedHold = 0
    var acknowledgements = 0
    var expiredCommands = 0
    var writeErrors = 0
    var maximumLatencyMS = 0.0
    var totalFrameLatencyMS = 0.0
    var totalTransportMS = 0.0
    var totalAnalysisMS = 0.0
    var lastPacket = ""
    var message = ScreenFollowLocalized("Not Started Yet")

    var averageLatencyMS: Double { analyzedFrames > 0 ? totalFrameLatencyMS / Double(analyzedFrames) : 0 }
    var averageTransportMS: Double { analyzedFrames > 0 ? totalTransportMS / Double(analyzedFrames) : 0 }
    var averageAnalysisMS: Double { analyzedFrames > 0 ? totalAnalysisMS / Double(analyzedFrames) : 0 }
    var averageDetectionMS: Double { faceDetectionFrames > 0 ? totalDetectionAnalysisMS / Double(faceDetectionFrames) : 0 }
    var averageTrackingMS: Double { visualTrackingFrames > 0 ? totalTrackingAnalysisMS / Double(visualTrackingFrames) : 0 }

    mutating func recordAnalysis(capturedAt: TimeInterval, receivedAt: TimeInterval, completedAt: TimeInterval, usedTracking: Bool = false) {
        guard capturedAt.isFinite, receivedAt.isFinite, completedAt.isFinite,
              receivedAt >= capturedAt, completedAt >= receivedAt else { return }
        analyzedFrames += 1
        let latency = (completedAt - capturedAt) * 1000
        maximumLatencyMS = max(maximumLatencyMS, latency)
        totalFrameLatencyMS += latency
        totalTransportMS += (receivedAt - capturedAt) * 1000
        totalAnalysisMS += (completedAt - receivedAt) * 1000
        if usedTracking {
            visualTrackingFrames += 1
            totalTrackingAnalysisMS += (completedAt - receivedAt) * 1000
        } else {
            faceDetectionFrames += 1
            totalDetectionAnalysisMS += (completedAt - receivedAt) * 1000
        }
    }
}
