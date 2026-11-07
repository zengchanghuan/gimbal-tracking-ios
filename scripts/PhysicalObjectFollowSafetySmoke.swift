import Foundation
import CoreGraphics

// INSERT_PRODUCTION_POLICY

// The policy above comes directly from CameraManager+ObjectRecognition.swift.
// These inputs measure policy decisions, not recognition or real motor behavior.
var assertions = 0
var failures = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    if !condition() {
        failures += 1
        print("FAIL: \(message)")
    }
}

let referenceBox = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
func observationReason(_ rect: CGRect, previous: CGRect? = nil,
                       confidence: Float = 0.9, at: TimeInterval = 1) -> String? {
    var safety = CMPhysicalObjectFollowSafety()
    return safety.observe(rect: rect, previousRect: previous ?? rect,
                          confidence: confidence, capturedAt: at)
}
func readyPolicy(recoveryEnabled: Bool = false) -> CMPhysicalObjectFollowSafety {
    var safety = CMPhysicalObjectFollowSafety(recoveryEnabled: recoveryEnabled)
    for index in 0..<3 {
        let reason = safety.observe(rect: referenceBox, previousRect: referenceBox,
                                    confidence: 0.9, capturedAt: 0.1 + Double(index) * 0.1)
        expect(reason == nil, "reliable setup observation \(index) accepted")
    }
    expect(safety.ready, "three reliable increasing setup frames enable following")
    return safety
}

do {
    var safety = CMPhysicalObjectFollowSafety()
    expect(!safety.ready, "new selection starts unready")
    expect(safety.heldX && safety.heldY, "new selection holds both axes")
    for index in 1...3 {
        let reason = safety.observe(rect: referenceBox, previousRect: referenceBox,
                                    confidence: 0.5, capturedAt: Double(index))
        expect(reason == nil, "confidence boundary 0.5 accepted")
        expect(safety.ready == (index == 3), "requires exactly three reliable frames")
    }
    expect(safety.observe(rect: referenceBox, previousRect: referenceBox,
                          confidence: 0.9, capturedAt: 3) != nil,
           "duplicate capture time is rejected")
    expect(safety.observe(rect: referenceBox, previousRect: referenceBox,
                          confidence: 0.9, capturedAt: 2.9) != nil,
           "out-of-order capture time is rejected")
}

for confidence: Float in [0, 0.499, .nan, .infinity, -.infinity] {
    expect(observationReason(referenceBox, confidence: confidence) != nil,
           "unreliable confidence \(confidence) is rejected")
}
for time: TimeInterval in [.nan, .infinity, -.infinity] {
    expect(observationReason(referenceBox, at: time) != nil,
           "nonfinite capture time \(time) is rejected")
}
let tiny = CGRect(x: 0.5, y: 0.5, width: 0.002, height: 0.003)
expect(observationReason(tiny) == nil, "2 per mille small object remains eligible")
let minimumSquare = CGRect(x: 0.4, y: 0.4, width: 0.002, height: 0.002)
expect(observationReason(minimumSquare) == nil, "both dimensions at small-object boundary accepted")
expect(observationReason(CGRect(x: 0.5, y: 0.5, width: 0.0019, height: 0.003)) != nil,
       "width below small-object minimum rejected")
expect(observationReason(CGRect(x: 0.5, y: 0.5, width: 0.003, height: 0.0019)) != nil,
       "height below small-object minimum rejected")
for box in [CGRect.zero, CGRect(x: -0.01, y: 0.4, width: 0.1, height: 0.1),
            CGRect(x: 0.95, y: 0.4, width: 0.1, height: 0.1),
            CGRect(x: 0.4, y: -0.01, width: 0.1, height: 0.1),
            CGRect(x: 0.4, y: 0.95, width: 0.1, height: 0.1),
            CGRect(x: CGFloat.nan, y: 0.4, width: 0.1, height: 0.1),
            CGRect(x: 0.4, y: CGFloat.nan, width: 0.1, height: 0.1),
            CGRect(x: 0.4, y: 0.4, width: CGFloat.infinity, height: 0.1)] {
    expect(observationReason(box, previous: referenceBox) != nil,
           "invalid normalized box rejected: \(box)")
}
let doubledArea = CGRect(x: 0.35, y: 0.4, width: 0.2, height: 0.1)
let halvedArea = CGRect(x: 0.425, y: 0.4, width: 0.05, height: 0.1)
expect(observationReason(doubledArea, previous: referenceBox) == nil, "area ratio 2 boundary accepted")
expect(observationReason(halvedArea, previous: referenceBox) == nil, "area ratio 0.5 boundary accepted")
expect(observationReason(CGRect(x: 0.349, y: 0.4, width: 0.202, height: 0.1),
                         previous: referenceBox) != nil, "area expansion above 2 rejected")
expect(observationReason(CGRect(x: 0.426, y: 0.4, width: 0.048, height: 0.1),
                         previous: referenceBox) != nil, "area contraction below 0.5 rejected")
expect(observationReason(tiny.offsetBy(dx: 0.039, dy: 0), previous: tiny) == nil,
       "tiny-object continuity allows bounded motion")
expect(observationReason(tiny.offsetBy(dx: 0.041, dy: 0), previous: tiny) != nil,
       "tiny-object horizontal jump rejected")
expect(observationReason(tiny.offsetBy(dx: 0, dy: 0.041), previous: tiny) != nil,
       "tiny-object vertical jump rejected")
let large = CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.2)
expect(observationReason(large.offsetBy(dx: 0.149, dy: 0.099), previous: large) == nil,
       "continuity thresholds scale independently with target dimensions")
expect(observationReason(large.offsetBy(dx: 0.151, dy: 0), previous: large) != nil,
       "scaled horizontal jump threshold enforced")
expect(observationReason(large.offsetBy(dx: 0, dy: 0.101), previous: large) != nil,
       "scaled vertical jump threshold enforced")

do {
    var safety = readyPolicy()
    for index in 0..<200 {
        let jitterX = [0, 20, -20, 70, -70, 109, -109][index % 7]
        let jitterY = [0, -20, 20, -80, 80, -129, 129][index % 7]
        expect(safety.control(rawX: jitterX, rawY: jitterY, at: 1 + Double(index) * 0.05,
                              commandedX: false, commandedY: false) == nil,
               "center jitter does not pause at sample \(index)")
        expect(safety.heldX && safety.heldY, "center jitter holds both axes at sample \(index)")
    }
}
do {
    var safety = readyPolicy()
    _ = safety.control(rawX: 149, rawY: 189, at: 1, commandedX: false, commandedY: false)
    expect(safety.heldX && safety.heldY, "within exit bounds preserves holding")
    _ = safety.control(rawX: 151, rawY: 0, at: 1.1, commandedX: false, commandedY: false)
    expect(!safety.heldX && safety.heldY, "horizontal release does not release vertical")
    _ = safety.control(rawX: 120, rawY: 0, at: 1.2, commandedX: false, commandedY: false)
    expect(!safety.heldX && safety.heldY, "horizontal hysteresis avoids premature relock")
    _ = safety.control(rawX: 109, rawY: -191, at: 1.3, commandedX: false, commandedY: false)
    expect(safety.heldX && !safety.heldY, "horizontal reentry and vertical release are independent")
    _ = safety.control(rawX: 0, rawY: -150, at: 1.4, commandedX: false, commandedY: false)
    expect(safety.heldX && !safety.heldY, "vertical hysteresis avoids premature relock")
    _ = safety.control(rawX: 0, rawY: -129, at: 1.5, commandedX: false, commandedY: false)
    expect(safety.heldX && safety.heldY, "vertical reentry restores hold")
}
for sign in [-1, 1] {
    var safety = readyPolicy()
    _ = safety.control(rawX: sign * 150, rawY: sign * 190, at: 1,
                       commandedX: false, commandedY: false)
    expect(!safety.heldX && !safety.heldY, "exit boundaries release both axes symmetrically")
    _ = safety.control(rawX: sign * 110, rawY: sign * 130, at: 1.1,
                       commandedX: false, commandedY: false)
    expect(safety.heldX && safety.heldY, "entry boundaries hold both axes symmetrically")
}

do {
    var safety = readyPolicy()
    for index in 0...100 {
        expect(safety.control(rawX: 350 + index, rawY: -350 - index,
                              at: 1 + Double(index) * 0.1,
                              commandedX: false, commandedY: false) == nil,
               "no transport demand cannot count as failed motor response \(index)")
    }
}
for horizontal in [true, false] {
    var safety = readyPolicy()
    for index in 0...19 {
        let offset = 350 + index * 4
        expect(safety.control(rawX: horizontal ? offset : 0,
                              rawY: horizontal ? 0 : -offset,
                              at: 1 + Double(index) * 0.1,
                              commandedX: horizontal, commandedY: !horizontal) == nil,
               "worsening \(horizontal ? "x" : "y") cannot fire before 2 seconds")
    }
    let reason = safety.control(rawX: horizontal ? 430 : 0,
                                rawY: horizontal ? 0 : -430,
                                at: 3.01, commandedX: horizontal, commandedY: !horizontal)
    expect(reason != nil, "sustained 2-second same-side worsening pauses \(horizontal ? "x" : "y")")
}
for horizontal in [true, false] {
    var safety = readyPolicy()
    for index in 0...39 {
        expect(safety.control(rawX: horizontal ? -450 : 0,
                              rawY: horizontal ? 0 : 450,
                              at: 1 + Double(index) * 0.1,
                              commandedX: horizontal, commandedY: !horizontal) == nil,
               "stagnant \(horizontal ? "x" : "y") cannot fire before 4 seconds")
    }
    expect(safety.control(rawX: horizontal ? -450 : 0,
                          rawY: horizontal ? 0 : 450, at: 5.01,
                          commandedX: horizontal, commandedY: !horizontal) != nil,
           "4-second stagnant demand pauses \(horizontal ? "x" : "y")")
}
do {
    var safety = readyPolicy()
    for index in 0...100 {
        let offset = max(0, 700 - index * 8)
        expect(safety.control(rawX: -offset, rawY: offset,
                              at: 1 + Double(index) * 0.1,
                              commandedX: true, commandedY: true) == nil,
               "progressing target is not mistaken for a failing loop \(index)")
    }
    expect(safety.heldX && safety.heldY, "progressing target eventually holds at center")
}
for stagnantHorizontal in [true, false] {
    var safety = readyPolicy()
    for index in 0...39 {
        let improving = 700 - index * 8
        expect(safety.control(rawX: stagnantHorizontal ? 450 : improving,
                              rawY: stagnantHorizontal ? -improving : -450,
                              at: 1 + Double(index) * 0.1,
                              commandedX: true, commandedY: true) == nil,
               "independent progress windows have not timed out")
    }
    let reason = safety.control(rawX: stagnantHorizontal ? 450 : 380,
                                rawY: stagnantHorizontal ? -380 : -450,
                                at: 5.01, commandedX: true, commandedY: true)
    expect(reason == (stagnantHorizontal ? "yaw_not_converging" : "pitch_not_converging"),
           "improvement on one axis cannot mask stagnation on the other")
}
do {
    var safety = readyPolicy()
    _ = safety.control(rawX: 300, rawY: 0, at: 1, commandedX: true, commandedY: false)
    expect(safety.control(rawX: 300, rawY: 0, at: 4.5,
                          commandedX: true, commandedY: false) == nil, "pre-stop demand has not timed out")
    _ = safety.control(rawX: 300, rawY: 0, at: 4.6, commandedX: false, commandedY: false)
    expect(safety.control(rawX: 300, rawY: 0, at: 20,
                          commandedX: true, commandedY: false) == nil, "disabled transport clears old demand timer")
    expect(safety.control(rawX: -300, rawY: 0, at: 23.5,
                          commandedX: true, commandedY: false) == nil, "crossing sides starts a new response window")
}

