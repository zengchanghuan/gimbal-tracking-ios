import Foundation
import CoreGraphics
// INSERT_PRODUCTION_POLICY
var assertions = 0
var failures = 0
func expect(_ value: Bool, _ name: String) {
    assertions += 1
    if !value { failures += 1; print("FAIL: \(name)") }
}
typealias S = CMPhysicalObjectPartsSession
let seed = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.2)
let top = CGRect(x: 0.1, y: 0.7, width: 0.8, height: 0.3)
let bottom = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.3)
func part(_ name: String, _ fraction: CGRect, _ confidence: Float = 0.8, dx: CGFloat = 0, dy: CGFloat = 0, scale: CGFloat = 1) -> S.Observation {
    let width = seed.width * scale, height = seed.height * scale
    return S.Observation(name: name, fraction: fraction, rect: CGRect(
        x: seed.midX + dx + (fraction.minX - 0.5) * width,
        y: seed.midY + dy + (fraction.minY - 0.5) * height,
        width: fraction.width * width, height: fraction.height * height), confidence: confidence)
}
let fullFraction = CGRect(x: 0, y: 0, width: 1, height: 1)
let full = part("full", fullFraction, 0.9)
expect(S.fuse(seed: seed, observations: [full])?.rect == seed, "healthy_full_observation_preserved")
expect(S.fuse(seed: seed, observations: []) == nil, "missing_observations_reject")
expect(S.fuse(seed: seed, observations: [part("top", top, 0.99)]) == nil, "single_partial_match_cannot_drive")
let coherent = S.fuse(seed: seed, observations: [part("top", top, 0.8, dx: 0.02, dy: 0.01, scale: 1.2), part("bottom", bottom, 0.9, dx: 0.02, dy: 0.01, scale: 1.2)])
expect(coherent?.source == "foreground_parts_consensus", "coherent_visible_parts_can_bridge_whole_object_loss")
expect(abs((coherent?.rect.midX ?? 0) - 0.47) < 0.000001 && abs((coherent?.rect.midY ?? 0) - 0.51) < 0.000001, "current_observations_determine_translation")
expect(abs((coherent?.rect.width ?? 0) - 0.12) < 0.000001, "current_observations_determine_scale")
expect(abs((coherent?.quality ?? 0) - 0.85) < 0.000001, "quality_comes_from_supporting_observations")
expect(S.fuse(seed: seed, observations: [part("top", top, 0.9, dx: 0.2), part("bottom", bottom, 0.9)]) == nil, "conflicting_local_positions_reject")
expect(S.fuse(seed: seed, observations: [part("top", top, 0.49), part("bottom", bottom, 0.99)]) == nil, "weak_part_cannot_be_second_vote")
expect(S.fuse(seed: seed, observations: [part("top", top, 0.5), part("bottom", bottom, 0.5)]) == nil, "two_weak_parts_do_not_raise_confidence")
let stretched = S.Observation(name: "full", fraction: fullFraction, rect: CGRect(x: 0.4,y: 0.4,width: 0.24,height: 0.2), confidence: 0.99)
expect(S.fuse(seed: seed, observations: [stretched]) == nil, "stretched_whole_box_cannot_override_geometry")
expect(S.fuse(seed: seed, observations: [stretched,part("top",top),part("bottom",bottom)])?.support.count == 2, "distorted_whole_box_excluded_from_consensus")
let contained = S.fuse(seed: seed, observations: [stretched, part("middle", CGRect(x:0.05,y:0.35,width:0.9,height:0.3),0.65)])
expect(contained?.source == "foreground_whole_with_visible_part" && contained?.quality == 0.65,
       "strong_whole_viewpoint_change_needs_current_contained_part_and_keeps_weaker_quality")
expect(S.fuse(seed: seed, observations: [stretched,part("top",top,0.649)]) == nil,
       "weak_contained_detail_cannot_rescue_distorted_whole")
expect(S.fuse(seed: seed, observations: [stretched,part("top",top,0.9,dx:0.3)]) == nil,
       "distant_detail_cannot_rescue_distorted_whole")
for quality: Float in [.nan, .infinity, -.infinity] {
    expect(S.fuse(seed: seed, observations: [part("top", top, quality),part("bottom",bottom)]) == nil, "nonfinite_quality_reject")
}
expect(S.fuse(seed: seed, observations: [part("top",top,0.9,scale:3),part("bottom",bottom,0.9,scale:3)]) == nil, "unbounded_scale_reject")
expect(S.fuse(seed: seed, observations: [part("a",top,0.8,dx:0.2),part("b",bottom,0.8,dx:0.2),part("c",top,0.8),part("d",bottom,0.8)]) == nil, "equally_strong_disjoint_groups_reject")
expect(!S.permitsSinglePart(confirmedFrames: 0, confidence: 1, similarity: 1, colorful: 1),
       "single_part_cannot_initialize_tracking")
expect(!S.permitsSinglePart(confirmedFrames: 5, confidence: 1, similarity: 1, colorful: 1),
       "single_part_needs_independent_confirmation_history")
expect(S.permitsSinglePart(confirmedFrames: 6, confidence: 0.8, similarity: 0.8, colorful: 0.8),
       "confirmed_current_visible_part_can_maintain_identity")
expect(!S.permitsSinglePart(confirmedFrames: 6, confidence: 0.7, similarity: 1, colorful: 1),
       "appearance_alone_does_not_replace_current_tracking_evidence")
expect(!S.permitsSinglePart(confirmedFrames: 6, confidence: 1, similarity: 0.6, colorful: 1),
       "confident_hand_or_background_with_changed_appearance_rejects")
expect(!S.permitsSinglePart(confirmedFrames: 6, confidence: 1, similarity: 1, colorful: 0),
       "gray_appearance_alone_cannot_authorize_single_part_bridge")
expect(!S.permitsSinglePart(confirmedFrames: 6, confidence: 1, similarity: .nan, colorful: 1),
       "invalid_appearance_match_rejects")
expect(!S.continuous(CGRect(x:0.4848,y:0.523,width:0.1483,height:0.2037),
                     with:CGRect(x:0.4391,y:0.4881,width:0.2139,height:0.3857)),
       "recorded_B71_weak_whole_scale_jump_must_not_replace_part_estimate")
expect(S.continuous(seed.offsetBy(dx:0.01,dy:0.01),with:seed), "real_small_motion_remains_eligible")
let localStretch = S.Observation(name:"detail", fraction:top,
    rect:CGRect(x:0.37,y:0.54,width:0.16,height:0.06),confidence:0.9)
expect(S.project(seed:seed,observation:localStretch) == nil,
       "stretched_detail_cannot_get_single_part_authority")
expect(S.project(seed:seed,observation:localStretch,maximumAspectChange:2.5) != nil,
       "perspective_stretch_is_available_for_multilateral_consensus_only")
expect(S.fuse(seed:seed,observations:[localStretch]) == nil,
       "wider_consensus_shape_model_still_cannot_drive_alone")
print("\(assertions) assertions, \(failures) failures")
exit(failures == 0 ? 0 : 1)
