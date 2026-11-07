import Foundation
import CoreGraphics
typealias CVPixelBuffer = Int
class VNDetectedObjectObservation {
    var boundingBox: CGRect
    var confidence: Float = 1
    init(boundingBox: CGRect) { self.boundingBox = boundingBox }
}
final class CMPhysicalObjectUnavailableWholeObservation: VNDetectedObjectObservation {
    override init(boundingBox: CGRect) { super.init(boundingBox: boundingBox); confidence = 0 }
}
final class VNTrackObjectRequest {
    var inputObservation: VNDetectedObjectObservation
    var cancelCalls = 0
    init(detectedObjectObservation: VNDetectedObjectObservation) { inputObservation = detectedObjectObservation }
    func cancel() { cancelCalls += 1 }
}
final class CMPhysicalObjectPatchTracker {
    static var trackResults: [Int: [String: Any]] = [:]
    static var frozenResults: [Int: [String: Any]] = [:]
    static var trackFrames: [Int] = []
    static var autoRecoveryFrames: [Int] = []
    static var frozenFrames: [(Int, TimeInterval)] = []
    static var supportsRecovery = true
    static var countFrozenVotes = false
    static var frozenVotes = 0
    static var frozenResets = 0
    var supportsCenterRecovery: Bool { Self.supportsRecovery }
    init?(pixelBuffer: CVPixelBuffer, selection: CGRect) {}
    func trackPixelBuffer(_ buffer: Int, referenceRect: CGRect, referenceConfidence: Float) -> [String: Any] {
        Self.trackFrames.append(buffer)
        return Self.trackResults[buffer] ?? ["accepted": false]
    }
    func recoverPixelBuffer(_ buffer: Int) -> [String: Any] {
        Self.autoRecoveryFrames.append(buffer)
        return ["accepted": false]
    }
    func recoverFrozenPixelBuffer(_ buffer: Int, frameToken: TimeInterval) -> [String: Any] {
        Self.frozenFrames.append((buffer, frameToken))
        if Self.countFrozenVotes {
            Self.frozenVotes += 1
            if Self.frozenVotes < 3 { return ["accepted": false] }
            var result = accepted()
            result["recovered_original_template"] = true
            return result
        }
        return Self.frozenResults[buffer] ?? ["accepted": false]
    }
    func resetFrozenRecoveryConfirmation() { Self.frozenVotes = 0; Self.frozenResets += 1 }
    static func reset() {
        trackResults = [:]; frozenResults = [:]; trackFrames = []; autoRecoveryFrames = []; frozenFrames = []
        supportsRecovery = true
        countFrozenVotes = false; frozenVotes = 0; frozenResets = 0
    }
}
// INSERT_NATIVE_TYPES
final class CMPhysicalObjectPartsSession {
    static var seeds: [CGRect] = []
    static var outputs: [Int: CMPhysicalObjectMeasurement] = [:]
    static var calls: [(pixels: Int, fullConfidence: Float, fullBox: CGRect, initialization: Bool)] = []
    static var released = 0
    let seed: CGRect
    init(seed: CGRect) { self.seed = seed; Self.seeds.append(seed) }
    deinit { Self.released += 1 }
    func measure(pixels: Int, full: VNDetectedObjectObservation, lastFrame: Bool = false,
                 initializationOnly: Bool = false) -> CMPhysicalObjectMeasurement {
        Self.calls.append((pixels, full.confidence, full.boundingBox, initializationOnly))
        return Self.outputs[pixels] ?? CMPhysicalObjectMeasurement(rect: seed, previousRect: seed,
            quality: 0.3, source: "foreground_parts_unconfirmed", isHeldObservation: true)
    }
    // INSERT_PART_CONTINUITY
    static func reset() { seeds = []; outputs = [:]; calls = []; released = 0 }
}
// INSERT_SNAPSHOT_SESSION

