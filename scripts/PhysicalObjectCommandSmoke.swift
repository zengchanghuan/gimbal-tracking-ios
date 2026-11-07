import Foundation
import CoreGraphics

// INSERT_POLICY

enum TrackingState: UInt8 { case normal = 1, exit = 4 }
enum CaptureMode { case photo, hitchcock }
enum HitchcockState { case idle, recording }
enum LensType { case front, back }
enum CMTrackingYawRestrictionPhase { case monitoring, paused, probing }
struct PhysicalObjectTrackingWriteContext {}
final class PreviewLayer { var bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000) }
final class CameraDevice { var videoZoomFactor: CGFloat = 1 }
final class CameraInput { var device = CameraDevice() }
final class Gesture { var isEnabled = true }
func kkLog(_ text: String) {}

// Boundary spy: receives controller arguments, not protocol bytes. Hardware
// effects and delivery are intentionally absent. Updating send time emulates
// the observable transport cadence consumed by the production controller.
final class ProtocolParser {
    static let shared = ProtocolParser()
    struct Write { let x: Int; let y: Int; let state: UInt8; let front: Bool; let scale: Int }
    var writes: [Write] = []
    var lastTrackingSendTime: Int64 = 0
    func reset() { writes = []; lastTrackingSendTime = 0 }
    func setTracking(centerX: Int, centerY: Int, state: UInt8, isFront: Bool,
                     scale: Int = 3, physicalObjectContext: PhysicalObjectTrackingWriteContext? = nil) {
        writes.append(Write(x: centerX, y: centerY, state: state, front: isFront, scale: scale))
        lastTrackingSendTime = Int64(Date().timeIntervalSince1970 * 1000)
    }
}
final class KKBLEManager {
    static let shared = KKBLEManager()
    var isCommandChannelReady = true
}
final class CameraManager {
    var previewLayer: PreviewLayer? = PreviewLayer()
    var videoInput: CameraInput? = CameraInput()
    var zoomScale: CGFloat = 1
    var isUsingWideCamera = false
    var lensType = LensType.back
    var captureMode = CaptureMode.photo
    var hitchcockState = HitchcockState.idle
    var isFaceTrackingMode = false
    var lastDetectedFaceRect: CGRect?
    var trackingHumanFallbackCenterX: CGFloat?
    var isPhysicalObjectTrackingActive = true
    var physicalObjectIsFollowing = true
    var physicalObjectIsDrawingSelection = false
    var physicalObjectNeedsReselection = false
    var physicalObjectAutoRecoveryEnabled = false
    var physicalObjectLastPositionAt: TimeInterval = 0
    var physicalObjectLastCameraFrameAt: TimeInterval = 0
    var physicalObjectLastResultConsumedAt: TimeInterval = 0
    var physicalObjectFollowSafety = CMPhysicalObjectFollowSafety()
    var trackingStartPoint: CGPoint?
    var trackingPanGesture = Gesture()
    func savePhysicalObjectFollowRecording(reason: String) {}
    var releaseCount = 0
    var clearCount = 0
    var renderCount = 0
    var searchBeginCalls = 0
    var autoSelectionResetCount = 0
    var restrictionChanges: [Bool] = []
    // UI/Vision lifetime boundary doubles; the production pause method calls them.
    func releaseCurrentObjectTrackingRequest() { releaseCount += 1 }
    func clearTrackingLayer() { clearCount += 1 }
    func renderPhysicalObjectDiscovery() { renderCount += 1 }
    // The search-entry helper's real exit/UI/request behavior is exercised by
    // ObjectSelectionHandoffSmoke; this fixture spies only on that boundary.
    func physicalObjectRecoverySearchDidBegin(reason: String = "confirmation_timeout") { searchBeginCalls += 1 }
    func resetAutoTrackingTargetSelection() { autoSelectionResetCount += 1 }
    func postTrackingYawRestrictionChanged(isRestricted: Bool) { restrictionChanges.append(isRestricted) }

    // INSERT_FIELDS
    // INSERT_METHODS
}