// Captured 2026-10-19T01:31:08.970Z through 01:31:22.245Z from the company
// iPhone 12 Pro Max log. Times are seconds since the first logged raw position.
// No boxes/confidence were logged, so this replays control safety only.
let recordedRaw: [(TimeInterval, Int, Int)] = [
    (0, -280, -103), (0.513, -315, -84), (1.038, -350, -60),
    (1.549, -339, -36), (2.067, -376, -33), (2.602, -386, -38),
    (3.135, -395, -54), (3.667, -394, -55), (4.196, -414, -40),
    (4.734, -418, -25), (5.271, -423, -38), (5.805, -416, -37),
    (6.334, -427, -36), (6.866, -448, -38), (7.404, -471, -47),
    (7.940, -483, -54), (8.472, -486, -49), (9.010, -489, -54),
    (9.538, -496, -56), (10.072, -500, -57), (10.608, -507, -66),
    (11.144, -514, -61), (11.677, -514, -71), (12.202, -517, -74),
    (12.739, -526, -81), (13.275, -521, -80),
]
do {
    var safety = readyPolicy()
    var firstPause: (TimeInterval, String)?
    for (index, sample) in recordedRaw.enumerated() {
        let (elapsed, rawX, rawY) = sample
        if let reason = safety.control(rawX: rawX, rawY: rawY, at: 1 + elapsed,
                                       commandedX: index > 0, commandedY: false) {
            firstPause = (elapsed, reason)
            break
        }
    }
    expect(firstPause != nil, "recorded runaway produces a pause")
    expect(firstPause.map { $0.0 >= 4.19 && $0.0 <= 4.20 } ?? false,
           "recorded runaway still holds before the original limit report at 5.379 seconds")
    if let (elapsed, reason) = firstPause {
        print(String(format: "Recorded incident replay: first pause at %.3f s, reason=%@; original final raw sample at %.3f s",
                     elapsed, reason, recordedRaw.last!.0))
        print("Replay uses zero prior output at the first sample, then the recorded nonzero yaw demand; sparse logs bound timing, not live execution.")
    }
}

// Mostly visible edge boxes remain on the same tracker; actual exits do not.
for box in [CGRect(x: -0.01, y: 0.4, width: 0.1, height: 0.1),
            CGRect(x: 0.91, y: 0.4, width: 0.1, height: 0.1),
            CGRect(x: 0.4, y: -0.01, width: 0.1, height: 0.1),
            CGRect(x: 0.4, y: 0.91, width: 0.1, height: 0.1)] {
    expect(observationReason(box) == nil, "90 percent visible edge object survives")
}
for box in [CGRect(x: -0.016, y: 0.4, width: 0.1, height: 0.1),
            CGRect(x: 0.916, y: 0.4, width: 0.1, height: 0.1)] {
    expect(observationReason(box) == "invalid_box", "unconfirmed partial edge object still rejected")
}
let recordedEdge = CGRect(x: 0.2863245213285406, y: -0.0020876067115905435,
                         width: 0.14124211521013408, height: 0.3191024902019095)
let recordedPrevious = CGRect(x: 0.2881536010309314, y: 0.0009561292827129364,
                             width: 0.1478052612737561, height: 0.33393034021905127)
expect(observationReason(recordedEdge, previous: recordedPrevious, confidence: 0.54526407) == nil,
       "recorded 99 percent visible edge result is no longer treated as lost")

// New frame-edge hold: the actual 2026-10-30 box crossed 85% visibility
// while still matching strongly. Return motions below are synthetic policy
// inputs, not a claimed camera recording of the target returning.
let partialEdgeSeed = CGRect(x: 0.4, y: 0, width: 0.1, height: 0.2)
let partialEdgeBox = partialEdgeSeed.offsetBy(dx: 0, dy: -0.04)
func edgeReadyPolicy(_ box: CGRect = partialEdgeSeed, recoveryEnabled: Bool = false) -> CMPhysicalObjectFollowSafety {
    var safety = CMPhysicalObjectFollowSafety(recoveryEnabled: recoveryEnabled)
    for index in 0..<3 {
        expect(safety.observe(rect: box, previousRect: box, confidence: 0.9,
            capturedAt: 0.1 + Double(index) * 0.1) == nil, "edge setup accepts confirmed visible target")
    }
    expect(safety.ready, "edge setup requires three confirmed frames")
    return safety
}
do {
    let before = CGRect(x: 0.3901654750649734, y: -0.10058183063718884,
                        width: 0.2661188748052518, height: 0.684305678070647)
    let crossing = CGRect(x: 0.39820386718439954, y: -0.10334125315235476,
                          width: 0.2646219561344723, height: 0.6804564586314996)
    var safety = edgeReadyPolicy(before)
    expect(safety.observe(rect: crossing, previousRect: before, confidence: 0.9024157, capturedAt: 1) == nil,
           "recorded 84.81 percent visible strong target is retained for observation")
    expect(safety.awaitingFrameReentry && safety.confirmingTarget && !safety.ready,
           "recorded edge transition withdraws motion immediately")
    for index in 1...5 {
        expect(safety.observe(rect: crossing, previousRect: crossing, confidence: 0.95,
            capturedAt: 1 + Double(index) * 0.05) == nil, "fresh strong partial target keeps original hold")
        expect(!safety.ready, "three or more strong partial frames cannot restore motion")
    }
    expect(safety.confidenceRecoveryReference(at: 1.3) == before,
           "partial frames cannot move the frozen reliable association anchor")
    let returned = before.offsetBy(dx: 0, dy: 0.05)
    for index in 1...3 {
        expect(safety.observe(rect: returned, previousRect: index == 1 ? crossing : returned,
            confidence: 0.75, capturedAt: 1.3 + Double(index) * 0.05) == nil,
            "return frame may have an already authorized partial previous box")
        expect(safety.ready == (index == 3), "only third fully visible strong frame restores motion")
    }
    expect(!safety.awaitingFrameReentry && !safety.confirmingTarget,
           "successful return clears edge observation hold")
    expect(safety.confidenceRecoveryReference(at: 2) == returned,
           "return resets velocity instead of predicting from the pre-hold motion")
    expect(safety.confirmationTimeoutReason(at: 3) == nil, "completed return clears its deadline")
}
do {
    var safety = edgeReadyPolicy()
    expect(safety.observe(rect: partialEdgeBox, previousRect: partialEdgeSeed,
        confidence: 0.75, capturedAt: 1) == nil, "0.75 is the strong edge-match boundary")
    let samples: [(Double, CGRect)] = [(1.1, partialEdgeSeed), (1.2, partialEdgeSeed),
        (1.3, partialEdgeBox), (1.4, partialEdgeSeed), (1.5, partialEdgeSeed),
        (2.0, partialEdgeBox), (2.49, partialEdgeBox)]
    var previous = partialEdgeBox
    for (time, box) in samples {
        expect(safety.observe(rect: box, previousRect: previous, confidence: 0.95, capturedAt: time) == nil,
               "bounded repeated edge crossings remain observations")
        expect(!safety.ready, "a new partial frame resets the consecutive return streak")
        previous = box
    }
    expect(!safety.confirmationExpired(at: 2.499), "edge hold remains bounded below 1.5 seconds")
    expect(safety.confirmationTimeoutReason(at: 2.5) == "frame_reentry_timeout",
           "new partial frames and incomplete return streaks cannot renew the deadline")
    expect(safety.observe(rect: partialEdgeSeed, previousRect: previous, confidence: 1, capturedAt: 2.5)
        == "frame_reentry_timeout", "late strong return cannot escape edge timeout")
}
for count in 0..<3 {
    var safety = CMPhysicalObjectFollowSafety()
    for index in 0..<count {
        _ = safety.observe(rect: partialEdgeSeed, previousRect: partialEdgeSeed, confidence: 0.9,
                           capturedAt: 0.1 + Double(index) * 0.1)
    }
    expect(safety.observe(rect: partialEdgeBox, previousRect: partialEdgeSeed,
        confidence: 0.95, capturedAt: 1) == "invalid_box", "edge retention requires a previously confirmed target")
    expect(!safety.awaitingFrameReentry, "unconfirmed selection cannot obtain an edge recovery window")
}
for confidence: Float in [0.2, 0.499, 0.749] {
    var safety = edgeReadyPolicy()
    expect(safety.observe(rect: partialEdgeBox, previousRect: partialEdgeSeed,
        confidence: confidence, capturedAt: 1) == "invalid_box", "weak edge observation cannot start the longer hold")
}
for confidence: Float in [0.2, 0.49, 0.74] {
    var safety = edgeReadyPolicy()
    _ = safety.observe(rect: partialEdgeBox, previousRect: partialEdgeSeed, confidence: 0.9, capturedAt: 1)
    expect(safety.observe(rect: partialEdgeSeed, previousRect: partialEdgeBox,
        confidence: confidence, capturedAt: 1.1) == nil,
        "edge return grants a bounded weak-match interval without trusting the box")
    expect(safety.awaitingFrameReentryMatch && !safety.ready,
           "weak fully visible box still cannot restore motor authority")
    expect(safety.confirmationTimeoutReason(at: 1.549) == nil &&
           safety.confirmationTimeoutReason(at: 1.551) == "frame_reentry_confidence_timeout",
           "nested weak matching gets only 450 ms from its first weak frame")
}