var assertions = 0, failures = 0
func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    assertions += 1
    if !condition() { failures += 1; print("FAIL: \(name)") }
}
let seed = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
func accepted(_ box: CGRect = seed, score: Double = 0.97, margin: Double = 0.15,
              source: String = "texture") -> [String: Any] {
    ["accepted": true, "score": score, "margin": margin, "measurement_source": source,
     "bbox": [box.minX, box.minY, box.width, box.height].map(Double.init)]
}
func part(_ box: CGRect = seed, quality: Float = 0.85, support: [String] = ["top", "bottom"],
          observations: [String]? = nil, held: Bool = false) -> CMPhysicalObjectMeasurement {
    CMPhysicalObjectMeasurement(rect: box, previousRect: seed, quality: quality,
        source: "foreground_parts_consensus", patchDiagnostics: ["support": support,
        "parts": (observations ?? support).map { ["name": $0, "confidence": quality] as [String: Any] }],
        isHeldObservation: held)
}
func setup(_ selection: CGRect = seed) -> (CMPhysicalObjectSnapshotPartsSession, VNTrackObjectRequest) {
    CMPhysicalObjectPatchTracker.reset()
    CMPhysicalObjectPartsSession.reset()
    let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: selection))
    let native = CMPhysicalObjectPatchSession(request: request, buffer: 0, selection: selection)
    return (CMPhysicalObjectSnapshotPartsSession(request: request, native: native, selection: selection), request)
}
@discardableResult
func frame(_ session: CMPhysicalObjectSnapshotPartsSession, _ index: Int, at time: TimeInterval? = nil,
           visionQuality: Float = 1, visionBox: CGRect = seed) -> CMPhysicalObjectMeasurement {
    let full = VNDetectedObjectObservation(boundingBox: visionBox)
    full.confidence = visionQuality
    return session.measure(buffer: index, vision: full, capturedAt: time ?? 100 + Double(index) * 0.01)
}
func warm(_ session: CMPhysicalObjectSnapshotPartsSession, score: Double = 0.97,
          margin: Double = 0.15, source: String = "texture") {
    for i in 1...3 {
        CMPhysicalObjectPatchTracker.trackResults[i] = accepted(score: score, margin: margin, source: source)
        let m = frame(session, i)
        expect(!m.isHeldObservation && !m.recoveredOriginalTemplate, "native_warmup_keeps_original_route_\(i)")
    }
}

func warmShadow(_ session: CMPhysicalObjectSnapshotPartsSession) {
    warm(session)
    for i in 4...6 {
        CMPhysicalObjectPatchTracker.trackResults[i] = accepted()
        CMPhysicalObjectPartsSession.outputs[i] = part()
        let m = frame(session, i)
        expect(m.source == "fixed_patch_multiscale" && !session.usesParts,
               "healthy_native_remains_sole_output_while_shadow_warms_\(i)")
    }
}