var assertions = 0
var failures = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    if !condition() { failures += 1; print("FAIL: \(message)") }
}
func point(rawX: Int, rawY: Int) -> CGPoint {
    CGPoint(x: Double(rawX + 1000) / 2, y: Double(rawY + 1000) / 2)
}
func fixture(ready: Bool = true, physical: Bool = true) -> CameraManager {
    ProtocolParser.shared.reset()
    KKBLEManager.shared.isCommandChannelReady = true
    let camera = CameraManager()
    camera.isPhysicalObjectTrackingActive = physical
    camera.latestHorizontalRotationRate = 0.1
    camera.latestHorizontalRotationSampleUptime = ProcessInfo.processInfo.systemUptime
    if ready {
        let box = CGRect(x: 0.3, y: 0.3, width: 0.1, height: 0.1)
        for index in 1...3 {
            expect(camera.physicalObjectFollowSafety.observe(rect: box, previousRect: box,
                   confidence: 0.9, capturedAt: Double(index)) == nil, "fixture accepts reliable frame")
        }
        expect(camera.physicalObjectFollowSafety.ready, "fixture ready after three observations")
    }
    return camera
}
func tick(_ camera: CameraManager, _ rawX: Int, _ rawY: Int, wait: Bool = true) {
    if wait { Thread.sleep(forTimeInterval: 0.065) }
    camera.sendTrackingCommand(state: .normal, centerPoint: point(rawX: rawX, rawY: rawY))
}

do {
    let camera = fixture(ready: false)
    tick(camera, 400, 400, wait: false)
    expect(ProtocolParser.shared.writes.isEmpty, "unready physical selection emits no normal command")
    expect(camera.lastSentState == -1, "unready call does not alter prior command state")
}