// The recorded lateral failure (2662B645, decisions 240...246) had two
// sufficiently visible strong frames followed by a rejected match. The held
// old box is 88% visible, but its published quality is 0.3, not the rejected
// native score of 0.88. Mirror the geometry to exercise the right edge too.
let lateralAnchor = CGRect(x: 0.00808877068085622, y: 0.24387991117160657,
                           width: 0.3183261768540201, height: 0.5100453515501914)
let lateralSamples: [(elapsed: Double, box: CGRect, quality: Float)] = [
    (0, CGRect(x: -0.048305035945890244, y: 0.24609304760876627,
        width: 0.31653559210921617, height: 0.5071763464477216), 0.89048934),
    (0.033362084, CGRect(x: -0.048305035945890244, y: 0.2476555476087663,
        width: 0.31653559210921617, height: 0.5071763464477216), 0.87888116),
    (0.066724167, CGRect(x: -0.047412226368694625, y: 0.249860629684717,
        width: 0.31475507940360187, height: 0.5043234794989532), 0.95764953),
    (0.1000865, CGRect(x: -0.04639421792651641, y: 0.25490530378049314,
        width: 0.30649275856925734, height: 0.49108498816210566), 0.91356003),
    (0.133448542, CGRect(x: -0.04222755125984974, y: 0.25490530378049314,
        width: 0.30649275856925734, height: 0.49108498816210566), 0.99475378),
    (0.166810625, CGRect(x: -0.03615473482567975, y: 0.2570652114467279,
        width: 0.30476873680230526, height: 0.4883226351036938), 0.98610133),
    (0.233534834, CGRect(x: -0.03615473482567975, y: 0.2570652114467279,
        width: 0.30476873680230526, height: 0.4883226351036938), 0.3)
]
for mirrored in [false, true] {
    func geometry(_ box: CGRect) -> CGRect {
        mirrored ? CGRect(x: 1 - box.maxX, y: box.minY, width: box.width, height: box.height) : box
    }
    let anchor = geometry(lateralAnchor)
    var safety = edgeReadyPolicy(anchor)
    var previous = anchor
    for sample in lateralSamples {
        let box = geometry(sample.box)
        expect(safety.observe(rect: box, previousRect: previous, confidence: sample.quality,
            capturedAt: 1 + sample.elapsed) == nil, "recorded lateral interruption retains the same observed identity")
        expect(!safety.ready, "recorded edge frames never regain motion before the weak interruption")
        previous = box
    }
    expect(safety.awaitingFrameReentryMatch, "actual rejected match starts the nested confidence window")
    // The recording stops here. Subsequent repeated holds and successful
    // matches are synthetic boundary checks, not a claimed native recovery.
    for time in [1.28, 1.32, 1.36] {
        expect(safety.observe(rect: previous, previousRect: previous, confidence: 0.3,
            capturedAt: time) == nil, "three repeated held boxes remain bounded observations")
        expect(safety.awaitingFrameReentryMatch && !safety.ready,
               "three 88-percent-visible old boxes cannot act as three recovery matches")
    }
    expect(safety.confidenceRecoveryReference(at: 1.37) == anchor,
           "nested weak frames preserve the original frozen edge anchor")
    for (index, time) in [1.4, 1.45, 1.5].enumerated() {
        expect(safety.observe(rect: previous, previousRect: previous, confidence: 0.75,
            capturedAt: time) == nil, "new strong visible match is eligible for both recovery streaks")
        expect(safety.ready == (index == 2) && safety.awaitingFrameReentryMatch == (index != 2),
               "the same three strong visible frames may confirm identity and return without six-frame delay")
    }
    expect(!safety.awaitingFrameReentry && safety.confirmationTimeoutReason(at: 4) == nil,
           "completed lateral return clears both deadlines")
}
do {
    var safety = edgeReadyPolicy()
    _ = safety.observe(rect: partialEdgeBox, previousRect: partialEdgeSeed, confidence: 0.9, capturedAt: 1)
    _ = safety.observe(rect: partialEdgeSeed, previousRect: partialEdgeBox, confidence: 0.3, capturedAt: 1.05)
    for (time, quality) in [(1.10, Float(0.95)), (1.15, 0.95), (1.20, 0.749),
                           (1.25, 0.95), (1.30, 0.95), (1.35, 0.3),
                           (1.40, 0.95), (1.45, 0.95), (1.49, 0.749)] {
        expect(safety.observe(rect: partialEdgeSeed, previousRect: partialEdgeSeed,
            confidence: quality, capturedAt: time) == nil, "interrupted two-frame confidence streak remains held")
        expect(safety.awaitingFrameReentryMatch && !safety.ready,
               "two strong samples cannot clear the nested deadline or authorize motion")
    }
    expect(safety.confirmationTimeoutReason(at: 1.499) == nil &&
           safety.confirmationTimeoutReason(at: 1.501) == "frame_reentry_confidence_timeout",
           "repeated weak samples and interrupted strong pairs never renew the first 450 ms deadline")
    expect(safety.observe(rect: partialEdgeSeed, previousRect: partialEdgeSeed,
        confidence: 1, capturedAt: 1.501) == "frame_reentry_confidence_timeout",
        "late strong sample cannot rescue an expired nested match window")
}
do {
    var safety = edgeReadyPolicy()
    _ = safety.observe(rect: partialEdgeBox, previousRect: partialEdgeSeed, confidence: 0.9, capturedAt: 1)
    _ = safety.observe(rect: partialEdgeBox, previousRect: partialEdgeBox, confidence: 0.3, capturedAt: 1.1)
    for (index, time) in [1.15, 1.2, 1.25].enumerated() {
        expect(safety.observe(rect: partialEdgeBox, previousRect: partialEdgeBox,
            confidence: 0.75, capturedAt: time) == nil, "strong partial matches can recover identity")
        expect(safety.awaitingFrameReentryMatch == (index != 2) && !safety.ready,
               "partial matching clears only weak-match recovery after three frames, never motor hold")
    }
    expect(safety.awaitingFrameReentry && safety.confirmationTimeoutReason(at: 1.56) == nil,
           "reconfirmed identity clears the weak deadline but retains the original edge state")
    expect(safety.confidenceRecoveryReference(at: 1.56) == partialEdgeSeed,
           "even strong partial re-matching cannot refresh the reliable position anchor")
    _ = safety.observe(rect: partialEdgeBox, previousRect: partialEdgeBox, confidence: 0.3, capturedAt: 1.6)
    for time in [1.65, 1.7, 1.75] {
        _ = safety.observe(rect: partialEdgeBox, previousRect: partialEdgeBox, confidence: 0.9, capturedAt: time)
    }
    _ = safety.observe(rect: partialEdgeBox, previousRect: partialEdgeBox, confidence: 0.3, capturedAt: 2.2)
    expect(safety.awaitingFrameReentryMatch, "another genuine weak episode starts only after confirmed re-matching")
    for time in [2.3, 2.4] {
        expect(safety.observe(rect: partialEdgeSeed, previousRect: time == 2.3 ? partialEdgeBox : partialEdgeSeed,
            confidence: 0.9, capturedAt: time) == nil && !safety.ready, "late visible strong pair still cannot recover")
    }
    expect(safety.confirmationTimeoutReason(at: 2.5) == "frame_reentry_timeout",
           "absolute edge deadline caps a later weak sub-window before its own 450 ms")
    expect(safety.observe(rect: partialEdgeSeed, previousRect: partialEdgeSeed,
        confidence: 0.9, capturedAt: 2.5) == "frame_reentry_timeout",
        "third strong return at the absolute deadline cannot extend total edge retention")
}
for severe: Float in [0.199, .nan, .infinity] {
    var safety = edgeReadyPolicy()
    _ = safety.observe(rect: partialEdgeBox, previousRect: partialEdgeSeed, confidence: 0.9, capturedAt: 1)
    _ = safety.observe(rect: partialEdgeBox, previousRect: partialEdgeBox, confidence: 0.3, capturedAt: 1.1)
    expect(safety.observe(rect: partialEdgeBox, previousRect: partialEdgeBox,
        confidence: severe, capturedAt: 1.2) == "low_confidence",
        "nested weak-match retention never accepts severe or nonfinite quality")
}
do {
    var safety = edgeReadyPolicy()
    _ = safety.observe(rect: partialEdgeBox, previousRect: partialEdgeSeed, confidence: 0.9, capturedAt: 1)
    var previous = partialEdgeBox
    for index in 1...4 {
        let box = partialEdgeBox.offsetBy(dx: Double(index) * 0.04, dy: 0)
        expect(safety.observe(rect: box, previousRect: previous, confidence: 0.3,
            capturedAt: 1 + Double(index) * 0.05) == (index < 4 ? nil : "frame_reentry_identity_jump"),
            "weak edge frames cannot walk the frozen identity anchor into another object")
        previous = box
    }
}
do {
    var safety = edgeReadyPolicy()
    _ = safety.observe(rect: partialEdgeSeed, previousRect: partialEdgeSeed, confidence: 0.43, capturedAt: 1)
    expect(safety.observe(rect: partialEdgeBox, previousRect: partialEdgeSeed,
        confidence: 0.9, capturedAt: 1.1) == "invalid_box", "weak-match recovery cannot convert into a longer edge hold")
    expect(!safety.awaitingFrameReentry && safety.confirmationTimeoutReason(at: 1.451) == "confidence_recovery_timeout",
           "ordinary weak-match deadline remains 450 ms")
}
do {
    let seed = CGRect(x: -0.01, y: 0.4, width: 0.1, height: 0.1)
    let half = CGRect(x: -0.05, y: 0.4, width: 0.1, height: 0.1)
    var safety = edgeReadyPolicy(seed)
    expect(safety.observe(rect: half, previousRect: seed, confidence: 0.9, capturedAt: 1) == nil && !safety.ready,
           "half-visible target with its center on the edge may only be observed")
    expect(safety.observe(rect: half.offsetBy(dx: -0.001, dy: 0), previousRect: half,
        confidence: 0.9, capturedAt: 1.1) == "invalid_box", "target center outside the image still terminates tracking")
}
for invalid in [CGRect.zero, CGRect(x: 1.1, y: 0, width: 0.1, height: 0.2),
    CGRect(x: CGFloat.nan, y: 0, width: 0.1, height: 0.2),
    CGRect(x: 0.4, y: 0, width: CGFloat.infinity, height: 0.2),
    CGRect(x: 0.5, y: 0, width: -0.1, height: 0.2),
    CGRect(x: 0.4, y: 0.2, width: 0.1, height: -0.2),
    CGRect(x: -0.04, y: -0.04, width: 0.1, height: 0.1)] {
    var safety = edgeReadyPolicy()
    _ = safety.observe(rect: partialEdgeBox, previousRect: partialEdgeSeed, confidence: 0.9, capturedAt: 1)
    expect(safety.observe(rect: invalid, previousRect: partialEdgeBox, confidence: 0.9, capturedAt: 1.1) == "invalid_box",
           "edge hold still rejects invalid, completely absent, or mostly hidden target geometry")
}
do {
    var safety = edgeReadyPolicy()
    let exactBoundary = partialEdgeSeed.offsetBy(dx: 0, dy: -0.03)
    expect(safety.observe(rect: exactBoundary, previousRect: partialEdgeSeed,
        confidence: 0.9, capturedAt: 1) == nil && safety.ready,
        "exact 85 percent visibility preserves the existing ordinary path")
    let outsideBoundary = exactBoundary.offsetBy(dx: 0, dy: -0.00001)
    expect(safety.observe(rect: outsideBoundary, previousRect: exactBoundary,
        confidence: 0.9, capturedAt: 1.1) == nil && safety.awaitingFrameReentry && !safety.ready,
        "a real movement below 85 percent immediately withdraws motor authority")
}
do {
    var safety = edgeReadyPolicy()
    expect(safety.observe(rect: partialEdgeSeed, previousRect: partialEdgeBox, confidence: 0.9, capturedAt: 1)
        == "invalid_box", "partial previous box is not legalized before a recorded edge hold")
}
do {
    var safety = edgeReadyPolicy()
    _ = safety.observe(rect: partialEdgeBox, previousRect: partialEdgeSeed, confidence: 0.9, capturedAt: 1)
    var previous = partialEdgeBox
    for index in 1...4 {
        let box = partialEdgeBox.offsetBy(dx: Double(index) * 0.04, dy: 0)
        let reason = safety.observe(rect: box, previousRect: previous, confidence: 0.9,
                                    capturedAt: 1 + Double(index) * 0.05)
        expect(reason == (index < 4 ? nil : "frame_reentry_identity_jump"),
               "continuous small edge steps cannot drift beyond the frozen original identity")
        previous = box
    }
}
for (box, reason) in [(partialEdgeBox.offsetBy(dx: 0.2, dy: 0), "box_position_jump"),
    (CGRect(x: 0.4, y: 0, width: 0.21, height: 0.2), "box_scale_jump")] {
    var safety = edgeReadyPolicy()
    _ = safety.observe(rect: partialEdgeBox, previousRect: partialEdgeSeed, confidence: 0.9, capturedAt: 1)
    expect(safety.observe(rect: box, previousRect: partialEdgeBox, confidence: 0.9, capturedAt: 1.1) == reason,
           "frame-edge recovery preserves geometry jump rejection")
}

