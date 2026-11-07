import Foundation

/// All boxes use Vision's bottom-left coordinates, relative to the selected preview crop.
struct ScreenFollowController {
    private(set) var target: ScreenFollowRect?
    private var confirmations = 0
    private var lastFrameID: UInt64 = 0
    private var lastObservationAt: TimeInterval?
    private var previous = ScreenFollowCommand.hold
    private var filteredX = 0.0
    private var filteredY = 0.0
    private var referencePitch = 0
    private var referenceFilteredY = 0.0
    private var previousError: (x: Double, y: Double)?
    private var visible = false
    private var centerLocked = false
    private var lastCenteredObservation: (errorY: Double, capturedAt: TimeInterval)?
    private var lastPitchObservation: (errorY: Double, capturedAt: TimeInterval)?
    private var downwardStarting = false
    private var upwardStarting = false
    private var pitchCenterTail: (startedAt: TimeInterval, magnitude: Double, handoff: Bool)?
    private var centerHandoffWindow: (startedAt: TimeInterval, magnitude: Double)?
    private var centerHandoffReversal: (errorY: Double, capturedAt: TimeInterval)?
    var hasConfirmedTarget: Bool { target != nil && confirmations >= 2 && visible }
    var trackingReference: ScreenFollowRect? { confirmations >= 2 ? target : nil }
    private(set) var decision = "waiting"
    private(set) var pitchStartBoosted = false
    private(set) var downwardLead = 0.0
    private(set) var centerHandoffTailActive = false

    private mutating func resetMotion() {
        previous = .hold
        filteredX = 0; filteredY = 0
        referencePitch = 0; referenceFilteredY = 0
        previousError = nil
        centerLocked = false
        lastCenteredObservation = nil
        lastPitchObservation = nil
        downwardStarting = false
        upwardStarting = false
        pitchCenterTail = nil
        centerHandoffWindow = nil
        centerHandoffReversal = nil
        downwardLead = 0
        centerHandoffTailActive = false
    }

    mutating func reset() {
        target = nil
        confirmations = 0
        lastObservationAt = nil
        visible = false
        decision = "reset"
        pitchStartBoosted = false
        resetMotion()
    }