do {
    let (session, request) = setup()
    for i in 1...6 {
        let current = seed.offsetBy(dx: Double(i - 1) * 0.01, dy: 0)
        CMPhysicalObjectPatchTracker.trackResults[i] = accepted(current)
        CMPhysicalObjectPartsSession.outputs[i] = part(current)
        let m = frame(session, i)
        expect(m.rect == current && m.quality == 0.97 && m.source == "fixed_patch_multiscale" && !session.usesParts,
               "native_positions_and_quality_unchanged_by_shadow_\(i)")
    }
    expect(CMPhysicalObjectPartsSession.seeds == [seed.offsetBy(dx: 0.02, dy: 0)]
        && CMPhysicalObjectPartsSession.calls.map { $0.pixels } == [3, 4, 5, 6]
        && CMPhysicalObjectPartsSession.calls.filter { $0.initialization }.map { $0.pixels } == [3],
           "third_trusted_current_native_frame_seeds_once_then_parts_observe_every_frame")
    let lastNative = seed.offsetBy(dx: 0.05, dy: 0)
    CMPhysicalObjectPartsSession.outputs[7] = part(seed.offsetBy(dx: 0.06, dy: 0))
    let hold = frame(session, 7)
    expect(session.usesParts && hold.isHeldObservation && hold.supportsCenterRecovery
        && hold.rect == lastNative && hold.previousRect == lastNative
        && hold.source == "snapshot_parts_shadow_handoff_hold",
           "previously_three_frame_corroborated_shadow_starts_handoff_with_one_stopped_frame")
    expect(CMPhysicalObjectPatchTracker.frozenFrames.isEmpty,
           "handoff_frame_never_counts_current_native_recovery_twice")
    CMPhysicalObjectPartsSession.outputs[8] = part(seed.offsetBy(dx: 0.07, dy: 0), quality: 0.55, support: ["top"])
    let continued = frame(session, 8)
    expect(!continued.isHeldObservation && continued.quality == 0.55 && continued.previousRect == lastNative,
           "active_parts_keep_existing_quality_rule_and_last_native_delivered_previous")
    CMPhysicalObjectPatchTracker.countFrozenVotes = true
    expect(frame(session, 9).isHeldObservation && CMPhysicalObjectPatchTracker.frozenVotes == 1,
           "active_parts_weak_frame_starts_frozen_original_recovery")
    expect(frame(session, 10).isHeldObservation && CMPhysicalObjectPatchTracker.frozenVotes == 2,
           "two_frozen_candidates_cannot_resume_original")
    CMPhysicalObjectPartsSession.outputs[11] = part(seed.offsetBy(dx: 0.08, dy: 0), quality: 0.55, support: ["top"])
    let reliable = frame(session, 11)
    expect(!reliable.isHeldObservation && CMPhysicalObjectPatchTracker.frozenVotes == 0,
           "reliable_parts_frame_breaks_frozen_confirmation_streak")
    expect(frame(session, 12).isHeldObservation && frame(session, 13).isHeldObservation,
           "after_reliable_gap_two_new_frozen_candidates_still_hold")
    let recovered = frame(session, 14)
    expect(recovered.recoveredOriginalTemplate && recovered.previousRect == reliable.rect && !session.usesParts
        && CMPhysicalObjectPartsSession.released == 1,
           "third_new_frozen_candidate_retires_parts_and_preserves_recovery_tag")
    expect(CMPhysicalObjectPatchTracker.trackFrames == Array(1...7)
        && CMPhysicalObjectPatchTracker.frozenFrames.map { $0.0 } == [9, 10, 12, 13, 14]
        && CMPhysicalObjectPatchTracker.frozenFrames.map { $0.1 } == [100.09, 100.10, 100.12, 100.13, 100.14],
           "active_parts_never_retrack_or_relearn_native_and_keep_original_capture_tokens")
    for i in 15...17 { CMPhysicalObjectPatchTracker.trackResults[i] = accepted(); frame(session, i) }
    expect(CMPhysicalObjectPartsSession.seeds.count == 2
        && CMPhysicalObjectPartsSession.calls.filter { $0.initialization }.map { $0.pixels } == [3, 17],
           "original_recovery_requires_three_new_native_frames_to_seed_a_new_shadow")
    CMPhysicalObjectPartsSession.outputs[18] = part()
    let cold = frame(session, 18)
    expect(cold.isHeldObservation && !session.usesParts && CMPhysicalObjectPartsSession.released == 2,
           "newly_seeded_shadow_cannot_borrow_previous_shadow_confirmation_history")
    expect(request.cancelCalls == 0 && CMPhysicalObjectPartsSession.calls.allSatisfy { $0.fullConfidence == 0 },
           "shadow_and_active_parts_never_use_whole_vision_votes_or_cancel_main_request")
}

for priorFrames in 0...2 {
    let (session, _) = setup()
    warm(session)
    if priorFrames > 0 {
        for i in 4..<(4 + priorFrames) {
            CMPhysicalObjectPatchTracker.trackResults[i] = accepted()
            CMPhysicalObjectPartsSession.outputs[i] = part()
            frame(session, i)
        }
    }
    let firstWeak = 4 + priorFrames
    CMPhysicalObjectPartsSession.outputs[firstWeak] = part()
    let held = frame(session, firstWeak)
    expect(held.isHeldObservation && !session.usesParts && CMPhysicalObjectPartsSession.released == 1,
           "initialization_or_current_weak_frame_cannot_complete_three_prior_shadow_votes_\(priorFrames)")
    frame(session, firstWeak + 1)
    expect(CMPhysicalObjectPartsSession.seeds.count == 1,
           "native_hold_pixels_never_create_a_replacement_shadow_\(priorFrames)")
}

