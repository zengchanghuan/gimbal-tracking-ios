import Foundation
import CoreGraphics
import CoreVideo
import Vision

// The detector is a fixture. Identity boundary tests inject explicit appearance
// distances; the actual production feature helper is also executed separately.
// A few tests delay real Vision completion to exercise source-age rejection.
// This harness compiles production policy,
// coordinator, diagnostics, and model contracts, and executes real CPU Vision.
// It does not measure model precision/recall or claim iPhone/motor performance.
final class FixtureDetector: ObjectDetecting {
    let backend: ObjectDetectionBackend
    init(backend: ObjectDetectionBackend = .coreMLCPU) { self.backend = backend }
    let modelIdentifier = "test-fixture-not-a-trained-model"
    private let lock = NSLock()
    private var values: [ObjectDetection] = []
    private var delay: TimeInterval = 0
    private var callCount = 0
    func configure(_ detections: [ObjectDetection], delay: TimeInterval = 0) {
        lock.lock(); values = detections; self.delay = delay; lock.unlock()
    }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return callCount }
    func detect(pixelBuffer: CVPixelBuffer, timestampMilliseconds: Int) throws -> [ObjectDetection] {
        lock.lock(); let result = values; let duration = delay; callCount += 1; lock.unlock()
        if duration > 0 { Thread.sleep(forTimeInterval: duration) }
        return result
    }
}

final class DelayedVisionPerformer {
    private let lock = NSLock()
    private var callCount = 0
    let delayedCalls: Set<Int>
    let delay: TimeInterval
    init(delayedCalls: Set<Int>, delay: TimeInterval) {
        self.delayedCalls = delayedCalls
        self.delay = delay
    }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return callCount }
    func perform(_ handler: VNSequenceRequestHandler, _ request: VNTrackObjectRequest,
                 _ image: CVPixelBuffer) throws {
        lock.lock(); callCount += 1; let call = callCount; lock.unlock()
        try handler.perform([request], on: image, orientation: .up)
        if delayedCalls.contains(call) { Thread.sleep(forTimeInterval: delay) }
    }
}

struct FixtureAppearanceFeature: ObjectTrackingAppearanceFeature {
    let value: Float
    let revision = 2
    func distance(to other: ObjectTrackingAppearanceFeature) throws -> Float {
        guard let other = other as? FixtureAppearanceFeature else { throw NSError(domain: "Fixture", code: 1) }
        return abs(value - other.value)
    }
}

final class FixtureAppearanceProvider {
    private let lock = NSLock()
    private var callCount = 0
    private var completedCount = 0
    private var observedBoxes: [CGRect] = []
    private var value: Float = 0
    private var duration: TimeInterval = 0
    private var shouldFail = false
    let delayedCalls: [Int: TimeInterval]
    init(delayedCalls: [Int: TimeInterval] = [:]) { self.delayedCalls = delayedCalls }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return callCount }
    var completed: Int { lock.lock(); defer { lock.unlock() }; return completedCount }
    var boxes: [CGRect] { lock.lock(); defer { lock.unlock() }; return observedBoxes }
    func configure(value: Float = 0, delay: TimeInterval = 0, fail: Bool = false) {
        lock.lock(); self.value = value; duration = delay; shouldFail = fail; lock.unlock()
    }
    func feature(_ buffer: CVPixelBuffer, _ box: CGRect) throws -> ObjectTrackingAppearanceFeature {
        lock.lock()
        callCount += 1
        observedBoxes.append(box)
        let value = value, delay = delayedCalls[callCount] ?? duration, fail = shouldFail
        lock.unlock()
        defer { lock.lock(); completedCount += 1; lock.unlock() }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if fail { throw NSError(domain: "Fixture.AppearanceUnavailable", code: 2) }
        return FixtureAppearanceFeature(value: value)
    }
}

final class GateAppearanceProvider {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var callCount = 0
    private var firstBlocked = false
    let failFirst: Bool
    init(failFirst: Bool) { self.failFirst = failFirst }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return callCount }
    var blocked: Bool { lock.lock(); defer { lock.unlock() }; return firstBlocked }
    func release() { gate.signal() }
    func feature(_ buffer: CVPixelBuffer, _ box: CGRect) throws -> ObjectTrackingAppearanceFeature {
        lock.lock(); callCount += 1; let first = callCount == 1; firstBlocked = first; lock.unlock()
        if first { _ = gate.wait(timeout: .now() + 2) }
        lock.lock(); firstBlocked = false; lock.unlock()
        if first && failFirst { throw NSError(domain: "Fixture.WarmupCancelledFailure", code: 1) }
        return FixtureAppearanceFeature(value: 0)
    }
}

final class RejectOldAdvancePerformer {
    private let lock = NSLock()
    private var first: VNTrackObjectRequest?
    private var armed = false
    private var failures = 0
    var rejected: Int { lock.lock(); defer { lock.unlock() }; return failures }
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func perform(_ handler: VNSequenceRequestHandler, _ request: VNTrackObjectRequest, _ image: CVPixelBuffer) throws {
        lock.lock()
        if first == nil { first = request }
        let reject = armed && first === request
        if reject { failures += 1 }
        lock.unlock()
        if reject { throw NSError(domain: "Fixture.OldTrackerAdvanceUnreliable", code: 1) }
        try handler.perform([request], on: image, orientation: .up)
    }
}

final class GateVisionPerformer {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var nextBlocked = false
    private var isBlocked = false
    var blocked: Bool { lock.lock(); defer { lock.unlock() }; return isBlocked }
    func blockNext() { lock.lock(); nextBlocked = true; lock.unlock() }
    func release() { gate.signal() }
    func perform(_ handler: VNSequenceRequestHandler, _ request: VNTrackObjectRequest, _ image: CVPixelBuffer) throws {
        try handler.perform([request], on: image, orientation: .up)
        lock.lock(); let block = nextBlocked; nextBlocked = false; isBlocked = block; lock.unlock()
        if block { _ = gate.wait(timeout: .now() + 2) }
        lock.lock(); isBlocked = false; lock.unlock()
    }
}

// Satisfy the production default factory without linking/downloading either
// backend. All tested coordinators receive an explicit FixtureDetector factory.
struct CoreMLObjectDetector: ObjectDetecting {
    let backend: ObjectDetectionBackend
    let modelIdentifier = "unused"
    init(backend: ObjectDetectionBackend, labelPolicy: ObjectDetectionLabelPolicy = .benchmarkSixClasses) throws { self.backend = backend }
    func detect(pixelBuffer: CVPixelBuffer, timestampMilliseconds: Int) throws -> [ObjectDetection] { [] }
}
typealias MediaPipeObjectDetector = CoreMLObjectDetector

@main
enum ObjectTrackingCoordinatorSmoke {
    static var assertions = 0
    static let diagnosticRoot = FileManager.default.temporaryDirectory.appendingPathComponent("object-tracking-fixture-\(UUID().uuidString)")
    static let box = CGRect(x: 0.28, y: 0.30, width: 0.28, height: 0.32)
    static var cup: ObjectDetection { ObjectDetection(label: "cup", confidence: 0.92, boundingBox: box) }

    // Preserve legacy fallback coverage independently of the new optional OS
    // feature model. Dedicated appearance tests below exercise success and faults.
    static let unavailableAppearance: ObjectTrackingCoordinator.AppearanceProvider = { _, _ in
        throw NSError(domain: "Fixture.AppearanceUnavailable", code: 1)
    }