    mutating func observe(faces: [ScreenFollowRect], frameID: UInt64, capturedAt: TimeInterval,
                          now: TimeInterval, yawSign: Double, pitchSign: Double) -> ScreenFollowCommand? {
        guard frameID > lastFrameID else { return nil }
        lastFrameID = frameID
        let wasCenterHandoffTailActive = centerHandoffTailActive
        pitchStartBoosted = false
        downwardLead = 0
        centerHandoffTailActive = false
        guard now.isFinite, capturedAt.isFinite, now >= capturedAt,
              now - capturedAt <= ScreenFollowConstants.maximumFrameAge,
              abs(yawSign) == 1, abs(pitchSign) == 1 else { reset(); decision = "stale_or_invalid"; return .hold }
        if let lastObservationAt, capturedAt <= lastObservationAt
            || capturedAt - lastObservationAt > ScreenFollowConstants.maximumFrameAge { reset() }
        // Reserve identity across a brief missed detection, but never move from an old box.
        // A longer miss requires two fresh observations, just like a new target.
        if !visible, let lastObservationAt, capturedAt - lastObservationAt > 0.35 { reset() }
        let candidates = faces.filter(\.validFace)
        let selected: ScreenFollowRect?
        if let target {
            selected = candidates.filter { $0.isContinuous(with: target) }
                .max { $0.continuityScore(with: target) < $1.continuityScore(with: target) }
        } else {
            selected = candidates.count == 1 ? candidates.first : nil
        }
        guard let selected else {
            if candidates.isEmpty, confirmations >= 2, let lastObservationAt,
               capturedAt - lastObservationAt <= 0.35 {
                visible = false
                resetMotion()
            } else { reset() }
            decision = candidates.isEmpty ? (faces.isEmpty ? "no_observation" : "invalid_box")
                : candidates.count > 1 && target == nil ? "ambiguous_target" : "target_mismatch"
            return .hold
        }
        let resumingAfterBriefMiss = !visible && confirmations >= 2
        let elapsed = lastObservationAt.map { capturedAt - $0 } ?? 0.1
        target = selected
        lastObservationAt = capturedAt
        visible = true
        confirmations += 1
        guard hasConfirmedTarget else { decision = "confirming"; return .hold }

        let errorX = (selected.centerX - 0.5) * 2000
        let errorY = (0.5 - selected.centerY) * 2000
        let pendingHandoffReversal = centerHandoffReversal
        centerHandoffReversal = nil
        // Pitch can start while yaw is still tracking. Keep its own confirmed
        // observation rather than relying on the shared two-axis center lock.
        defer {
            lastPitchObservation = (errorY, capturedAt)
            if centerLocked {
                referencePitch = previous.pitch
                referenceFilteredY = filteredY
            }
        }
        // Keep the accepted centered stop region, but release a little earlier:
        // waiting for 150/190 and then ramping from zero delayed both axes.
        // Separate entry/release thresholds still absorb small face-box noise.
        let yawRelease = 130.0
        let pitchRelease = 160.0
        // Real departures cross 160 before reaching 240; waiting for 240 missed
        // the first command and discarded its evidence when the lock released.
        // Only a fresh, substantial outward change may boost a stopped/minimum
        // pitch output. Loss recovery and an old opposite direction stay soft.
        let rapidPitchStart = !resumingAfterBriefMiss && abs(errorY) >= pitchRelease
            && abs(previous.pitch) <= 14
            && Double(previous.pitch) * errorY * pitchSign >= 0
            && filteredY * errorY * pitchSign >= 0
            && (lastPitchObservation.map {
                let dt = capturedAt - $0.capturedAt
                return dt >= 0.04 && dt <= 0.18
                    && abs($0.errorY) <= pitchRelease
                    // Preserve the 100ms outward-speed requirement when
                    // v27 admits frames near15Hz; small changes still need40.
                    // Upward behavior and intervals>=100ms remain unchanged.
                    && abs(errorY) - abs($0.errorY) >= (errorY > 0
                        ? max(40, 70 * min(1, dt / 0.1)) : 70)
                    && (errorY - $0.errorY) * errorY > 0
            } ?? false)
        let inPitchHandoffRegion = abs(errorY) > 80 + 1e-9 && abs(errorY) <= 130
        if !inPitchHandoffRegion
            || (lastPitchObservation.map { $0.errorY * errorY <= 0 } ?? false) {
            centerHandoffWindow = nil
        }
        let wasCenterLocked = centerLocked
        if centerLocked {
            if abs(errorX) >= yawRelease || abs(errorY) >= pitchRelease { centerLocked = false }
        } else if abs(errorX) <= 110 && abs(errorY) <= 130 { centerLocked = true }
        if centerLocked {
            // Start a confirmed downward departure one small motor step earlier,
            // without releasing the shared lock that keeps yaw stationary.
            let centeredElapsed = lastCenteredObservation.map { capturedAt - $0.capturedAt }
            let freshCenteredSample = centeredElapsed.map { $0 > 0 && $0 <= 0.35 } ?? false
            let movingDown = (centeredElapsed.map { $0 >= 0.04 } ?? false)
                && (lastCenteredObservation.map { errorY - $0.errorY >= 24 } ?? false)
            // A new handoff tail needs the usual real-command reversal hold.
            // Keep that observed reversal for exactly the next fresh frame so
            // stopping does not discard the small opposite departure itself.
            let continuingHandoffReversal = pendingHandoffReversal.map {
                let dt = capturedAt - $0.capturedAt
                return dt >= 0.04 && dt <= 0.18 && errorY * $0.errorY > 0
                    && abs(errorY) > 130 && abs(errorY) < 160
            } ?? false
            let directionSafe = Double(previous.pitch) * pitchSign >= 0 && filteredY * pitchSign >= 0
            let startDown = freshCenteredSample && errorY > 130 && directionSafe
                && (downwardStarting || movingDown || continuingHandoffReversal)
            // Mirror the minimum downward assist for an observed upward
            // departure, but only from two closely spaced current frames.
            let freshUpwardSample = centeredElapsed.map { $0 >= 0.04 && $0 <= 0.18 } ?? false
            let movingUp = lastCenteredObservation.map { $0.errorY - errorY >= 24 } ?? false
            let upwardDirectionSafe = Double(previous.pitch) * pitchSign <= 0 && filteredY * pitchSign <= 0
            let startUp = freshUpwardSample && errorY < -130 && upwardDirectionSafe
                && (upwardStarting || movingUp || continuingHandoffReversal)
            if wasCenterHandoffTailActive, freshUpwardSample,
               abs(errorY) > 130, abs(errorY) < 160,
               Double(previous.pitch) * errorY * pitchSign < 0,
               (errorY > 0 ? movingDown : movingUp) {
                centerHandoffReversal = (errorY, capturedAt)
            }

            // The existing joint lock still stops yaw. A pitch command already
            // approaching that lock may finish with a short, decreasing tail;
            // small orthogonal errors cannot start a new tail on their own.
            let pitchSampleAge = lastPitchObservation.map { capturedAt - $0.capturedAt }
            let freshPitchSample = pitchSampleAge.map { $0 >= 0.04 && $0 <= 0.18 } ?? false
            let samePitchDirection = Double(previous.pitch) * errorY * pitchSign > 0
                && filteredY * errorY * pitchSign > 0
            // Normalized box arithmetic can reconstruct -80 as slightly
            // larger than 80. Keep the true-center stop symmetric on both sides.
            let inTailRegion = inPitchHandoffRegion
            if !resumingAfterBriefMiss && freshPitchSample && samePitchDirection && inTailRegion {
                if pitchCenterTail == nil,
                   let prior = lastPitchObservation,
                   prior.errorY * errorY > 0 {
                    // Seed the original tail from the un-led command. A larger
                    // preceding live command must not prolong the center tail.
                    let magnitude = min(28, Double(min(abs(previous.pitch), abs(referencePitch))))
                    if abs(prior.errorY) > 130 {
                        pitchCenterTail = (capturedAt, magnitude, false)
                    } else if !wasCenterLocked, abs(prior.errorY) > 80 + 1e-9,
                              Double(referencePitch) * errorY * pitchSign > 0 {
                        // Yaw entering its center must not abruptly cut an
                        // already-moving pitch. Repeated yaw crossings share
                        // one window while pitch remains in this same band.
                        let window = centerHandoffWindow ?? (capturedAt, magnitude)
                        centerHandoffWindow = window
                        if capturedAt - window.startedAt < 0.18, window.magnitude > 0 {
                            pitchCenterTail = (window.startedAt, min(magnitude, window.magnitude), true)
                        }
                    }
                }
            } else { pitchCenterTail = nil }
            var tailPitch = 0
            if let tail = pitchCenterTail {
                let duration = capturedAt - tail.startedAt
                let magnitude = min(tail.magnitude * max(0, 1 - duration / 0.18),
                                    min(Double(abs(previous.pitch)), abs(errorY) * 0.65 / 3))
                let rounded = Int(magnitude.rounded())
                if duration < 0.18 && rounded >= 14 {
                    tailPitch = Int(copysign(Double(rounded), errorY * pitchSign))
                } else {
                    if tail.handoff { centerHandoffWindow = (tail.startedAt, 0) }
                    pitchCenterTail = nil
                }
            }
            previous = .hold
            filteredX = 0
            previousError = nil
            lastCenteredObservation = (errorY, capturedAt)
            downwardStarting = startDown
            upwardStarting = startUp
            if startDown {
                // Keep this narrow 130...160 region at the existing minimum
                // output. Seed the filter too, so normal tracking can take over
                // smoothly after the shared lock releases.
                previous = ScreenFollowCommand(yaw: 0, pitch: Int(14 * pitchSign))
                filteredY = Double(previous.pitch)
                decision = "downward_start"
                return previous
            }
            if startUp {
                previous = ScreenFollowCommand(yaw: 0, pitch: Int(-14 * pitchSign))
                filteredY = Double(previous.pitch)
                decision = "upward_start"
                return previous
            }
            if tailPitch != 0 {
                previous = ScreenFollowCommand(yaw: 0, pitch: tailPitch)
                filteredY = Double(tailPitch)
                centerHandoffTailActive = pitchCenterTail?.handoff ?? false
                decision = "pitch_center_tail"
                return previous
            }
            filteredY = 0
            decision = "center_locked"
            return .hold
        }
        lastCenteredObservation = nil
        pitchCenterTail = nil
        if downwardStarting && errorY <= 130 {
            // A jump to the upper side must start exactly as it did before the
            // downward assist, without a residual pitch reversal guard delay.
            previous = ScreenFollowCommand(yaw: previous.yaw, pitch: 0)
            filteredY = 0
            referencePitch = 0; referenceFilteredY = 0
        }
        if upwardStarting && errorY >= -130 {
            previous = ScreenFollowCommand(yaw: previous.yaw, pitch: 0)
            filteredY = 0
            referencePitch = 0; referenceFilteredY = 0
        }
        downwardStarting = false
        upwardStarting = false

        // Native tracking brakes while approaching the center. This approach
        // projection can only reduce the current error without reversing it.
        func approachError(_ current: Double, previous: Double?) -> Double {
            guard let previous, elapsed >= 0.06, elapsed <= 0.35,
                  current * previous > 0,
                  abs(previous) - abs(current) >= max(24, abs(previous) * 0.12) else { return current }
            let horizon = min(0.12, max(0.07, elapsed * 0.65))
            let projected = current + (current - previous) / elapsed * horizon
            return projected * current > 0 ? copysign(min(abs(current), abs(projected)), current) : 0
        }
        var predictedX = approachError(errorX, previous: previousError?.x)
        let observedPitchTarget = approachError(errorY, previous: previousError?.y)
        var predictedY = observedPitchTarget
        // A short lead helps the filter catch a confirmed downward departure.
        // It does not increase gain, slew limits or the current-error envelope.
        if errorY >= pitchRelease, elapsed >= 0.04, elapsed <= 0.18,
           let previousY = previousError?.y, previousY >= pitchRelease,
           errorY - previousY >= max(18, previousY * 0.08), !resumingAfterBriefMiss {
            downwardLead = min((errorY - previousY) / elapsed * 0.055, min(70, errorY * 0.20))
            predictedY = errorY + downwardLead
        }
        // Match the native horizontal capture path: a short, bounded lead only
        // when the target is measurably moving away. Approaching still brakes.
        if let previousX = previousError?.x, elapsed >= 0.04, elapsed <= 0.35,
           errorX * previousX > 0,
           abs(errorX) - abs(previousX) >= max(18, abs(previousX) * 0.08) {
            let horizon = min(0.048, max(0.03, elapsed * 0.28))
            let lead = min(abs((errorX - previousX) / elapsed * horizon), min(55, max(18, abs(errorX) * 0.1)))
            predictedX = errorX + copysign(lead, errorX)
        }
        let responseScale = min(0.18, max(0.06, elapsed)) / 0.1
        // A brief loss already stopped the motor and cleared the filter. Keep
        // the full observation gap for identity and yaw, but do not accumulate
        // that stopped time into pitch's first restart step. Later observations
        // use the ordinary response again.
        let pitchResponseScale = resumingAfterBriefMiss ? min(1, responseScale) : responseScale
        // Help an already-moving downward target before it gets farther away.
        // Two observed offsets must be outside the pitch release boundary, with
        // meaningful further movement. A short-loss restart keeps v21's softness.
        let sustainedDownward = !resumingAfterBriefMiss && errorY >= pitchRelease
            && elapsed >= 0.04 && elapsed <= 0.35
            && (previousError.map {
                $0.y >= pitchRelease && errorY - $0.y >= max(18, $0.y * 0.08)
            } ?? false)
        // React faster to a measured rapid vertical departure on either side.
        // Two fresh same-side observations are required. Do not spend a stopped
        // interval as acceleration credit, or boost slow drift / center approach.
        let rapidPitchDeparture = !resumingAfterBriefMiss && abs(errorY) >= 270
            && elapsed >= 0.04 && elapsed <= 0.18
            && (previousError.map {
                errorY * $0.y > 0 && abs($0.y) >= pitchRelease
                    && abs(errorY) - abs($0.y) >= max(60, abs($0.y) * 0.18)
            } ?? false)
        pitchStartBoosted = rapidPitchStart
        let horizontalStep = (abs(predictedX) >= 650 ? 56.0 : abs(predictedX) >= 400 ? 42.0 : 28.0) * responseScale
        // Keep v15's early pitch startup, but soften large departures. The live
        // trace reaches strong pitch commands before required loss/identity stops;
        // less authority reduces that jump without driving through a safety hold.
        // A continuous curve avoids adding a gain step at the transition.
        let verticalMagnitude = abs(observedPitchTarget)
        let verticalGain: Double
        if verticalMagnitude <= 270 {
            verticalGain = 0.65
        } else {
            verticalGain = 0.65 + min(1, (verticalMagnitude - 270) / 380) * 0.10
        }
        let verticalStep = (verticalMagnitude >= 650 ? 48.0 : verticalMagnitude >= 400 ? 38.0 : 28.0)
            * pitchResponseScale * (rapidPitchStart ? 1.60 : rapidPitchDeparture ? 1.30 : sustainedDownward ? 1.12 : 1)
        func output(_ error: Double, observedError: Double? = nil, sign: Double,
                    gain: Double = 0.65, accelerating: Bool, responseScale: Double,
                    acceleratingResponse: Double = 0.65,
                    previous: Int, maxStep: Double, filtered: inout Double) -> Int {
            let envelopeError = observedError ?? error
            guard abs(envelopeError) > 35 else { filtered = 0; return 0 }
            let desired = max(-250, min(250, error * gain * sign / 3))
            let envelopeDesired = max(-250, min(250, envelopeError * gain * sign / 3))
            // Never keep driving the old direction after the current error reverses.
            guard Double(previous) * envelopeDesired >= 0, filtered * envelopeDesired >= 0 else { filtered = 0; return 0 }
            // Reduce startup lag only while an axis is outside its own release
            // boundary and is not approaching center. Do not accelerate a small
            // orthogonal error merely because the other axis unlocked.
            // Preserve the original filter for all deceleration; gains and step
            // limits still bound the stronger buildup.
            let response = accelerating && abs(desired) > abs(filtered) ? acceleratingResponse : 0.45
            let alpha = 1 - pow(1 - response, responseScale)
            // Retain the filter below the motor's minimum output. Otherwise a faster
            // frame rate can repeatedly round a small startup step to zero forever.
            filtered += (desired - filtered) * alpha
            filtered = copysign(min(abs(filtered), abs(envelopeDesired)), envelopeDesired)
            let ramped = Double(previous) + max(-maxStep, min(maxStep, filtered - Double(previous)))
            // During approach, prediction lowers the filter target;
            // the current observed error still limits magnitude and direction.
            // This allows a short deceleration instead of clipping straight to
            // the predicted value. Actual center lock and target loss stop above.
            let bounded = copysign(min(abs(ramped), abs(envelopeDesired)), envelopeDesired)
            let result = Int(bounded.rounded())
            return abs(result) >= 14 ? result : 0
        }
        let horizontalApproachEnvelope = abs(predictedX) < abs(errorX) ? errorX : nil
        // Use the accepted yaw deceleration rule for pitch too. A projection
        // crossing center should lower the filter target, not force an abrupt
        // zero while the current face is still displaced. Actual center lock,
        // observed axis center, direction reversal and target loss still stop.
        let verticalApproachEnvelope = downwardLead > 0 || abs(predictedY) < abs(errorY) ? errorY : nil
        let acceleratingX = abs(errorX) >= yawRelease
            && (previousError.map { abs(errorX) >= abs($0.x) } ?? true)
        let acceleratingY = abs(errorY) >= pitchRelease
            && (previousError.map { abs(errorY) >= abs($0.y) } ?? true)
        // Keep one un-led pitch reference using the same output calculation.
        // Each live frame starts from its pre-update filter, so an outward lead
        // cannot remain accumulated in the filter during approach or a tail.
        // The live path still uses its actual previous command for direction
        // protection and slew limits; the reference cannot bypass either.
        let referenceFilterBefore = referenceFilteredY
        referencePitch = output(observedPitchTarget,
                                observedError: abs(observedPitchTarget) < abs(errorY) ? errorY : nil,
                                sign: pitchSign, gain: verticalGain, accelerating: acceleratingY,
                                responseScale: pitchResponseScale,
                                acceleratingResponse: rapidPitchStart ? 0.80 : rapidPitchDeparture ? 0.75 : sustainedDownward ? 0.72 : 0.65,
                                previous: referencePitch, maxStep: verticalStep, filtered: &referenceFilteredY)
        filteredY = referenceFilterBefore
        previous = ScreenFollowCommand(yaw: output(predictedX, observedError: horizontalApproachEnvelope,
                                                   sign: yawSign, accelerating: acceleratingX, responseScale: responseScale,
                                                   previous: previous.yaw,
                                                   maxStep: horizontalStep, filtered: &filteredX),
                                       pitch: output(predictedY, observedError: verticalApproachEnvelope,
                                                     sign: pitchSign, gain: verticalGain, accelerating: acceleratingY,
                                                     responseScale: pitchResponseScale,
                                                     acceleratingResponse: rapidPitchStart ? 0.80 : rapidPitchDeparture ? 0.75 : sustainedDownward ? 0.72 : 0.65,
                                                     previous: previous.pitch, maxStep: verticalStep, filtered: &filteredY))
        previousError = (errorX, errorY)
        decision = previous == .hold ? "braking_or_small_error" : "tracking"
        return previous
    }
}
