import Foundation

@main
enum ScreenFollowCoreSmoke {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        assertions += 1
        precondition(condition(), name)
    }
    static func rejects(_ body: () throws -> Void, _ name: String) {
        do { try body(); preconditionFailure(name) } catch { assertions += 1 }
    }
    static func main() throws {
        let id = UUID(), peripheral = UUID()
        let config = ScreenFollowConfiguration(sessionID: id, peripheralID: peripheral, port: 8999, preparedUptime: 100)
        expect(config.canStart(now: 100), "fresh configuration")
        expect(config.canStart(now: 220), "TTL boundary")
        expect(!config.canStart(now: 220.01), "expired configuration")
        expect(!config.canStart(now: 99), "uptime reset")
        expect(!config.canStart(now: .nan), "invalid clock")
        var invalid = config; invalid.version = 2
        expect(!invalid.canStart(now: 100), "old protocol rejected")
        expect(GimbalTrackingPacket.encode() == Data([0x55,0x55,0x07,0xd1,0x01,0x27,0x10,0x27,0x10,0xdb]), "known hardware hold packet")
        expect(GimbalTrackingPacket.encode(exit: true)[4] == 4, "exit state")
        expect(GimbalTrackingPacket.encode(.init(yaw: 301, pitch: -301)) == GimbalTrackingPacket.encode(.init(yaw: 300, pitch: -300)), "wire saturation")
        let jpeg = Data((0..<8000).map { UInt8($0 % 256) })
        let message = ScreenFollowMessage(kind: .frame, sessionID: id, frameID: 42, capturedAt: 100, jpeg: jpeg)
        let packet = try ScreenFollowPacketDecoder.encode(message)
        for strideSize in [1, 3, 4, 100, 65536] {
            var decoder = ScreenFollowPacketDecoder(), bodies: [Data] = []
            for start in stride(from: 0, to: packet.count, by: strideSize) {
                bodies += try decoder.append(Data(packet[start..<min(packet.count, start + strideSize)]))
            }
            expect(bodies.count == 1, "stream reassembly \(strideSize)")
            let decoded = try JSONDecoder().decode(ScreenFollowMessage.self, from: bodies[0])
            expect(decoded.sessionID == id && decoded.frameID == 42 && decoded.jpeg == jpeg, "frame survives stream split")
        }
        var decoder = ScreenFollowPacketDecoder()
        expect(tryCount(&decoder, packet + packet) == 2, "coalesced messages")
        rejects({ var d = ScreenFollowPacketDecoder(); _ = try d.append(Data([0, 0, 0, 0])) }, "zero length")
        rejects({ var d = ScreenFollowPacketDecoder(); _ = try d.append(Data([0x7f, 0xff, 0xff, 0xff])) }, "huge length")
        rejects({ _ = try ScreenFollowPacketDecoder.encode(.init(kind: .frame, sessionID: id, jpeg: Data(count: 512 * 1024))) }, "oversized sender")
        let centered = ScreenFollowRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let right = ScreenFollowRect(x: 0.65, y: 0.4, width: 0.2, height: 0.2)
        var controller = ScreenFollowController()
        for i in 1...3 {
            let command = controller.observe(faces: [centered], frameID: UInt64(i), capturedAt: Double(i) / 10,
                                             now: Double(i) / 10, yawSign: 1, pitchSign: 1)
            expect(command == .hold, "center dead zone")
        }
        expect(controller.hasConfirmedTarget, "stable observations confirm")
        expect(controller.observe(faces: [right], frameID: 3, capturedAt: 0.3, now: 0.3, yawSign: 1, pitchSign: 1) == nil, "duplicate ignored")
        expect(controller.observe(faces: [centered], frameID: 4, capturedAt: 0.4, now: 1, yawSign: 1, pitchSign: 1) == .hold, "stale result holds")
        expect(!controller.hasConfirmedTarget, "stale clears target")
        expect(controller.observe(faces: [centered, right], frameID: 5, capturedAt: 1, now: 1, yawSign: 1, pitchSign: 1) == .hold, "multiple initial faces hold")
        for signs in [(1.0, 1.0), (-1.0, -1.0), (-1.0, 1.0), (1.0, -1.0)] {
            var tracking = ScreenFollowController()
            let offCenter = ScreenFollowRect(x: 0.7, y: 0.1, width: 0.2, height: 0.2)
            var previous = ScreenFollowCommand.hold
            for i in 1...40 {
                let now = Double(i) / 10
                let command = tracking.observe(faces: [offCenter], frameID: UInt64(i), capturedAt: now,
                                                now: now, yawSign: signs.0, pitchSign: signs.1)!
                // This fixture has rawY=600, which uses v13's 38-unit pitch
                // tier; the accepted 42-unit horizontal bound is unchanged.
                expect(abs(command.yaw - previous.yaw) <= 42 && abs(command.pitch - previous.pitch) <= 38,
                       "large-error yaw and medium/large pitch slew limits")
                expect(abs(command.yaw) <= 250 && abs(command.pitch) <= 250, "control clamp")
                previous = command
            }
            expect(Double(previous.yaw) * signs.0 > 0 && Double(previous.pitch) * signs.1 > 0, "calibrated axes")
            expect(tracking.observe(faces: [], frameID: 41, capturedAt: 4.1, now: 4.1, yawSign: signs.0, pitchSign: signs.1) == .hold, "lost target stops immediately")
            expect(!tracking.hasConfirmedTarget, "miss has no current confirmed observation")
            let recovered = tracking.observe(faces: [offCenter], frameID: 42, capturedAt: 4.2, now: 4.2,
                                             yawSign: signs.0, pitchSign: signs.1)!
            expect(recovered != .hold && tracking.hasConfirmedTarget, "brief miss resumes same target from fresh observation")
            expect(tracking.observe(faces: [], frameID: 43, capturedAt: 4.6, now: 4.6,
                                    yawSign: signs.0, pitchSign: signs.1) == .hold, "long miss holds")
            expect(tracking.target == nil, "long miss clears identity")
            expect(tracking.observe(faces: [offCenter], frameID: 44, capturedAt: 4.7, now: 4.7,
                                    yawSign: signs.0, pitchSign: signs.1) == .hold, "long loss needs confirmation again")
        }
        stabilityRegressions()
        var metrics = ScreenFollowDiagnostics()
        expect(metrics.averageLatencyMS == 0, "empty diagnostics")
        metrics.recordAnalysis(capturedAt: 10, receivedAt: 10.08, completedAt: 10.2)
        metrics.recordAnalysis(capturedAt: 11, receivedAt: 11.12, completedAt: 11.3)
        expect(metrics.analyzedFrames == 2 && abs(metrics.averageLatencyMS - 250) < 0.001, "end-to-end latency average")
        expect(abs(metrics.averageTransportMS - 100) < 0.001 && abs(metrics.averageAnalysisMS - 150) < 0.001,
               "transport and analysis costs separated")
        metrics.recordAnalysis(capturedAt: .nan, receivedAt: 10, completedAt: 11)
        metrics.recordAnalysis(capturedAt: 12, receivedAt: 11, completedAt: 13)
        expect(metrics.analyzedFrames == 2, "invalid timing does not poison metrics")
        metrics.recordAnalysis(capturedAt: 12, receivedAt: 12.01, completedAt: 12.03, usedTracking: true)
        expect(metrics.faceDetectionFrames == 2 && metrics.visualTrackingFrames == 1, "detection and tracking frame counts remain distinct")
        expect(abs(metrics.averageDetectionMS - 150) < 0.001 && abs(metrics.averageTrackingMS - 20) < 0.001,
               "detection and tracking timings remain distinct")
        edgeAndCorrectionRegressions()
        print("screen_follow_core=passed assertions=\(assertions)")
    }

    static func edgeAndCorrectionRegressions() {
        // Exact v4 detector samples: the face was still mostly visible but the
        // strict raw-box check kept the gimbal stopped at the image boundary.
        for raw in [ScreenFollowRect(x: -0.102, y: 0.416, width: 0.542, height: 0.251),
                    .init(x: 0.592, y: 0.425, width: 0.465, height: 0.215),
                    .init(x: 0.743, y: 0.476, width: 0.310, height: 0.143),
                    .init(x: 0.4, y: -0.02, width: 0.2, height: 0.2),
                    .init(x: 0.4, y: 0.85, width: 0.2, height: 0.2)] {
            expect(!raw.validFace, "raw edge sample reproduces the former rejection")
            guard let visible = raw.visibleFace else { preconditionFailure("mostly visible edge face was rejected") }
            expect(visible.validFace, "edge normalization produces a bounded control box")
            expect(visible.visibleFace == visible, "normalization is idempotent without floating-point clipping noise")
            var controller = ScreenFollowController()
            var command = ScreenFollowCommand.hold
            for i in 1...5 {
                command = controller.observe(faces: [visible], frameID: UInt64(i), capturedAt: Double(i) / 10,
                                             now: Double(i) / 10, yawSign: 1, pitchSign: 1)!
            }
            expect(controller.hasConfirmedTarget && command != .hold, "partially visible face can move back into view")
            expect(abs(command.yaw) <= 250 && abs(command.pitch) <= 250, "partial faces retain control limits")
        }
        let untouched = ScreenFollowRect(x: 0.33, y: 0.47, width: 0.39, height: 0.18)
        expect(untouched.visibleFace == untouched, "an in-bounds observation is unchanged")
        for invalid in [ScreenFollowRect(x: 0.88, y: 0.4, width: 0.4, height: 0.2),
                        .init(x: -0.3, y: 0.4, width: 0.4, height: 0.2),
                        .init(x: 1.1, y: 0.4, width: 0.2, height: 0.2),
                        .init(x: -.infinity, y: 0.4, width: 0.2, height: 0.2),
                        .init(x: .nan, y: 0.4, width: 0.2, height: 0.2),
                        .init(x: 0.2, y: 0.4, width: -0.2, height: 0.2),
                        .init(x: 0, y: 0, width: 1.2, height: 1),
                        .init(x: 0.2, y: 0.4, width: 0.02, height: 0.2)] {
            expect(invalid.visibleFace == nil, "departed, malformed or too small faces cannot become edge targets")
        }
        let tracked = ScreenFollowRect(x: 0.309, y: 0.416, width: 0.4, height: 0.2)
        let face = ScreenFollowRect(x: 0.3915, y: 0.4335, width: 0.4, height: 0.2)
        expect(face.needsTrackingCorrection(from: tracked), "frame184 center drift requires correction despite overlap")
        expect(!ScreenFollowRect(x: 0.315, y: 0.42, width: 0.405, height: 0.199).needsTrackingCorrection(from: tracked),
               "small detector jitter does not repeatedly rebuild a healthy sequence")
        expect(ScreenFollowRect(x: 0.249, y: 0.416, width: 0.52, height: 0.2).needsTrackingCorrection(from: tracked),
               "same-center size drift also corrects the visual template")
        var controller = ScreenFollowController()
        for i in 1...3 {
            _ = controller.observe(faces: [tracked], frameID: UInt64(i), capturedAt: Double(i) / 10,
                                   now: Double(i) / 10, yawSign: 1, pitchSign: 1)
        }
        expect(controller.decision == "center_locked", "drifted frame184 tracker falsely stays centered")
        let corrected = controller.observe(faces: [face], frameID: 4, capturedAt: 0.4, now: 0.4, yawSign: 1, pitchSign: 1)!
        expect(corrected.yaw > 0 && corrected.yaw <= 28 && controller.hasConfirmedTarget,
               "fresh correction unlocks center with bounded acceleration and retained identity")
    }

    static func stabilityRegressions() {
        func face(_ centerX: Double, _ centerY: Double = 0.5) -> ScreenFollowRect {
            ScreenFollowRect(x: centerX - 0.2, y: centerY - 0.15, width: 0.4, height: 0.3)
        }
        var tracking = ScreenFollowController()
        var frame: UInt64 = 0
        func observe(_ rect: ScreenFollowRect) -> ScreenFollowCommand {
            frame += 1
            let time = Double(frame) * 0.1
            return tracking.observe(faces: [rect], frameID: frame, capturedAt: time, now: time,
                                    yawSign: 1, pitchSign: 1)!
        }
        var steady = ScreenFollowCommand.hold
        for _ in 0..<10 { steady = observe(face(0.68)) }
        let approaching = observe(face(0.62))
        // Prediction is now the horizontal filter target; the fresh observed
        // error remains the hard envelope rather than the old predicted limit.
        let currentErrorLimit = Int(((0.62 - 0.5) * 2000 * 0.65 / 3).rounded())
        expect(approaching.yaw > 0 && approaching.yaw <= currentErrorLimit && approaching.yaw < steady.yaw,
               "approach brakes below steady output and obeys the current observed-error bound")
        expect(observe(face(0.55)) == .hold, "center entry brakes immediately")
        // v15 releases at 130 instead of 150; jitter within the retained center
        // region and the narrower hysteresis must still leave the motor quiet.
        for x in [0.51, 0.52, 0.49, 0.54, 0.56, 0.564, 0.44, 0.5] {
            expect(observe(face(x)) == .hold, "center hysteresis absorbs detection jitter")
        }
        expect(observe(face(0.568)).yaw > 0, "v15 starts inside the former 150-unit lock boundary")

        for sign in [1.0, -1.0] {
            var crossing = ScreenFollowController()
            for i in 1...10 {
                _ = crossing.observe(faces: [face(0.62, 0.3)], frameID: UInt64(i), capturedAt: Double(i) / 10,
                                     now: Double(i) / 10, yawSign: sign, pitchSign: sign)
            }
            let command = crossing.observe(faces: [face(0.38, 0.3)], frameID: 11, capturedAt: 1.1,
                                           now: 1.1, yawSign: sign, pitchSign: sign)!
            expect(Double(command.yaw) * sign <= 0, "crossing center never drives old yaw direction")
            expect(command.yaw == 0, "direction reversal inserts immediate yaw brake")
            let next = crossing.observe(faces: [face(0.38, 0.3)], frameID: 12, capturedAt: 1.2,
                                        now: 1.2, yawSign: sign, pitchSign: sign)!
            expect(Double(next.yaw) * sign < 0, "fresh reversed observation ramps correct direction")

            var pitchCrossing = ScreenFollowController()
            for i in 1...10 {
                _ = pitchCrossing.observe(faces: [face(0.7, 0.38)], frameID: UInt64(i), capturedAt: Double(i) / 10,
                                          now: Double(i) / 10, yawSign: sign, pitchSign: sign)
            }
            let vertical = pitchCrossing.observe(faces: [face(0.7, 0.62)], frameID: 11, capturedAt: 1.1,
                                                 now: 1.1, yawSign: sign, pitchSign: sign)!
            expect(vertical.pitch == 0, "crossing center brakes old pitch direction")
        }

        func response(interval: Double, samples: Int) -> Int {
            var controller = ScreenFollowController()
            let offset = ScreenFollowRect(x: 0.7, y: 0.4, width: 0.2, height: 0.2)
            var command = ScreenFollowCommand.hold
            for i in 1...3 {
                command = controller.observe(faces: [offset], frameID: UInt64(i), capturedAt: Double(i) / 10,
                                             now: Double(i) / 10, yawSign: 1, pitchSign: 1)!
            }
            for i in 1...samples {
                let time = 0.3 + Double(i) * interval
                command = controller.observe(faces: [offset], frameID: UInt64(i + 3), capturedAt: time,
                                             now: time, yawSign: 1, pitchSign: 1)!
            }
            return command.yaw
        }
        expect(abs(response(interval: 0.1, samples: 4) - response(interval: 0.2, samples: 2)) <= 12,
               "similar acceleration over equal elapsed time at 5 and 10 fps")

        var fast = ScreenFollowController()
        var fastCommand = ScreenFollowCommand.hold
        for i in 1...8 {
            let time = Double(i) / 15
            fastCommand = fast.observe(faces: [face(0.58)], frameID: UInt64(i), capturedAt: time, now: time,
                                       yawSign: 1, pitchSign: 1)!
        }
        expect(fastCommand.yaw > 0, "15 fps small offset does not remain stuck below motor startup threshold")

        let small = ScreenFollowRect(x: 0.2, y: 0.4, width: 0.05, height: 0.08)
        let moved = ScreenFollowRect(x: 0.252, y: 0.4, width: 0.05, height: 0.08)
        expect(small.overlap(with: moved) == 0 && moved.isContinuous(with: small),
               "native size-distance rule preserves a small moving face without overlap")
        expect(!ScreenFollowRect(x: 0.7, y: 0.4, width: 0.05, height: 0.08).isContinuous(with: small),
               "a distant similar face is not the same target")
        expect(!ScreenFollowRect(x: 0.17, y: 0.3, width: 0.35, height: 0.4).isContinuous(with: small),
               "large incompatible region cannot inherit a tiny face")
        var continuity = ScreenFollowController()
        expect(continuity.observe(faces: [small], frameID: 1, capturedAt: 0.1, now: 0.23,
                                  yawSign: 1, pitchSign: 1) == .hold, "first observation still holds")
        _ = continuity.observe(faces: [small], frameID: 2, capturedAt: 0.24, now: 0.37, yawSign: 1, pitchSign: 1)
        expect(continuity.hasConfirmedTarget, "native two-frame confirmation")
        _ = continuity.observe(faces: [moved], frameID: 3, capturedAt: 0.38, now: 0.51, yawSign: 1, pitchSign: 1)
        expect(continuity.hasConfirmedTarget, "moving small face does not restart confirmation")
        _ = continuity.observe(faces: [], frameID: 4, capturedAt: 0.52, now: 0.65, yawSign: 1, pitchSign: 1)
        expect(!continuity.hasConfirmedTarget && continuity.trackingReference != nil,
               "identity remains available while no current observation can move the motor")

        var edge = ScreenFollowController()
        let nearEdge = ScreenFollowRect(x: 0.7, y: 0.4, width: 0.2, height: 0.2)
        _ = edge.observe(faces: [nearEdge], frameID: 1, capturedAt: 0.1, now: 0.1, yawSign: 1, pitchSign: 1)
        let entry = edge.observe(faces: [nearEdge], frameID: 2, capturedAt: 0.2, now: 0.2, yawSign: 1, pitchSign: 1)!
        let outward = edge.observe(faces: [.init(x: 0.75, y: 0.4, width: 0.2, height: 0.2)], frameID: 3,
                                   capturedAt: 0.3, now: 0.3, yawSign: 1, pitchSign: 1)!
        expect(outward.yaw - entry.yaw > 28 && outward.yaw - entry.yaw <= 56,
               "edge capture uses bounded native horizontal acceleration")
        expect(outward.pitch == 0 && abs(outward.yaw) <= 250, "horizontal capture does not excite centered pitch")

        var reserved = ScreenFollowController()
        for i in 1...3 {
            _ = reserved.observe(faces: [face(0.7)], frameID: UInt64(i), capturedAt: Double(i) / 10,
                                 now: Double(i) / 10, yawSign: 1, pitchSign: 1)
        }
        expect(reserved.observe(faces: [], frameID: 4, capturedAt: 0.4, now: 0.4, yawSign: 1, pitchSign: 1) == .hold,
               "identity reservation never extrapolates motion")
        expect(reserved.observe(faces: [face(0.22)], frameID: 5, capturedAt: 0.5, now: 0.5, yawSign: 1, pitchSign: 1) == .hold,
               "different face after brief miss cannot inherit movement")
        expect(!reserved.hasConfirmedTarget, "different face requires new confirmation")
    }
    static func tryCount(_ decoder: inout ScreenFollowPacketDecoder, _ data: Data) -> Int {
        (try? decoder.append(data).count) ?? -1
    }
}