    // Existing worker/identity tests intentionally pause source submission.
    // Keep their expiry scheduler controlled; the default dispatch-main lease
    // is exercised separately by deliveryExpiryChecks with real elapsed time.
    static let controlledExpiryScheduler: ObjectTrackingCoordinator.MotionExpiryScheduler = { _, _ in }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        precondition(condition(), message)
    }

    static func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.003)) }
    }

    static func wait(_ message: String, timeout: TimeInterval = 3, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { pump(0.005) }
        expect(predicate(), message)
    }

    static func buffer(box: CGRect = box) -> CVPixelBuffer {
        let width = 320, height = 240
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                        nil, &result)
        precondition(status == kCVReturnSuccess, "CVPixelBufferCreate status=\(status)")
        let pixelBuffer = result!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let bytes = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let x0 = Int(box.minX * CGFloat(width)), x1 = Int(box.maxX * CGFloat(width))
        let y0 = Int((1 - box.maxY) * CGFloat(height)), y1 = Int((1 - box.minY) * CGFloat(height))
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                let inside = x >= x0 && x < x1 && y >= y0 && y < y1
                let localX = x - x0, localY = y - y0
                let shade = inside ? UInt8((localX * 19 + localY * 37 + localX * localY * 3) & 255) : UInt8(42)
                bytes[offset] = shade
                bytes[offset + 1] = inside ? 255 - shade : shade
                bytes[offset + 2] = inside ? UInt8((localX * 53 + localY * 11) & 255) : shade
                bytes[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    static func submit(_ coordinator: ObjectTrackingCoordinator, _ image: CVPixelBuffer,
                       geometry: UInt64 = 1) {
        let now = ProcessInfo.processInfo.systemUptime
        expect(coordinator.submit(pixelBuffer: image, capturedAt: now, mediaPTS: now - 1, geometryID: geometry),
               "fresh input admitted")
    }

    static func policyChecks() {
        expect(!ObjectTrackingPolicy.isFresh(10, now: 9.9), "future frames cannot authorize motion")
        expect(ObjectTrackingPolicy.isFresh(10, now: 10.25), "position boundary is inclusive")
        expect(!ObjectTrackingPolicy.isFresh(10, now: 10.251), "expired positions rejected")
        expect(!ObjectTrackingPolicy.mayMove(positionAt: 10.7, semanticAt: 10, now: 10.751, trackingConfidence: 0.9),
               "new positions do not extend semantic identity")
        expect(!ObjectTrackingPolicy.mayMove(positionAt: 10, semanticAt: 10.2, now: 10.3, trackingConfidence: 0.9),
               "new semantics do not extend old position")
        expect(ObjectTrackingPolicy.validBoundingBox(CGRect(x: .nan, y: 0, width: 0.2, height: 0.2)) == nil,
               "NaN boxes rejected before Vision")
        expect(ObjectTrackingPolicy.validBoundingBox(CGRect(x: 0, y: 0, width: -0.2, height: 0.2)) == nil,
               "negative sizes rejected")
        let neighbor = ObjectDetection(label: "cup", confidence: 0.99, boundingBox: box.offsetBy(dx: 0.04, dy: 0))
        if case .ambiguous = ObjectTrackingPolicy.associate(cup, with: [cup, neighbor]) {
            assertions += 1
        } else { preconditionFailure("two plausible instances must not be ranked by score") }
        let differentClass = ObjectDetection(label: "bottle", confidence: 1, boundingBox: box)
        if case .missing = ObjectTrackingPolicy.associate(cup, with: [differentClass]) { assertions += 1 }
        else { preconditionFailure("class changes cannot inherit identity") }
        expect(ObjectTrackingPolicy.candidate(at: CGPoint(x: box.midX, y: box.midY), in: [cup, neighbor]) == nil,
               "indistinguishable overlap is not a selection")
        let tiny = ObjectDetection(label: "cell phone", confidence: 0.8,
                                   boundingBox: CGRect(x: box.midX - 0.02, y: box.midY - 0.02, width: 0.04, height: 0.04))
        expect(ObjectTrackingPolicy.candidate(at: CGPoint(x: box.midX, y: box.midY), in: [cup, tiny])?.label == "cell phone",
               "unambiguous smaller containing box wins the click")
        expect(!ObjectTrackingPolicy.detectionIsDue(state: .tracking, lastDetectionAt: 10.5,
                                                    capturedAt: 10.64, semanticAt: 10.5),
               "recent semantic evidence retains ordinary detector cadence")
        expect(ObjectTrackingPolicy.detectionIsDue(state: .tracking, lastDetectionAt: 10.5,
                                                   capturedAt: 10.64, semanticAt: 10),
               "near-expiry semantics get a detector opportunity before the next ordinary tick")
        expect(!ObjectTrackingPolicy.correctionIsNeeded(cup, with: cup, trackingConfidence: 0.95,
                                                          lastSeedAt: 10, capturedAt: 10.3),
               "stable geometry does not trigger redundant initialization")
        expect(!ObjectTrackingPolicy.correctionIsNeeded(cup, with: differentClass, trackingConfidence: 0.95,
                                                          lastSeedAt: 10, capturedAt: 11.2),
               "periodic correction cannot inherit a different class")
        expect(ObjectTrackingPolicy.correctionIsNeeded(cup, with: neighbor, trackingConfidence: 0.95,
                                                         lastSeedAt: 10, capturedAt: 10.1),
               "geometry requiring confirmation cannot bypass it during seed throttling")
        expect(!ObjectTrackingPolicy.correctionSeedIsDue(lastSeedAt: 10, capturedAt: 10.1),
               "pending identity evidence cannot force seed before its minimum interval")
    }

    static func startTracking(_ coordinator: ObjectTrackingCoordinator, detector: FixtureDetector,
                              image: CVPixelBuffer) {
        coordinator.start(backend: .coreMLCPU)
        wait("test run ready") { coordinator.snapshot?.state == .searching }
        submit(coordinator, image)
        wait("test candidate displayed") { coordinator.snapshot?.candidates.count == 1 }
        expect(coordinator.selectNormalizedPoint(CGPoint(x: box.midX, y: box.midY)), "test candidate selected")
        submit(coordinator, image)
        wait("first fresh confirmation completed") { coordinator.snapshot?.frameID == 2 }
        pump(0.13)
        submit(coordinator, image)
        wait("two fresh confirmations start real Vision") { coordinator.snapshot?.shouldMove == true }
    }

    static func flushedEvents(_ coordinator: ObjectTrackingCoordinator) -> String {
        var exported: URL?
        coordinator.prepareExport { exported = $0 }
        wait("test diagnostics flushed") { exported != nil }
        return try! String(contentsOf: exported!.appendingPathComponent("events.jsonl"), encoding: .utf8)
    }

    static func correctionChecks() {
        let detector = FixtureDetector()
        detector.configure([cup])
        let coordinator = ObjectTrackingCoordinator(onUpdate: { _ in }, detectorFactory: { _ in detector },
                                                    trackerUsesCPUOnly: true, diagnosticsRootDirectory: diagnosticRoot, appearanceProvider: unavailableAppearance, motionExpiryScheduler: controlledExpiryScheduler, appearanceWarmupEnabled: false)
        let image = buffer()
        startTracking(coordinator, detector: detector, image: image)
        let control = coordinator.snapshot!.controlID
        let corrected = ObjectDetection(label: "cup", confidence: 0.96, boundingBox: box.offsetBy(dx: 0.04, dy: 0))
        detector.configure([corrected])
        pump(0.26)
        submit(coordinator, image)
        wait("first correction candidate was considered") { coordinator.snapshot?.frameID == 4 }
        expect(coordinator.snapshot!.selectedDetection!.confidence == cup.confidence
               && ObjectTrackingPolicy.intersectionOverUnion(coordinator.snapshot!.selectedDetection!.boundingBox,
                                                              corrected.boundingBox) < 0.95,
               "one fresh detector candidate cannot replace the tracked position or confidence")
        pump(0.13)
        submit(coordinator, image)
        wait("twice-confirmed detector correction was published") { coordinator.snapshot?.frameID == 5 }
        expect(coordinator.snapshot?.shouldMove == true && coordinator.snapshot?.controlID == control,
               "compatible correction preserves this target's active control generation")
        expect(ObjectTrackingPolicy.intersectionOverUnion(coordinator.snapshot!.selectedDetection!.boundingBox,
                                                          corrected.boundingBox) > 0.95,
               "correction adopts the current measured geometry instead of the drifted tracker box")
        coordinator.stop(reason: "correction_test_done")
        let events = flushedEvents(coordinator)
        expect(events.contains("tracker_correction_attempt") && events.contains("tracker_correction_applied"),
               "correction attempt and successful application are independently observable")
    }

    static func seedFreshnessRetryChecks() {
        let detector = FixtureDetector()
        detector.configure([cup])
        let performer = DelayedVisionPerformer(delayedCalls: [1], delay: 0.26)
        var updates: [ObjectTrackingSnapshot] = []
        let coordinator = ObjectTrackingCoordinator(onUpdate: { updates.append($0) }, detectorFactory: { _ in detector },
            trackerUsesCPUOnly: true, diagnosticsRootDirectory: diagnosticRoot, trackerPerformer: performer.perform, appearanceProvider: unavailableAppearance, motionExpiryScheduler: controlledExpiryScheduler, appearanceWarmupEnabled: false)
        coordinator.start(backend: .coreMLCPU)
        wait("slow-seed run ready") { coordinator.snapshot?.state == .searching }
        let image = buffer()
        submit(coordinator, image)
        wait("slow-seed candidate ready") { coordinator.snapshot?.candidates.count == 1 }
        expect(coordinator.selectNormalizedPoint(CGPoint(x: box.midX, y: box.midY)), "slow-seed candidate selected")
        let heldControl = coordinator.snapshot!.controlID
        submit(coordinator, image)
        wait("slow-seed first confirmation completed") { coordinator.snapshot?.frameID == 2 }
        pump(0.13)
        submit(coordinator, image)
        wait("late real Vision seed completed") { coordinator.snapshot?.frameID == 3 }
        expect(coordinator.snapshot?.state == .confirming && coordinator.snapshot?.selectedDetection?.label == "cup",
               "expired seed retains only the bounded original selection")
        expect(coordinator.snapshot?.controlID == heldControl && !updates.contains { $0.shouldMove },
               "expired seed never acquires a movement token or emits motion")
        expect(!coordinator.submit(pixelBuffer: image, capturedAt: coordinator.snapshot!.capturedAt,
                                   mediaPTS: 0, geometryID: 1),
               "retry cannot resubmit the old expired seed frame as fresh evidence")
        submit(coordinator, image)
        wait("first retry detection completed") { coordinator.snapshot?.frameID == 4 }
        expect(coordinator.snapshot?.state == .confirming && coordinator.snapshot?.shouldMove == false,
               "one new detection cannot inherit expired seed confirmations")
        pump(0.13)
        submit(coordinator, image)
        wait("two new fresh detections can restore the selected target") { coordinator.snapshot?.shouldMove == true }
        expect(coordinator.snapshot!.frameID == 5 && coordinator.snapshot!.controlID != heldControl,
               "successful retry publishes a new frame and a new movement generation")
        coordinator.stop(reason: "seed_retry_test_done")
        expect(flushedEvents(coordinator).contains("tracker_seed_retry"), "expired initialization retry is logged")
    }

    static func retryDeadlineChecks() {
        let detector = FixtureDetector()
        detector.configure([cup])
        let performer = DelayedVisionPerformer(delayedCalls: [1], delay: 0.26)
        let coordinator = ObjectTrackingCoordinator(onUpdate: { _ in }, detectorFactory: { _ in detector },
            trackerUsesCPUOnly: true, diagnosticsRootDirectory: diagnosticRoot, trackerPerformer: performer.perform, appearanceProvider: unavailableAppearance, motionExpiryScheduler: controlledExpiryScheduler, appearanceWarmupEnabled: false)
        coordinator.start(backend: .coreMLCPU)
        wait("deadline retry run ready") { coordinator.snapshot?.state == .searching }
        let image = buffer()
        submit(coordinator, image)
        wait("deadline retry candidate ready") { coordinator.snapshot?.candidates.count == 1 }
        expect(coordinator.selectNormalizedPoint(CGPoint(x: box.midX, y: box.midY)), "deadline retry candidate selected")
        submit(coordinator, image)
        wait("deadline retry first confirmation completed") { coordinator.snapshot?.frameID == 2 }
        pump(0.13)
        submit(coordinator, image)
        wait("deadline retry late seed rejected") { coordinator.snapshot?.frameID == 3 }
        expect(coordinator.snapshot?.state == .confirming, "late seed initially retains its selection")
        // This exceeds the original selection deadline, while remaining well
        // within a hypothetical new 750ms deadline started at the retry.
        pump(0.40)
        submit(coordinator, image)
        wait("original selection deadline still expires") { coordinator.snapshot?.state == .searching }
        expect(coordinator.snapshot?.selectedDetection == nil && coordinator.snapshot?.shouldMove == false,
               "retry does not turn a bounded selection into indefinite reacquisition")
        expect(performer.calls == 1, "expired original selection cannot run another tracker seed")
        coordinator.stop(reason: "retry_deadline_test_done")
    }

    static func expiredCorrectionChecks() {
        let detector = FixtureDetector()
        detector.configure([cup])
        let performer = DelayedVisionPerformer(delayedCalls: [4], delay: 0.26)
        var updates: [ObjectTrackingSnapshot] = []
        let coordinator = ObjectTrackingCoordinator(onUpdate: { updates.append($0) }, detectorFactory: { _ in detector },
            trackerUsesCPUOnly: true, diagnosticsRootDirectory: diagnosticRoot, trackerPerformer: performer.perform, appearanceProvider: unavailableAppearance, motionExpiryScheduler: controlledExpiryScheduler, appearanceWarmupEnabled: false)
        let image = buffer()
        startTracking(coordinator, detector: detector, image: image)
        let movingControl = coordinator.snapshot!.controlID
        detector.configure([ObjectDetection(label: "cup", confidence: 0.96, boundingBox: box.offsetBy(dx: 0.04, dy: 0))])
        pump(0.26)
        submit(coordinator, image)
        wait("first delayed-correction candidate is pending") { coordinator.snapshot?.frameID == 4 }
        pump(0.13)
        submit(coordinator, image)
        wait("expired correction enters a holding state") { coordinator.snapshot?.state == .temporarilyLost }
        expect(coordinator.snapshot?.shouldMove == false && coordinator.snapshot?.controlID != movingControl,
               "late correction revokes movement rather than publishing a new position")
        expect(!updates.contains { $0.frameID == 5 && $0.shouldMove },
               "no motion callback contains the expired correction frame")
        submit(coordinator, image)
        wait("first correction recovery detection completed") { coordinator.snapshot?.frameID == 6 }
        expect(coordinator.snapshot?.state == .temporarilyLost && coordinator.snapshot?.shouldMove == false,
               "late correction cannot resume from a single fresh match")
        pump(0.13)
        submit(coordinator, image)
        wait("two fresh matches recover after rejected correction") { coordinator.snapshot?.shouldMove == true }
        expect(coordinator.snapshot?.frameID == 7, "recovery uses only the new source frame")
        coordinator.stop(reason: "expired_correction_test_done")
        expect(flushedEvents(coordinator).contains("tracker_correction_rejected"),
               "rejected correction is distinct from successful application in telemetry")
    }

    static func correctionInvalidationChecks() {
        let detector = FixtureDetector()
        detector.configure([cup])
        let performer = DelayedVisionPerformer(delayedCalls: [4], delay: 0.26)
        let coordinator = ObjectTrackingCoordinator(onUpdate: { _ in }, detectorFactory: { _ in detector },
            trackerUsesCPUOnly: true, diagnosticsRootDirectory: diagnosticRoot, trackerPerformer: performer.perform, appearanceProvider: unavailableAppearance, motionExpiryScheduler: controlledExpiryScheduler, appearanceWarmupEnabled: false)
        let image = buffer()
        startTracking(coordinator, detector: detector, image: image)
        detector.configure([ObjectDetection(label: "cup", confidence: 0.96, boundingBox: box.offsetBy(dx: 0.04, dy: 0))])
        pump(0.26)
        submit(coordinator, image)
        wait("first cancellable correction candidate is pending") { coordinator.snapshot?.frameID == 4 }
        pump(0.13)
        submit(coordinator, image)
        wait("confirmed correction is executing") { performer.calls == 4 }
        coordinator.stop(reason: "stop_during_correction")
        let stoppedControl = coordinator.snapshot!.controlID
        pump(0.30)
        expect(coordinator.snapshot?.state == .idle && coordinator.snapshot?.shouldMove == false,
               "stop during a correction persists after real Vision completes")
        expect(coordinator.snapshot?.controlID == stoppedControl,
               "late correction cannot restore the prior control generation")
        let events = flushedEvents(coordinator)
        expect(events.contains("tracker_correction_attempt") && !events.contains("tracker_correction_applied"),
               "cancelled correction cannot be counted as applied")
    }

    static func correctionIdentityChecks() {
        for scenario in ["return_to_original", "ambiguous", "pending_ambiguous", "mixed_class", "missing", "expired_pair", "same_source", "stop_pending"] {
            let detector = FixtureDetector()
            detector.configure([cup])
            let coordinator = ObjectTrackingCoordinator(onUpdate: { _ in }, detectorFactory: { _ in detector },
                                                        trackerUsesCPUOnly: true, diagnosticsRootDirectory: diagnosticRoot, appearanceProvider: unavailableAppearance, motionExpiryScheduler: controlledExpiryScheduler, appearanceWarmupEnabled: false)
            let image = buffer()
            startTracking(coordinator, detector: detector, image: image)
            // A same-class neighbor with IoU ~0.379 passes ordinary association,
            // but one observation must never move the target to that neighbor.
            let neighbor = ObjectDetection(label: "cup", confidence: 0.99, boundingBox: box.offsetBy(dx: 0.126, dy: 0))
            detector.configure([neighbor])
            pump(0.26)
            submit(coordinator, image)
            wait("\(scenario): first neighbor observation processed") { coordinator.snapshot?.frameID == 4 }
            expect(coordinator.snapshot!.selectedDetection!.confidence == cup.confidence
                   && ObjectTrackingPolicy.intersectionOverUnion(coordinator.snapshot!.selectedDetection!.boundingBox,
                                                                 neighbor.boundingBox) < 0.80,
                   "\(scenario): pending neighbor cannot change the selected position")
            let pendingSource = coordinator.snapshot!.capturedAt
            if scenario == "stop_pending" {
                coordinator.stop(reason: scenario)
            } else {
                if scenario == "return_to_original" { detector.configure([cup]) }
                if scenario == "ambiguous" { detector.configure([cup, neighbor]) }
                if scenario == "pending_ambiguous" {
                    // This second neighbor is compatible with B but not with
                    // the original A. Association must be unique from both.
                    let outsideOriginal = ObjectDetection(label: "cup", confidence: 0.98,
                        boundingBox: box.offsetBy(dx: 0.27, dy: 0))
                    detector.configure([neighbor, outsideOriginal])
                }
                if scenario == "mixed_class" {
                    detector.configure([cup, ObjectDetection(label: "bottle", confidence: 0.98, boundingBox: box)])
                }
                if scenario == "missing" { detector.configure([]) }
                pump(scenario == "expired_pair" ? 0.36 : 0.13)
                if scenario == "same_source" {
                    expect(coordinator.submit(pixelBuffer: image, capturedAt: pendingSource, mediaPTS: pendingSource - 1, geometryID: 1),
                           "still-fresh repeated source may enter but is not a second confirmation")
                } else {
                    submit(coordinator, image)
                }
                wait("\(scenario): next observation processed") { coordinator.snapshot?.frameID == 5 }
                if ["ambiguous", "pending_ambiguous", "mixed_class"].contains(scenario) {
                    expect(coordinator.snapshot?.state == .temporarilyLost && coordinator.snapshot?.shouldMove == false,
                           "\(scenario): conflicting identity revokes motion")
                } else {
                    expect(ObjectTrackingPolicy.intersectionOverUnion(coordinator.snapshot!.selectedDetection!.boundingBox,
                                                                     neighbor.boundingBox) < 0.80,
                           "\(scenario): unconfirmed neighbor never replaces the original geometry")
                }
                coordinator.stop(reason: scenario)
            }
            let events = flushedEvents(coordinator)
            expect(events.contains("tracker_correction_pending") && !events.contains("tracker_correction_applied"),
                   "\(scenario): no single/expired/conflicting candidate can be counted as applied")
            let contents = try! String(contentsOf: coordinator.exportURL!.appendingPathComponent("frames.jsonl"), encoding: .utf8)
            let rows = contents.split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
            let first = rows.first { $0["frameID"] as? Int == 4 }!
            expect((first["semanticAgeMs"] as? Double ?? 0) >= 250,
                   "\(scenario): pending neighbor did not renew semantic authorization")
            let rawBox = first["trackerObservationBoundingBox"] as! [Double]
            let publishedBox = (first["selected"] as! [String: Any])["boundingBox"] as! [Double]
            expect(zip(rawBox, publishedBox).allSatisfy { abs($0 - $1) < 1e-10 }
                   && first["trackerPhase"] as? String == "advance",
                   "\(scenario): first pending position is exactly the real tracker output, not the detector candidate")
            if let second = rows.first(where: { $0["frameID"] as? Int == 5 }) {
                expect((second["semanticAgeMs"] as? Double ?? 0) >= 350,
                       "\(scenario): rejected confirmation does not renew pending identity semantics")
            }
        }
    }

    static func semanticRefreshChecks() {
        let detector = FixtureDetector()
        detector.configure([cup])
        let coordinator = ObjectTrackingCoordinator(onUpdate: { _ in }, detectorFactory: { _ in detector },
                                                    trackerUsesCPUOnly: true, diagnosticsRootDirectory: diagnosticRoot, appearanceProvider: unavailableAppearance, motionExpiryScheduler: controlledExpiryScheduler, appearanceWarmupEnabled: false)
        let image = buffer()
        startTracking(coordinator, detector: detector, image: image)
        detector.configure([])
        pump(0.26)
        submit(coordinator, image)
        wait("first semantic miss completed") { coordinator.snapshot?.frameID == 4 }
        pump(0.26)
        submit(coordinator, image)
        wait("second semantic miss completed") { coordinator.snapshot?.frameID == 5 }
        let calls = detector.calls
        pump(0.13)
        submit(coordinator, image)
        wait("deadline-aware frame completed") { coordinator.snapshot?.frameID == 6 }
        expect(detector.calls == calls + 1, "stale semantics trigger an earlier actual detector invocation")
        pump(0.13)
        submit(coordinator, image)
        wait("unrenewed semantics stop motion") { coordinator.snapshot?.state == .temporarilyLost }
        expect(coordinator.snapshot?.shouldMove == false,
               "successful tracker updates never extend expired semantic authorization")
        coordinator.stop(reason: "semantic_test_done")
    }

    static func stopAndBackpressureChecks() {
        let detector = FixtureDetector()
        detector.configure([cup], delay: 0.12)
        var updates: [ObjectTrackingSnapshot] = []
        let coordinator = ObjectTrackingCoordinator(onUpdate: { updates.append($0) }, detectorFactory: { _ in detector },
                                                    trackerUsesCPUOnly: true, diagnosticsRootDirectory: diagnosticRoot, appearanceProvider: unavailableAppearance, motionExpiryScheduler: controlledExpiryScheduler, appearanceWarmupEnabled: false)
        coordinator.start(backend: .coreMLCPU)
        wait("model initialized") { coordinator.snapshot?.state == .searching }
        let image = buffer()
        expect(!coordinator.submit(pixelBuffer: image, capturedAt: ProcessInfo.processInfo.systemUptime - 0.10,
                                   mediaPTS: 1, geometryID: 1),
               "camera backlog captured before this session cannot enter a new generation")
        submit(coordinator, image)
        wait("fixture inference started") { detector.calls == 1 }
        for _ in 0..<20 { submit(coordinator, image) }
        wait("latest retained frame, not queued history, was consumed") { coordinator.snapshot?.frameID == 21 }
        expect(detector.calls == 1, "non-due frames do not trigger redundant detection")
        expect(!updates.contains { $0.shouldMove }, "searching never drives motion")
        pump(0.26)
        submit(coordinator, image)
        wait("second fixture inference started") { detector.calls == 2 }
        coordinator.stop(reason: "smoke_stop_in_flight")
        let stoppedControl = coordinator.snapshot!.controlID
        pump(0.18)
        expect(!coordinator.isActive && coordinator.snapshot?.state == .idle, "stop is immediate and persists after inference")
        expect(coordinator.snapshot?.controlID == stoppedControl, "late result cannot restore a stopped token")

        let oldSession = coordinator.snapshot!.sessionID
        let oldURL = coordinator.exportURL!
        coordinator.start(backend: .coreMLCPU)
        coordinator.recordEvent("ble_actual_write", details: ["sessionID": oldSession.uuidString, "controlID": stoppedControl.uuidString])
        wait("next run initialized") { coordinator.snapshot?.state == .searching }
        pump(0.06)
        let oldEvents = (try? String(contentsOf: oldURL.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        let newEvents = (try? String(contentsOf: coordinator.exportURL!.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        expect(oldEvents.contains("ble_actual_write"), "late BLE event stays in the original run")
        expect(!newEvents.contains("ble_actual_write"), "late BLE event does not contaminate the next run")
        let oldSummary = try! JSONSerialization.jsonObject(with: Data(contentsOf: oldURL.appendingPathComponent("summary.json"))) as! [String: Any]
        let oldCounts = oldSummary["counts"] as! [String: Any]
        expect(oldCounts["analyzedFrames"] as? Int == 2 && oldCounts["postStopCompletedFrames"] as? Int == 1,
               "in-flight completion after stop is distinct from active-run analysis")
        expect(oldSummary["latencyObservationCount"] as? Int == 2,
               "late cancelled analysis cannot skew the completed run latency")
        coordinator.stop(reason: "smoke_done")
    }

    static func realVisionChecks() {
        let detector = FixtureDetector()
        detector.configure([cup])
        var updates: [ObjectTrackingSnapshot] = []
        let coordinator = ObjectTrackingCoordinator(onUpdate: { updates.append($0) }, detectorFactory: { _ in detector },
                                                    trackerUsesCPUOnly: true, diagnosticsRootDirectory: diagnosticRoot, appearanceProvider: unavailableAppearance, motionExpiryScheduler: controlledExpiryScheduler, appearanceWarmupEnabled: false)
        coordinator.start(backend: .coreMLCPU)
        coordinator.recordConfiguration(["fixtureCameraWidth": 320, "fixtureCameraFPS": 30.0])
        wait("real Vision run ready") { coordinator.snapshot?.state == .searching }
        let image = buffer()
        submit(coordinator, image)
        wait("candidate displayed") { coordinator.snapshot?.candidates.count == 1 }
        coordinator.selectNormalizedPoint(CGPoint(x: box.midX, y: box.midY))
        let selectingControl = coordinator.snapshot!.controlID
        expect(coordinator.snapshot?.state == .confirming && coordinator.snapshot?.shouldMove == false,
               "click creates a holding confirmation state")
        submit(coordinator, image)
        wait("first confirmation performed") { detector.calls >= 2 }
        pump(0.02)
        expect(coordinator.snapshot?.state == .confirming, "one confirmation cannot move")
        pump(0.13)
        submit(coordinator, image)
        wait("two detections initialize actual Vision on their source buffer") { coordinator.snapshot?.shouldMove == true }
        let trackingControl = coordinator.snapshot!.controlID
        expect(trackingControl != selectingControl, "motion never reuses the held selection token")
        expect(ObjectTrackingPolicy.intersectionOverUnion(coordinator.snapshot!.selectedDetection!.boundingBox, box) > 0.70,
               "real tracker initializes over the source object")

        // A second plausible cup forces an immediate hold, then two unique
        // confirmations may recover within the bounded identity window.
        detector.configure([cup, ObjectDetection(label: "cup", confidence: 0.99, boundingBox: box.offsetBy(dx: 0.025, dy: 0))])
        pump(0.26)
        submit(coordinator, image)
        wait("ambiguity holds the target") { coordinator.snapshot?.state == .temporarilyLost }
        let lostControl = coordinator.snapshot!.controlID
        expect(lostControl != trackingControl && coordinator.snapshot?.shouldMove == false,
               "loss revokes the former movement token")
        detector.configure([cup])
        submit(coordinator, image)
        pump(0.14)
        submit(coordinator, image)
        wait("unique original target can be confirmed again") { coordinator.snapshot?.shouldMove == true }
        expect(coordinator.snapshot!.controlID != lostControl, "recovery gets a fresh unblocked movement token")

        detector.configure([cup, ObjectDetection(label: "cup", confidence: 0.99, boundingBox: box.offsetBy(dx: 0.025, dy: 0))])
        pump(0.26)
        submit(coordinator, image)
        wait("second ambiguity enters recovery") { coordinator.snapshot?.state == .temporarilyLost }
        pump(0.51)
        detector.configure([cup])
        submit(coordinator, image)
        wait("recovery window expires even when the same class returns") { coordinator.snapshot?.state == .searching }
        expect(coordinator.snapshot?.selectedDetection == nil && coordinator.snapshot?.shouldMove == false,
               "expired identity cannot reacquire without a new user selection")

        coordinator.invalidateControl(reason: "smoke_watchdog")
        let watchdogControl = coordinator.snapshot!.controlID
        expect(coordinator.snapshot?.state == .searching && coordinator.snapshot?.shouldMove == false,
               "independent watchdog requires user reselection")
        submit(coordinator, image)
        pump(0.05)
        expect(coordinator.snapshot?.controlID == watchdogControl && coordinator.snapshot?.shouldMove == false,
               "fresh detections alone cannot resume after watchdog")
        submit(coordinator, image, geometry: 2)
        pump(0.05)
        expect(coordinator.snapshot!.controlID != watchdogControl && coordinator.snapshot?.shouldMove == false,
               "geometry changes revoke selection")
        coordinator.stop(reason: "smoke_done")
        var exported: URL?
        coordinator.prepareExport { exported = $0 }
        wait("diagnostics flushed") { exported != nil }
        let summary = try! JSONSerialization.jsonObject(with: Data(contentsOf: exported!.appendingPathComponent("summary.json"))) as! [String: Any]
        let manifest = try! JSONSerialization.jsonObject(with: Data(contentsOf: exported!.appendingPathComponent("manifest.json"))) as! [String: Any]
        expect(manifest["fixtureCameraWidth"] as? Int == 320 && manifest["fixtureCameraFPS"] as? Double == 30,
               "thread-safe configuration persists in the run manifest")
        expect(manifest["trackerRevision"] as? Int == VNTrackObjectRequestRevision2
               && manifest["trackerRevisionApplied"] as? Int == VNTrackObjectRequestRevision2,
               "production default requests and actually seeds Vision revision 2")
        expect(manifest["trackerLevel"] as? String == "accurate"
               && manifest["trackerLevelEffective"] as? String == "ignored_by_VNTrackObjectRequestRevision2",
               "manifest does not misrepresent accurate as an effective revision 2 option")
        expect((manifest["hardwareMachine"] as? String)?.isEmpty == false && manifest["executionEnvironment"] as? String == "macos_host",
               "manifest identifies hardware and host environment without a generic device label")
        expect(summary["precision"] is NSNull && summary["recall"] is NSNull, "diagnostics never invent accuracy")
        expect(summary["diagnosticWriteFailures"] as? Int == 0, "diagnostic data are valid JSON")
    }

    static func appearanceChecks() {
        // Test the real production crop/request helper independently of fixture
        // state-machine cases. This is API execution, not accuracy evidence.
        let image = buffer()
        let realA = try! ObjectTrackingCoordinator.makeAppearanceFeature(image, box)
        let realB = try! ObjectTrackingCoordinator.makeAppearanceFeature(image, box)
        expect(realA.revision == 2 && realB.revision == 2, "actual feature observations use revision 2")
        expect(try! realA.distance(to: realB) < 0.0001, "same actual crop has stable self distance")

        let farBox = box.offsetBy(dx: 0.40, dy: 0.10)
        let far = ObjectDetection(label: "cup", confidence: 0.91, boundingBox: farBox)
        let farImage = buffer(box: farBox)
        func enterHold(_ coordinator: ObjectTrackingCoordinator, _ detector: FixtureDetector) {
            detector.configure([ObjectDetection(label: "bottle", confidence: 0.99, boundingBox: box)])
            pump(0.26); submit(coordinator, image)
            wait("conflicting class stops motion before appearance search") { coordinator.snapshot?.state == .temporarilyLost }
            expect(coordinator.snapshot?.shouldMove == false, "hold has no movement authorization")
        }
        func processed(_ coordinator: ObjectTrackingCoordinator, _ pixels: CVPixelBuffer = farImage,
                       interval: TimeInterval = 0.13) {
            let previous = coordinator.snapshot!.frameID
            pump(interval); submit(coordinator, pixels)
            wait("appearance test frame consumed") { coordinator.snapshot!.frameID > previous }
        }
        // Every scenario starts from a real Vision tracker and fixed template.
        // Model fixtures control a later observation; feature fixtures control
        // identity evidence and delay, never a tracker output or clock.
        for scenario in ["recover", "wrong_appearance", "missing", "conflict", "ambiguous",
                         "pair_expired", "stale_feature", "feature_failure", "stale_seed", "deadline",
                         "feature_deadline", "seed_deadline", "stop"] {
            let detector = FixtureDetector(); detector.configure([cup])
            let provider = FixtureAppearanceProvider()
            let performer = DelayedVisionPerformer(delayedCalls: ["stale_seed", "seed_deadline"].contains(scenario) ? [3] : [],
                                                   delay: scenario == "seed_deadline" ? 0.20 : 0.26)
            var updates: [ObjectTrackingSnapshot] = []
            let coordinator = ObjectTrackingCoordinator(onUpdate: { updates.append($0) },
                detectorFactory: { _ in detector }, trackerUsesCPUOnly: true,
                diagnosticsRootDirectory: diagnosticRoot, trackerPerformer: performer.perform,
                appearanceProvider: provider.feature, motionExpiryScheduler: controlledExpiryScheduler, appearanceWarmupEnabled: false)
            startTracking(coordinator, detector: detector, image: image)
            expect(provider.calls == 1, "template created exactly once from confirmed initial detection")
            enterHold(coordinator, detector)
            let oldBox = coordinator.snapshot!.selectedDetection!.boundingBox
            detector.configure([far])
            pump(0.52)
            if scenario == "wrong_appearance" { provider.configure(value: 0.71) }
            if scenario == "stale_feature" { provider.configure(delay: 0.26) }
            if scenario == "feature_failure" { provider.configure(fail: true) }
            if ["deadline", "feature_deadline", "seed_deadline"].contains(scenario) { pump(2.23) }
            if scenario == "stop" {
                provider.configure(delay: 0.12)
                submit(coordinator, farImage)
                wait("candidate appearance began") { provider.calls == 2 }
                coordinator.stop(reason: "stop_during_appearance")
                let count = updates.filter(\.shouldMove).count
                pump(0.16)
                expect(coordinator.snapshot?.state == .idle && updates.filter(\.shouldMove).count == count,
                       "late appearance after stop cannot publish or restore a template")
                continue
            }
            processed(coordinator, interval: 0)
            if scenario == "feature_failure" {
                expect(coordinator.snapshot?.state == .searching && coordinator.snapshot?.shouldMove == false,
                       "feature failure shrinks recovery to original 500ms deadline")
                expect(flushedEvents(coordinator).contains("effectiveDeadlineHostTime"), "fallback deadline is auditable")
                coordinator.stop(); continue
            }
            expect(coordinator.snapshot?.shouldMove == false && coordinator.snapshot?.selectedDetection?.boundingBox == oldBox,
                   "one appearance candidate cannot update real target or authorize movement")
            if scenario == "wrong_appearance" || scenario == "stale_feature" {
                provider.configure()
                processed(coordinator)
                expect(coordinator.snapshot?.shouldMove == false, "rejected or stale identity evidence cannot count as first confirmation")
            }
            if scenario == "missing" || scenario == "conflict" {
                if scenario == "missing" { detector.configure([]) }
                else { detector.configure([far, ObjectDetection(label: "bottle", confidence: 0.99, boundingBox: farBox)]) }
                processed(coordinator)
                detector.configure([far]); processed(coordinator)
                expect(coordinator.snapshot?.shouldMove == false, "missing or mixed-class conflict clears the old appearance confirmation")
            }
            if scenario == "ambiguous" {
                detector.configure([far, cup]); processed(coordinator)
                expect(coordinator.snapshot?.state == .searching && coordinator.snapshot?.shouldMove == false,
                       "two same-class candidates anywhere require new user selection")
                coordinator.stop(); continue
            }
            if scenario == "pair_expired" {
                processed(coordinator, interval: 0.36)
                expect(coordinator.snapshot?.shouldMove == false, "expired pair cannot seed from old identity history")
            }
            if scenario == "deadline" {
                // The first candidate did not restart the original hold window.
                processed(coordinator, interval: 0.30)
                expect(coordinator.snapshot?.state == .searching && coordinator.snapshot?.shouldMove == false,
                       "candidate evidence cannot extend the original three-second hold deadline")
                coordinator.stop(); continue
            }
            if scenario == "feature_deadline" { provider.configure(delay: 0.20) }
            processed(coordinator)
            if scenario == "feature_deadline" || scenario == "seed_deadline" {
                expect(coordinator.snapshot?.state == .searching && coordinator.snapshot?.shouldMove == false,
                       "fresh feature or seed finishing after original hold deadline cannot recover")
                coordinator.stop(); continue
            }
            if scenario == "stale_seed" {
                expect(coordinator.snapshot?.state == .temporarilyLost && coordinator.snapshot?.shouldMove == false,
                       "recovery seed completing after 250ms never moves")
                processed(coordinator)
                expect(coordinator.snapshot?.shouldMove == false, "late recovery seed discards the old pair")
                processed(coordinator)
            }
            expect(coordinator.snapshot?.state == .tracking && coordinator.snapshot?.shouldMove == true,
                   "two fresh unique appearance matches can recover after the old 500ms window")
            expect(ObjectTrackingPolicy.intersectionOverUnion(coordinator.snapshot!.selectedDetection!.boundingBox, farBox) > 0.80,
                   "recovered position comes from second fresh detection's new location")
            let events = flushedEvents(coordinator)
            expect(events.components(separatedBy: "appearance_template_created").count == 2,
                   "fixed original template is not replaced during recovery")
            expect(events.contains("appearance_recovery_confirmed") && events.contains("sourceIntervalMs"),
                   "both identity source frames and original hold time are recorded")
            coordinator.stop()
        }
        // Cold template generation preserves identity only; retry must acquire
        // two fresh appearance-confirmed frames within the original 750ms limit.
        for scenario in ["retry", "selection_deadline", "reselection"] {
            let detector = FixtureDetector(); detector.configure([cup])
            let provider = FixtureAppearanceProvider(delayedCalls: [1: scenario == "selection_deadline" ? 0.65 : 0.26])
            let coordinator = ObjectTrackingCoordinator(onUpdate: { _ in }, detectorFactory: { _ in detector },
                trackerUsesCPUOnly: true, diagnosticsRootDirectory: diagnosticRoot, appearanceProvider: provider.feature, motionExpiryScheduler: controlledExpiryScheduler, appearanceWarmupEnabled: false)
            coordinator.start(backend: .coreMLCPU)
            wait("cold template session ready") { coordinator.snapshot?.state == .searching }
            submit(coordinator, image)
            wait("cold template candidate") { coordinator.snapshot?.candidates.count == 1 }
            expect(coordinator.selectNormalizedPoint(CGPoint(x: box.midX, y: box.midY)), "cold template selected")
            submit(coordinator, image)
            wait("first initial confirmation") { coordinator.snapshot?.frameID == 2 }
            processed(coordinator, image)
            if scenario == "selection_deadline" {
                expect(coordinator.snapshot?.state == .searching && coordinator.snapshot?.shouldMove == false,
                       "template finishing after selection deadline cannot be retained")
                expect(!flushedEvents(coordinator).contains("appearance_template_created"), "late template is not logged as accepted")
                coordinator.stop(); continue
            }
            expect(coordinator.snapshot?.state == .confirming && coordinator.snapshot?.shouldMove == false,
                   "cold template never supplies expired movement")
            if scenario == "reselection" {
                // New selection resets the fixed identity, not just control ID.
                coordinator.invalidateControl(reason: "fixture_new_selection")
                detector.configure([cup]); processed(coordinator, image, interval: 0)
                expect(coordinator.selectNormalizedPoint(CGPoint(x: box.midX, y: box.midY)), "new user selection accepted")
                submit(coordinator, image); pump(0.03); processed(coordinator, image)
                wait("new selection obtains own template") { coordinator.snapshot?.shouldMove == true }
                let text = flushedEvents(coordinator)
                expect(text.components(separatedBy: "appearance_template_created").count == 3,
                       "new selection creates a new immutable template")
            } else {
                provider.configure(value: 0.71)
                processed(coordinator, image, interval: 0)
                expect(coordinator.snapshot?.shouldMove == false, "nearby different appearance cannot inherit cached template selection")
                provider.configure()
                processed(coordinator, image)
                expect(coordinator.snapshot?.shouldMove == false, "cached template does not retain expired initial confirmations")
                processed(coordinator, image)
                expect(coordinator.snapshot?.shouldMove == true, "two fresh matching frames complete bounded cold-template retry")
                expect(flushedEvents(coordinator).contains("appearance_initial_retry_confirmed"), "initial retry has separate identity evidence")
            }
            coordinator.stop()
        }
    }

    static func warmupChecks() {
        let initialAssertions = assertions
        let image = buffer()
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        func documents(_ coordinator: ObjectTrackingCoordinator) -> (frames: [[String: Any]], events: [[String: Any]], manifest: [String: Any]) {
            _ = flushedEvents(coordinator)
            let directory = coordinator.exportURL!
            func rows(_ name: String) -> [[String: Any]] {
                let value = (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
                return value.split(separator: "\n").map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            }
            let manifest = try! JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as! [String: Any]
            return (rows("frames.jsonl"), rows("events.jsonl"), manifest)
        }
        func start(_ coordinator: ObjectTrackingCoordinator) {
            coordinator.start(backend: .coreMLCPU)
            wait("warmup test session initialized") { coordinator.snapshot?.state == .searching }
            submit(coordinator, image)
        }
        func nextCandidate(_ coordinator: ObjectTrackingCoordinator, geometry: UInt64 = 1) {
            let previous = coordinator.snapshot!.frameID
            submit(coordinator, image, geometry: geometry)
            wait("post-warmup fresh source supplies candidates") {
                coordinator.snapshot!.frameID > previous && coordinator.snapshot?.candidates.count == 1
            }
        }
        func selectAndConfirm(_ coordinator: ObjectTrackingCoordinator, geometry: UInt64 = 1) {
            let previous = coordinator.snapshot!.frameID
            let selectedAt = ProcessInfo.processInfo.systemUptime
            expect(coordinator.selectNormalizedPoint(CGPoint(x: box.midX, y: box.midY)), "fresh post-warmup object can be selected")
            submit(coordinator, image, geometry: geometry)
            wait("warmup cannot count as initial confirmation") { coordinator.snapshot!.frameID > previous }
            expect(coordinator.snapshot?.state == .confirming && coordinator.snapshot?.shouldMove == false,
                   "first post-selection detection is still holding")
            pump(0.13); submit(coordinator, image, geometry: geometry)
            wait("two fresh post-selection detections initialize real Vision") { coordinator.snapshot?.shouldMove == true }
            expect(ProcessInfo.processInfo.systemUptime - selectedAt < ObjectTrackingPolicy.selectionLifetime,
                   "warmup does not extend original 750ms selection budget")
        }
        func enterHold(_ coordinator: ObjectTrackingCoordinator, _ detector: FixtureDetector, geometry: UInt64) {
            detector.configure([ObjectDetection(label: "bottle", confidence: 0.99, boundingBox: box)])
            // Keep the default 250ms delivery lease fresh while waiting for the
            // normal 250ms detector cadence. No scheduler is disabled here.
            var previous = coordinator.snapshot!.frameID
            pump(0.14); submit(coordinator, image, geometry: geometry)
            wait("intermediate position keeps default lease fresh") { coordinator.snapshot!.frameID > previous }
            previous = coordinator.snapshot!.frameID
            pump(0.13); submit(coordinator, image, geometry: geometry)
            wait("conflict holds warmup-test target") { coordinator.snapshot!.frameID > previous && coordinator.snapshot?.state == .temporarilyLost }
        }
        do {
            let detector = FixtureDetector(); detector.configure([cup])
            let provider = FixtureAppearanceProvider(delayedCalls: [1: 0.32])
            var updates: [ObjectTrackingSnapshot] = []
            let coordinator = ObjectTrackingCoordinator(onUpdate: { updates.append($0) }, detectorFactory: { _ in detector },
                trackerUsesCPUOnly: true, diagnosticsRootDirectory: diagnosticRoot, appearanceProvider: provider.feature)
            start(coordinator)
            wait("injected cold warmup started") { provider.calls == 1 }
            expect(!coordinator.selectNormalizedPoint(CGPoint(x: box.midX, y: box.midY)), "warmup frame is never selectable")
            pump(0.12); submit(coordinator, image)
            wait("injected cold warmup completed") { provider.completed == 1 }
            pump(0.03)
            expect(detector.calls == 0 && updates.allSatisfy { $0.candidates.isEmpty && !$0.shouldMove },
                   "warmup and its still-fresh queued frame cannot supply candidates or motion")
            let before = documents(coordinator)
            let row = before.frames.first { $0["appearanceWarmupRan"] as? Bool == true }!
            expect((row["appearanceWarmupMs"] as! Double) >= 300, "injected first-use work exceeds position lifetime")
            expect(row["appearanceMs"] as? Double == 0 && row["detectorMs"] == nil && row["trackerMs"] == nil,
                   "warmup cost is separate from detector, tracker, template and candidate costs")
            expect(row["shouldMove"] as? Bool == false && row["hasAppearanceTemplate"] as? Bool == false && row["semanticAt"] is NSNull,
                   "runtime initialization creates no semantic identity or template")
            expect((row["captureToAnalysisEndMs"] as! Double) >= (row["appearanceWarmupMs"] as! Double),
                   "capture-to-analysis latency still includes first-use work")
            expect(before.events.contains { $0["reason"] as? String == "captured_before_warmup_completed" },
                   "queued source captured during warmup is explicitly discarded")
            expect(before.manifest["appearanceWarmupRevisionApplied"] as? Int == 2 && before.manifest["appearanceWarmupEnabled"] as? Bool == true,
                   "actual warmup revision is distinct and default-enabled")
            expect(before.manifest["expirySchedulerKind"] as? String == "dispatch_main", "warmup tests retain real delivery expiry")
            nextCandidate(coordinator)
            selectAndConfirm(coordinator)
            expect(provider.calls == 2 && provider.boxes == [whole, box], "only full-frame warmup and second-confirmation model crop are extracted")
            let after = documents(coordinator)
            let templates = after.events.filter { $0["event"] as? String == "appearance_template_created" }
            expect(templates.count == 1 && (templates[0]["details"] as! [String: String])["templateFrameID"] == String(coordinator.snapshot!.frameID),
                   "fixed template belongs to second selection confirmation, never warmup")
            expect(after.events.filter { $0["event"] as? String == "appearance_warmup_finished" }.count == 1,
                   "session has exactly one warmup completion")
            coordinator.stop(reason: "warmup_cold_fixture_done")
        }
        // Session-scoped failure survives both control invalidation and geometry
        // reset, even if the injected API subsequently becomes available.
        do {
            let detector = FixtureDetector(); detector.configure([cup])
            let provider = FixtureAppearanceProvider(); provider.configure(fail: true)
            let coordinator = ObjectTrackingCoordinator(onUpdate: { _ in }, detectorFactory: { _ in detector },
                trackerUsesCPUOnly: true, diagnosticsRootDirectory: diagnosticRoot, appearanceProvider: provider.feature)
            start(coordinator)
            wait("failed warmup completed") { provider.completed == 1 }; pump(0.02)
            provider.configure()
            for geometry: UInt64 in [1, 2] {
                detector.configure([cup])
                nextCandidate(coordinator, geometry: geometry)
                selectAndConfirm(coordinator, geometry: geometry)
                expect(provider.calls == 1, "selection cannot retry or revive failed session appearance")
                enterHold(coordinator, detector, geometry: geometry)
                let data = documents(coordinator)
                let lost = data.events.last { $0["event"] as? String == "target_lost" }!["details"] as! [String: String]
                expect(lost["windowSeconds"] == "0.5" && lost["hasAppearanceTemplate"] == "false",
                       "unavailable warmup retains only original 500ms recovery")
                coordinator.invalidateControl(reason: "warmup_failure_reselect")
            }
            let data = documents(coordinator)
            expect(data.manifest["appearanceWarmupStatus"] as? String == "failed_discarded", "failure remains manifest-visible after multiple selections")
            expect(!data.events.contains { $0["event"] as? String == "appearance_template_created" }, "failed warmup never creates a template")
            coordinator.stop()
        }
        // A concurrent same-session control/geometry reset must not erase the
        // original attempt or its failure. New sessions must not inherit either.
        for scenario in ["control_success", "control_failure", "geometry_failure", "restart_success", "restart_failure"] {
            let detector = FixtureDetector(); detector.configure([cup])
            let provider = GateAppearanceProvider(failFirst: scenario.hasSuffix("failure"))
            var updates: [ObjectTrackingSnapshot] = []
            let coordinator = ObjectTrackingCoordinator(onUpdate: { updates.append($0) }, detectorFactory: { _ in detector },
                trackerUsesCPUOnly: true, diagnosticsRootDirectory: diagnosticRoot, appearanceProvider: provider.feature)
            start(coordinator)
            wait("warmup blocks on real worker") { provider.blocked }
            let oldSession = coordinator.snapshot!.sessionID
            let restarting = scenario.hasPrefix("restart")
            let geometry: UInt64 = scenario.hasPrefix("geometry") ? 2 : 1
            if restarting { coordinator.stop(reason: "stop_during_warmup"); coordinator.start(backend: .coreMLCPU) }
            else if geometry == 2 { submit(coordinator, image, geometry: geometry) }
            else { coordinator.invalidateControl(reason: "control_during_warmup") }
            provider.release()
            wait("old warmup has left provider") { !provider.blocked }; pump(0.03)
            expect(updates.allSatisfy { $0.candidates.isEmpty && !$0.shouldMove }, "late warmup never publishes candidates or motion")
            if restarting {
                wait("new session initialized after old work") { coordinator.snapshot?.state == .searching && coordinator.snapshot?.sessionID != oldSession }
                submit(coordinator, image)
                wait("new session independently warms once") { provider.calls == 2 }; pump(0.03)
            }
            nextCandidate(coordinator, geometry: geometry)
            selectAndConfirm(coordinator, geometry: geometry)
            let disabled = scenario.hasSuffix("failure") && !restarting
            expect(provider.calls == (restarting ? 3 : disabled ? 1 : 2),
                   "session attempts and failure isolation survive concurrent lifecycle changes")
            let data = documents(coordinator)
            expect(data.frames.last?["hasAppearanceTemplate"] as? Bool == !disabled,
                   "only current session's successful warmup can enable its template")
            expect(data.events.filter { $0["event"] as? String == "appearance_warmup_started" }.count == 1,
                   "current session starts exactly one warmup despite resets")
            coordinator.stop()
        }
        // Execute the unchanged default OS feature provider, not only fixtures.
        // This proves the real request/crop path, not that this process is cold.
        do {
            let detector = FixtureDetector(); detector.configure([cup])
            let coordinator = ObjectTrackingCoordinator(onUpdate: { _ in }, detectorFactory: { _ in detector },
                trackerUsesCPUOnly: true, diagnosticsRootDirectory: diagnosticRoot)
            start(coordinator)
            wait("default real Vision warmup finished") {
                ((try? String(contentsOf: coordinator.exportURL!.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? "").contains("appearance_warmup_finished")
            }
            expect(coordinator.snapshot?.candidates.isEmpty == true && detector.calls == 0, "real full-frame result is also discarded")
            let data = documents(coordinator)
            expect(data.manifest["appearanceProviderKind"] as? String == "vision_feature_print" && data.manifest["appearanceWarmupRevisionApplied"] as? Int == 2,
                   "real provider produced actual revision 2")
            nextCandidate(coordinator); selectAndConfirm(coordinator)
            expect(documents(coordinator).frames.last?["hasAppearanceTemplate"] as? Bool == true,
                   "post-warmup real model crop becomes the separate fixed template")
            coordinator.stop()
        }
        print("default_enabled_warmup_assertions=\(assertions-initialAssertions) expiry_scheduler=dispatch_main injected_cold_delay_ms=320 actual_os_cold_claim=false")
    }

    static func deliveryExpiryChecks() {
        let initialAssertions = assertions
        let image = buffer()
        func at(_ deadline: TimeInterval) { pump(max(0, deadline - ProcessInfo.processInfo.systemUptime)) }
        func next(_ coordinator: ObjectTrackingCoordinator) {
            let old = coordinator.snapshot!.frameID
            submit(coordinator, image)
            wait("new actual motion publication") { coordinator.snapshot!.frameID > old }
            pump(0.005)
        }
        for scenario in ["position", "new_frame", "consumer_replaced_frame", "new_selection_timer", "blocked_position_delivery",
                         "semantic", "blocked_semantic_delivery", "watchdog_first",
                         "worker_stop", "stop_on_hold"] {
            let detector = FixtureDetector(); detector.configure([cup])
            let provider = FixtureAppearanceProvider()
            let gate = GateVisionPerformer()
            var updates: [(ObjectTrackingSnapshot, TimeInterval)] = []
            var stopOnHold = false
            var coordinator: ObjectTrackingCoordinator!
            coordinator = ObjectTrackingCoordinator(onUpdate: { snapshot in
                updates.append((snapshot, ProcessInfo.processInfo.systemUptime))
                if stopOnHold && snapshot.state == .temporarilyLost { coordinator.stop(reason: "fixture_stop_on_hold") }
            }, detectorFactory: { _ in detector }, trackerUsesCPUOnly: true,
               diagnosticsRootDirectory: diagnosticRoot, trackerPerformer: gate.perform, appearanceProvider: provider.feature, appearanceWarmupEnabled: false)
            // No scheduler injection: these exercise the actual main dispatch
            // deadline, including genuine main-thread stalls and worker blocking.
            startTracking(coordinator, detector: detector, image: image)
            let original = coordinator.snapshot!, origin = original.semanticAt
            expect(original.motionExpiresAt == min(original.capturedAt + 0.25, origin + 0.75),
                   "motion deadline is the minimum of the two immutable source leases")
            if scenario == "position" {
                wait("no fresh frames expire actual default position lease", timeout: 0.6) { coordinator.snapshot?.state == .searching }
                expect(coordinator.snapshot?.controlID != original.controlID, "expired position revokes its control generation")
            } else if scenario == "new_frame" || scenario == "consumer_replaced_frame" {
                at(origin + 0.14); next(coordinator)
                let newer = coordinator.snapshot!
                at(origin + 0.29)
                if scenario == "consumer_replaced_frame" {
                    coordinator.expireMotionAuthorization(original, boundary: "fixture_old_watchdog")
                }
                expect(coordinator.snapshot?.shouldMove == true && coordinator.snapshot?.frameID == newer.frameID,
                       "new frame cancels the old deadline even with unchanged controlID")
                wait("newer position eventually expires", timeout: 0.4) { coordinator.snapshot?.state == .searching }
            } else if scenario == "new_selection_timer" {
                at(origin + 0.14)
                expect(coordinator.selectNormalizedPoint(CGPoint(x: box.midX, y: box.midY)), "new selection cancels old motion lease")
                next(coordinator)
                at(origin + 0.29)
                expect(coordinator.snapshot?.state == .confirming && coordinator.snapshot?.shouldMove == false,
                       "old target deadline cannot invalidate a newly selected identity awaiting its second frame")
                next(coordinator)
                wait("new selection gets its own movement deadline") { coordinator.snapshot?.shouldMove == true }
                expect(provider.calls == 2, "new selection builds its own immutable appearance template")
                wait("new identity expires only at its own position cutoff", timeout: 0.5) { coordinator.snapshot?.state == .searching }
            } else if scenario == "blocked_position_delivery" {
                at(origin + 0.10); submit(coordinator, image)
                Thread.sleep(forTimeInterval: 0.30) // Deliberately do not pump the main loop.
                wait("queued expired position is rejected at actual delivery") { coordinator.snapshot?.state == .searching }
                expect(!updates.contains { $0.0.shouldMove && !$0.0.isMotionValid(at: $0.1) },
                       "a blocked main thread never delivers an expired true snapshot")
            } else {
                detector.configure([])
                let neighbor = ObjectDetection(label: "cup", confidence: 0.92, boundingBox: box.offsetBy(dx: 0.04, dy: 0))
                for offset in [0.10, 0.20, 0.30, 0.40, 0.50, 0.63] {
                    if offset == 0.63 && scenario == "worker_reselection" { detector.configure([neighbor]) }
                    at(origin + offset); next(coordinator)
                }
                expect(coordinator.snapshot?.shouldMove == true && coordinator.snapshot?.semanticAt == origin,
                       "tracker-only frames do not extend semantics")
                let lastMotion = coordinator.snapshot!
                expect(lastMotion.motionExpiresAt == origin + 0.75 && lastMotion.capturedAt + 0.25 > origin + 0.75,
                       "semantic deadline precedes the still-fresh position deadline")
                if scenario == "blocked_semantic_delivery" {
                    at(origin + 0.67); submit(coordinator, image)
                    Thread.sleep(forTimeInterval: 0.12)
                } else if scenario == "watchdog_first" {
                    Thread.sleep(forTimeInterval: max(0, origin + 0.77 - ProcessInfo.processInfo.systemUptime))
                    // Invoke the exact Camera watchdog entry before pumping the
                    // overdue dispatch task; both consumers must preserve hold.
                    coordinator.expireMotionAuthorization(lastMotion, boundary: "camera_watchdog")
                } else if scenario == "worker_stop" || scenario == "worker_reselection" {
                    gate.blockNext(); at(origin + 0.67); submit(coordinator, image)
                    wait("real Vision worker blocked before completing its frame") { gate.blocked }
                }
                stopOnHold = scenario == "stop_on_hold"
                wait("semantic cutoff is applied without waiting for another source frame", timeout: 0.5) {
                    coordinator.snapshot?.state == .temporarilyLost || coordinator.snapshot?.state == .idle
                }
                expect(coordinator.snapshot?.shouldMove == false && coordinator.snapshot?.controlID != original.controlID,
                       "semantic cutoff immediately holds with a new control token")
                expect(!updates.contains { $0.0.shouldMove && !$0.0.isMotionValid(at: $0.1) },
                       "all true snapshots were valid when the real consumer callback executed")
                if scenario == "worker_stop" {
                    coordinator.stop(reason: "stop_before_semantic_worker_transition")
                    gate.release(); pump(0.06)
                    expect(coordinator.snapshot?.state == .idle, "queued semantic hold cannot resurrect a stopped session")
                } else if scenario == "worker_reselection" {
                    expect(coordinator.selectNormalizedPoint(CGPoint(x: neighbor.boundingBox.midX, y: neighbor.boundingBox.midY)),
                           "fresh displayed candidate permits a new selection during queued old hold")
                    let selectedControl = coordinator.snapshot!.controlID
                    gate.release(); detector.configure([neighbor])
                    next(coordinator); pump(0.13); next(coordinator)
                    wait("new selection completes after old worker releases") { coordinator.snapshot?.shouldMove == true }
                    expect(coordinator.snapshot?.controlID != selectedControl && provider.calls == 2,
                           "old transition does not revive old identity or replace the newly selected template")
                } else if scenario == "semantic" {
                    pump(0.53)
                    expect(coordinator.snapshot?.state == .temporarilyLost, "a held semantic cutoff does not run the position expiry timer")
                    detector.configure([cup]); next(coordinator); pump(0.13); next(coordinator)
                    wait("same selection can recover through the unchanged appearance window") { coordinator.snapshot?.shouldMove == true }
                    expect(provider.calls == 3, "semantic cutoff preserves the one original template and checks two recovery frames")
                    let events = flushedEvents(coordinator)
                    let loss = events.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String:Any] }
                        .first { $0["event"] as? String == "target_lost" }
                    if let details = loss?["details"] as? [String:String], let lostAt = Double(details["lostAt"] ?? "") {
                        expect(abs(lostAt - (origin + 0.75)) < 0.000001, "recovery origin is the original semantic deadline, not later callback time")
                    } else { preconditionFailure("semantic hold must record original lostAt") }
                } else if scenario == "stop_on_hold" {
                    let events = flushedEvents(coordinator)
                    expect(events.contains("motion_expired_after_delivery"), "expiry decision survives an onUpdate callback stopping the session")
                }
            }
            let events = flushedEvents(coordinator)
            expect(events.contains("motion_expired_after_delivery") || events.contains("motion_rejected_at_delivery")
                   || events.contains("motion_rejected_at_consumer"),
                   "analysis authorization and actual delivery rejection have distinct diagnostic events")
            coordinator.stop(reason: "delivery_test_done")
        }
        // Invalid source values must not turn min(NaN, finite) into a lease.
        let invalid = ObjectTrackingSnapshot(state: .tracking, sessionID: UUID(), controlID: UUID(),
            frameID: 1, capturedAt: 10, geometryID: 1, candidates: [], candidatesCapturedAt: 10,
            selectedDetection: cup, shouldMove: true, semanticAt: .nan, error: nil)
        expect(invalid.motionExpiresAt == nil && !invalid.isMotionValid(at: 10.1), "invalid semantic source fails closed")
        print("default_dispatch_main_expiry_assertions=\(assertions-initialAssertions) real_main_stalls=true real_worker_blocks=true appearance_warmup=disabled_test")
    }

    static func correctionHoldChecks() {
        let corrected = ObjectDetection(label: "cup", confidence: 0.96,
            boundingBox: box.offsetBy(dx: 0.04, dy: 0))

        func make(_ detector: FixtureDetector, performer: DelayedVisionPerformer? = nil, gate: GateVisionPerformer? = nil,
                  observed: @escaping (ObjectTrackingSnapshot) -> Void = { _ in }) -> ObjectTrackingCoordinator {
            ObjectTrackingCoordinator(onUpdate: observed, detectorFactory: { _ in detector },
                trackerUsesCPUOnly: true, diagnosticsRootDirectory: diagnosticRoot,
                trackerPerformer: { handler, request, image in
                    if let gate { try gate.perform(handler, request, image) }
                    else if let performer { try performer.perform(handler, request, image) }
                    else { try handler.perform([request], on: image, orientation: .up) }
                }, appearanceProvider: unavailableAppearance,
                motionExpiryScheduler: controlledExpiryScheduler, appearanceWarmupEnabled: false)
        }
        func pending(_ coordinator: ObjectTrackingCoordinator, _ detector: FixtureDetector,
                     _ image: CVPixelBuffer, delay: TimeInterval = 0.26) -> (UUID, TimeInterval) {
            startTracking(coordinator, detector: detector, image: image)
            let old = coordinator.snapshot!.controlID
            let originalDeadline = coordinator.snapshot!.semanticAt + ObjectTrackingPolicy.semanticLifetime
            detector.configure([corrected])
            pump(delay)
            let stale = ProcessInfo.processInfo.systemUptime
            submit(coordinator, image)
            wait("first fresh correction is a stationary hold") { coordinator.snapshot?.frameID == 4 }
            expect(coordinator.snapshot?.shouldMove == false, "one correction candidate cannot authorize the old tracker")
            expect(coordinator.snapshot?.selectedDetection == nil, "hold UI cannot draw the old selected location")
            expect(coordinator.snapshot?.controlID != old, "first pending revokes the prior motion generation")
            expect(!coordinator.submit(pixelBuffer: image, capturedAt: stale, mediaPTS: 0, geometryID: 1),
                   "pre-hold captured sources cannot become the second confirmation")
            return (coordinator.snapshot!.controlID, originalDeadline)
        }
        do {
            let detector = FixtureDetector(); detector.configure([cup])
            var seen: [ObjectTrackingSnapshot] = []
            let coordinator = make(detector, observed: { seen.append($0) }); let image = buffer()
            let (held, _) = pending(coordinator, detector, image)
            pump(0.13); submit(coordinator, image)
            wait("second fresh correction completes") { coordinator.snapshot?.shouldMove == true }
            expect(coordinator.snapshot!.controlID != held, "held generation is never reused for movement")
            expect(ObjectTrackingPolicy.intersectionOverUnion(coordinator.snapshot!.selectedDetection!.boundingBox,
                    corrected.boundingBox) > 0.95, "second measured geometry replaces drift after confirmation")
            expect(!seen.contains { $0.controlID == held && $0.shouldMove }, "no motion callback escapes the hold generation")
            coordinator.stop(reason: "candidate_success")
        }
        for failure in ["missing", "changed", "conflict", "ambiguous"] {
            let detector = FixtureDetector(); detector.configure([cup])
            let coordinator = make(detector); let image = buffer()
            let (held, _) = pending(coordinator, detector, image)
            switch failure {
            case "missing": detector.configure([])
            case "changed": detector.configure([ObjectDetection(label: "cup", confidence: 0.96, boundingBox: box.offsetBy(dx: -0.04, dy: 0))])
            case "conflict": detector.configure([corrected, ObjectDetection(label: "bottle", confidence: 0.98, boundingBox: box)])
            default: detector.configure([corrected, ObjectDetection(label: "cup", confidence: 0.97, boundingBox: box.offsetBy(dx: 0.05, dy: 0))])
            }
            pump(0.13); submit(coordinator, image)
            wait("interrupted correction enters existing lost path: \(failure)") { coordinator.snapshot?.controlID != held }
            expect(coordinator.snapshot?.shouldMove == false && coordinator.snapshot?.state == .temporarilyLost,
                   "clearing pending never reauthorizes the old tracker")
            coordinator.stop(reason: "candidate_\(failure)")
        }
        do {
            let detector = FixtureDetector(); detector.configure([cup])
            let coordinator = make(detector); let image = buffer()
            let (held, originalDeadline) = pending(coordinator, detector, image)
            wait("no-source hold reaches original semantic deadline") { coordinator.snapshot?.controlID != held }
            expect(coordinator.snapshot?.shouldMove == false, "no-source timeout remains motionless")
            coordinator.stop(reason: "candidate_no_source")
            let text = flushedEvents(coordinator)
            let events = text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            let loss = events.first { $0["event"] as? String == "target_lost" }!
            let details = loss["details"] as! [String: String]
            expect(abs(Double(details["lostAt"]!)! - originalDeadline) < 0.000001,
                   "late worker observation does not restart the stationary recovery origin")
        }
        for cancel in ["stop", "reselect", "geometry"] {
            let detector = FixtureDetector(); detector.configure([cup])
            let coordinator = make(detector); let image = buffer()
            let (_, deadline) = pending(coordinator, detector, image)
            if cancel == "stop" { coordinator.stop(reason: "candidate_stop") }
            else if cancel == "reselect" {
                expect(coordinator.selectNormalizedPoint(CGPoint(x: corrected.boundingBox.midX, y: corrected.boundingBox.midY)),
                       "new selection is permitted during the correction hold")
                submit(coordinator, image); pump(0.13); submit(coordinator, image)
                wait("new selection confirmed before old hold deadline") { coordinator.snapshot?.shouldMove == true }
            } else {
                expect(coordinator.submit(pixelBuffer: image, capturedAt: ProcessInfo.processInfo.systemUptime, mediaPTS: 0, geometryID: 2),
                       "new geometry admitted")
                expect(coordinator.snapshot?.shouldMove == false, "geometry change immediately revokes movement")
                // The existing geometry path publishes paused before the worker
                // reset; a queued transition frame may legitimately be dropped.
                pump(0.02)
                expect(coordinator.submit(pixelBuffer: image, capturedAt: ProcessInfo.processInfo.systemUptime, mediaPTS: 0, geometryID: 2),
                       "post-reset source for new geometry is admitted")
                wait("fresh new-geometry source publishes searching") { coordinator.snapshot?.state == .searching }
            }
            let replacement = coordinator.snapshot!.controlID
            pump(max(0, deadline - ProcessInfo.processInfo.systemUptime) + 0.06)
            expect(coordinator.snapshot?.controlID == replacement, "old hold timer cannot invalidate \(cancel)")
            coordinator.stop(reason: "candidate_cancel_done")
        }
        for cancel in ["stop", "reselect"] {
            let detector = FixtureDetector(); detector.configure([cup])
            let gate = GateVisionPerformer(); var seen: [ObjectTrackingSnapshot] = []
            let coordinator = make(detector, gate: gate, observed: { seen.append($0) }); let image = buffer()
            let (held, _) = pending(coordinator, detector, image)
            gate.blockNext(); pump(0.13); submit(coordinator, image)
            wait("hold worker is blocked before correction completion") { gate.blocked }
            if cancel == "stop" {
                coordinator.stop(reason: "candidate_blocked_stop"); gate.release(); pump(0.08)
                expect(coordinator.snapshot?.state == .idle, "blocked correction cannot revive stopped selection")
            } else {
                expect(coordinator.selectNormalizedPoint(CGPoint(x: corrected.boundingBox.midX, y: corrected.boundingBox.midY)),
                       "new selection wins against blocked correction")
                let freshControl = coordinator.snapshot!.controlID
                gate.release(); pump(0.02); submit(coordinator, image); pump(0.13); submit(coordinator, image)
                wait("new selection confirms after obsolete correction completes") { coordinator.snapshot?.shouldMove == true }
                expect(coordinator.snapshot!.controlID != freshControl && coordinator.snapshot!.controlID != held,
                       "reselected identity owns its own confirmation generation")
            }
            expect(!seen.contains { $0.controlID == held && $0.shouldMove }, "obsolete blocked hold never authorizes movement")
            coordinator.stop(reason: "candidate_blocked_cancel_done")
        }
        for (delay, firstWait, reason) in [(0.27, 0.26, "position"), (0.15, 0.50, "semantic")] {
            let detector = FixtureDetector(); detector.configure([cup])
            let performer = DelayedVisionPerformer(delayedCalls: [3], delay: delay)
            var movements: [ObjectTrackingSnapshot] = []
            let coordinator = make(detector, performer: performer, observed: { if $0.shouldMove { movements.append($0) } })
            let image = buffer(); let (held, _) = pending(coordinator, detector, image, delay: firstWait)
            pump(0.13); submit(coordinator, image)
            wait("late correction seed fails closed: \(reason)") { coordinator.snapshot?.controlID != held }
            expect(coordinator.snapshot?.shouldMove == false, "late \(reason) seed cannot resume movement")
            expect(!movements.contains { $0.frameID == 5 }, "late seed never appears as an authorized callback")
            coordinator.stop(reason: "candidate_late_\(reason)")
        }
    }

    static func correctionHoldDefaultSchedulerCheck() {
        let detector = FixtureDetector(); detector.configure([cup])
        var seen: [ObjectTrackingSnapshot] = []
        var invalidDelivered = 0
        let coordinator = ObjectTrackingCoordinator(onUpdate: {
            if $0.shouldMove && !$0.isMotionValid(at: ProcessInfo.processInfo.systemUptime) { invalidDelivered += 1 }
            seen.append($0)
        }, detectorFactory: { _ in detector }, trackerUsesCPUOnly: true,
            diagnosticsRootDirectory: diagnosticRoot, appearanceProvider: unavailableAppearance,
            appearanceWarmupEnabled: false)
        let image = buffer(); startTracking(coordinator, detector: detector, image: image)
        let firstControl = coordinator.snapshot!.controlID
        let corrected = ObjectDetection(label: "cup", confidence: 0.96, boundingBox: box.offsetBy(dx: 0.04, dy: 0))
        detector.configure([corrected])
        let limit = ProcessInfo.processInfo.systemUptime + 1.5
        var held: UUID?
        while ProcessInfo.processInfo.systemUptime < limit {
            submit(coordinator, image); pump(0.035)
            if let current = coordinator.snapshot, !current.shouldMove && current.controlID != firstControl { held = current.controlID }
            if let held, coordinator.snapshot?.shouldMove == true, coordinator.snapshot?.controlID != held { break }
        }
        expect(held != nil, "default scheduler observes the stationary correction generation")
        expect(coordinator.snapshot?.shouldMove == true, "continuous fresh input resumes after two confirmations")
        expect(!seen.contains { $0.controlID == held && $0.shouldMove }, "no held-token movement with real main queue timers")
        expect(invalidDelivered == 0, "real main queue delivery preserves both source and semantic deadlines")
        let resumed = coordinator.snapshot!.controlID
        wait("final real position lease expires without further sources") { coordinator.snapshot?.controlID != resumed }
        expect(coordinator.snapshot?.shouldMove == false, "default expiry revokes the last resumed position")
        coordinator.stop(reason: "candidate_default_scheduler")
    }

    static func correctionPriorityChecks(detectorFirst: Bool) {
        let prior = assertions
        let corrected = ObjectDetection(label: "cup", confidence: 0.96, boundingBox: box.offsetBy(dx: 0.04, dy: 0))
        // A measured old-request failure is an injected boundary condition.
        // The detector remains a fixture; new seeds still execute real Vision.
        for failOldAdvance in [false, true] {
            let detector = FixtureDetector(backend: .coreMLAll); detector.configure([cup])
            let performer = RejectOldAdvancePerformer()
            var seen: [ObjectTrackingSnapshot] = []
            let coordinator = ObjectTrackingCoordinator(onUpdate: { seen.append($0) }, detectorFactory: { _ in detector },
                trackerUsesCPUOnly: true, diagnosticsRootDirectory: diagnosticRoot,
                trackerPerformer: { try performer.perform($0, $1, $2) }, appearanceProvider: unavailableAppearance,
                motionExpiryScheduler: controlledExpiryScheduler, appearanceWarmupEnabled: false)
            let image = buffer(); startTracking(coordinator, detector: detector, image: image)
            let semantic = coordinator.snapshot!.semanticAt
            detector.configure([corrected]); pump(0.26); submit(coordinator, image)
            wait("priority fixture first correction holds") { coordinator.snapshot?.frameID == 4 }
            expect(coordinator.snapshot?.shouldMove == false && coordinator.snapshot?.selectedDetection == nil,
                   "priority requires an already stationary first-evidence hold")
            let held = coordinator.snapshot!.controlID
            let firstSource = coordinator.snapshot!.capturedAt
            let oldCalls = detector.calls
            if failOldAdvance { performer.arm() }
            pump(0.04); submit(coordinator, image)
            wait("priority fixture second source completes") { coordinator.snapshot?.frameID == 5 }
            if failOldAdvance && !detectorFirst {
                expect(performer.rejected == 1, "tracker-first control really encounters the injected old-request failure")
                expect(detector.calls == oldCalls, "tracker-first aborts before the new detector confirmation")
                expect(coordinator.snapshot?.shouldMove == false, "failed old tracker cannot move")
            } else {
                expect(detector.calls == oldCalls + 1, "new confirmation runs after 40ms rather than waiting 120ms")
                expect(coordinator.snapshot?.shouldMove == true && coordinator.snapshot?.controlID != held,
                       "only completed two-frame seed creates a new movement generation")
                expect(performer.rejected == 0, "held detector-first path never invokes the invalid old tracker")
                expect(coordinator.snapshot!.capturedAt > firstSource && coordinator.snapshot!.capturedAt - firstSource <= 0.35,
                       "second position uses a distinct captured source inside the original pair bound")
                expect(coordinator.snapshot!.semanticAt > semantic && coordinator.snapshot!.isMotionValid(at: ProcessInfo.processInfo.systemUptime),
                       "successful seed remains fresh with renewed semantics from its second source")
                expect(ObjectTrackingPolicy.intersectionOverUnion(coordinator.snapshot!.selectedDetection!.boundingBox, corrected.boundingBox) > 0.95,
                       "successful new seed reports its second detector geometry")
            }
            expect(!seen.contains { $0.controlID == held && $0.shouldMove }, "no held-control position is ever authorized")
            let events = flushedEvents(coordinator)
            expect(events.contains("correction_motion_suspended"), "stationary correction decision is recorded")
            if !failOldAdvance || detectorFirst {
                expect(events.contains("correction_motion_resumed") && events.contains("originalSemanticDeadline")
                    && events.contains("heldControlID") && events.contains("firstFrameID") && events.contains("secondFrameID"),
                    "two-source resume can be independently audited")
            }
            coordinator.stop(reason: "priority_fixture_done")
        }
        do {
            let detector = FixtureDetector(backend: .coreMLCPU); detector.configure([cup])
            let coordinator = ObjectTrackingCoordinator(onUpdate: { _ in }, detectorFactory: { _ in detector },
                trackerUsesCPUOnly: true, diagnosticsRootDirectory: diagnosticRoot,
                appearanceProvider: unavailableAppearance, motionExpiryScheduler: controlledExpiryScheduler,
                appearanceWarmupEnabled: false)
            let image = buffer(); startTracking(coordinator, detector: detector, image: image)
            detector.configure([corrected]); pump(0.26); submit(coordinator, image)
            wait("CPU enters the same safe stationary correction hold") { coordinator.snapshot?.frameID == 4 }
            let calls = detector.calls; let held = coordinator.snapshot!.controlID
            pump(0.04); submit(coordinator, image)
            wait("CPU early source remains held without a new detection") { coordinator.snapshot?.frameID == 5 }
            expect(detector.calls == calls && coordinator.snapshot?.shouldMove == false && coordinator.snapshot?.controlID == held,
                   "CPU does not inherit the CoreMLAll 30ms cadence")
            pump(0.09); submit(coordinator, image)
            wait("CPU confirms at its unchanged 120ms cadence") { coordinator.snapshot?.shouldMove == true }
            expect(detector.calls == calls + 1, "CPU obtains exactly one independent second detector result")
            coordinator.stop(reason: "cpu_cadence_unchanged")
        }
        print("candidate_priority_assertions=\(assertions-prior) detector_first=\(detectorFirst) injected_old_advance_failure=true real_new_seed=true")
    }

    static func leaseLifecycleChecks() {
        let detector = FixtureDetector(backend: .coreMLAll); detector.configure([cup])
        var updates: [ObjectTrackingSnapshot] = []
        let coordinator = ObjectTrackingCoordinator(onUpdate: { updates.append($0) }, detectorFactory: { _ in detector },
            trackerUsesCPUOnly: true, diagnosticsRootDirectory: diagnosticRoot,
            appearanceProvider: unavailableAppearance, motionExpiryScheduler: controlledExpiryScheduler,
            appearanceWarmupEnabled: false)
        let image = buffer()
        coordinator.start(backend: .coreMLAll)
        wait("lease initial search ready") { coordinator.snapshot?.state == .searching }
        let searching = coordinator.snapshot!
        expect(searching.controlLease != nil, "production publish attaches a lease")
        submit(coordinator, image)
        wait("lease candidate ready") { coordinator.snapshot?.candidates.count == 1 }
        expect(coordinator.snapshot!.controlLease === searching.controlLease, "same control retains same revocable object")
        expect(coordinator.selectNormalizedPoint(CGPoint(x: box.midX,y:box.midY)), "lease select")
        let confirming = coordinator.snapshot!
        expect(!searching.controlLease!.isValid(sessionID: searching.sessionID,controlID: searching.controlID,
            expiresAt: ProcessInfo.processInfo.systemUptime+10), "select synchronously revokes prior lease")
        submit(coordinator,image)
        wait("lease first confirmation") { coordinator.snapshot?.frameID == 2 }
        pump(0.13); submit(coordinator,image)
        wait("lease real Vision confirmation") { coordinator.snapshot?.shouldMove == true }
        let tracking = coordinator.snapshot!
        expect(!confirming.controlLease!.isValid(sessionID:confirming.sessionID,controlID:confirming.controlID,
            expiresAt:ProcessInfo.processInfo.systemUptime+10), "tracking control revokes confirming lease")
        expect(tracking.controlLease!.isValid(sessionID:tracking.sessionID,controlID:tracking.controlID,
            expiresAt:tracking.motionExpiresAt!), "current true snapshot has live bounded lease")
        let corrected = ObjectDetection(label:"cup", confidence:0.96,boundingBox:box.offsetBy(dx:0.04,dy:0))
        detector.configure([corrected]); pump(0.26)
        let deliveredBefore = updates.last!.controlID
        submit(coordinator,image)
        // Deliberately do not run main. Analysis discovers hold and rotates,
        // while the Camera-equivalent consumer still only knows the old token.
        let deadline = Date().addingTimeInterval(2)
        while coordinator.snapshot?.frameID != 4 && Date() < deadline { Thread.sleep(forTimeInterval:0.002) }
        let held = coordinator.snapshot!
        expect(held.frameID == 4 && !held.shouldMove && held.controlID != tracking.controlID, "worker produced hold before delivery")
        expect(updates.last!.controlID == deliveredBefore, "main hold callback has not executed")
        expect(!tracking.controlLease!.isValid(sessionID:tracking.sessionID,controlID:tracking.controlID,
            expiresAt:ProcessInfo.processInfo.systemUptime+10), "worker rotation revokes BLE lease before main callback")
        pump(0.04); submit(coordinator,image)
        wait("lease second fresh correction") { coordinator.snapshot?.shouldMove == true }
        let resumed = coordinator.snapshot!
        expect(resumed.controlID != held.controlID && resumed.controlLease !== held.controlLease, "resume uses new lease")
        expect(!held.controlLease!.isValid(sessionID:held.sessionID,controlID:held.controlID,
            expiresAt:ProcessInfo.processInfo.systemUptime+10), "stationary lease is permanently revoked on resume")
        coordinator.invalidateControl(reason:"lease_fixture")
        expect(!resumed.controlLease!.isValid(sessionID:resumed.sessionID,controlID:resumed.controlID,
            expiresAt:ProcessInfo.processInfo.systemUptime+10), "explicit invalidation revokes current lease")
        pump(0.03)
        let priorGeometry=coordinator.snapshot!
        submit(coordinator,image,geometry:2)
        expect(!priorGeometry.controlLease!.isValid(sessionID:priorGeometry.sessionID,controlID:priorGeometry.controlID,
            expiresAt:ProcessInfo.processInfo.systemUptime+10), "geometry change revokes old authorization immediately")
        let beforeStop=coordinator.snapshot!
        coordinator.stop(reason:"lease_done")
        expect(!beforeStop.controlLease!.isValid(sessionID:beforeStop.sessionID,controlID:beforeStop.controlID,
            expiresAt:ProcessInfo.processInfo.systemUptime+10), "stop revokes snapshot lease")
        expect(updates.allSatisfy { $0.controlLease?.sessionID == $0.sessionID && $0.controlLease?.controlID == $0.controlID },
            "every published snapshot preserves immutable lease identity")
        var errors:[ObjectTrackingSnapshot]=[]
        let failed=ObjectTrackingCoordinator(onUpdate:{errors.append($0)},detectorFactory:{ _ in
            throw NSError(domain:"LeaseFixture",code:1)
        }, diagnosticsRootDirectory:diagnosticRoot,appearanceWarmupEnabled:false)
        failed.start(backend:.coreMLAll)
        wait("lease factory error completed") { failed.snapshot?.error != nil }
        let loading=errors.first!
        expect(!loading.controlLease!.isValid(sessionID:loading.sessionID,controlID:loading.controlID,
            expiresAt:ProcessInfo.processInfo.systemUptime+10), "factory failure revokes loading lease")
        failed.stop(reason:"lease_failure_done")
    }
    static func main() {
        policyChecks()
        stopAndBackpressureChecks()
        realVisionChecks()
        seedFreshnessRetryChecks()
        retryDeadlineChecks()
        semanticRefreshChecks()
        appearanceChecks()
        deliveryExpiryChecks()
        warmupChecks()
        print("unaffected_regression_assertions=\(assertions)")
        let prior = assertions
        correctionHoldChecks()
        correctionHoldDefaultSchedulerCheck()
        print("candidate_hold_assertions=\(assertions-prior) total=\(assertions)")
        correctionPriorityChecks(detectorFirst: true)
        leaseLifecycleChecks()
        print("final_assertions=\(assertions)")
        print("diagnostic_root=\(diagnosticRoot.path)")
    }
}