do {
    var safety = readyPolicy()
    for index in 0...200 {
        let error = 155 + index % 70
        expect(safety.control(rawX: error, rawY: -error, at: 1 + Double(index) * 0.1,
                              commandedX: true, commandedY: true) == nil,
               "moving target in central region is not killed by timer")
    }
    expect(!safety.motionPaused, "central lag never starts motor hold")
}
do {
    var safety = readyPolicy()
    _ = safety.control(rawX: 300, rawY: 0, at: 1, commandedX: true, commandedY: false)
    expect(safety.control(rawX: 410, rawY: 0, at: 3.1, commandedX: true, commandedY: false) != nil,
           "outer divergence begins motor hold")
    expect(safety.motionPaused && safety.ready, "hold preserves tracker readiness")
    _ = safety.control(rawX: 0, rawY: 0, at: 3.2, commandedX: false, commandedY: false)
    _ = safety.control(rawX: 0, rawY: 0, at: 3.3, commandedX: false, commandedY: false)
    expect(safety.motionPaused, "two centered observations cannot rearm")
    _ = safety.control(rawX: 200, rawY: 0, at: 3.4, commandedX: false, commandedY: false)
    for time in [3.5, 3.6] {
        _ = safety.control(rawX: 0, rawY: 0, at: time, commandedX: false, commandedY: false)
        expect(safety.motionPaused, "off-center sample resets centered streak")
    }
    _ = safety.control(rawX: 0, rawY: 0, at: 3.7, commandedX: false, commandedY: false)
    expect(!safety.motionPaused, "same target centered for 150 ms rearms")
    _ = safety.control(rawX: 400, rawY: 0, at: 4, commandedX: true, commandedY: false)
    _ = safety.control(rawX: 470, rawY: 0, at: 6.1, commandedX: true, commandedY: false)
    expect(safety.motionPaused, "a later divergence can hold again")
    _ = safety.control(rawX: 0, rawY: 0, at: 6.2, commandedX: false, commandedY: false)
    expect(safety.motionPaused, "second hold cannot reuse first hold center streak")
}


// Moderate-confidence motion dips from the two phone failures retain the
// established tracker; recovery inputs below are synthetic, not observed video.
for confidence: Float in [0.43239686, 0.434055, 0.2, 0.499] {
    var safety = readyPolicy()
    expect(safety.observe(rect: referenceBox, previousRect: referenceBox,
        confidence: confidence, capturedAt: 1) == nil, "established target enters confidence grace")
    expect(safety.confirmingTarget && !safety.ready, "grace cannot authorize motor motion")
    expect(!safety.confirmationExpired(at: 1.449), "grace permits less than 450 ms")
    expect(safety.confirmationExpired(at: 1.451), "grace has bounded duration")
    for index in 1...3 {
        expect(safety.observe(rect: referenceBox, previousRect: referenceBox,
            confidence: 0.6, capturedAt: 1 + Double(index) * 0.05) == nil,
            "strong recovery observation accepted")
        expect(safety.ready == (index == 3), "only third consecutive strong frame restores motion")
    }
    expect(!safety.confirmingTarget, "successful confirmation clears uncertainty")
}
do {
    var safety = readyPolicy()
    _ = safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.43, capturedAt: 1)
    for (time, confidence) in [(1.05, Float(0.9)), (1.10, 0.49), (1.15, 0.9), (1.20, 0.9)] {
        expect(safety.observe(rect: referenceBox, previousRect: referenceBox,
            confidence: confidence, capturedAt: time) == nil, "mixed recovery frames remain bounded")
        expect(!safety.ready, "weak recovery frame resets strong-frame streak")
    }
    expect(safety.observe(rect: referenceBox, previousRect: referenceBox,
        confidence: 0.9, capturedAt: 1.25) == nil && safety.ready, "fresh third strong frame recovers")
    _ = safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.43, capturedAt: 2)
    expect(safety.confirmingTarget && !safety.ready, "later dip starts a fresh grace")
    expect(safety.observe(rect: referenceBox, previousRect: referenceBox,
        confidence: 0.9, capturedAt: 2.46) == "confidence_recovery_timeout",
        "late strong result cannot escape recovery deadline")
}
// Captured handheld bottle recovery confidence pattern. The full trace is
// replayed separately; these controlled boxes isolate confidence aggregation.
do {
    var safety = readyPolicy()
    _ = safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.47760078, capturedAt: 1)
    for (index, confidence) in [Float(0.72221637), 0.55954444, 0.58386034].enumerated() {
        expect(safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: confidence,
            capturedAt: 1 + Double(index + 1) / 30) == nil, "captured usable confidence window accepted")
        expect(safety.ready == (index == 2), "aggregate recovery still needs three continuous observations")
    }
    expect(safety.ready && !safety.confirmingTarget, "mean 0.622 recovers despite individual dips below 0.6")
}
do {
    var safety = readyPolicy()
    _ = safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.43, capturedAt: 1)
    for index in 1...12 {
        _ = safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.59,
                           capturedAt: 1 + Double(index) / 30)
        expect(!safety.ready, "persistent marginal confidence cannot self-promote to reliable")
    }
    expect(safety.confirmationExpired(at: 1.451), "marginal observations cannot extend recovery deadline")
}
for weakIndex in 0..<3 {
    var safety = readyPolicy()
    _ = safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.43, capturedAt: 1)
    for index in 0..<3 {
        _ = safety.observe(rect: referenceBox, previousRect: referenceBox,
            confidence: index == weakIndex ? 0.499 : 1,
            capturedAt: 1 + Double(index + 1) / 30)
        expect(!safety.ready, "one high-confidence spike cannot average away an unusable frame")
    }
}
do {
    var safety = readyPolicy()
    _ = safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.43, capturedAt: 1)
    for (index, confidence) in [Float(0.51), 0.51, 0.51, 0.59, 0.75].enumerated() {
        _ = safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: confidence,
            capturedAt: 1 + Double(index + 1) / 30)
        expect(safety.ready == (index == 4), "only latest three usable frames decide recovery")
    }
    _ = safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.43, capturedAt: 1.3)
    _ = safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.9, capturedAt: 1.34)
    expect(!safety.ready, "later dip cannot reuse a previous recovery window")
}
for severe: Float in [0.199, .nan, .infinity] {
    var safety = readyPolicy()
    expect(safety.observe(rect: referenceBox, previousRect: referenceBox,
        confidence: severe, capturedAt: 1) == "low_confidence", "severe loss still rejects established target")
}
do {
    var safety = readyPolicy()
    _ = safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.43, capturedAt: 1)
    var previous = referenceBox
    for index in 1...5 {
        let rect = referenceBox.offsetBy(dx: Double(index) * 0.035, dy: 0)
        let reason = safety.observe(rect: rect, previousRect: previous, confidence: 0.43,
                                    capturedAt: 1 + Double(index) * 0.05)
        expect(reason == (index < 5 ? nil : "confidence_recovery_identity_jump"),
               "small per-frame drift cannot move recovery anchor indefinitely")
        previous = rect
    }
}
do {
    var safety = readyPolicy()
    _ = safety.control(rawX: 300, rawY: 0, at: 1, commandedX: true, commandedY: false)
    _ = safety.control(rawX: 410, rawY: 0, at: 3.1, commandedX: true, commandedY: false)
    expect(safety.motionPaused, "fixture has motor hold before quality loss")
    _ = safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.43, capturedAt: 4)
    for index in 1...3 {
        _ = safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.9,
                           capturedAt: 4 + Double(index) * 0.05)
    }
    expect(safety.ready && safety.motionPaused, "quality recovery cannot override a motor safety hold")
}