do {
    let camera = fixture()
    KKBLEManager.shared.isCommandChannelReady = false
    for _ in 0..<5 {
        camera.sendTrackingCommand(state: .normal, centerPoint: point(rawX: -350, rawY: 300))
        ProtocolParser.shared.lastTrackingSendTime = 0
        camera.trackingLastControlUpdateTimeMs = 0
    }
    expect(ProtocolParser.shared.writes.isEmpty, "disconnected preview does not claim a normal motor write")
    expect(camera.lastSentState == -1 && camera.lastSentFinalX == 0 && camera.lastSentFinalY == 0,
           "disconnected preview retains no sent-command deduplication state")
    expect(camera.trackingLastOutputX == 0 && camera.trackingLastOutputY == 0,
           "disconnected preview does not wind up controller output")
    KKBLEManager.shared.isCommandChannelReady = true
    camera.sendTrackingCommand(state: .normal, centerPoint: point(rawX: -350, rawY: 300))
    expect(ProtocolParser.shared.writes.count == 1,
           "channel becoming ready sends current target even when position is unchanged")
    if let sent = ProtocolParser.shared.writes.last {
        expect(sent.x < 0 && sent.y > 0 && abs(sent.x) <= 120 && abs(sent.y) <= 180,
               "connection starts in the measured direction with bounded startup output")
    }
}
do {
    let camera = fixture()
    camera.physicalObjectIsFollowing = false
    tick(camera, 400, 400, wait: false)
    expect(ProtocolParser.shared.writes.isEmpty, "inactive following emits no normal command")
}
do {
    let camera = fixture()
    for (x, y) in [(0, 0), (80, -100), (-100, 110), (130, -180), (0, 0)] {
        tick(camera, x, y)
    }
    expect(!ProtocolParser.shared.writes.isEmpty, "ready centered target sends a zero hold")
    expect(ProtocolParser.shared.writes.allSatisfy { $0.x == 0 && $0.y == 0 && $0.state == 1 },
           "center jitter cannot escape as a nonzero command")
    expect(camera.trackingLastOutputX == 0 && camera.trackingLastOutputY == 0,
           "held axes retain no filtered output")
}
do {
    let camera = fixture()
    tick(camera, 80, 500, wait: false)
    expect(ProtocolParser.shared.writes.last?.x == 0, "yaw stays zero while pitch follows")
    expect((ProtocolParser.shared.writes.last?.y ?? 0) > 0, "released pitch produces positive demand")
    tick(camera, 300, 500)
    expect((ProtocolParser.shared.writes.last?.x ?? 0) > 0, "yaw resumes beyond release threshold")
    expect((ProtocolParser.shared.writes.last?.y ?? 0) > 0, "yaw release preserves pitch following")
    let previousCount = ProtocolParser.shared.writes.count
    tick(camera, 80, 500, wait: false)
    expect(ProtocolParser.shared.writes.count == previousCount,
           "center reentry respects the current 50 ms transport window")
    tick(camera, 80, 500)
    expect(ProtocolParser.shared.writes.last?.x == 0,
           "next legal send explicitly zeros returning yaw")
    expect((ProtocolParser.shared.writes.last?.y ?? 0) > 0,
           "yaw hold does not stop active pitch")
    tick(camera, 80, 80)
    expect(ProtocolParser.shared.writes.last?.x == 0 && ProtocolParser.shared.writes.last?.y == 0,
           "both centered axes emit a final zero hold")
}
do {
    let camera = fixture()
    let before = ProcessInfo.processInfo.systemUptime - 2.2
    expect(camera.physicalObjectFollowSafety.control(rawX: -200, rawY: 0, at: before,
           commandedX: true, commandedY: false) == nil, "past divergent-demand seed is initially admissible")
    camera.lastSentState = Int(TrackingState.normal.rawValue)
    camera.lastSentFinalX = -60
    tick(camera, -410, 0, wait: false)
    expect(ProtocolParser.shared.writes.count == 1, "progress rejection produces one write")
    expect(ProtocolParser.shared.writes.last?.state == TrackingState.exit.rawValue,
           "progress rejection routes through production pause and exit")
    expect(ProtocolParser.shared.writes.last?.x == 0 && ProtocolParser.shared.writes.last?.y == 0,
           "exit carries zero movement")
    expect(camera.physicalObjectIsFollowing && !camera.physicalObjectNeedsReselection,
           "motor hold preserves visual tracking and selection")
    expect(camera.releaseCount == 0 && camera.clearCount == 0 && camera.renderCount == 1,
           "motor hold retains target and updates visual state")
    tick(camera, -500, 0)
    expect(ProtocolParser.shared.writes.count == 1, "off-center target cannot resume during motor hold")
    tick(camera, 0, 0)
    tick(camera, 0, 0)
    expect(ProtocolParser.shared.writes.count == 1, "two centered frames cannot resume movement")
    tick(camera, 0, 0)
    tick(camera, 0, 0)
    expect(!camera.physicalObjectFollowSafety.motionPaused, "sustained center clears hold for same target")
    expect(ProtocolParser.shared.writes.last?.state == 1 && ProtocolParser.shared.writes.last?.x == 0,
           "resume starts with zero command")
    tick(camera, 220, 0)
    expect((ProtocolParser.shared.writes.last?.x ?? 0) > 0, "same tracked target can move again after hold")
    expect(camera.releaseCount == 0, "resume never reinitializes tracker or changes target")
    camera.pausePhysicalObjectFollowing(reason: "low_confidence")
    expect(!camera.physicalObjectIsFollowing && camera.releaseCount == 1,
           "actual target loss still withdraws tracker")
    let stoppedWrites = ProtocolParser.shared.writes.count
    tick(camera, 220, 0)
    expect(ProtocolParser.shared.writes.count == stoppedWrites, "hard loss cannot auto-resume")
}
do {
    let camera = fixture()
    _ = camera.physicalObjectFollowSafety.control(rawX: 156, rawY: 0,
        at: ProcessInfo.processInfo.systemUptime - 5, commandedX: true, commandedY: false)
    camera.lastSentState = Int(TrackingState.normal.rawValue)
    camera.lastSentFinalX = 42
    tick(camera, 217, 0, wait: false)
    expect(ProtocolParser.shared.writes.last?.state == 1 && (ProtocolParser.shared.writes.last?.x ?? 0) > 0,
           "observed small-error moving target continues normal follow")
    expect(camera.releaseCount == 0 && !camera.physicalObjectFollowSafety.motionPaused,
           "small tracking lag is neither target loss nor motor hold")
}
do {
    let camera = fixture()
    _ = camera.physicalObjectFollowSafety.control(rawX: -200, rawY: 0,
        at: ProcessInfo.processInfo.systemUptime - 5, commandedX: true, commandedY: false)
    camera.lastSentState = Int(TrackingState.normal.rawValue)
    camera.lastSentFinalX = -60
    KKBLEManager.shared.isCommandChannelReady = false
    tick(camera, -300, 0, wait: false)
    expect(camera.physicalObjectIsFollowing, "unavailable BLE cannot establish failed motor response")
    expect(!ProtocolParser.shared.writes.contains { $0.state == 4 },
           "unavailable BLE does not trigger progress-based exit")
}
do {
    let camera = fixture(ready: false, physical: false)
    camera.physicalObjectIsFollowing = false
    tick(camera, 300, -300, wait: false)
    expect(ProtocolParser.shared.writes.count == 1, "legacy nonphysical route remains enabled without object readiness")
    expect((ProtocolParser.shared.writes.last?.x ?? 0) > 0 && (ProtocolParser.shared.writes.last?.y ?? 0) < 0,
           "legacy route retains its expected control signs")
    expect(ProtocolParser.shared.writes.last?.state == 1, "legacy route sends normal state")
}

