import Foundation
import CoreGraphics

@main
enum ScreenFollowAsyncVisionSmoke {
    static var assertions = 0
    static func expect(_ value: @autoclosure () -> Bool, _ label: String) {
        assertions += 1
        precondition(value(), label)
    }

    // Face detections and completion order are controlled; every object-tracker
    // step still runs production CPU Vision against a genuinely translated image.
    static func image(_ face: ScreenFollowRect) -> CGImage {
        let context = CGContext(data: nil, width: 320, height: 480, bitsPerComponent: 8,
                                bytesPerRow: 1280, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 480))
        for y in 0..<12 {
            for x in 0..<10 {
                context.setFillColor(CGColor(gray: CGFloat((x * 7 + y * 11 + x * y) % 17) / 16, alpha: 1))
                context.fill(CGRect(x: (face.x + Double(x) * face.width / 10) * 320,
                                    y: (face.y + Double(y) * face.height / 12) * 480,
                                    width: face.width * 320 / 10, height: face.height * 480 / 12))
            }
        }
        return context.makeImage()!
    }

    final class ManualScheduler {
        private var jobs: [() -> Void] = []
        var count: Int { jobs.count }
        func schedule(_ job: @escaping () -> Void) { jobs.append(job) }
        func runNext() {
            expect(!jobs.isEmpty, "manual completion requires a queued job")
            jobs.removeFirst()()
        }
    }

    enum FixtureError: Error { case failedDetection }

    final class Pipeline {
        var current = ScreenFollowRect(x: 0.20, y: 0.425, width: 0.25, height: 0.25)
        var syncFaces: [ScreenFollowRect]?
        var asyncFaces: [ScreenFollowRect] = []
        var asyncThrows = false
        var synchronousDetections = 0
        var backgroundDetections = 0
        var context = "async-session"
        var controller = ScreenFollowController()
        var lastCommand: ScreenFollowCommand?
        let scheduler = ManualScheduler()
        private var frameID: UInt64 = 0
        lazy var worker = ScreenFollowValidationWorker(detect: { [unowned self] _ in
            backgroundDetections += 1
            if asyncThrows { throw FixtureError.failedDetection }
            return asyncFaces
        }, schedule: { [unowned self] job in scheduler.schedule(job) }, clock: { 1000 })
        lazy var analyzer = ScreenFollowFaceAnalyzer(timeSource: { 1000 }, asyncValidation: worker) { [unowned self] _ in
            synchronousDetections += 1
            return syncFaces ?? [current]
        }

        @discardableResult
        func step(_ time: TimeInterval) throws -> ScreenFollowFaceAnalyzer.Result {
            frameID += 1
            let result = try analyzer.analyze(image(current), capturedAt: time, now: time + 0.010,
                                              context: context, confirmedTarget: controller.trackingReference)
            if result.resetsTarget { controller.reset() }
            lastCommand = controller.observe(faces: result.faces, frameID: frameID,
                                             capturedAt: time, now: time + 0.010, yawSign: 1, pitchSign: 1)
            return result
        }

        func establishAndQueue() throws {
            let first = try step(100)
            let second = try step(100.10)
            expect(!first.usedTracking && !second.usedTracking && synchronousDetections == 2
                   && scheduler.count == 0 && controller.hasConfirmedTarget,
                   "acquisition stays synchronous and requires two fresh face detections")
            let fast = try step(100.30)
            expect(fast.usedTracking && scheduler.count == 0, "healthy tracking needs no early validation")
            asyncFaces = [current]
            let pending = try step(100.56)
            expect(pending.usedTracking && pending.faces.count == 1 && synchronousDetections == 2,
                   "450 ms periodic validation does not block the current CPU tracking result")
            expect(scheduler.count == 1 && backgroundDetections == 0,
                   "one validation job is admitted without executing it inline")
        }
    }

    static func defaultQueueCancellationDiscardsRunningDetection() {
        let face = ScreenFollowRect(x: 0.20, y: 0.425, width: 0.25, height: 0.25)
        let began = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        // Keep the real default DispatchQueue occupied in the injected detector.
        // Semaphores coordinate execution; this test does not guess a sleep time.
        let worker = ScreenFollowValidationWorker(detect: { _ in
            began.signal()
            defer { returned.signal() }
            guard release.wait(timeout: .now() + 2) == .success else { throw FixtureError.failedDetection }
            return [face]
        })
        let input = ScreenFollowValidationWorker.Input(generation: 1, context: "real-queue", capturedAt: 100, reference: face)
        expect(worker.start(image(face), input: input), "default queue accepts a real asynchronous operation")
        expect(began.wait(timeout: .now() + 2) == .success, "default queue actually enters the detector")
        worker.cancel()
        expect(!worker.start(image(face), input: input) && worker.takeCompleted() == nil,
               "canceled running work retains its physical slot and cannot publish a result")
        release.signal()
        expect(returned.wait(timeout: .now() + 2) == .success, "real detector exits after cancellation")
        expect(worker.takeCompleted() == nil, "the real canceled operation cannot deliver its face afterward")
    }

    static func cancellationKeepsOnePhysicalJobUntilDrained() {
        let scheduler = ManualScheduler()
        let face = ScreenFollowRect(x: 0.20, y: 0.425, width: 0.25, height: 0.25)
        var clock: TimeInterval = 10
        var duringDetection: (() -> Void)?
        let worker = ScreenFollowValidationWorker(detect: { _ in
            clock += 0.027
            duringDetection?()
            return [face]
        }, schedule: { scheduler.schedule($0) }, clock: { clock })
        let old = ScreenFollowValidationWorker.Input(generation: 1, context: "old", capturedAt: 100, reference: face)
        let fresh = ScreenFollowValidationWorker.Input(generation: 2, context: "fresh", capturedAt: 101, reference: face)
        let frame = image(face)
        expect(worker.start(frame, input: old), "idle worker admits one job")
        expect(!worker.start(frame, input: fresh), "busy worker rejects a second concurrent job")
        worker.cancel()
        for _ in 0..<20 {
            expect(!worker.start(frame, input: fresh), "logical cancellation cannot enqueue work behind an undrained job")
        }
        expect(scheduler.count == 1 && worker.takeCompleted() == nil,
               "cancellation neither grows the queue nor publishes an unfinished result")
        scheduler.runNext()
        expect(worker.takeCompleted() == nil, "a canceled job cannot publish a late completion")
        expect(worker.start(frame, input: fresh), "draining the old job restores admission")
        scheduler.runNext()
        guard let completed = worker.takeCompleted() else { preconditionFailure("fresh completion missing") }
        expect(completed.input.generation == 2 && completed.input.context == "fresh"
               && completed.input.capturedAt == 101 && completed.input.reference == face,
               "completion retains the image identity used for validation")
        if case .success(let faces) = completed.result { expect(faces == [face], "worker returns its detector result") }
        else { preconditionFailure("unexpected detection error") }
        expect(abs(completed.elapsedMS - 27) < 0.001 && worker.takeCompleted() == nil,
               "completion reports measured work time and is consumed exactly once")
        duringDetection = {
            worker.cancel()
            expect(!worker.start(frame, input: fresh), "cancel during detection remains busy until execution returns")
        }
        expect(worker.start(frame, input: old), "running-cancel fixture starts a new job")
        scheduler.runNext()
        duringDetection = nil
        expect(worker.takeCompleted() == nil && scheduler.count == 0,
               "cancel during detection discards its eventual result without queuing replacement work")
        expect(worker.start(frame, input: fresh), "worker remains reusable")
        scheduler.runNext()
        worker.cancel()
        expect(worker.takeCompleted() == nil, "cancel also removes a completed but unread result")
    }

    static func oldImageValidationCannotMoveTheCurrentBox() throws {
        let pipeline = Pipeline()
        defer { pipeline.analyzer.reset() }
        try pipeline.establishAndQueue()
        let queuedFace = pipeline.current
        pipeline.current.x += 0.08
        pipeline.scheduler.runNext()
        let result = try pipeline.step(100.64)
        expect(result.usedTracking && pipeline.synchronousDetections == 2 && !result.resetsTarget,
               "a matching old-image detection validates its old reference, even after the target moves")
        expect(result.faces.count == 1 && result.faces[0].overlap(with: pipeline.current) >= 0.80
               && abs(result.faces[0].centerX - pipeline.current.centerX) < 0.015,
               "completed validation returns the current tracked image position")
        expect((result.faces.first?.centerX ?? 0) - queuedFace.centerX > 0.06,
               "old detector coordinates can never replace the current moving target")

        _ = try pipeline.step(100.90)
        expect(pipeline.scheduler.count == 0, "accepted validation does not immediately queue another check")
        let nextPending = try pipeline.step(101.02)
        expect(nextPending.usedTracking && pipeline.scheduler.count == 1,
               "next validation is due from the original 100.56 capture, not its 100.64 completion")
        _ = try pipeline.step(101.20)
        let expired = try pipeline.step(101.32)
        expect(!expired.usedTracking && pipeline.synchronousDetections == 3,
               "a pending job cannot extend identity beyond 750 ms from the accepted source capture")
    }

    static func pendingValidationCannotBypassTheDeadline() throws {
        let pipeline = Pipeline()
        defer { pipeline.analyzer.reset() }
        try pipeline.establishAndQueue()
        for time in [100.62, 100.70, 100.80] {
            let result = try pipeline.step(time)
            expect(result.usedTracking && pipeline.synchronousDetections == 2 && pipeline.scheduler.count == 1,
                   "pending validation keeps current tracking responsive without scheduling duplicate jobs")
        }
        let expired = try pipeline.step(100.86)
        expect(!expired.usedTracking && pipeline.synchronousDetections == 3,
               "750 ms identity deadline forces fresh detection even when the worker has not finished")
        expect(pipeline.scheduler.count == 1, "deadline cancellation leaves only the original physical job to drain")
        pipeline.asyncFaces = []
        pipeline.scheduler.runNext()
        let fresh = try pipeline.step(100.94)
        expect(fresh.usedTracking && !fresh.resetsTarget && pipeline.synchronousDetections == 3,
               "late canceled no-face result cannot invalidate the newly detected current face")
    }

    static func uncertainOldResultsRequireCurrentDetection() throws {
        for kind in ["correction", "conflict", "scale_conflict", "missing", "multiple", "invalid", "error"] {
            let pipeline = Pipeline()
            defer { pipeline.analyzer.reset() }
            try pipeline.establishAndQueue()
            let original = pipeline.current
            switch kind {
            case "correction":
                var corrected = original; corrected.x += 0.06
                pipeline.asyncFaces = [corrected]
            case "conflict":
                pipeline.asyncFaces = [ScreenFollowRect(x: 0.72, y: original.y, width: 0.25, height: 0.25)]
            case "scale_conflict":
                pipeline.asyncFaces = [ScreenFollowRect(x: 0.16, y: 0.35, width: 0.50, height: 0.40)]
            case "missing": pipeline.asyncFaces = []
            case "multiple": pipeline.asyncFaces = [original, original]
            case "invalid": pipeline.asyncFaces = [ScreenFollowRect(x: 0.95, y: original.y, width: 0.25, height: 0.25)]
            default: pipeline.asyncThrows = true
            }
            pipeline.current.x += 0.025
            pipeline.scheduler.runNext()
            let result = try pipeline.step(100.64)
            expect(!result.usedTracking && pipeline.synchronousDetections == 3,
                   "old-image \(kind) must trigger detection on the current image")
            expect(result.faces.count == 1 && result.faces[0].overlap(with: pipeline.current) >= 0.80,
                   "old-image \(kind) cannot substitute its stale box or emptiness for a current face")
            if ["conflict", "scale_conflict", "multiple", "invalid"].contains(kind) {
                expect(result.resetsTarget && !pipeline.controller.hasConfirmedTarget
                       && pipeline.controller.trackingReference == nil && pipeline.lastCommand == .hold
                       && pipeline.controller.target == pipeline.current,
                       "old-image \(kind) clears the old identity and holds its current candidate at first confirmation")
                let confirmed = try pipeline.step(100.72)
                expect(!confirmed.usedTracking && pipeline.synchronousDetections == 4
                       && pipeline.controller.hasConfirmedTarget && pipeline.lastCommand != .hold,
                       "old-image \(kind) needs another consistent current detector frame before moving again")
            } else {
                expect(!result.resetsTarget && pipeline.controller.hasConfirmedTarget,
                       "old-image \(kind) can preserve identity only after its current image freshly validates that face")
            }
        }
    }

    static func unresolvedValidationCannotReceiveAnotherMissGrace() throws {
        for kind in ["missing", "error", "geometry"] {
            let pipeline = Pipeline()
            defer { pipeline.analyzer.reset() }
            try pipeline.establishAndQueue()
            switch kind {
            case "missing": pipeline.asyncFaces = []
            case "error": pipeline.asyncThrows = true
            default:
                var corrected = pipeline.current; corrected.x += 0.06
                pipeline.asyncFaces = [corrected]
            }
            // Texture remains trackable, but two attempts cannot validate it as
            // a face. It must not earn another grace from high tracker confidence.
            pipeline.syncFaces = []
            pipeline.scheduler.runNext()
            let stopped = try pipeline.step(100.64)
            expect(!stopped.usedTracking && pipeline.synchronousDetections == 3 && stopped.faces.isEmpty,
                   "async \(kind) followed by current-image no-face cannot receive a second miss grace")
            expect(pipeline.lastCommand == .hold && !pipeline.controller.hasConfirmedTarget,
                   "unresolved \(kind) stops the motor despite still-trackable texture")
            let absent = try pipeline.step(100.72)
            expect(absent.faces.isEmpty && pipeline.lastCommand == .hold && pipeline.synchronousDetections == 4,
                   "continuing no-face after \(kind) cannot revive the old tracker")
        }
    }

    static func lateResultsCannotCrossTrackerLifetimes() throws {
        for kind in ["reset", "context", "reseed"] {
            let pipeline = Pipeline()
            defer { pipeline.analyzer.reset() }
            try pipeline.establishAndQueue()
            pipeline.controller.reset()
            if kind == "reset" { pipeline.analyzer.reset() }
            if kind == "context" { pipeline.context = "new-session" }
            pipeline.current.x = 0.60
            _ = try pipeline.step(100.64)
            _ = try pipeline.step(100.75)
            expect(pipeline.controller.hasConfirmedTarget && pipeline.synchronousDetections == 4,
                   "\(kind) establishes a different target with fresh detections")
            pipeline.asyncFaces = []
            pipeline.scheduler.runNext()
            let fresh = try pipeline.step(100.83)
            expect(fresh.usedTracking && !fresh.resetsTarget && pipeline.synchronousDetections == 4
                   && pipeline.controller.hasConfirmedTarget,
                   "late old \(kind) completion cannot clear or revalidate the new identity")
            expect(fresh.faces.count == 1 && fresh.faces[0].overlap(with: pipeline.current) >= 0.80,
                   "\(kind) keeps the newly seeded image position")
        }
    }

    static func clippedTrackerRequiresCurrentDetection() throws {
        let pipeline = Pipeline()
        pipeline.current = ScreenFollowRect(x: 0.64, y: 0.43, width: 0.31, height: 0.14)
        defer { pipeline.analyzer.reset() }
        try pipeline.establishAndQueue()
        pipeline.current.x = 0.76
        let clipped = try pipeline.step(100.64)
        expect(!clipped.usedTracking && pipeline.synchronousDetections == 3,
               "a clipped edge tracker must synchronously detect its current image even with validation pending")
        expect(clipped.faces.count == 1 && clipped.faces[0].validFace
               && clipped.faces[0].overlap(with: pipeline.current.visibleFace!) >= 0.80,
               "edge detection returns the currently visible face, not an old validation position")
        expect(pipeline.scheduler.count == 1, "edge fallback never adds a second physical validation job")
    }

    static func main() throws {
        cancellationKeepsOnePhysicalJobUntilDrained()
        defaultQueueCancellationDiscardsRunningDetection()
        try oldImageValidationCannotMoveTheCurrentBox()
        try pendingValidationCannotBypassTheDeadline()
        try uncertainOldResultsRequireCurrentDetection()
        try unresolvedValidationCannotReceiveAnotherMissGrace()
        try lateResultsCannotCrossTrackerLifetimes()
        try clippedTrackerRequiresCurrentDetection()
        print("screen_follow_async_vision=passed assertions=\(assertions) input=synthetic detector=fixture tracker=realCPU scheduler=manualAndDefault")
    }
}