for bad in [part(quality: 0.6), part(support: ["top"]), part(support: ["full", "top"]),
            part(support: ["top", "top"]), part(observations: ["top"]), part(quality: .nan),
            part(seed.offsetBy(dx: 0.06, dy: 0)), part(CGRect(x: 0.4, y: 0.4, width: 0.32, height: 0.2))] {
    let (session, _) = setup()
    warm(session)
    CMPhysicalObjectPatchTracker.trackResults[4] = accepted()
    CMPhysicalObjectPartsSession.outputs[4] = bad
    let native = frame(session, 4)
    expect(native.source == "fixed_patch_multiscale" && native.quality == 0.97 && native.rect == seed
        && CMPhysicalObjectPartsSession.released == 1 && !session.usesParts,
           "weak_or_conflicting_shadow_retires_without_changing_native_result_\(bad.quality)")
    for i in 5...6 { CMPhysicalObjectPatchTracker.trackResults[i] = accepted(); frame(session, i) }
    expect(CMPhysicalObjectPartsSession.seeds.count == 1, "retired_shadow_cannot_reuse_previous_native_seed_streak")
    CMPhysicalObjectPatchTracker.trackResults[7] = accepted()
    frame(session, 7)
    expect(CMPhysicalObjectPartsSession.seeds.count == 2
        && CMPhysicalObjectPartsSession.calls.last?.pixels == 7
        && CMPhysicalObjectPartsSession.calls.last?.initialization == true,
           "only_third_new_trusted_native_frame_rebuilds_retired_shadow")
}

// Inter-frame motion floors are unsafe as agreement on the same image.
do {
    let tiny = CGRect(x: 0.4, y: 0.4, width: 0.02, height: 0.02)
    let other = tiny.offsetBy(dx: 0.03, dy: 0)
    let (session, _) = setup(tiny)
    expect(CMPhysicalObjectPartsSession.continuous(other, with: tiny)
        && CMPhysicalObjectPartsSession.continuous(tiny, with: other)
        && tiny.intersection(other).isNull,
           "disjoint_small_boxes_demonstrate_same_frame_motion_floor_hazard")
    for i in 1...3 { CMPhysicalObjectPatchTracker.trackResults[i] = accepted(tiny); frame(session, i) }
    CMPhysicalObjectPatchTracker.trackResults[4] = accepted(tiny)
    CMPhysicalObjectPartsSession.outputs[4] = part(other)
    let m = frame(session, 4)
    expect(m.rect == tiny && m.source == "fixed_patch_multiscale" && CMPhysicalObjectPartsSession.released == 1,
           "same_frame_agreement_rejects_disjoint_small_shadow_even_when_mutual_motion_is_legal")
    frame(session, 5)
    expect(!session.usesParts, "rejected_small_object_shadow_never_gains_handoff_authority")
}
do {
    let (session, _) = setup()
    warm(session)
    for i in 4...12 {
        let current = seed.offsetBy(dx: Double(i - 3) * 0.015, dy: 0)
        CMPhysicalObjectPatchTracker.trackResults[i] = accepted(current)
        CMPhysicalObjectPartsSession.outputs[i] = part(current)
        frame(session, i)
    }
    expect(CMPhysicalObjectPartsSession.released == 0,
           "shadow_agrees_with_current_native_frame_instead_of_stale_seed_geometry")
    CMPhysicalObjectPartsSession.outputs[13] = part(seed.offsetBy(dx: 0.15, dy: 0))
    expect(frame(session, 13).source == "snapshot_parts_shadow_handoff_hold" && session.usesParts,
           "consistent_current_motion_can_handoff_far_from_original_seed")
}