// Confidence recovery must follow already established target motion instead of
// treating the last reliable center as a stationary identity anchor. All
// trajectories below are controlled inputs, not inferred missing camera frames.
func movingPolicy(horizontal: Bool, sign: Double) -> (CMPhysicalObjectFollowSafety, CGRect, Double) {
    var safety = CMPhysicalObjectFollowSafety()
    let origin = CGRect(x: 0.45, y: 0.4, width: 0.068, height: 0.068)
    var previous = origin
    var time = 0.0
    for index in 0..<9 {
        time = 1 + Double(index) * 0.04
        let offset = sign * Double(index) * 0.02
        let rect = origin.offsetBy(dx: horizontal ? offset : 0, dy: horizontal ? 0 : offset)
        expect(safety.observe(rect: rect, previousRect: previous, confidence: 0.9,
            capturedAt: time) == nil, "confirmed motion seed accepted")
        previous = rect
    }
    return (safety, previous, time)
}
for horizontal in [true, false] {
    for sign in [-1.0, 1.0] {
        var (safety, anchor, time) = movingPolicy(horizontal: horizontal, sign: sign)
        var previous = anchor
        for index in 1...9 {
            let delta = sign * Double(index) * 0.02
            let rect = anchor.offsetBy(dx: horizontal ? delta : 0, dy: horizontal ? 0 : delta)
            let confidence: Float = index <= 6 ? 0.43 : 0.65
            expect(safety.observe(rect: rect, previousRect: previous, confidence: confidence,
                capturedAt: time + Double(index) * 0.04) == nil,
                "moving target stays inside motion-aware recovery window")
            expect(safety.ready == (index == 9), "moving recovery never drives on predicted/weak frames")
            previous = rect
        }
        expect(safety.ready, "three reliable frames recover same moving target")
    }
}
do {
    var (safety, anchor, time) = movingPolicy(horizontal: true, sign: -1)
    var previous = anchor
    var rejected = false
    for index in 1...9 {
        let rect = anchor.offsetBy(dx: Double(index) * 0.02, dy: 0)
        let reason = safety.observe(rect: rect, previousRect: previous, confidence: 0.43,
                                    capturedAt: time + Double(index) * 0.04)
        if let reason = reason {
            expect(reason == "confidence_recovery_identity_jump", "opposite low-confidence drift rejected")
            rejected = true
            break
        }
        previous = rect
    }
    expect(rejected && !safety.ready, "motion estimate does not allow opposite drift to drive")
}
do {
    var (safety, anchor, time) = movingPolicy(horizontal: true, sign: 1)
    let reference = safety.confidenceRecoveryReference(at: time + 1)!
    expect(abs(reference.midX - anchor.midX) <= 0.25, "predicted reference shift capped at quarter image")
    _ = safety.observe(rect: anchor, previousRect: anchor, confidence: 0.43, capturedAt: time + 0.2)
    expect(safety.confidenceRecoveryReference(at: time + 0.4) == anchor,
           "stale reliable motion estimate is cleared before confidence grace")
}

// 89AD3942: the object moved left, then decisions 892...899 contained the
// identical published HOLD box. At 233.5 ms the old policy compared that old
// box with a moving prediction and cancelled it as an identity jump. The
// recorded positions below establish motion; synthetic recovery events then
// test policy authority, not the native frozen-template matching algorithm.
let centerReturnLeadIn: [(box: CGRect, quality: Float)] = [
    (CGRect(x: 0.410055539032456, y: 0.4169408107486616,
        width: 0.10127431450160683, height: 0.24414343674494482), 0.99501157),
    (CGRect(x: 0.3975873566929934, y: 0.4177992160197087,
        width: 0.10121033039498836, height: 0.24398918934506103), 0.99030596),
    (CGRect(x: 0.3809813151141901, y: 0.4195087269880624,
        width: 0.10108841564638395, height: 0.24369528771896104), 0.98751962),
    (CGRect(x: 0.36217766569524373, y: 0.41937863145651133,
        width: 0.10119630258979527, height: 0.24395537231468484), 0.98378736),
    (CGRect(x: 0.34326843276682684, y: 0.42133625439549804,
        width: 0.10151651395973585, height: 0.2447273104386487), 0.98281497),
    (CGRect(x: 0.3206362092583293, y: 0.42028129821143057,
        width: 0.10303926166913187, height: 0.24839822009522844), 0.98409545),
    (CGRect(x: 0.2969509607305375, y: 0.41998004893460206,
        width: 0.10458485059416886, height: 0.2521241933966568), 0.97928619)
]
let centerReturnHoldOffsets = [0.033361833, 0.066723583, 0.100085250, 0.133447042,
                              0.166808792, 0.200170625, 0.233532292, 0.266894125]
do {
    var safety = CMPhysicalObjectFollowSafety()
    var previous = centerReturnLeadIn[0].box
    var lastTime = 0.0
    for (index, sample) in centerReturnLeadIn.enumerated() {
        lastTime = 1 + Double(index) * 0.03336175
        expect(safety.observe(rect: sample.box, previousRect: previous, confidence: sample.quality,
            capturedAt: lastTime) == nil, "recorded moving lead-in establishes a trusted target")
        previous = sample.box
    }
    let anchor = previous
    let heldAt = lastTime + centerReturnHoldOffsets[0]
    for offset in centerReturnHoldOffsets {
        expect(safety.observe(rect: anchor, previousRect: anchor, confidence: 0.3,
            capturedAt: lastTime + offset, isHeldObservation: true, supportsCenterRecovery: true) == nil,
            "recorded old HOLD survives without comparing its position to a velocity prediction")
        expect(safety.awaitingOriginalTargetReturn && safety.confirmingTarget && !safety.ready,
               "native-capable HOLD always remains stopped while waiting for original identity")
    }
    expect(safety.confidenceRecoveryReference(at: lastTime + 0.4) == anchor,
           "waiting for original identity exposes a frozen reference instead of a moving HOLD target")
    expect(safety.confirmationTimeoutReason(at: heldAt + 1.499) == nil &&
           safety.confirmationTimeoutReason(at: heldAt + 1.501) == "original_target_return_timeout",
           "first native HOLD owns one fixed 1.5 second absolute deadline")
    let centered = CGRect(x: 0.5 - anchor.width / 2, y: 0.5 - anchor.height / 2,
                          width: anchor.width, height: anchor.height)
    expect(abs(centered.midX - anchor.midX) > anchor.width * 0.5,
           "center-return fixture crosses the unchanged ordinary motion gate")
    expect(safety.observe(rect: centered, previousRect: anchor, confidence: 0.9,
        capturedAt: heldAt + 0.8, supportsCenterRecovery: true, recoveredOriginalTemplate: true) == nil,
        "native three-frame identity proof may rebase a centered original object once")
    expect(safety.ready && !safety.confirmingTarget && !safety.awaitingOriginalTargetReturn &&
           !safety.awaitingFrameReentry && !safety.awaitingFrameReentryMatch,
           "committed native identity proof clears all observation recovery states immediately")
    expect(safety.confidenceRecoveryReference(at: heldAt + 2) == centered &&
           safety.confirmationTimeoutReason(at: heldAt + 3) == nil,
           "committed recovery clears old clocks and velocity rather than projecting the old motion")
}

