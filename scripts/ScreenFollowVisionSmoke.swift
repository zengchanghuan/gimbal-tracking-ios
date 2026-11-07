import Foundation
import CoreGraphics

@main
enum ScreenFollowVisionSmoke {
    static var assertions = 0
    static func expect(_ value: @autoclosure () -> Bool, _ label: String) {
        assertions += 1
        precondition(value(), label)
    }

    // Synthetic textured object; detector is a fixture, sequence tracking is real CPU Vision.
    static func image(centerX: Double?, centerY: Double = 0.55,
                      width: Double = 0.25, height: Double = 0.25) -> CGImage {
        let context = CGContext(data: nil, width: 320, height: 480, bitsPerComponent: 8,
                                bytesPerRow: 1280, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 480))
        if let centerX {
            let cellWidth = width * 320 / 10
            let cellHeight = height * 480 / 12
            for y in 0..<12 {
                for x in 0..<10 {
                    let shade = CGFloat((x * 7 + y * 11 + x * y) % 17) / 16
                    context.setFillColor(CGColor(gray: shade, alpha: 1))
                    context.fill(CGRect(x: centerX * 320 - width * 160 + Double(x) * cellWidth,
                                        y: centerY * 480 - height * 240 + Double(y) * cellHeight,
                                        width: cellWidth, height: cellHeight))
                }
            }
        }
        return context.makeImage()!
    }

    struct Step {
        let capturedAt: TimeInterval
        let completedAt: TimeInterval
        let analysis: ScreenFollowFaceAnalyzer.Result
        let command: ScreenFollowCommand?
        let ranDetection: Bool
    }

    /// Use the production controller's reference exactly as the main App does.
    /// The virtual clock includes 10 ms transport, 120 ms full detection or 9 ms
    /// tracking, then ACK/admission time before the next frame can be captured.
    /// No sleeping is needed, and the Vision tracker still processes real images.
    final class Pipeline {
        enum Detection { case face, missing, differentFace }
        var detection = Detection.face
        var objectVisible = true
        var current = ScreenFollowRect(x: 0.12, y: 0.425, width: 0.25, height: 0.25)
        var reportedFace: ScreenFollowRect?
        var reportedFaces: [ScreenFollowRect]?
        var controller = ScreenFollowController()
        var nextCapture: TimeInterval = 100
        var session = "session-1"
        var detectionCalls = 0
        var missingDetectionCalls = 0
        var lastFaceDetectionAt: TimeInterval?
        private var frameID: UInt64 = 0
        private var detectorCapture: TimeInterval = 0
        lazy var analyzer = ScreenFollowFaceAnalyzer(detectionOverride: { [unowned self] _ in
            detectionCalls += 1
            switch detection {
            case .face:
                lastFaceDetectionAt = detectorCapture
                return reportedFaces ?? [reportedFace ?? current]
            case .missing:
                missingDetectionCalls += 1
                return []
            case .differentFace:
                // A fresh detector reports a disjoint target even though the old
                // textured object is still trackable. It must not be accepted as
                // validation of the old identity or silently inherit its motion.
                return [ScreenFollowRect(x: 0.72, y: 0.425, width: 0.25, height: 0.25)]
            }
        })

        func step() throws -> Step {
            frameID += 1
            let capturedAt = nextCapture
            detectorCapture = capturedAt
            let callsBefore = detectionCalls
            let result = try analyzer.analyze(ScreenFollowVisionSmoke.image(centerX: objectVisible ? current.centerX : nil,
                                                                            centerY: current.centerY,
                                                                            width: current.width, height: current.height),
                                              capturedAt: capturedAt, now: capturedAt + 0.010,
                                              context: session, confirmedTarget: controller.trackingReference)
            let ranDetection = detectionCalls > callsBefore
            let completedAt = capturedAt + 0.010 + (ranDetection ? 0.120 : 0.009)
            if result.resetsTarget { controller.reset() }
            let command = controller.observe(faces: result.faces, frameID: frameID,
                                             capturedAt: capturedAt, now: completedAt,
                                             yawSign: 1, pitchSign: 1)
            nextCapture = max(capturedAt + 1.0 / 15.0, completedAt + 0.006)
            return Step(capturedAt: capturedAt, completedAt: completedAt,
                        analysis: result, command: command, ranDetection: ranDetection)
        }

        func beginSession(_ name: String) {
            session = name
            controller = ScreenFollowController()
            frameID = 0
        }
    }

    static func sameImageValidationRequiresOverlap() throws {
        let small = ScreenFollowRect(x: 0.32, y: 0.425, width: 0.04, height: 0.04)
        let neighbor = ScreenFollowRect(x: 0.37, y: 0.425, width: 0.04, height: 0.04)
        expect(neighbor.isContinuous(with: small) && neighbor.overlap(with: small) == 0,
               "small disjoint boxes fit cross-frame displacement tolerance")
        let frame = image(centerX: small.centerX, centerY: small.centerY,
                          width: small.width, height: small.height)
        var detected = small
        let analyzer = ScreenFollowFaceAnalyzer(timeSource: { 1000 }) { _ in [detected] }
        defer { analyzer.reset() }
        let seed = try analyzer.analyze(frame, capturedAt: 300, now: 300.01,
                                        context: "same-image", confirmedTarget: nil)
        expect(seed.decision == "detected", "small texture seeds a real CPU tracker: \(seed.decision)")
        let tracked = try analyzer.analyze(frame, capturedAt: 300.1, now: 300.11,
                                           context: "same-image", confirmedTarget: small)
        expect(tracked.usedTracking && tracked.faces.count == 1,
               "small texture has a healthy fast tracker before validation")
        let reference = tracked.faces[0]
        expect(neighbor.isContinuous(with: reference) && neighbor.overlap(with: reference) < 0.08,
               "neighbor fits movement tolerance but cannot overlap the current tracker box")
        detected = neighbor
        let rejected = try analyzer.analyze(frame, capturedAt: 300.47, now: 300.48,
                                            context: "same-image", confirmedTarget: reference)
        expect(rejected.decision == "identity_conflict" && rejected.resetsTarget && !rejected.usedTracking,
               "same-image neighbor cannot validate non-face texture: \(rejected.decision) \(rejected.details)")
        expect(rejected.faces == [neighbor],
               "one fresh disjoint face is retained only for acquisition after clearing the old identity")
    }

    static func trackingCompletionRechecksIdentityDeadline() throws {
        let target = ScreenFollowRect(x: 0.12, y: 0.425, width: 0.25, height: 0.25)
        let frame = image(centerX: target.centerX)
        var present = true
        var detectionCalls = 0
        var clockReads = 0
        var crossesDeadline = false
        let analyzer = ScreenFollowFaceAnalyzer(timeSource: {
            clockReads += 1
            // Read 1 starts this analysis; read 2 admits the still-fresh tracker.
            // Subsequent reads represent 40 ms spent inside the real Vision call.
            return crossesDeadline && clockReads >= 3 ? 1000.04 : 1000
        }) { _ in
            detectionCalls += 1
            return present ? [target] : []
        }
        defer { analyzer.reset() }
        _ = try analyzer.analyze(frame, capturedAt: 400, now: 400.01,
                                 context: "completion-deadline", confirmedTarget: nil)
        let tracked = try analyzer.analyze(frame, capturedAt: 400.3, now: 400.31,
                                           context: "completion-deadline", confirmedTarget: target)
        expect(tracked.usedTracking, "deadline fixture starts with a real healthy tracker")
        present = false
        let grace = try analyzer.analyze(frame, capturedAt: 400.65, now: 400.66,
                                         context: "completion-deadline", confirmedTarget: target)
        expect(grace.decision == "detector_miss_grace" && !grace.faces.isEmpty,
               "one missed validation leaves a bounded retry window")
        clockReads = 0
        crossesDeadline = true
        let callsBefore = detectionCalls
        // Latest validation is 730 ms old on admission. The last attempt was only
        // 70 ms ago, so the normal 120 ms retry gate would permit a fast return.
        // The injected tracker completion takes its validation age to 770 ms.
        let expired = try analyzer.analyze(frame, capturedAt: 400.72, now: 400.73,
                                           context: "completion-deadline", confirmedTarget: target)
        expect(clockReads >= 3, "identity age is checked after tracker processing")
        expect(detectionCalls == callsBefore + 1 && !expired.usedTracking,
               "tracking completion past 750 ms cannot use the fast return")
        expect(expired.faces.isEmpty && expired.details.contains("fallback=validation_expired"),
               "expired validation with no fresh face stops: \(expired.decision) \(expired.details)")
    }

    static func partiallyVisibleFaceSurvivesRoundTrips() throws {
        let pipeline = Pipeline()
        pipeline.current = ScreenFollowRect(x: 0.64, y: 0.43, width: 0.31, height: 0.14)
        defer { pipeline.analyzer.reset() }
        _ = try pipeline.step()
        _ = try pipeline.step()
        expect(pipeline.controller.hasConfirmedTarget, "edge fixture confirms the fully visible face first")

        var partiallyVisibleFrames = 0
        // Repeat turns across the right boundary. At x=.72, .75 and .78 the
        // original face has approximately 90%, 81% and 71% of its area visible.
        // The texture itself is clipped by the image boundary, not merely by a
        // detector fixture, so the real tracker must handle these partial views.
        for _ in 0..<6 {
            var returnedToFastTracking = false
            for (position, x) in [0.66, 0.69, 0.72, 0.75, 0.78, 0.75, 0.72, 0.69, 0.66, 0.64].enumerated() {
                pipeline.current.x = x
                let step = try pipeline.step()
                let expected = pipeline.current.visibleFace!
                expect(step.analysis.faces.count == 1 && step.analysis.faces[0].validFace,
                       "partial face produces an in-bounds observation: \(step.analysis.decision) \(step.analysis.details)")
                expect(step.analysis.faces[0].overlap(with: expected) >= 0.50,
                       "real tracker follows the currently visible portion through repeated turns")
                expect(pipeline.controller.hasConfirmedTarget && step.command != nil && step.command != .hold,
                       "partial face remains confirmed and moving: \(step.analysis.decision) \(step.analysis.details)")
                if !pipeline.current.validFace { partiallyVisibleFrames += 1 }
                if position >= 7 && step.analysis.usedTracking { returnedToFastTracking = true }
            }
            expect(returnedToFastTracking, "returning fully inside the image restores fast tracking on every round trip")
        }
        expect(partiallyVisibleFrames == 30, "round trips exercised 30 genuinely clipped face observations")

        // Only 55% of this face remains visible. Keep that partial texture in the
        // image so rejection must come from the visibility bound or tracker loss.
        pipeline.current.x = 0.83
        expect(pipeline.current.visibleFace == nil, "less than 65 percent visibility is not a valid face")
        let lastValidAt = pipeline.lastFaceDetectionAt!
        var stopped: Step?
        for _ in 0..<16 {
            let step = try pipeline.step()
            if !pipeline.controller.hasConfirmedTarget && step.command == .hold { stopped = step; break }
        }
        expect(stopped != nil, "mostly off-screen face cannot remain an active target")
        if let stopped {
            expect(stopped.capturedAt - lastValidAt <= 0.90,
                   "mostly off-screen texture stops within bounded validation time")
        }
        for _ in 0..<5 {
            let step = try pipeline.step()
            expect(step.analysis.faces.isEmpty && step.command == .hold && !pipeline.controller.hasConfirmedTarget,
                   "mostly hidden face cannot reacquire control through unconditional clipping")
        }

        pipeline.current.x = 0.64
        pipeline.beginSession("edge-no-face")
        _ = try pipeline.step()
        _ = try pipeline.step()
        expect(pipeline.controller.hasConfirmedTarget, "face is freshly acquired before disappearance")
        pipeline.objectVisible = false
        pipeline.detection = .missing
        let disappearedAt = pipeline.nextCapture
        var disappearanceStop: Step?
        for _ in 0..<16 {
            let step = try pipeline.step()
            if step.analysis.faces.isEmpty && step.command == .hold { disappearanceStop = step; break }
        }
        expect(disappearanceStop != nil && !pipeline.controller.hasConfirmedTarget,
               "empty current image stops a previously confirmed edge target")
        if let disappearanceStop {
            expect(disappearanceStop.capturedAt - disappearedAt <= 0.90,
                   "no-face image cannot use edge clipping to extend stale identity")
        }
    }

    static func validatedFaceCorrectsTrackerCenter() throws {
        let pipeline = Pipeline()
        // Device log frame 184: a tracker center of .509,.516 kept the motor
        // center-locked although the same-image face center was .5915,.5335.
        pipeline.current = ScreenFollowRect(x: 0.308, y: 0.423, width: 0.402, height: 0.186)
        let face = ScreenFollowRect(x: 0.420, y: 0.454, width: 0.343, height: 0.159)
        defer { pipeline.analyzer.reset() }
        _ = try pipeline.step()
        _ = try pipeline.step()
        let centered = try pipeline.step()
        expect(centered.analysis.usedTracking && centered.command == .hold
               && pipeline.controller.hasConfirmedTarget && pipeline.controller.decision == "center_locked",
               "real tracker reproduces the incorrectly centered geometry before face validation")

        pipeline.reportedFace = face
        var corrected: Step?
        for _ in 0..<12 {
            let step = try pipeline.step()
            if step.ranDetection { corrected = step; break }
        }
        expect(corrected != nil, "correction fixture reaches same-image face validation")
        if let corrected {
            expect(corrected.analysis.decision == "corrected" && !corrected.analysis.usedTracking,
                   "significant face displacement corrects the tracker: \(corrected.analysis.decision) \(corrected.analysis.details)")
            expect(corrected.analysis.faces.first == face,
                   "correction reports the current detected face instead of the biased tracker box")
            expect(pipeline.controller.hasConfirmedTarget && pipeline.controller.decision != "center_locked"
                   && pipeline.controller.target == face,
                   "correction releases center lock on this frame without losing the target")
        }
        let followup = try pipeline.step()
        expect(followup.analysis.usedTracking && followup.analysis.faces.count == 1,
               "correction seeds a usable real tracker without another full detection")
        expect(abs(followup.analysis.faces[0].centerX - face.centerX) < 0.025
               && abs(followup.analysis.faces[0].centerY - face.centerY) < 0.025,
               "next fast frame keeps the corrected reference instead of snapping back")
        expect(pipeline.controller.hasConfirmedTarget && (followup.command?.yaw ?? 0) > 0,
               "corrected target continues moving without repeated confirmation")
    }

    static func seededTrackerFollowsImmediateTranslation() throws {
        for direction in [-1.0, 1.0] {
            let pipeline = Pipeline()
            pipeline.current = ScreenFollowRect(x: 0.375, y: 0.425, width: 0.25, height: 0.25)
            defer { pipeline.analyzer.reset() }
            _ = try pipeline.step()
            let confirmed = try pipeline.step()
            expect(confirmed.ranDetection && pipeline.controller.hasConfirmedTarget,
                   "rapid-translation fixture confirms its initial target in two detector frames")

            let original = pipeline.current
            pipeline.current.x += direction * 0.08
            // No detector may supply the displaced answer. Replacing the seed's
            // returned observation with a new observation used to initialize a
            // new tracker here, at the old coordinates, with confidence 1.0.
            pipeline.detection = .missing
            let callsBeforeMove = pipeline.detectionCalls
            for index in 0..<3 {
                let moved = try pipeline.step()
                expect(moved.analysis.usedTracking && !moved.ranDetection
                       && pipeline.detectionCalls == callsBeforeMove,
                       "initial seed follows translation with CPU tracking alone: \(moved.analysis.decision)")
                expect(moved.analysis.faces.count == 1 && pipeline.controller.hasConfirmedTarget,
                       "initial seed preserves confirmation after immediate translation")
                if let face = moved.analysis.faces.first {
                    expect(face.overlap(with: pipeline.current) >= 0.80
                           && abs(face.centerX - pipeline.current.centerX) < 0.015,
                           "seed frame \(index) direction \(direction) follows current texture, even when confidence is high: \(moved.analysis.details)")
                    expect((face.centerX - original.centerX) * direction >= 0.06,
                           "initial seed cannot remain at its old position after translation")
                }
            }
        }
    }

    static func correctedTrackerFollowsImmediateTranslation() throws {
        for direction in [-1.0, 1.0] {
            let pipeline = Pipeline()
            pipeline.current = ScreenFollowRect(x: 0.308, y: 0.423, width: 0.402, height: 0.186)
            let correctedFace = ScreenFollowRect(x: 0.420, y: 0.454, width: 0.343, height: 0.159)
            defer { pipeline.analyzer.reset() }
            _ = try pipeline.step()
            _ = try pipeline.step()
            _ = try pipeline.step()
            pipeline.reportedFace = correctedFace
            var correction: Step?
            for _ in 0..<12 {
                let step = try pipeline.step()
                if step.ranDetection { correction = step; break }
            }
            expect(correction?.analysis.decision == "corrected"
                   && correction?.analysis.faces.first == correctedFace
                   && pipeline.controller.hasConfirmedTarget,
                   "rapid-translation fixture performs a genuine same-image tracker correction")

            pipeline.current.x += direction * 0.08
            var movedFace = correctedFace
            movedFace.x += direction * 0.08
            pipeline.detection = .missing
            let callsBeforeMove = pipeline.detectionCalls
            for index in 0..<3 {
                let moved = try pipeline.step()
                expect(moved.analysis.usedTracking && !moved.ranDetection
                       && pipeline.detectionCalls == callsBeforeMove,
                       "corrected seed follows translation without a detector answer: \(moved.analysis.decision)")
                expect(moved.analysis.faces.count == 1 && pipeline.controller.hasConfirmedTarget,
                       "corrected seed preserves the confirmed identity during immediate translation")
                if let face = moved.analysis.faces.first {
                    expect(face.overlap(with: movedFace) >= 0.80
                           && abs(face.centerX - movedFace.centerX) < 0.015,
                           "corrected seed frame \(index) direction \(direction) follows current texture: \(moved.analysis.details)")
                    expect((face.centerX - correctedFace.centerX) * direction >= 0.06,
                           "corrected seed cannot reinitialize at the previous image's coordinates")
                }
            }
        }
    }

    static func weaklyOverlappingNeighborRequiresFreshConfirmation() throws {
        let pipeline = Pipeline()
        let original = ScreenFollowRect(x: 0.15, y: 0.40, width: 0.10, height: 0.15)
        let neighbor = ScreenFollowRect(x: 0.20, y: 0.40, width: 0.10, height: 0.15)
        pipeline.current = original
        defer { pipeline.analyzer.reset() }
        expect(abs(original.overlap(with: neighbor) - 1.0 / 3.0) < 0.000001,
               "neighbor has meaningful but insufficient same-image overlap for identity correction")
        _ = try pipeline.step()
        _ = try pipeline.step()
        let established = try pipeline.step()
        expect(established.analysis.usedTracking && pipeline.controller.hasConfirmedTarget,
               "neighbor conflict starts with a real confirmed CPU tracker")

        pipeline.reportedFace = neighbor
        var conflict: Step?
        for _ in 0..<12 {
            let step = try pipeline.step()
            if step.ranDetection { conflict = step; break }
        }
        expect(conflict?.analysis.decision == "identity_conflict" && conflict?.analysis.resetsTarget == true,
               "weak same-image overlap cannot inherit identity via tracker correction")
        expect(conflict?.analysis.faces == [neighbor] && conflict?.command == .hold
               && pipeline.controller.trackingReference == nil && !pipeline.controller.hasConfirmedTarget,
               "identity conflict explicitly clears confirmation before producing a hold")
        expect(pipeline.controller.target == neighbor && pipeline.controller.decision == "confirming",
               "the current detector result starts the neighbor's first confirmation without inheriting identity")

        // A different face on the next detector frame cannot complete the first
        // candidate's confirmation, even though acquisition has already started.
        let unrelated = ScreenFollowRect(x: 0.72, y: 0.40, width: 0.10, height: 0.15)
        expect(!unrelated.isContinuous(with: neighbor), "the next fixture face is genuinely inconsistent")
        pipeline.current = unrelated
        pipeline.reportedFace = nil
        let mismatch = try pipeline.step()
        expect(mismatch.ranDetection && mismatch.command == .hold
               && !pipeline.controller.hasConfirmedTarget && pipeline.controller.target == nil
               && pipeline.controller.decision == "target_mismatch",
               "an inconsistent next detection clears pending confirmation and keeps the motor stopped")
        let first = try pipeline.step()
        expect(first.ranDetection && first.command == .hold && !pipeline.controller.hasConfirmedTarget
               && pipeline.controller.trackingReference == nil && pipeline.controller.target == unrelated,
               "the inconsistent replacement still needs its own first fresh confirmation")
        let second = try pipeline.step()
        expect(second.ranDetection && pipeline.controller.hasConfirmedTarget
               && second.analysis.faces.first == unrelated && (second.command?.yaw ?? 0) > 0,
               "only two fresh consistent observations of the replacement can restart horizontal motion")
    }

    static func loggedScaleConflictsReuseFreshDetectionForAcquisition() throws {
        // Geometry is from v8 device-log frames 122/123 and 185/186. The image
        // remains synthetic texture and timing is Pipeline's controlled clock;
        // this checks the observed scale-conflict transition, not camera replay.
        let fixtures: [(name: String, tracked: ScreenFollowRect, candidate: ScreenFollowRect,
                        next: ScreenFollowRect, yawSign: Int)] = [
            ("122/123",
             ScreenFollowRect(x: 0.211, y: 0.424, width: 0.275, height: 0.163),
             ScreenFollowRect(x: 0.021, y: 0.364, width: 0.502, height: 0.232),
             ScreenFollowRect(x: 0.116, y: 0.380, width: 0.451, height: 0.209), -1),
            ("185/186",
             ScreenFollowRect(x: 0.511, y: 0.477, width: 0.241, height: 0.133),
             ScreenFollowRect(x: 0.500, y: 0.409, width: 0.462, height: 0.214),
             ScreenFollowRect(x: 0.406, y: 0.414, width: 0.440, height: 0.204), 1)
        ]
        for fixture in fixtures {
            let pipeline = Pipeline()
            pipeline.current = fixture.tracked
            defer { pipeline.analyzer.reset() }
            expect(fixture.candidate.needsTrackingCorrection(from: fixture.tracked)
                   && !fixture.candidate.canCorrectTracking(fixture.tracked)
                   && fixture.next.isContinuous(with: fixture.candidate),
                   "logged \(fixture.name) geometry needs fresh acquisition but preserves next-frame continuity")
            _ = try pipeline.step()
            _ = try pipeline.step()
            let established = try pipeline.step()
            expect(established.analysis.usedTracking && pipeline.controller.hasConfirmedTarget,
                   "logged \(fixture.name) fixture begins with a confirmed real CPU tracker")

            pipeline.reportedFace = fixture.candidate
            var conflict: Step?
            for _ in 0..<12 {
                let step = try pipeline.step()
                if step.ranDetection { conflict = step; break }
            }
            expect(conflict?.analysis.decision == "identity_conflict"
                   && conflict?.analysis.details.contains("fallback=correction_identity_uncertain") == true
                   && conflict?.analysis.resetsTarget == true,
                   "logged \(fixture.name) scale jump clears the old tracked identity")
            expect(conflict?.analysis.faces == [fixture.candidate] && conflict?.command == .hold
                   && pipeline.controller.target == fixture.candidate
                   && pipeline.controller.trackingReference == nil && !pipeline.controller.hasConfirmedTarget
                   && pipeline.controller.decision == "confirming",
                   "logged \(fixture.name) conflict retains one current face as an unconfirmed candidate and stops")

            pipeline.current = fixture.next
            pipeline.reportedFace = nil
            let callsBefore = pipeline.detectionCalls
            let confirmed = try pipeline.step()
            expect(confirmed.ranDetection && pipeline.detectionCalls == callsBefore + 1
                   && !confirmed.analysis.usedTracking && !confirmed.analysis.resetsTarget,
                   "logged \(fixture.name) second confirmation must come from one more fresh full detection")
            expect(confirmed.analysis.faces == [fixture.next]
                   && pipeline.controller.hasConfirmedTarget && pipeline.controller.trackingReference == fixture.next
                   && (confirmed.command?.yaw ?? 0) * fixture.yawSign > 0,
                   "logged \(fixture.name) resumes horizontal motion on the second consistent face without discarding the first")
        }
    }

    static func competingFacesClearConfirmedIdentity() throws {
        let pipeline = Pipeline()
        pipeline.current = ScreenFollowRect(x: 0.35, y: 0.40, width: 0.10, height: 0.15)
        defer { pipeline.analyzer.reset() }
        _ = try pipeline.step()
        _ = try pipeline.step()
        let established = try pipeline.step()
        expect(established.analysis.usedTracking && pipeline.controller.hasConfirmedTarget,
               "multi-face conflict starts from a confirmed real CPU tracker")
        pipeline.reportedFaces = [pipeline.current,
                                  ScreenFollowRect(x: 0.37, y: 0.40, width: 0.10, height: 0.15)]
        var conflict: Step?
        for _ in 0..<12 {
            let step = try pipeline.step()
            if step.ranDetection { conflict = step; break }
        }
        expect(conflict?.analysis.detectedFaceCount == 2
               && conflict?.analysis.decision == "identity_conflict" && conflict?.analysis.resetsTarget == true,
               "two same-image candidate faces cannot silently validate one identity")
        expect(conflict?.analysis.faces.isEmpty == true && conflict?.command == .hold && pipeline.controller.trackingReference == nil
               && !pipeline.controller.hasConfirmedTarget,
               "multiple matching candidates stop motion and clear identity")
    }

    static func centerDepartureStartsAfterSlowValidation() {
        var controller = ScreenFollowController()
        // Geometry comes from live-follow-yaw-stop-device.log frames 125, 129
        // and 130. Times are a controlled fixture for the observed 150 ms capture
        // interval and 29 ms completion interval, not a replay of camera images.
        // Repeat frame 125's centered geometry only to establish confirmation.
        let centered = ScreenFollowRect(x: 0.373, y: 0.424, width: 0.359, height: 0.194)
        let validated = ScreenFollowRect(x: 0.249, y: 0.418, width: 0.380, height: 0.205)
        let departing = ScreenFollowRect(x: 0.176, y: 0.406, width: 0.392, height: 0.212)
        expect(validated.isContinuous(with: centered) && departing.isContinuous(with: validated),
               "logged boxes preserve one target through center lock and departure")
        _ = controller.observe(faces: [centered], frameID: 124, capturedAt: 600,
                               now: 600.010, yawSign: 1, pitchSign: 1)
        let locked = controller.observe(faces: [centered], frameID: 125, capturedAt: 600.100,
                                         now: 600.110, yawSign: 1, pitchSign: 1)
        expect(locked == .hold && controller.hasConfirmedTarget && controller.decision == "center_locked",
               "departure fixture begins with a confirmed center-locked target")

        let validationCapture = 600.250
        let validationCompletion = 600.380
        let beforeDeparture = controller.observe(faces: [validated], frameID: 129,
                                                  capturedAt: validationCapture, now: validationCompletion,
                                                  yawSign: 1, pitchSign: 1)
        expect(beforeDeparture == .hold && controller.hasConfirmedTarget
               && controller.decision == "center_locked" && controller.target == validated,
               "logged frame 129 stays locked inside the center-release threshold")

        let departureCapture = validationCapture + 0.150
        let departureCompletion = validationCompletion + 0.029
        let command = controller.observe(faces: [departing], frameID: 130,
                                         capturedAt: departureCapture, now: departureCompletion,
                                         yawSign: 1, pitchSign: 1)
        expect(controller.hasConfirmedTarget && controller.target == departing,
               "first fresh departure frame retains the established target")
        let report = "screen_follow_center_departure captureMS=150 completedMS=29 rawX=\(Int(((departing.centerX - 0.5) * 2000).rounded())) yaw=\(command?.yaw ?? 0) input=deviceLogGeometry timing=controlled images=replayUnavailable\n"
        FileHandle.standardOutput.write(Data(report.utf8))
        expect((command?.yaw ?? 0) <= -14 && command?.pitch == 0,
               "first fresh outward frame starts horizontal motion despite the short completion interval")
    }

    static func main() throws {
        let pipeline = Pipeline()
        var tracked = 0
        var detectionsWithLatency = 0
        for frame in 0..<48 {
            // Continuous displacement depends on simulated elapsed time, including
            // slow detection frames, instead of giving every request a free 15 fps.
            pipeline.current.x = 0.12 + (pipeline.nextCapture - 100) * 0.020
            let step = try pipeline.step()
            let result = step.analysis
            expect(!result.decision.isEmpty, "analysis provides a continuity decision")
            expect(result.faces.count == 1, "moving target remains observed: \(result.decision)")
            expect(result.faces[0].overlap(with: pipeline.current) >= 0.55,
                   "CPU tracker follows current translated texture: \(result.decision)")
            if frame == 0 {
                expect(!pipeline.controller.hasConfirmedTarget && step.command == .hold,
                       "new target waits for the second fresh observation")
            } else {
                expect(pipeline.controller.hasConfirmedTarget,
                       "continuous movement never restarts confirmation: frame=\(frame) \(result.decision)")
                expect(step.command != nil && step.command != .hold,
                       "off-center confirmed target receives continuous motion: \(result.decision)")
            }
            if result.usedTracking { tracked += 1 }
            if step.ranDetection {
                detectionsWithLatency += 1
                expect(abs(step.completedAt - step.capturedAt - 0.130) < 0.000001,
                       "full detection consumes 120 ms plus transport in controller and next-frame time")
            }
        }
        expect(tracked > 28, "healthy moving target predominantly uses current-image tracking")
        expect(detectionsWithLatency >= 5 && detectionsWithLatency < 18,
               "450 ms periodic validation remains active without repeated reseeding")

        // Miss a detector result while the target remains in the current image.
        // The retained tracker must bridge exactly this failure without requiring
        // the controller to acquire and confirm the same person all over again.
        pipeline.detection = .missing
        let missesBefore = pipeline.missingDetectionCalls
        var missedStep: Step?
        for _ in 0..<16 {
            pipeline.current.x += 0.001
            let step = try pipeline.step()
            expect(pipeline.controller.hasConfirmedTarget && !step.analysis.faces.isEmpty,
                   "one detector miss retains a freshly tracked target: \(step.analysis.decision)")
            if pipeline.missingDetectionCalls > missesBefore { missedStep = step; break }
        }
        expect(missedStep != nil, "fixture reached a real periodic detector miss")
        if let missedStep {
            expect(missedStep.ranDetection && missedStep.analysis.decision == "detector_miss_grace",
                   "single missed validation records a full detection with tracker grace")
            expect(!missedStep.analysis.faces.isEmpty
                   && missedStep.analysis.faces[0].overlap(with: pipeline.current) >= 0.55,
                   "single missed validation uses this image's current CPU tracker result")
        }
        pipeline.detection = .face
        for _ in 0..<14 {
            let step = try pipeline.step()
            expect(pipeline.controller.hasConfirmedTarget && !step.analysis.faces.isEmpty,
                   "successful validation after one miss keeps confirmation: \(step.analysis.decision)")
        }

        // Repeated detection failures may not keep chasing a textured non-face.
        // Keep the texture visible to prevent a tracker-confidence failure from
        // accidentally making this face-validation deadline test pass.
        pipeline.detection = .missing
        let lastValidatedAt = pipeline.lastFaceDetectionAt!
        let persistentMissesBefore = pipeline.missingDetectionCalls
        var stoppedStep: Step?
        for _ in 0..<18 {
            let step = try pipeline.step()
            if step.analysis.faces.isEmpty { stoppedStep = step; break }
        }
        expect(stoppedStep != nil, "continuous missed face validation eventually rejects trackable texture")
        expect(pipeline.missingDetectionCalls - persistentMissesBefore >= 1,
               "stop follows a missing face validation")
        if let stoppedStep {
            expect(stoppedStep.command == .hold && !pipeline.controller.hasConfirmedTarget,
                   "expired face validation stops motion: \(stoppedStep.analysis.decision)")
            // The 750 ms identity deadline is evaluated on admission. Account for
            // one admitted frame and its simulated full-detection completion.
            expect(stoppedStep.capturedAt - lastValidatedAt <= 0.90,
                   "identity grace cannot outlive 750 ms plus one admitted frame")
        }
        for _ in 0..<5 {
            let step = try pipeline.step()
            expect(step.analysis.faces.isEmpty && step.command == .hold,
                   "repeated misses cannot restart stale target motion: \(step.analysis.decision)")
        }

        pipeline.detection = .face
        pipeline.beginSession("session-2")
        let callsBeforeSession = pipeline.detectionCalls
        let fresh = try pipeline.step()
        expect(fresh.ranDetection && pipeline.detectionCalls == callsBeforeSession + 1,
               "new session performs fresh face detection")
        expect(!pipeline.controller.hasConfirmedTarget && fresh.command == .hold,
               "new session cannot inherit the old confirmation")
        _ = try pipeline.step()
        expect(pipeline.controller.hasConfirmedTarget, "new session confirms two fresh observations")

        pipeline.detection = .differentFace
        var conflict: Step?
        for _ in 0..<16 {
            let step = try pipeline.step()
            if step.ranDetection { conflict = step; break }
        }
        expect(conflict != nil, "periodic validation observes the deliberately different target")
        expect(conflict?.command == .hold && !pipeline.controller.hasConfirmedTarget,
               "a different detected target cannot inherit previous motion: \(conflict?.analysis.decision ?? "none")")

        // Repeated session reseeding must release old tracker resources.
        pipeline.detection = .face
        for index in 0..<40 {
            pipeline.beginSession("resource-session-\(index)")
            let step = try pipeline.step()
            expect(step.ranDetection && step.analysis.faces.count == 1,
                   "reseed remains usable: \(step.analysis.decision)")
        }
        pipeline.analyzer.reset()

        try sameImageValidationRequiresOverlap()
        try trackingCompletionRechecksIdentityDeadline()
        try partiallyVisibleFaceSurvivesRoundTrips()
        try validatedFaceCorrectsTrackerCenter()
        try seededTrackerFollowsImmediateTranslation()
        try correctedTrackerFollowsImmediateTranslation()
        try weaklyOverlappingNeighborRequiresFreshConfirmation()
        try loggedScaleConflictsReuseFreshDetectionForAcquisition()
        try competingFacesClearConfirmedIdentity()
        centerDepartureStartsAfterSlowValidation()

        let actualDetector = ScreenFollowFaceAnalyzer()
        let blank = try actualDetector.analyze(image(centerX: nil), capturedAt: 200, now: 200.01,
                                               context: "blank", confirmedTarget: nil)
        expect(blank.faces.isEmpty, "real face detector rejects blank image")
        actualDetector.reset()
        print("screen_follow_vision=passed assertions=\(assertions) tracked=\(tracked) input=synthetic detector=fixture tracker=realCPU controller=production simulatedDetectionMS=120")
    }
}