for bad in [part(quality: 0.74), part(support: ["top"]), part(seed.offsetBy(dx: 0.2, dy: 0)),
            part(CGRect(x: 0.4, y: 0.4, width: 0.4, height: 0.3))] {
    let (session, _) = setup()
    warmShadow(session)
    CMPhysicalObjectPartsSession.outputs[7] = bad
    expect(frame(session, 7).isHeldObservation && !session.usesParts && CMPhysicalObjectPartsSession.released == 1,
           "previous_shadow_votes_never_override_weak_or_discontinuous_current_handoff_frame")
}
for (score, margin, source) in [(0.949, 0.15, "texture"), (0.97, 0.119, "texture"),
                               (0.97, .nan, "texture"), (0.97, .infinity, "texture"),
                               (0.97, 0.15, "foreground_features"), (0.97, 0.15, "foreground_color_shape")] {
    let (session, _) = setup()
    warm(session, score: score, margin: margin, source: source)
    expect(CMPhysicalObjectPartsSession.seeds.isEmpty,
           "only_strong_unambiguous_ordinary_texture_can_seed_shadow_\(score)_\(margin)_\(source)")
}
do {
    let (session, _) = setup()
    CMPhysicalObjectPatchTracker.supportsRecovery = false
    warm(session)
    expect(CMPhysicalObjectPartsSession.seeds.isEmpty, "unfrozen_native_identity_cannot_seed_shadow")
}
do {
    let (session, _) = setup()
    for i in 1...5 { CMPhysicalObjectPatchTracker.trackResults[i] = accepted(score: i == 3 ? 0.9 : 0.97); frame(session, i) }
    expect(CMPhysicalObjectPartsSession.seeds.isEmpty,
           "native_snapshot_seed_requires_three_consecutive_high_quality_frames")
}
for source in ["foreground_features", "foreground_color_shape"] {
    let (session, _) = setup()
    warmShadow(session)
    CMPhysicalObjectPatchTracker.trackResults[7] = accepted(source: source)
    let m = frame(session, 7)
    expect(m.source == source && CMPhysicalObjectPartsSession.released == 1 && !session.usesParts,
           "native_feature_or_color_identity_retires_texture_shadow_without_changing_native_output_\(source)")
}
for invalid in [100.06, 100.05, .nan, .infinity] {
    let (session, _) = setup()
    warmShadow(session)
    let calls = CMPhysicalObjectPartsSession.calls.count
    let nativeCalls = CMPhysicalObjectPatchTracker.trackFrames.count
    expect(frame(session, 99, at: invalid).isHeldObservation
        && CMPhysicalObjectPartsSession.calls.count == calls && CMPhysicalObjectPatchTracker.trackFrames.count == nativeCalls,
           "invalid_frame_does_not_measure_or_refresh_shadow_confirmation_\(invalid)")
    CMPhysicalObjectPartsSession.outputs[7] = part()
    expect(!frame(session, 7).recoveredOriginalTemplate && !session.usesParts,
           "invalid_frame_breaks_shadow_qualification_before_next_native_hold")
}
do {
    let (session, _) = setup()
    let m = frame(session, 1, visionQuality: 0.1)
    expect(m.source == "vision" && m.quality == 0.1 && !m.isHeldObservation,
           "unlocked_native_route_keeps_severe_whole_vision_confidence_unchanged")
}
do {
    let (session, _) = setup()
    var safety = CMPhysicalObjectFollowSafety()
    for i in 1...10 {
        if i <= 6 { CMPhysicalObjectPatchTracker.trackResults[i] = accepted() }
        if i >= 4 { CMPhysicalObjectPartsSession.outputs[i] = part() }
        let m = frame(session, i)
        expect(safety.observe(rect: m.rect, previousRect: m.previousRect, confidence: m.quality,
            capturedAt: 100 + Double(i) * 0.01, isHeldObservation: m.isHeldObservation,
            supportsCenterRecovery: m.supportsCenterRecovery, recoveredOriginalTemplate: m.recoveredOriginalTemplate) == nil,
               "shadow_candidate_respects_original_safety_gate_\(i)")
        if i == 7 {
            expect(safety.awaitingOriginalTargetReturn && !safety.ready,
                   "first_native_hold_opens_stopped_original_return_window_before_bridge_delivery")
        } else if i == 8 || i == 9 {
            expect(!safety.ready, "native_shadow_cross_checks_do_not_replace_safety_confirmation_\(i)")
        } else if i == 10 {
            expect(safety.ready, "three_parts_deliveries_after_handoff_restore_existing_safety_ready")
        }
    }
}
print("ShadowPartsSessionSmoke: \(assertions) assertions, \(failures) failures")
print("Scope: extracted shadow wrapper, native Swift routing and Safety; image matching, Vision and part pixels are explicit doubles.")
exit(failures == 0 ? 0 : 1)