func originalReturnPolicy(_ box: CGRect = referenceBox, recoveryEnabled: Bool = false) -> CMPhysicalObjectFollowSafety {
    var safety = edgeReadyPolicy(box, recoveryEnabled: recoveryEnabled)
    expect(safety.observe(rect: box, previousRect: box, confidence: 0.3, capturedAt: 1,
        isHeldObservation: true, supportsCenterRecovery: true) == nil,
        "confirmed native selection enters original-target return wait")
    expect(safety.awaitingOriginalTargetReturn && !safety.ready,
           "original-target wait never has motor authority")
    return safety
}
let recoveredCenterBox = CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)
do {
    var safety = originalReturnPolicy()
    for time in [1.2, 1.4, 1.6, 1.8, 2.0, 2.2, 2.4, 2.49] {
        expect(safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.3,
            capturedAt: time, isHeldObservation: true, supportsCenterRecovery: true) == nil,
            "repeated old HOLD frames consume the existing return window")
        expect(!safety.ready, "repeated HOLD cannot count as original-target proof")
    }
    expect(safety.confirmationTimeoutReason(at: 2.5) == "original_target_return_timeout",
           "continued native HOLD does not renew the 1.5 second deadline")
    expect(safety.observe(rect: recoveredCenterBox, previousRect: referenceBox, confidence: 1,
        capturedAt: 2.5, supportsCenterRecovery: true, recoveredOriginalTemplate: true)
        == "original_target_return_timeout", "even a tagged strong return cannot revive an expired original-target window")
}
do {
    var (safety, anchor, time) = movingPolicy(horizontal: true, sign: -1)
    for index in 1...8 {
        expect(safety.observe(rect: anchor, previousRect: anchor, confidence: 0.3,
            capturedAt: time + Double(index) * 0.04, isHeldObservation: true) == nil,
            "non-recoverable HOLD still avoids false spatial evidence during the ordinary short window")
        expect(!safety.awaitingOriginalTargetReturn && !safety.ready,
               "a route without native recovery cannot obtain the longer return wait")
    }
    expect(safety.confirmationTimeoutReason(at: time + 0.491) == "confidence_recovery_timeout",
           "ordinary non-recoverable HOLD retains the original 450 ms timeout")
}
do {
    var safety = edgeReadyPolicy()
    _ = safety.observe(rect: partialEdgeBox, previousRect: partialEdgeSeed, confidence: 0.9, capturedAt: 1)
    expect(safety.observe(rect: partialEdgeBox, previousRect: partialEdgeBox, confidence: 0.3,
        capturedAt: 1.2, isHeldObservation: true, supportsCenterRecovery: true) == nil,
        "native HOLD may wait inside an existing edge episode")
    expect(safety.awaitingFrameReentry && safety.awaitingOriginalTargetReturn && !safety.ready,
           "both edge and original identity boundaries remain active")
    expect(safety.confirmationTimeoutReason(at: 2.5) == "frame_reentry_timeout",
           "earlier edge deadline still caps the later original-target window")
    let returned = CGRect(x: 0.45, y: 0.4, width: 0.1, height: 0.2)
    expect(safety.observe(rect: returned, previousRect: partialEdgeBox, confidence: 0.95,
        capturedAt: 2.5, supportsCenterRecovery: true, recoveredOriginalTemplate: true)
        == "frame_reentry_timeout", "native proof cannot override an already expired edge episode")
}
do {
    var safety = edgeReadyPolicy()
    _ = safety.observe(rect: partialEdgeBox, previousRect: partialEdgeSeed, confidence: 0.9, capturedAt: 1)
    _ = safety.observe(rect: partialEdgeBox, previousRect: partialEdgeBox, confidence: 0.3,
        capturedAt: 1.2, isHeldObservation: true, supportsCenterRecovery: true)
    let returned = CGRect(x: 0.45, y: 0.4, width: 0.1, height: 0.2)
    expect(safety.observe(rect: returned, previousRect: partialEdgeBox, confidence: 0.95,
        capturedAt: 1.8, supportsCenterRecovery: true, recoveredOriginalTemplate: true) == nil,
        "verified central return accepts an authorized partial previous box before the edge deadline")
    expect(safety.ready && !safety.awaitingFrameReentry && !safety.awaitingOriginalTargetReturn &&
           safety.confirmationTimeoutReason(at: 4) == nil, "verified return atomically clears edge and original-target clocks")
}
// A capability flag is not match evidence, and a committed-native tag is not
// permission to bypass required state, confidence, geometry, or deadline.
do {
    var safety = readyPolicy()
    expect(safety.observe(rect: recoveredCenterBox, previousRect: referenceBox, confidence: 0.99,
        capturedAt: 1, supportsCenterRecovery: true, recoveredOriginalTemplate: true) != nil,
        "tag outside an active original-target wait is rejected")
}
do {
    var safety = CMPhysicalObjectFollowSafety()
    expect(safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.3,
        capturedAt: 1, isHeldObservation: true, supportsCenterRecovery: true) != nil &&
        !safety.awaitingOriginalTargetReturn, "unconfirmed target cannot start native identity recovery")
}
for quality: Float in [0.3, 0.5, 0.8999, .nan, .infinity] {
    var safety = originalReturnPolicy()
    expect(safety.observe(rect: recoveredCenterBox, previousRect: referenceBox, confidence: quality,
        capturedAt: 1.2, supportsCenterRecovery: true, recoveredOriginalTemplate: true) != nil && !safety.ready,
        "original-template tag cannot promote weak or nonfinite evidence")
}
do {
    var safety = originalReturnPolicy()
    expect(safety.observe(rect: recoveredCenterBox, previousRect: referenceBox, confidence: 1,
        capturedAt: 1.2, recoveredOriginalTemplate: true) != nil && !safety.ready,
        "a route that does not support native recovery cannot use the tag")
}
for quality: Float in [0.3, 1] {
    var safety = originalReturnPolicy()
    expect(safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: quality,
        capturedAt: 1.2, isHeldObservation: true, supportsCenterRecovery: true,
        recoveredOriginalTemplate: true) != nil && !safety.ready,
        "HOLD and current-frame original-template proof are mutually exclusive")
}
for (box, quality) in [(referenceBox.offsetBy(dx: 0.001, dy: 0), Float(0.3)),
                       (referenceBox, Float(0.5)), (referenceBox, Float(1))] {
    var safety = readyPolicy()
    expect(safety.observe(rect: box, previousRect: referenceBox, confidence: quality,
        capturedAt: 1, isHeldObservation: true, supportsCenterRecovery: true) != nil &&
        !safety.awaitingOriginalTargetReturn, "HOLD must exactly retain its previous box and carry unusable quality")
}
for invalid in [CGRect.zero, CGRect(x: CGFloat.nan, y: 0.45, width: 0.1, height: 0.1),
    CGRect(x: 0.45, y: 0.45, width: CGFloat.infinity, height: 0.1),
    CGRect(x: 0.55, y: 0.45, width: -0.1, height: 0.1),
    CGRect(x: 1.1, y: 0.45, width: 0.1, height: 0.1),
    CGRect(x: 0.1999, y: 0.45, width: 0.1, height: 0.1),
    CGRect(x: 0.7001, y: 0.45, width: 0.1, height: 0.1),
    CGRect(x: 0.45, y: 0.1999, width: 0.1, height: 0.1),
    CGRect(x: 0.45, y: 0.7001, width: 0.1, height: 0.1),
    CGRect(x: 0.39, y: 0.45, width: 0.22, height: 0.1),
    CGRect(x: 0.48, y: 0.45, width: 0.04, height: 0.1)] {
    var safety = originalReturnPolicy()
    expect(safety.observe(rect: invalid, previousRect: referenceBox, confidence: 0.99,
        capturedAt: 1.2, supportsCenterRecovery: true, recoveredOriginalTemplate: true) != nil && !safety.ready,
        "tag cannot bypass finite positive geometry, central position, or frozen identity scale bounds")
}
do {
    let wideAnchor = CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.1)
    var safety = originalReturnPolicy(wideAnchor)
    let tooHidden = CGRect(x: -0.15, y: 0.45, width: 0.8, height: 0.1)
    expect(safety.observe(rect: tooHidden, previousRect: wideAnchor, confidence: 0.99,
        capturedAt: 1.2, supportsCenterRecovery: true, recoveredOriginalTemplate: true) != nil && !safety.ready,
        "central candidate at valid two-times area still needs at least 85 percent visible")
}
for midpoint in [CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.75, y: 0.5),
                 CGPoint(x: 0.5, y: 0.25), CGPoint(x: 0.5, y: 0.75)] {
    var safety = originalReturnPolicy()
    let box = CGRect(x: midpoint.x - 0.05, y: midpoint.y - 0.05, width: 0.1, height: 0.1)
    expect(safety.observe(rect: box, previousRect: referenceBox, confidence: 0.9,
        capturedAt: 1.2, supportsCenterRecovery: true, recoveredOriginalTemplate: true) == nil && safety.ready,
        "exact central-region and native-score boundaries accept verified original identity")
}
do {
    let farAnchor = CGRect(x: 0.05, y: 0.45, width: 0.1, height: 0.1)
    var safety = originalReturnPolicy(farAnchor)
    expect(safety.observe(rect: recoveredCenterBox, previousRect: farAnchor, confidence: 0.99,
        capturedAt: 1.2, supportsCenterRecovery: true) == "box_position_jump",
        "capability alone cannot bypass ordinary motion limits without original-template proof")
}
do {
    var safety = readyPolicy()
    _ = safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.43, capturedAt: 1)
    expect(safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.3,
        capturedAt: 1.451, isHeldObservation: true, supportsCenterRecovery: true) == "confidence_recovery_timeout" &&
        !safety.awaitingOriginalTargetReturn, "already-expired ordinary recovery cannot acquire a new native deadline")
}

