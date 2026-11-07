import Foundation

@main
enum ScreenFollowCadenceSmoke {
    static var assertions = 0
    static var trajectories = 0
    static var sourceFrames = 0
    static var addedAdmissions = 0
    static var smallestSpacing = Double.infinity
    static let period = 1.0 / 15.0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        precondition(condition(), message)
    }

    // Frozen pre-v27 rule. Deliberately retain the strict comparison and reset
    // to the actual callback time; the expected rates are not produced by v27.
    struct PreviousAdmission {
        var lastSentAt: TimeInterval?
        mutating func sendIfDue(_ time: TimeInterval) -> Bool {
            guard lastSentAt.map({ time - $0 >= period }) ?? true else { return false }
            lastSentAt = time
            return true
        }
    }

    static func verifySpacingAndBudget(_ sends: [TimeInterval], label: String) {
        expect(sends.count > 1, "\(label) exercises multiple successful admissions")
        for (previous, next) in zip(sends, sends.dropFirst()) {
            let spacing = next - previous
            smallestSpacing = min(smallestSpacing, spacing)
            expect(spacing >= 0.06 - 0.000000002,
                   "\(label) cannot feed the controller faster than its 60-ms response scale")
        }
        let duration = sends.last! - sends.first!
        expect(Double(sends.count - 1) <= duration * 15 + 1.000001,
               "\(label) has at most one phase-boundary admission beyond its long-term 15-Hz budget")
        // Inclusive endpoints permit sixteen commands in a one-second window.
        // Check actual rolling windows rather than only the aggregate count.
        for window in [1.0, 2.0, 10.0] {
            var end = 0
            for start in sends.indices {
                end = max(end, start)
                while end < sends.count && sends[end] - sends[start] <= window + 0.000000002 { end += 1 }
                expect(end - start <= Int(window * 15) + 1,
                       "\(label) rolling \(window)-second budget has no catch-up burst")
            }
        }
    }

    static func realNumberSourceTrajectories() {
        for base in [0.0, 12_000.0] {
            for fps in [30.0, 30.1, 60.0, 60.1] {
                for jitter in [0.0, 0.001, 0.003] {
                    var cadence = ScreenFollowFrameCadence()
                    var old = PreviousAdmission()
                    var sends: [TimeInterval] = []
                    var oldSends: [TimeInterval] = []
                    for index in 0...Int(fps * 120) {
                        // Deterministic, bounded callback jitter using real
                        // timestamps, not an integer-millisecond clock.
                        let time = base + Double(index) / fps
                            + jitter * sin(Double(index) * 2.399963229728653)
                        if cadence.isDue(at: time) {
                            cadence.didSend(at: time)
                            sends.append(time)
                        }
                        if old.sendIfDue(time) { oldSends.append(time) }
                        sourceFrames += 1
                    }
                    let label = "source=\(fps)Hz jitter=\(jitter * 1000)ms base=\(base)"
                    verifySpacingAndBudget(sends, label: label)
                    let rate = Double(sends.count - 1) / (sends.last! - sends.first!)
                    expect(rate >= 14.97 && rate <= 15.02,
                           "\(label) stays close to the unchanged target rate in this synthetic source")
                    expect(sends.count >= oldSends.count,
                           "\(label) does not lose admissions relative to the strict reanchoring rule")
                    if jitter > 0 || fps == 30.1 || fps == 60.1 {
                        expect(sends.count > oldSends.count,
                               "\(label) exercises the historical quantization loss")
                    }
                    if jitter == 0 && (fps == 30.1 || fps == 60.1) {
                        let oldRate = Double(oldSends.count - 1) / (oldSends.last! - oldSends.first!)
                        let expectedOld = fps == 30.1 ? fps / 3 : fps / 5
                        expect(abs(oldRate - expectedOld) < 0.000001,
                               "slightly fast source reproduces the independently calculated old 10/12-Hz division")
                    }
                    trajectories += 1
                    addedAdmissions += sends.count - oldSends.count
                    print("cadence_trajectory \(label) new=\(sends.count) old=\(oldSends.count) effectiveHz=\(String(format: "%.3f", rate))")
                }
            }
        }
    }

    static func successfulCommitAndInvalidClock() {
        var cadence = ScreenFollowFrameCadence()
        for invalid in [-1.0, .nan, .infinity, -.infinity] {
            expect(!cadence.isDue(at: invalid), "invalid initial clock is rejected")
            cadence.didSend(at: invalid)
        }
        expect(cadence.isDue(at: 0), "a rejected timestamp cannot poison first admission")
        expect(cadence.isDue(at: 0), "read-only probes do not consume an encode candidate")
        cadence.didSend(at: 0)
        expect(!cadence.isDue(at: 0) && !cadence.isDue(at: -0.01), "duplicate and backward committed clocks are rejected")
        expect(!cadence.isDue(at: 0.05), "first phase deadline and minimum spacing both reject a short gap")
        cadence.didSend(at: 0.05) // Caller misuse must not advance a rejected slot.
        expect(cadence.isDue(at: period), "rejected didSend cannot advance phase")
        expect(cadence.isDue(at: period), "failed JPEG encoding leaves the due slot eligible")
        cadence.didSend(at: period)
        for invalid in [0.0, period, .nan, .infinity, -.infinity] {
            expect(!cadence.isDue(at: invalid), "invalid later clock is rejected")
            cadence.didSend(at: invalid)
        }
        expect(cadence.isDue(at: 2 * period), "invalid commits cannot move the next valid deadline")
        cadence.didSend(at: 2 * period)
        expect(!cadence.isDue(at: 2 * period), "successful commit consumes exactly one candidate")
        cadence.reset()
        expect(cadence.isDue(at: 0), "explicit reset permits a new earlier clock origin")
        cadence.didSend(at: 0)
        expect(!cadence.isDue(at: 0), "reset does not relax duplicate rejection after a new send")

        var boundary = ScreenFollowFrameCadence()
        boundary.didSend(at: 0)
        boundary.didSend(at: 0.13) // Late enough that the next phase is close.
        expect(!boundary.isDue(at: 0.18999), "an overdue phase never bypasses the 60-ms minimum spacing")
        expect(boundary.isDue(at: 0.19), "the exact 60-ms spacing survives floating-point cancellation")
        boundary.didSend(at: 0.19)
        expect(!boundary.isDue(at: 0.20), "a nearby phase after a late admission cannot emit a catch-up frame")
    }

    static func shortAndLongPauseDoNotAccumulateDebt() {
        for pause in [0.17, 0.19, 0.5, 3.0, 120.0] {
            var cadence = ScreenFollowFrameCadence()
            cadence.didSend(at: 0)
            expect(cadence.isDue(at: pause), "a current frame after pause is eligible")
            cadence.didSend(at: pause)
            expect(!cadence.isDue(at: pause), "resume does not admit the same frame twice")
            for offset in [0.001, 0.01, 0.033, 0.059] {
                expect(!cadence.isDue(at: pause + offset), "missed phase slots cannot cause a resume burst")
            }
            var sends = [pause]
            for index in 1...1200 {
                let time = pause + Double(index) / 60
                if cadence.isDue(at: time) {
                    cadence.didSend(at: time)
                    sends.append(time)
                }
            }
            verifySpacingAndBudget(sends, label: "pause=\(pause)s")
            expect((299...301).contains(sends.count - 1), "resume returns to the target rate without replaying missed slots")
        }
    }

    static func callerOwnsSingleFlightAndDrops() {
        var cadence = ScreenFollowFrameCadence()
        var inFlightUntil: TimeInterval?
        var sends: [TimeInterval] = []
        var inFlightDrops = 0, admissionBusyDrops = 0, encodeDrops = 0, expiredDrops = 0
        var outstanding = 0
        for index in 0...3600 {
            let time = 100 + Double(index) / 60
            if let completion = inFlightUntil, completion <= time {
                inFlightUntil = nil
                outstanding -= 1
            }
            // These gates model the caller contract, not behavior owned by
            // ScreenFollowFrameCadence. A dropped candidate never calls didSend.
            if index % 97 == 0 { admissionBusyDrops += 1; continue }
            if inFlightUntil != nil { inFlightDrops += 1; continue }
            guard cadence.isDue(at: time) else { continue }
            if index % 101 == 0 {
                encodeDrops += 1
                expect(cadence.isDue(at: time), "an encoding failure cannot consume the deadline")
                continue
            }
            if index % 103 == 0 {
                expiredDrops += 1
                expect(cadence.isDue(at: time), "an expired image cannot consume the deadline")
                continue
            }
            let ackDelay = sends.count % 31 == 0 ? 0.23 : (sends.count % 7 == 0 ? 0.09 : 0.025)
            cadence.didSend(at: time)
            sends.append(time)
            inFlightUntil = time + ackDelay
            outstanding += 1
            expect(outstanding == 1, "caller never queues a second frame before the first frame ACK")
        }
        expect(inFlightDrops > 0 && admissionBusyDrops > 0 && encodeDrops > 0 && expiredDrops > 0,
               "caller fixture exercises every bounded drop path")
        verifySpacingAndBudget(sends, label: "caller-with-ACK-stalls")
        print("cadence_caller sourceFrames=3601 sent=\(sends.count) inFlightDrops=\(inFlightDrops) busyDrops=\(admissionBusyDrops) encodeDrops=\(encodeDrops) expiredDrops=\(expiredDrops)")
    }

    static func main() {
        successfulCommitAndInvalidClock()
        realNumberSourceTrajectories()
        shortAndLongPauseDoNotAccumulateDebt()
        callerOwnsSingleFlightAndDrops()
        print("screen_follow_cadence=passed assertions=\(assertions) trajectories=\(trajectories) sourceFrames=\(sourceFrames) addedAdmissionsVsStrict=\(addedAdmissions) minimumSpacingMS=\(String(format: "%.6f", smallestSpacing * 1000)) controller=unchanged-v26 physicalAcceptance=unmeasured")
    }
}