do {
    let camera = fixture()
    let box = CGRect(x: 0.3, y: 0.3, width: 0.1, height: 0.1)
    tick(camera, 300, 0, wait: false)
    expect(ProtocolParser.shared.writes.last?.state == 1 && (ProtocolParser.shared.writes.last?.x ?? 0) > 0,
           "quality test begins with actual nonzero sender output")
    _ = camera.physicalObjectFollowSafety.observe(rect: box, previousRect: box,
        confidence: 0.43, capturedAt: 4)
    camera.holdPhysicalObjectObservation(confidence: 0.43)
    expect(ProtocolParser.shared.writes.last?.state == 4,
           "quality hold explicitly withdraws previous motor output")
    expect(camera.releaseCount == 0 && camera.physicalObjectIsFollowing,
           "quality hold does not release the selected tracker")
    let countAfterExit = ProtocolParser.shared.writes.count
    tick(camera, 350, 0)
    expect(ProtocolParser.shared.writes.count == countAfterExit, "uncertain target cannot send normal motion")
    for (offset, confidence) in [Float(0.72221637), 0.55954444, 0.58386034].enumerated() {
        let index = offset + 1
        _ = camera.physicalObjectFollowSafety.observe(rect: box, previousRect: box,
            confidence: confidence, capturedAt: 4 + Double(index) * 0.05)
        tick(camera, 300, 0)
        expect(ProtocolParser.shared.writes.count == countAfterExit + (index == 3 ? 1 : 0),
               "sender waits for three continuous usable frames with strong mean before resuming")
    }
    expect(ProtocolParser.shared.writes.last?.state == 1 && (ProtocolParser.shared.writes.last?.x ?? 0) > 0,
           "confirmed same target resumes existing normal command path")
}
do {
    let camera = fixture(ready: false)
    let inside = CGRect(x: 0.4, y: 0.01, width: 0.2, height: 0.4)
    let partial = CGRect(x: 0.4, y: -0.07, width: 0.2, height: 0.4)
    let returned = CGRect(x: 0.4, y: 0.02, width: 0.2, height: 0.4)
    for index in 1...3 {
        expect(camera.physicalObjectFollowSafety.observe(rect: inside, previousRect: inside,
            confidence: 0.9, capturedAt: Double(index)) == nil, "edge sender setup accepts strong frame")
    }
    tick(camera, 0, 400, wait: false)
    expect(ProtocolParser.shared.writes.last?.state == 1 && (ProtocolParser.shared.writes.last?.y ?? 0) > 0,
           "edge sender test starts with nonzero pitch demand")
    expect(camera.physicalObjectFollowSafety.observe(rect: partial, previousRect: inside,
        confidence: 0.9, capturedAt: 4) == nil, "partial edge observation is retained")
    camera.holdPhysicalObjectObservation(confidence: 0.9)
    expect(ProtocolParser.shared.writes.last?.state == 4
        && ProtocolParser.shared.writes.last?.x == 0 && ProtocolParser.shared.writes.last?.y == 0,
           "edge hold immediately sends explicit zero exit")
    expect(camera.releaseCount == 0 && camera.physicalObjectIsFollowing
        && !camera.physicalObjectFollowSafety.ready && camera.physicalObjectFollowSafety.awaitingFrameReentry,
           "edge hold retains selection while withdrawing sender authority")
    let countAfterExit = ProtocolParser.shared.writes.count
    for index in 1...3 {
        _ = camera.physicalObjectFollowSafety.observe(rect: partial, previousRect: partial,
            confidence: 0.9, capturedAt: 4 + Double(index) * 0.03)
        tick(camera, 0, 500)
        expect(ProtocolParser.shared.writes.count == countAfterExit,
               "sender cannot move during strong but partially visible frame \(index)")
    }
    for index in 1...3 {
        expect(camera.physicalObjectFollowSafety.observe(rect: returned,
            previousRect: index == 1 ? partial : returned, confidence: 0.9,
            capturedAt: 4.2 + Double(index) * 0.05) == nil,
               "sender accepts continuous return observation \(index)")
        tick(camera, 0, 400)
        expect(ProtocolParser.shared.writes.count == countAfterExit + (index == 3 ? 1 : 0),
               "sender waits for three in-frame observations before resuming \(index)")
    }
    expect(camera.releaseCount == 0 && camera.physicalObjectFollowSafety.ready
        && ProtocolParser.shared.writes.last?.state == 1 && (ProtocolParser.shared.writes.last?.y ?? 0) > 0,
           "same selection resumes bounded pitch output after frame reentry")
}
do {
    let camera = fixture(ready: false)
    let inside = CGRect(x: 0.02, y: 0.2570652, width: 0.3047687, height: 0.4883226)
    let partial = inside.offsetBy(dx: -0.08, dy: 0)
    let returned = CGRect(x: -0.0361547, y: 0.2570652, width: 0.3047687, height: 0.4883226)
    for index in 1...3 {
        expect(camera.physicalObjectFollowSafety.observe(rect: inside, previousRect: inside,
            confidence: 0.9, capturedAt: Double(index)) == nil, "edge match sender setup accepts strong frame")
    }
    tick(camera, 400, 0, wait: false)
    expect(ProtocolParser.shared.writes.last?.state == 1 && (ProtocolParser.shared.writes.last?.x ?? 0) > 0,
           "edge match sender begins with measured yaw demand")
    _ = camera.physicalObjectFollowSafety.observe(rect: partial, previousRect: inside,
        confidence: 0.9, capturedAt: 4)
    camera.holdPhysicalObjectObservation(confidence: 0.9)
    var countAfterExit = ProtocolParser.shared.writes.count
    expect(ProtocolParser.shared.writes.last?.state == 4, "edge match starts with explicit motor exit")
    var previous = partial
    let confidences: [Float] = [0.9, 0.9, 0.3, 0.3, 0.9, 0.9, 0.3, 0.9, 0.9, 0.9]
    for (offset, confidence) in confidences.enumerated() {
        let index = offset + 1
        let wasConfirmingMatch = camera.physicalObjectFollowSafety.awaitingFrameReentryMatch
        expect(camera.physicalObjectFollowSafety.observe(rect: returned, previousRect: previous,
            confidence: confidence, capturedAt: 4 + Double(index) * 0.02) == nil,
               "edge match observation retained at controlled capture time \(index)")
        previous = returned
        if camera.physicalObjectFollowSafety.awaitingFrameReentryMatch && !wasConfirmingMatch {
            camera.holdPhysicalObjectObservation(confidence: confidence)
            expect(ProtocolParser.shared.writes.count == countAfterExit + 1
                && ProtocolParser.shared.writes.last?.state == 4,
                   "entering_edge_weak_match_reasserts_explicit_exit")
            countAfterExit = ProtocolParser.shared.writes.count
        }
        tick(camera, 400, 0)
        expect(ProtocolParser.shared.writes.count == countAfterExit + (index == confidences.count ? 1 : 0),
               "weak boxes and interrupted strong streaks cannot produce normal yaw \(index)")
        if confidence < 0.75 {
            expect(camera.physicalObjectFollowSafety.awaitingFrameReentryMatch
                && !camera.physicalObjectFollowSafety.ready && camera.releaseCount == 0,
                   "edge match subwindow preserves identity without sender authority \(index)")
        }
    }
    expect(camera.releaseCount == 0 && camera.physicalObjectFollowSafety.ready
        && !camera.physicalObjectFollowSafety.awaitingFrameReentryMatch
        && ProtocolParser.shared.writes.last?.state == 1 && (ProtocolParser.shared.writes.last?.x ?? 0) > 0,
           "three final strong matches resume original yaw controller")
}
do {
    let camera = fixture(ready: false)
    let selected = CGRect(x: 0.02, y: 0.35, width: 0.2, height: 0.2)
    let oldHeldBox = CGRect(x: 0.72, y: 0.65, width: 0.2, height: 0.2)
    let recovered = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
    for index in 1...3 {
        expect(camera.physicalObjectFollowSafety.observe(rect: selected, previousRect: selected,
            confidence: 0.94, capturedAt: Double(index)) == nil,
               "original target sender setup confirms explicit selection")
    }
    tick(camera, -400, 0, wait: false)
    expect(ProtocolParser.shared.writes.last?.state == 1 && (ProtocolParser.shared.writes.last?.x ?? 0) < 0,
           "original target sender starts with measured motion")
    expect(camera.physicalObjectFollowSafety.observe(rect: oldHeldBox, previousRect: oldHeldBox,
        confidence: 0.3, capturedAt: 4, isHeldObservation: true, supportsCenterRecovery: true) == nil,
           "eligible native hold is not rejected as a fresh coordinate jump")
    camera.holdPhysicalObjectObservation(confidence: 0.3)
    let stoppedCount = ProtocolParser.shared.writes.count
    expect(ProtocolParser.shared.writes.last?.state == 4
        && camera.physicalObjectFollowSafety.awaitingOriginalTargetReturn && !camera.physicalObjectFollowSafety.ready,
           "original target return window explicitly withdraws motor authority")
    for index in 1...3 {
        expect(camera.physicalObjectFollowSafety.observe(rect: oldHeldBox, previousRect: oldHeldBox,
            confidence: 0.3, capturedAt: 4 + Double(index) * 0.05,
            isHeldObservation: true, supportsCenterRecovery: true) == nil,
               "pending native original matches retain stopped observation \(index)")
        tick(camera, 500, 500)
        expect(ProtocolParser.shared.writes.count == stoppedCount && camera.releaseCount == 0,
               "held coordinates cannot authorize either motor axis \(index)")
    }
    KKBLEManager.shared.isCommandChannelReady = false
    expect(camera.physicalObjectFollowSafety.observe(rect: recovered, previousRect: oldHeldBox,
        confidence: 0.96, capturedAt: 4.2, supportsCenterRecovery: true,
        recoveredOriginalTemplate: true) == nil && camera.physicalObjectFollowSafety.ready,
           "native confirmed center can bridge old held position after eligibility")
    tick(camera, 300, -300)
    expect(ProtocolParser.shared.writes.count == stoppedCount,
           "confirmed original target cannot bypass disconnected command channel")
    KKBLEManager.shared.isCommandChannelReady = true
    tick(camera, 300, -300)
    expect(ProtocolParser.shared.writes.count == stoppedCount + 1
        && ProtocolParser.shared.writes.last?.state == 1
        && (ProtocolParser.shared.writes.last?.x ?? 0) > 0
        && (ProtocolParser.shared.writes.last?.y ?? 0) < 0 && camera.releaseCount == 0,
           "recovered original target resumes the existing bounded sender only when connected")
}
do {
    let camera = fixture(ready: false)
    camera.physicalObjectAutoRecoveryEnabled = true
    camera.physicalObjectFollowSafety = CMPhysicalObjectFollowSafety(recoveryEnabled: true)
    let original = CGRect(x: 0.25, y: 0.3, width: 0.15, height: 0.2)
    let returned = CGRect(x: 0.55, y: 0.25, width: 0.25, height: 0.35)
    for index in 1...3 {
        _ = camera.physicalObjectFollowSafety.observe(rect: original, previousRect: original,
            confidence: 0.96, capturedAt: Double(index))
    }
    tick(camera, -350, 300, wait: false)
    expect(ProtocolParser.shared.writes.last?.state == 1,
           "persistent_search_sender_starts_from_confirmed_motion")
    _ = camera.physicalObjectFollowSafety.observe(rect: original, previousRect: original,
        confidence: 0.3, capturedAt: 4, isHeldObservation: true)
    camera.holdPhysicalObjectObservation(confidence: 0.3)
    let stoppedCount = ProtocolParser.shared.writes.count
    expect(ProtocolParser.shared.writes.last?.state == 4
        && ProtocolParser.shared.writes.last?.x == 0 && ProtocolParser.shared.writes.last?.y == 0,
           "persistent_search_withdraws_both_motor_axes_before_waiting")
    expect(camera.physicalObjectFollowSafety.handleConfirmationTimeout(at: 4.5) == nil
        && camera.physicalObjectFollowSafety.searchingOriginalTarget,
           "opted_in_timeout_keeps_identity_in_search_without_motor_authority")
    for time in [5.0, 8.0, 30.0] {
        _ = camera.physicalObjectFollowSafety.observe(rect: returned, previousRect: original,
            confidence: 0.99, capturedAt: time)
        tick(camera, 500, -500)
        expect(ProtocolParser.shared.writes.count == stoppedCount && camera.releaseCount == 0
            && camera.physicalObjectIsFollowing && !camera.physicalObjectFollowSafety.ready,
               "ordinary_high_confidence_cannot_resume_either_axis_during_search_\(time)")
    }
    expect(camera.physicalObjectFollowSafety.observe(rect: returned, previousRect: original,
        confidence: 0.96, capturedAt: 30.1, recoveredVerifiedIdentity: true) == nil
        && camera.physicalObjectFollowSafety.ready, "verified_identity_recovery_restores_sender_eligibility")
    KKBLEManager.shared.isCommandChannelReady = false
    tick(camera, 500, -500)
    expect(ProtocolParser.shared.writes.count == stoppedCount,
           "verified_identity_recovery_still_cannot_drive_disconnected_gimbal")
    KKBLEManager.shared.isCommandChannelReady = true
    tick(camera, 500, -500)
    let resumed = ProtocolParser.shared.writes.last!
    let resumedCount = ProtocolParser.shared.writes.count
    // Compare the production controller's first step at the same input. Its
    // startup bound scales with offset; a fixed bound from a smaller-offset
    // fixture would not test whether stale pre-loss output was actually reset.
    let freshController = fixture()
    tick(freshController, 500, -500, wait: false)
    let freshStep = ProtocolParser.shared.writes.last!
    expect(resumedCount == stoppedCount + 1 && resumed.state == 1
        && resumed.x > 0 && resumed.y < 0 && resumed.x == freshStep.x && resumed.y == freshStep.y
        && camera.releaseCount == 0,
           "verified_return_uses_existing_bounded_startup_controller_for_same_identity")
}
do {
    let camera = fixture(ready: false)
    camera.physicalObjectAutoRecoveryEnabled = true
    camera.physicalObjectFollowSafety = CMPhysicalObjectFollowSafety(recoveryEnabled: true)
    let box = CGRect(x: 0.3, y: 0.3, width: 0.1, height: 0.1)
    let base = ProcessInfo.processInfo.systemUptime - 0.5
    for index in 0..<3 {
        _ = camera.physicalObjectFollowSafety.observe(rect: box, previousRect: box,
            confidence: 0.99, capturedAt: base + Double(index) * 0.01)
    }
    tick(camera, 400, -400, wait: false)
    camera.pausePhysicalObjectFollowing(reason: "legacy_position_expired")
    let stopped = ProtocolParser.shared.writes.count
    expect(ProtocolParser.shared.writes.last?.state == 4 && camera.releaseCount == 0
        && camera.searchBeginCalls == 0 && !camera.physicalObjectFollowSafety.ready,
           "pipeline_expiry_withdraws_both_axes_without_releasing_or_global_search")
    for index in 1...3 {
        _ = camera.physicalObjectFollowSafety.observe(rect: box, previousRect: box,
            confidence: 0.95, capturedAt: ProcessInfo.processInfo.systemUptime)
        tick(camera, 400, -400)
        expect(ProtocolParser.shared.writes.count == stopped + (index == 3 ? 1 : 0),
               "pipeline_gap_sender_waits_for_three_fresh_local_confirmations_\(index)")
    }
    expect(ProtocolParser.shared.writes.last?.state == 1 && camera.releaseCount == 0
        && camera.searchBeginCalls == 0, "post_gap_motor_resume_keeps_original_local_session")
}

print("PhysicalObjectCommandSmoke: \(assertions) assertions, \(failures) failures")
print("Scope: complete production command method, helpers, and pause method; transport/UI/hardware are explicit spies.")
print("No protocol-byte, native Vision, BLE-delivery, or motor measurement is claimed.")
if failures > 0 { exit(1) }