// Persistent original-identity search is an explicit opt-in; a deadline ends
// short positional confirmation without giving up the confirmed target anchor.
func searchingPolicy(_ box: CGRect = referenceBox) -> CMPhysicalObjectFollowSafety {
    var safety = originalReturnPolicy(box, recoveryEnabled: true)
    expect(safety.handleConfirmationTimeout(at: 2.5) == nil && safety.searchingOriginalTarget,
           "opted_in_original_return_deadline_enters_persistent_search")
    expect(safety.confirmingTarget && !safety.ready && safety.heldX && safety.heldY,
           "persistent_search_has_no_motor_authority")
    return safety
}
do {
    var legacy = originalReturnPolicy()
    expect(legacy.handleConfirmationTimeout(at: 2.5) == "original_target_return_timeout"
        && !legacy.searchingOriginalTarget && !legacy.ready,
           "default_policy_retains_legacy_terminal_timeout")
    var enabled = originalReturnPolicy(recoveryEnabled: true)
    expect(enabled.handleConfirmationTimeout(at: 2.499) == nil && !enabled.searchingOriginalTarget,
           "opt_in_does_not_enter_search_before_absolute_short_deadline")
    expect(enabled.handleConfirmationTimeout(at: 2.5) == nil && enabled.searchingOriginalTarget,
           "timer_transitions_at_original_deadline_without_renewing_it")
    expect(!enabled.awaitingOriginalTargetReturn && !enabled.awaitingFrameReentry && !enabled.awaitingFrameReentryMatch,
           "search_replaces_expired_short_confirmation_states")
}
do {
    var safety = originalReturnPolicy(recoveryEnabled: true)
    let ordinaryJump = CGRect(x: 0.75, y: 0.05, width: 0.2, height: 0.4)
    expect(safety.observe(rect: ordinaryJump, previousRect: referenceBox, confidence: 1,
        capturedAt: 2.5) == nil && safety.searchingOriginalTarget && !safety.ready,
           "capture_observation_transitions_to_search_before_stale_geometry_can_end_identity")
    expect(safety.confidenceRecoveryReference(at: 100) == referenceBox,
           "ordinary_jump_after_deadline_cannot_replace_original_search_anchor")
}
do {
    var safety = readyPolicy(recoveryEnabled: true)
    _ = safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.43, capturedAt: 1)
    expect(safety.handleConfirmationTimeout(at: 1.451) == nil && safety.searchingOriginalTarget,
           "opted_in_ordinary_confidence_deadline_also_retains_confirmed_identity")
}
for nestedWeak in [false, true] {
    var safety = edgeReadyPolicy(recoveryEnabled: true)
    _ = safety.observe(rect: partialEdgeBox, previousRect: partialEdgeSeed, confidence: 0.9, capturedAt: 1)
    if nestedWeak {
        _ = safety.observe(rect: partialEdgeBox, previousRect: partialEdgeBox, confidence: 0.3,
            capturedAt: 1.1, isHeldObservation: true)
    }
    expect(safety.handleConfirmationTimeout(at: nestedWeak ? 1.551 : 2.5) == nil && safety.searchingOriginalTarget,
           "edge_or_nested_weak_deadline_enters_persistent_search_\(nestedWeak)")
    expect(safety.confidenceRecoveryReference(at: 100) == partialEdgeSeed,
           "partially_visible_last_observation_never_becomes_search_anchor")
    expect(safety.observe(rect: recoveredCenterBox, previousRect: partialEdgeBox, confidence: 0.95,
        capturedAt: 100, recoveredVerifiedIdentity: true) == nil && safety.ready,
           "verified_return_does_not_require_old_partial_frame_to_be_fully_visible")
}
do {
    var safety = CMPhysicalObjectFollowSafety(recoveryEnabled: true)
    expect(safety.handleConfirmationTimeout(at: 100) == nil && !safety.searchingOriginalTarget,
           "unconfirmed_selection_has_no_identity_to_keep_searching")
    expect(safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.3,
        capturedAt: 1, isHeldObservation: true, supportsCenterRecovery: true) == "low_confidence",
           "unconfirmed_native_hold_cannot_create_search_identity")
    expect(safety.observe(rect: recoveredCenterBox, previousRect: referenceBox, confidence: 1,
        capturedAt: 2, recoveredVerifiedIdentity: true) == "invalid_verified_identity_recovery" && !safety.ready,
           "verified_identity_tag_cannot_create_a_target_without_an_active_search")
}
for enabled in [false, true] {
    var safety = readyPolicy(recoveryEnabled: enabled)
    expect(safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.99,
        capturedAt: 1, recoveredVerifiedIdentity: true) == "invalid_verified_identity_recovery",
           "new_identity_tag_is_never_a_normal_following_shortcut_\(enabled)")
}
do {
    var safety = searchingPolicy()
    for (index, time) in [3.0, 10, 60, 3600].enumerated() {
        let box = index % 2 == 0 ? CGRect(x: 0.05, y: 0.1, width: 0.7, height: 0.7) : CGRect.zero
        expect(safety.observe(rect: box, previousRect: box, confidence: index % 2 == 0 ? 1 : 0,
            capturedAt: time, isHeldObservation: index % 2 != 0, supportsCenterRecovery: true) == nil,
               "unverified_or_missing_search_candidate_keeps_waiting_\(time)")
        expect(safety.searchingOriginalTarget && !safety.ready && safety.confirmingTarget
            && safety.confidenceRecoveryReference(at: time + 1000) == referenceBox,
               "arbitrarily_late_ordinary_candidate_never_renews_anchor_or_motor_authority_\(time)")
        expect(safety.handleConfirmationTimeout(at: time) == nil && safety.confirmationTimeoutReason(at: time) == nil,
               "persistent_search_has_no_repeating_terminal_deadline_\(time)")
        expect(safety.control(rawX: 900, rawY: -900, at: time, commandedX: true, commandedY: true) == nil
            && safety.heldX && safety.heldY && !safety.motionPaused,
               "stale_control_demand_cannot_accumulate_progress_or_release_search_axes_\(time)")
    }
    let depthChanged = CGRect(x: 0.7, y: 0.1, width: 0.25, height: 0.4)
    expect(safety.observe(rect: depthChanged, previousRect: CGRect(x: -10, y: -10, width: 0.1, height: 0.1),
        confidence: 0.95, capturedAt: 3601, recoveredVerifiedIdentity: true) == nil && safety.ready
        && !safety.searchingOriginalTarget && !safety.confirmingTarget,
           "complete_verified_identity_can_recover_after_an_hour_and_large_depth_change")
    expect(safety.confidenceRecoveryReference(at: 4000) == depthChanged && safety.heldX && safety.heldY,
           "successful_full_identity_recovery_rebases_anchor_and_clears_velocity")
}

let validVerifiedBoxes = [CGRect(x: 0, y: 0, width: 1, height: 1),
    CGRect(x: 0.005, y: 0.7, width: 0.01, height: 0.02),
    CGRect(x: 0.9, y: 0.1, width: 0.05, height: 0.05),
    CGRect(x: 0.4, y: 0.4, width: 0.002, height: 0.002),
    CGRect(x: -0.03, y: 0.3, width: 0.2, height: 0.2),
    CGRect(x: 0.83, y: 0.3, width: 0.2, height: 0.2),
    CGRect(x: 0.3, y: -0.03, width: 0.2, height: 0.2),
    CGRect(x: 0.3, y: 0.83, width: 0.2, height: 0.2)]
for box in validVerifiedBoxes {
    var safety = searchingPolicy()
    expect(safety.observe(rect: box, previousRect: referenceBox, confidence: 0.9,
        capturedAt: 10, recoveredVerifiedIdentity: true) == nil && safety.ready,
           "verified_identity_accepts_full_frame_location_normalized_size_and_exact_visibility_boundaries_\(box)")
}
let invalidVerifiedBoxes = [CGRect.zero,
    CGRect(x: 0.4, y: 0.4, width: 0.0019, height: 0.1),
    CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.0019),
    CGRect(x: 0, y: 0, width: 1.0001, height: 0.2),
    CGRect(x: 0, y: 0, width: 0.2, height: 1.0001),
    CGRect(x: 0.6, y: 0.4, width: -0.1, height: 0.1),
    CGRect(x: 0.4, y: 0.6, width: 0.1, height: -0.1),
    CGRect(x: -0.03001, y: 0.3, width: 0.2, height: 0.2),
    CGRect(x: 0.83001, y: 0.3, width: 0.2, height: 0.2),
    CGRect(x: -0.3, y: 0.3, width: 0.2, height: 0.2),
    CGRect(x: .nan, y: 0.4, width: 0.1, height: 0.1),
    CGRect(x: 0.4, y: .infinity, width: 0.1, height: 0.1)]
for box in invalidVerifiedBoxes {
    var safety = searchingPolicy()
    expect(safety.observe(rect: box, previousRect: referenceBox, confidence: 1,
        capturedAt: 10, recoveredVerifiedIdentity: true) == "invalid_verified_identity_recovery"
        && safety.searchingOriginalTarget && !safety.ready,
           "invalid_full_identity_geometry_is_rejected_without_ending_search_\(box)")
    expect(safety.confidenceRecoveryReference(at: 100) == referenceBox,
           "rejected_geometry_never_poisons_original_anchor")
}
for quality: Float in [0, 0.899, .nan, .infinity, -.infinity] {
    var safety = searchingPolicy()
    expect(safety.observe(rect: recoveredCenterBox, previousRect: referenceBox, confidence: quality,
        capturedAt: 10, recoveredVerifiedIdentity: true) == "invalid_verified_identity_recovery"
        && safety.searchingOriginalTarget && !safety.ready,
           "weak_or_nonfinite_verified_identity_candidate_keeps_searching_\(quality)")
}
for held in [false, true] {
    var safety = searchingPolicy()
    expect(safety.observe(rect: recoveredCenterBox, previousRect: referenceBox, confidence: 0.95,
        capturedAt: 10, isHeldObservation: held, supportsCenterRecovery: true,
        recoveredOriginalTemplate: !held, recoveredVerifiedIdentity: true) == "invalid_verified_identity_recovery",
           "conflicting_identity_tags_or_held_identity_claim_cannot_resume_\(held)")
}
for time: TimeInterval in [1, 0.9, .nan, .infinity, -.infinity] {
    var safety = searchingPolicy()
    expect(safety.observe(rect: recoveredCenterBox, previousRect: referenceBox, confidence: 0.95,
        capturedAt: time, recoveredVerifiedIdentity: true) == "nonmonotonic_frame" && safety.searchingOriginalTarget,
           "search_rejects_duplicate_old_or_nonfinite_frame_token_\(time)")
    expect(safety.observe(rect: recoveredCenterBox, previousRect: referenceBox, confidence: 0.95,
        capturedAt: 3, recoveredVerifiedIdentity: true) == nil && safety.ready,
           "rejected_frame_token_does_not_poison_next_fresh_verified_return")
}
do {
    var safety = searchingPolicy()
    expect(safety.observe(rect: recoveredCenterBox, previousRect: referenceBox, confidence: 0.4,
        capturedAt: 10, recoveredVerifiedIdentity: true) == "invalid_verified_identity_recovery",
           "invalid_candidate_is_not_accepted_as_current_identity")
    expect(safety.observe(rect: recoveredCenterBox, previousRect: referenceBox, confidence: 0.95,
        capturedAt: 10, recoveredVerifiedIdentity: true) == "nonmonotonic_frame",
           "replaying_rejected_candidate_with_higher_score_does_not_reuse_same_frame")
    expect(safety.observe(rect: recoveredCenterBox, previousRect: referenceBox, confidence: 0.95,
        capturedAt: 10.01, recoveredVerifiedIdentity: true) == nil && safety.ready,
           "a_new_valid_candidate_can_recover_after_rejected_candidate")
}
do {
    var safety = searchingPolicy()
    expect(safety.observe(rect: recoveredCenterBox, previousRect: CGRect.zero, confidence: 0.9,
        capturedAt: 10, supportsCenterRecovery: true, recoveredOriginalTemplate: true) == nil && safety.ready,
           "legacy_center_template_proof_can_recover_past_old_deadline_using_preserved_anchor")
}
for (box, supported) in [(CGRect(x: 0.8, y: 0.4, width: 0.1, height: 0.1), true),
                         (CGRect(x: 0.4, y: 0.4, width: 0.3, height: 0.3), true),
                         (CGRect(x: 0.49, y: 0.49, width: 0.02, height: 0.02), true),
                         (recoveredCenterBox, false)] {
    var safety = searchingPolicy()
    expect(safety.observe(rect: box, previousRect: referenceBox, confidence: 0.95,
        capturedAt: 10, supportsCenterRecovery: supported, recoveredOriginalTemplate: true)
        == "invalid_original_target_recovery" && safety.searchingOriginalTarget && !safety.ready,
           "old_template_tag_keeps_its_center_scale_and_capability_limits_\(box)_\(supported)")
}
do {
    var safety = readyPolicy(recoveryEnabled: true)
    _ = safety.control(rawX: 450, rawY: -450, at: 1, commandedX: true, commandedY: true)
    expect(safety.control(rawX: 450, rawY: -450, at: 5.01, commandedX: true, commandedY: true) != nil
        && safety.motionPaused, "search_reset_fixture_has_a_real_prior_stall")
    _ = safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.3, capturedAt: 6,
        isHeldObservation: true, supportsCenterRecovery: true)
    _ = safety.handleConfirmationTimeout(at: 7.5)
    expect(safety.searchingOriginalTarget && !safety.motionPaused && safety.heldX && safety.heldY,
           "entering_persistent_search_resets_stall_and_axis_baseline")
    let changed = CGRect(x: 0.6, y: 0.2, width: 0.3, height: 0.3)
    expect(safety.observe(rect: changed, previousRect: referenceBox, confidence: 0.95,
        capturedAt: 20, recoveredVerifiedIdentity: true) == nil && safety.ready
        && !safety.motionPaused && safety.heldX && safety.heldY,
           "verified_recovery_restores_current_measurement_with_fresh_control_baseline")
    expect(safety.control(rawX: 450, rawY: -450, at: 20.01, commandedX: true, commandedY: true) == nil
        && safety.control(rawX: 450, rawY: -450, at: 21, commandedX: true, commandedY: true) == nil,
           "old_progress_timers_do_not_immediately_repause_recovered_identity")
}

do {
    var disabled = readyPolicy()
    expect(!disabled.beginOriginalTargetSearch() && !disabled.searchingOriginalTarget && disabled.ready,
           "explicit_search_entry_is_disabled_by_default")
    var unconfirmed = CMPhysicalObjectFollowSafety(recoveryEnabled: true)
    expect(!unconfirmed.beginOriginalTargetSearch() && !unconfirmed.searchingOriginalTarget,
           "explicit_search_entry_requires_a_confirmed_original_anchor")
    _ = unconfirmed.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.99, capturedAt: 1)
    _ = unconfirmed.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.99, capturedAt: 2)
    expect(!unconfirmed.beginOriginalTargetSearch(), "two_unconfirmed_frames_cannot_start_original_identity_search")
    var ready = readyPolicy(recoveryEnabled: true)
    _ = ready.control(rawX: 450, rawY: -450, at: 1, commandedX: true, commandedY: true)
    expect(ready.beginOriginalTargetSearch() && ready.searchingOriginalTarget && !ready.ready
        && ready.confirmingTarget && ready.heldX && ready.heldY,
           "explicit_visual_loss_enters_stopped_search_immediately_without_waiting_for_timeout")
    for _ in 0..<3 {
        expect(!ready.beginOriginalTargetSearch() && ready.searchingOriginalTarget && !ready.ready
            && ready.confidenceRecoveryReference(at: 100) == referenceBox,
               "repeated_explicit_search_entry_is_idempotent_and_keeps_original_anchor")
    }
    expect(ready.observe(rect: recoveredCenterBox, previousRect: referenceBox, confidence: 0.95,
        capturedAt: 0.4, recoveredVerifiedIdentity: true) == nil && ready.ready,
           "immediate_search_can_accept_verified_identity_before_old_short_window_would_expire")
}

// Existing parts get one bounded local-recovery opportunity. This read-only
// query cannot authorize movement or create a search without the outer caller.
do {
    var unconfirmed = CMPhysicalObjectFollowSafety(recoveryEnabled: true)
    expect(!unconfirmed.partRecoverySearchDue(at: 100), "part_grace_requires_an_existing_missing_match_clock")
    _ = unconfirmed.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.3,
        capturedAt: 0.5, isHeldObservation: true)
    expect(!unconfirmed.partRecoverySearchDue(at: 100), "unconfirmed_held_box_does_not_start_part_grace")
    let ready = readyPolicy(recoveryEnabled: true)
    expect(!ready.partRecoverySearchDue(at: 100), "confirmed_tracking_without_loss_does_not_start_part_grace")
}
for nativeHold in [false, true] {
    var safety = readyPolicy(recoveryEnabled: true)
    let heldAt = 0.5
    expect(safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.3,
        capturedAt: heldAt, isHeldObservation: true, supportsCenterRecovery: nativeHold) == nil,
           "part_grace_fixture_enters_waiting_\(nativeHold)")
    for time in [heldAt - 1, heldAt, heldAt + 0.119999] {
        expect(!safety.partRecoverySearchDue(at: time), "part_grace_does_not_expire_early_\(nativeHold)_\(time)")
    }
    expect(safety.partRecoverySearchDue(at: heldAt + 0.12), "part_grace_exact_120ms_boundary_\(nativeHold)")
    expect(safety.partRecoverySearchDue(at: heldAt + 0.121), "part_grace_after_boundary_\(nativeHold)")
    for time: TimeInterval in [.nan, .infinity, -.infinity] {
        expect(!safety.partRecoverySearchDue(at: time), "part_grace_nonfinite_query_rejected_\(nativeHold)")
    }
    _ = safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.3,
        capturedAt: heldAt + 0.1, isHeldObservation: true, supportsCenterRecovery: true)
    expect(safety.awaitingOriginalTargetReturn && safety.partRecoverySearchDue(at: heldAt + 0.12),
           "repeated_or_upgraded_hold_keeps_earliest_part_grace_clock_\(nativeHold)")
    expect(!safety.searchingOriginalTarget && !safety.ready,
           "part_grace_query_does_not_mutate_authority_\(nativeHold)")
    expect(safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.95,
        capturedAt: heldAt + 0.13, supportsCenterRecovery: true, recoveredOriginalTemplate: true) == nil
        && safety.ready && !safety.partRecoverySearchDue(at: 100),
           "local_original_template_recovery_clears_part_grace_\(nativeHold)")
}
do {
    var safety = edgeReadyPolicy(recoveryEnabled: true)
    expect(safety.observe(rect: partialEdgeBox, previousRect: partialEdgeSeed, confidence: 0.9,
        capturedAt: 0.5) == nil && safety.awaitingFrameReentry,
           "part_grace_edge_fixture_waits_while_strong")
    expect(!safety.partRecoverySearchDue(at: 0.9), "strong_partial_edge_alone_is_not_a_missing_part_match")
    expect(safety.observe(rect: partialEdgeBox, previousRect: partialEdgeBox, confidence: 0.3,
        capturedAt: 1, isHeldObservation: true) == nil && safety.awaitingFrameReentryMatch,
           "weak_edge_frame_starts_part_grace")
    expect(!safety.partRecoverySearchDue(at: 1.119999) && safety.partRecoverySearchDue(at: 1.12),
           "weak_edge_uses_its_own_120ms_clock_instead_of_earlier_strong_edge_clock")
    _ = safety.observe(rect: partialEdgeBox, previousRect: partialEdgeBox, confidence: 0.3,
        capturedAt: 1.1, isHeldObservation: true, supportsCenterRecovery: true)
    expect(safety.awaitingOriginalTargetReturn && safety.partRecoverySearchDue(at: 1.12),
           "edge_to_native_hold_keeps_earliest_weak_clock")
}
do {
    var safety = readyPolicy(recoveryEnabled: true)
    expect(safety.beginOriginalTargetSearch() && safety.partRecoverySearchDue(at: 0.4)
        && safety.partRecoverySearchDue(at: 3600), "already_searching_never_restarts_local_part_grace")
    for time: TimeInterval in [.nan, .infinity, -.infinity] {
        expect(!safety.partRecoverySearchDue(at: time), "search_state_still_requires_a_finite_query_time")
    }
    expect(safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.95,
        capturedAt: 0.4, recoveredVerifiedIdentity: true) == nil && safety.ready
        && !safety.partRecoverySearchDue(at: 100), "verified_search_recovery_clears_part_grace_state")
}

do {
    var legacy = readyPolicy()
    expect(!legacy.beginProcessingGapHold(at: 1) && legacy.ready,
           "pipeline_gap_opt_in_does_not_change_default_policy")
    var empty = CMPhysicalObjectFollowSafety(recoveryEnabled: true)
    expect(!empty.beginProcessingGapHold(at: 1), "pipeline_gap_cannot_invent_an_anchor")
    var safety = readyPolicy(recoveryEnabled: true)
    for time: TimeInterval in [.nan, .infinity, -.infinity] {
        expect(!safety.beginProcessingGapHold(at: time) && safety.ready, "pipeline_gap_rejects_nonfinite_start")
    }
    expect(safety.beginProcessingGapHold(at: 1) && !safety.ready && safety.confirmingTarget
        && !safety.searchingOriginalTarget && safety.heldX && safety.heldY,
           "pipeline_gap_stops_axes_and_keeps_local_identity")
    expect(!safety.beginProcessingGapHold(at: 1.2)
        && safety.confirmationTimeoutReason(at: 1.451) == "confidence_recovery_timeout",
           "repeated_pipeline_gap_cannot_extend_original_confirmation_deadline")
    for time in [0.8, 0.9, 0.99] {
        expect(safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.99,
            capturedAt: time) == nil && !safety.ready,
               "queued_pre_gap_frames_never_count_toward_resumption_\(time)")
    }
    for index in 0..<3 {
        expect(safety.observe(rect: referenceBox, previousRect: referenceBox, confidence: 0.95,
            capturedAt: 1 + Double(index) * 0.03) == nil && safety.ready == (index == 2),
               "three_distinct_post_gap_local_frames_resume_without_global_search_\(index)")
    }
    expect(!safety.searchingOriginalTarget && safety.confidenceRecoveryReference(at: 1.2) == referenceBox,
           "pipeline_recovery_preserves_current_original_anchor")
    expect(safety.beginProcessingGapHold(at: 2), "later_processing_gap_gets_new_bounded_hold")
    expect(safety.handleConfirmationTimeout(at: 2.451) == nil && safety.searchingOriginalTarget,
           "persistent_processing_gap_eventually_searches_without_driving")
}

print("PhysicalObjectFollowSafetySmoke: \(assertions) assertions, \(failures) failures")
print("Scope: production policy decisions only; no new camera, Vision, BLE, or physical gimbal measurements.")
if failures > 0 { exit(1) }
