import Foundation
import CoreGraphics
typealias CVPixelBuffer = Int
func CVPixelBufferGetWidth(_ buffer: Int) -> Int { 480 }
func CVPixelBufferGetHeight(_ buffer: Int) -> Int { 640 }
enum CMTrustedPixelFixture {
    static var copies: [(buffer: Int, copied: Int)] = []
    static var attempts: [Int] = []
    static var failures: Set<Int> = []
    static func copy(_ source: Int) -> Int? {
        attempts.append(source)
        guard !failures.contains(source) else { return nil }
        let copied = source + 100_000
        copies.append((source, copied))
        return copied
    }
}
class VNDetectedObjectObservation {
    var boundingBox: CGRect
    var confidence: Float = 0.95
    init(boundingBox: CGRect) { self.boundingBox = boundingBox }
}
final class CMPhysicalObjectUnavailableWholeObservation: VNDetectedObjectObservation {
    override init(boundingBox: CGRect) { super.init(boundingBox: boundingBox); confidence = 0 }
}
final class VNTrackObjectRequest {
    enum TrackingLevel { case accurate }
    static var created: [VNTrackObjectRequest] = []
    var revision = 1
    var trackingLevel = TrackingLevel.accurate
    var isLastFrame = false
    var cancelCalls = 0
    var inputAssignments = 0
    var inputObservation: VNDetectedObjectObservation { didSet { inputAssignments += 1 } }
    var results: [VNDetectedObjectObservation]?
    init(detectedObjectObservation: VNDetectedObjectObservation) {
        inputObservation = detectedObjectObservation
        Self.created.append(self)
    }
    func cancel() { cancelCalls += 1 }
}
let VNTrackObjectRequestRevision2 = 2
final class VNSequenceRequestHandler {
    static var performed: [(buffer: Int, request: VNTrackObjectRequest)] = []
    static var failBuffers: Set<Int> = []
    static var outputs: [Int: VNDetectedObjectObservation] = [:]
    func perform(_ requests: [VNTrackObjectRequest], on buffer: Int) throws {
        for request in requests {
            Self.performed.append((buffer, request))
            if request.cancelCalls > 0 || Self.failBuffers.contains(buffer) { throw NSError(domain: "fixture.vision", code: 1) }
            request.results = [Self.outputs[buffer] ?? request.inputObservation]
        }
    }
}
final class CMPhysicalObjectReacquirer {
    static var available = true
    static var initializations: [(buffer: Int, rect: CGRect)] = []
    static var adds: [(buffer: Int, rect: CGRect)] = []
    static var finds: [(buffer: Int, token: Double)] = []
    static var resets = 0
    static var addOutcomes: [Int: Bool] = [:]
    static var findResults: [Int: [String: Any]] = [:]
    static var acceptedBox = CGRect(x: 0.65, y: 0.1, width: 0.3, height: 0.4)
    private var votes = 0
    private var lastToken: TimeInterval?
    init?(pixelBuffer: Int, selection: CGRect) {
        guard Self.available else { return nil }
        Self.initializations.append((pixelBuffer, selection))
    }
    func addTrustedPixelBuffer(_ buffer: Int, rect: CGRect) -> [String: Any] {
        Self.adds.append((buffer, rect))
        return ["added": Self.addOutcomes[buffer] ?? (Self.adds.count <= 7), "accepted": false]
    }
    func findPixelBuffer(_ buffer: Int, frameToken: Double) -> [String: Any] {
        Self.finds.append((buffer, frameToken))
        if let explicit = Self.findResults[buffer] { votes = 0; lastToken = frameToken; return explicit }
        if let previous = lastToken, frameToken - previous > 0.25 { votes = 0 }
        lastToken = frameToken
        votes += 1
        guard votes >= 3 else { return ["accepted": false, "identity_match": true, "quality": 0.0] }
        return ["accepted": true, "quality": 0.96, "recovered_verified_identity": true,
            "bbox": [Self.acceptedBox.minX, Self.acceptedBox.minY, Self.acceptedBox.width, Self.acceptedBox.height].map(Double.init)]
    }
    func resetSearchConfirmation() { votes = 0; Self.resets += 1 }
    static func reset() {
        available = true; initializations = []; adds = []; finds = []; resets = 0; findResults = [:]; addOutcomes = [:]
        CMTrustedPixelFixture.copies = []; CMTrustedPixelFixture.failures = []; CMTrustedPixelFixture.attempts = []
        acceptedBox = CGRect(x: 0.65, y: 0.1, width: 0.3, height: 0.4)
        VNTrackObjectRequest.created = []; VNSequenceRequestHandler.performed = []
        VNSequenceRequestHandler.failBuffers = []; VNSequenceRequestHandler.outputs = [:]
        CMPhysicalObjectPartsSession.calls = []; CMPhysicalObjectPartsSession.outputs = [:]
        CMPhysicalObjectPartsSession.seeds = []; CMPhysicalObjectPartsSession.releases = 0
    }
}
// INSERT_MEASUREMENT_AND_SAFETY
final class CMPhysicalObjectPartsSession {
    static var seeds: [CGRect] = []
    static var calls: [(buffer: Int, initialization: Bool, full: VNDetectedObjectObservation)] = []
    static var outputs: [Int: CMPhysicalObjectMeasurement] = [:]
    static var releases = 0
    let seed: CGRect
    var lastRect: CGRect
    var wholeFailure: String?
    init(seed: CGRect) { self.seed = seed; lastRect = seed; Self.seeds.append(seed) }
    deinit { Self.releases += 1 }
    // INSERT_WHOLE_OBSERVATION
    // INSERT_CONTINUITY
    func measure(pixels: Int, full: VNDetectedObjectObservation, initializationOnly: Bool = false) -> CMPhysicalObjectMeasurement {
        Self.calls.append((pixels, initializationOnly, full))
        let output = Self.outputs[pixels] ?? CMPhysicalObjectMeasurement(rect: full.confidence >= 0.5 ? full.boundingBox : lastRect,
            previousRect: lastRect, quality: full.confidence >= 0.5 ? full.confidence : 0.3,
            source: full.confidence >= 0.5 ? "foreground_instance_vision" : "foreground_parts_unconfirmed",
            isHeldObservation: full.confidence < 0.5)
        if output.quality >= 0.5 { lastRect = output.rect }
        return output
    }
}
// INSERT_RECOVERY_SESSION

var assertions = 0, failures = 0
func expect(_ value: @autoclosure () -> Bool, _ label: String) {
    assertions += 1
    if !value() { failures += 1; print("FAIL: \(label)") }
}
let seed = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
func measurement(_ rect: CGRect = seed, previous: CGRect? = nil, quality: Float = 0.97,
                 source: String = "fixed_patch_multiscale", margin: Double? = 0.15,
                 held: Bool = false, originalTag: Bool = false, verifiedTag: Bool = false) -> CMPhysicalObjectMeasurement {
    var diagnostics: [String: Any] = ["accepted": true]
    if let margin { diagnostics["margin"] = margin }
    if source.hasSuffix("foreground_parts_consensus") {
        diagnostics["support"] = ["top", "bottom"]
        diagnostics["parts"] = [["name": "top", "confidence": Float(0.8)], ["name": "bottom", "confidence": Float(0.8)]]
    }
    if source.hasSuffix("foreground_confirmed_part") {
        diagnostics["support"] = ["top"]
        diagnostics["appearance_similarity"] = ["top": Float(0.9)]
    }
    return CMPhysicalObjectMeasurement(rect: rect, previousRect: previous ?? rect, quality: quality, source: source,
        patchDiagnostics: diagnostics, isHeldObservation: held,
        recoveredOriginalTemplate: originalTag, recoveredVerifiedIdentity: verifiedTag)
}
func setup() -> (CMPhysicalObjectRecoverySession, VNTrackObjectRequest) {
    CMPhysicalObjectReacquirer.reset()
    let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: seed))
    return (CMPhysicalObjectRecoverySession(request: request, buffer: 0, selection: seed)!, request)
}
@discardableResult
func searchFrame(_ session: CMPhysicalObjectRecoverySession, buffer: Int, at time: Double) -> CMPhysicalObjectMeasurement {
    let full = session.observation(buffer: buffer) ?? VNDetectedObjectObservation(boundingBox: seed)
    return session.measure(buffer: buffer, observation: full, capturedAt: time)
}
func learn(_ session: CMPhysicalObjectRecoverySession, start: Int = 1, time: Double = 100,
           measured: CMPhysicalObjectMeasurement = measurement()) {
    for i in 0..<3 { session.observeReliable(measurement: measured, buffer: start + i, capturedAt: time + Double(i) * 0.01) }
}
func propose(_ session: CMPhysicalObjectRecoverySession, start: Int = 10, time: Double = 101) -> CMPhysicalObjectMeasurement {
    session.beginSearch()
    let warmCount = session.pendingHistoryCount
    for index in 0..<warmCount {
        let before = CMPhysicalObjectReacquirer.finds.count
        let historical = searchFrame(session, buffer: 10_000 + index, at: time - 0.08 + Double(index) * 0.01)
        expect(historical.source == "verified_identity_history_warmup_hold" && historical.isHeldObservation &&
            !historical.recoveredVerifiedIdentity && CMPhysicalObjectReacquirer.finds.count == before,
            "one_frozen_history_view_per_fresh_frame_never_advances_native_confirmation")
    }
    let first = searchFrame(session, buffer: start, at: time)
    let second = searchFrame(session, buffer: start + 1, at: time + 0.01)
    expect(first.isHeldObservation && second.isHeldObservation && !first.recoveredVerifiedIdentity && !second.recoveredVerifiedIdentity,
           "first_two_backend_identity_matches_never_create_recovery_proposal")
    let third = searchFrame(session, buffer: start + 2, at: time + 0.02)
    expect(third.recoveredVerifiedIdentity && !third.recoveredOriginalTemplate && third.quality >= 0.9
        && session.isSearching && !session.hasResumedTracking,
           "third_complete_identity_match_proposes_without_exiting_search")
    return third
}

do {
    CMPhysicalObjectReacquirer.reset()
    CMPhysicalObjectReacquirer.available = false
    let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: seed))
    expect(CMPhysicalObjectRecoverySession(request: request, buffer: 0, selection: seed) == nil,
           "empty_native_identity_fails_session_initialization")
}
do {
    let (session, request) = setup()
    expect(session.requestIdentity == ObjectIdentifier(request) && session.observation(buffer: 1) == nil
        && !session.isSearching && !session.hasResumedTracking,
           "new_identity_session_does_not_replace_normal_tracking_route")
    expect(CMPhysicalObjectReacquirer.initializations.count == 1
        && CMPhysicalObjectReacquirer.initializations[0].buffer == 0 && CMPhysicalObjectReacquirer.initializations[0].rect == seed,
           "native_identity_is_created_on_exact_original_selection_pixels_and_box")
    expect(session.unavailableObservation.confidence == 0 && session.unavailableObservation.boundingBox == seed,
           "unavailable_observation_is_explicit_zero_confidence")
    for i in 1...2 { session.observeReliable(measurement: measurement(), buffer: i, capturedAt: 100 + Double(i) * 0.01) }
    expect(CMTrustedPixelFixture.copies.isEmpty, "two_strong_ready_callbacks_cannot_add_identity_view")
    session.observeReliable(measurement: measurement(), buffer: 3, capturedAt: 100.03)
    expect(CMTrustedPixelFixture.copies.map { $0.buffer } == [3], "third_strong_ready_frame_caches_an_independent_copy_of_its_exact_pixels")
    learn(session, start: 4, time: 100.1)
    expect(CMTrustedPixelFixture.copies.count == 1, "bank_sampling_is_rate_limited_after_three_more_strong_frames")
    session.observeReliable(measurement: measurement(), buffer: 7, capturedAt: 100.1499)
    expect(CMTrustedPixelFixture.copies.count == 1, "less_than_120ms_since_cache_attempt_cannot_add_another_view")
    session.observeReliable(measurement: measurement(), buffer: 8, capturedAt: 100.1501)
    expect(CMTrustedPixelFixture.copies.map { $0.buffer } == [3, 8], "history_cache_uses_current_frame_after_sampling_interval")
    let added = CMTrustedPixelFixture.copies.count
    session.observeReliable(measurement: measurement(), buffer: 8, capturedAt: 100.1501)
    expect(CMTrustedPixelFixture.copies.count == added, "same_capture_token_is_never_added_twice")
}
let learningCases: [(String, Float, Double?, Bool)] = [
    ("fixed_patch_multiscale", 0.95, 0.12, true), ("appearance_patch_multiscale", 0.949, 0.15, false),
    ("fixed_patch_multiscale", 0.97, 0.119, false), ("fixed_patch_multiscale", 1, nil, false),
    ("fixed_patch_multiscale", 1, .nan, false), ("foreground_color_shape", 0.85, 0.15, true),
    ("foreground_color_shape", 0.849, 0.15, false), ("foreground_color_shape", 0.95, 0.149, false),
    ("foreground_features", 0.95, nil, true), ("foreground_features", 0.949, nil, false),
    ("foreground_parts_consensus", 0.8, nil, true), ("foreground_parts_consensus", 0.799, nil, false),
    ("foreground_confirmed_part", 0.8, nil, true), ("foreground_confirmed_part", 0.799, nil, false),
    ("foreground_whole_with_visible_part", 0.9, nil, true), ("foreground_instance_vision", 0.9, nil, true),
    ("foreground_instance_vision", 0.899, nil, false),
    ("vision", 1, nil, false), ("unknown", 1, nil, false),
    ("snapshot_parts_shadow_foreground_parts_consensus", 0.9, nil, true),
    ("verified_identity_resume_foreground_features", 0.95, nil, true)]
for (source, quality, margin, permitted) in learningCases {
    let (session, _) = setup()
    learn(session, measured: measurement(quality: quality, source: source, margin: margin))
    expect((CMTrustedPixelFixture.copies.count == 1) == permitted,
           "bank_source_specific_quality_and_margin_gate_\(source)_\(quality)_\(String(describing: margin))")
}
for blocked in [measurement(held: true), measurement(originalTag: true), measurement(verifiedTag: true),
                measurement(quality: .nan), measurement(seed.offsetBy(dx: 0.2, dy: 0), previous: seed),
                measurement(CGRect(x: 0, y: 0, width: 1.1, height: 0.1))] {
    let (session, _) = setup()
    learn(session, measured: blocked)
    expect(CMTrustedPixelFixture.copies.isEmpty, "held_recovery_tag_or_invalid_geometry_never_trains_bank")
}
for source in ["fixed_patch_multiscale", "foreground_color_shape", "foreground_features"] {
    let (session, _) = setup()
    var rejected = measurement(quality: 1, source: source)
    rejected.patchDiagnostics["accepted"] = false
    learn(session, measured: rejected)
    expect(CMTrustedPixelFixture.copies.isEmpty, "native_source_label_without_actual_native_acceptance_cannot_train_\(source)")
}
for similarity: Float in [0.849, .nan, .infinity] {
    let (session, _) = setup()
    var weak = measurement(quality: 0.8, source: "foreground_confirmed_part")
    weak.patchDiagnostics["appearance_similarity"] = ["top": similarity, "bottom": Float(1)]
    learn(session, measured: weak)
    expect(CMTrustedPixelFixture.copies.isEmpty, "single_part_requires_its_own_supported_frozen_appearance_similarity_\(similarity)")
}
do {
    let (session, _) = setup()
    var boundary = measurement(quality: 0.8, source: "foreground_confirmed_part")
    boundary.patchDiagnostics["appearance_similarity"] = ["top": Double(0.85)]
    learn(session, measured: boundary)
    expect(CMTrustedPixelFixture.copies.count == 1, "single_part_exact_similarity_boundary_is_eligible_for_canonical_validation")
}
for parts: [[String: Any]] in [
    [["name": "top", "confidence": Float(0.74)], ["name": "bottom", "confidence": Float(0.9)]],
    [["name": "top", "confidence": Float(0.9)], ["name": "top", "confidence": Float(0.9)]],
    [["name": "top", "confidence": Float(0.9)], ["name": "full", "confidence": Float(1)]]
] {
    let (session, _) = setup()
    var weak = measurement(quality: 0.9, source: "foreground_parts_consensus")
    weak.patchDiagnostics["parts"] = parts
    learn(session, measured: weak)
    expect(CMTrustedPixelFixture.copies.isEmpty, "consensus_learning_requires_two_distinct_nonfull_current_strong_parts")
}
do {
    let (session, _) = setup()
    CMPhysicalObjectReacquirer.addOutcomes[100_003] = false
    learn(session)
    session.observeReliable(measurement: measurement(), buffer: 4, capturedAt: 100.03)
    expect(CMTrustedPixelFixture.copies.map { $0.buffer } == [3] && CMPhysicalObjectReacquirer.adds.isEmpty,
           "normal_tracking_only_caches_and_never_attempts_canonical_sift_learning")
    session.observeReliable(measurement: measurement(), buffer: 5, capturedAt: 100.1401)
    expect(CMTrustedPixelFixture.copies.map { $0.buffer } == [3, 5],
           "cache_sampling_clock_is_independent_of_future_native_add_success")
}
do {
    let (session, _) = setup()
    session.observeReliable(measurement: measurement(), buffer: 1, capturedAt: 100.01)
    session.observeReliable(measurement: measurement(), buffer: 2, capturedAt: 100.02)
    session.invalidateReliableSequence()
    for i in 3...4 { session.observeReliable(measurement: measurement(), buffer: i, capturedAt: 100 + Double(i) * 0.01) }
    expect(CMTrustedPixelFixture.copies.isEmpty, "main_rejected_frame_breaks_learning_sequence_even_without_observe_callback")
    session.observeReliable(measurement: measurement(), buffer: 5, capturedAt: 100.05)
    expect(CMTrustedPixelFixture.copies.map { $0.buffer } == [5], "learning_requires_three_new_frames_after_main_invalidates_sequence")
}
do {
    let (session, _) = setup()
    learn(session, time: 200)
    for index in 4...12 {
        session.observeReliable(measurement: measurement(), buffer: index, capturedAt: 200.02 + Double(index - 3) * 0.13)
    }
    expect(session.cachedHistoryCount == 7 && session.pendingHistoryCount == 0 &&
        CMPhysicalObjectReacquirer.adds.isEmpty && CMPhysicalObjectReacquirer.finds.isEmpty,
        "normal_tracking_history_is_bounded_to_seven_with_zero_native_learning_or_search_work")
    expect(CMTrustedPixelFixture.copies.allSatisfy { $0.buffer != $0.copied } &&
        session.lastLearningDiagnostics?["native_learning_performed"] as? Bool == false &&
        session.lastLearningDiagnostics?["captured_at"] as? Double == 200.02 + 9 * 0.13,
        "history_owns_independent_pixel_ids_and_records_exact_authorized_capture_time")
    session.beginSearch()
    expect(session.cachedHistoryCount == 0 && session.pendingHistoryCount == 7,
        "search_freezes_and_transfers_bounded_pre_loss_history_without_importing_it_synchronously")
    for index in 0..<7 {
        let current = searchFrame(session, buffer: 100 + index, at: 300 + Double(index) * 0.01)
        expect(current.isHeldObservation && !current.recoveredVerifiedIdentity &&
            CMPhysicalObjectReacquirer.finds.isEmpty && CMPhysicalObjectReacquirer.adds.count == index + 1 &&
            session.pendingHistoryCount == 6 - index,
            "warmup_\(index)_imports_one_history_copy_and_never_matches_current_lost_pixels")
        expect(current.patchDiagnostics["native_learning_performed"] as? Bool == true &&
            current.patchDiagnostics["captured_at"] as? Double == 300 + Double(index) * 0.01,
            "warmup_diagnostic_\(index)_belongs_to_current_callback")
        session.beginSearch()
        expect(session.pendingHistoryCount == 6 - index, "repeated_begin_does_not_restart_history_import_\(index)")
    }
    expect(CMPhysicalObjectReacquirer.adds.map { $0.buffer } == Array(6...12).map { $0 + 100_000 },
        "warmup_imports_latest_seven_saved_copies_in_capture_order_and_releases_evicted_older_views")
    let one = searchFrame(session, buffer: 200, at: 300.1)
    let two = searchFrame(session, buffer: 201, at: 300.11)
    let three = searchFrame(session, buffer: 202, at: 300.12)
    expect(one.isHeldObservation && two.isHeldObservation && three.recoveredVerifiedIdentity &&
        CMPhysicalObjectReacquirer.finds.map { $0.buffer } == [200, 201, 202],
        "warmup_is_followed_by_three_new_current_image_confirmations")
}
do {
    let (session, _) = setup()
    CMTrustedPixelFixture.failures.insert(3)
    learn(session)
    session.observeReliable(measurement: measurement(), buffer: 4, capturedAt: 100.03)
    expect(CMTrustedPixelFixture.attempts == [3] && session.cachedHistoryCount == 0 &&
        CMPhysicalObjectReacquirer.adds.isEmpty,
        "failed_small_pixel_copy_is_rate_limited_and_cannot_retain_or_learn_camera_pool_pixels")
    session.observeReliable(measurement: measurement(), buffer: 5, capturedAt: 100.1401)
    expect(CMTrustedPixelFixture.attempts == [3, 5] && session.cachedHistoryCount == 1,
        "later_fresh_strong_frame_can_fill_cache_after_copy_failure")
    session.beginSearch()
    let before = session.pendingHistoryCount
    let invalid = searchFrame(session, buffer: 6, at: .nan)
    expect(invalid.isHeldObservation && session.pendingHistoryCount == before && CMPhysicalObjectReacquirer.adds.isEmpty,
        "invalid_current_timestamp_cannot_consume_history_or_advance_confirmation")
    CMPhysicalObjectReacquirer.addOutcomes[100_005] = false
    let warm = searchFrame(session, buffer: 7, at: 101)
    expect(warm.isHeldObservation && session.pendingHistoryCount == 0 && CMPhysicalObjectReacquirer.finds.isEmpty,
        "rejected_canonical_history_is_discarded_once_without_retrying_or_matching_current_frame")
    let current = searchFrame(session, buffer: 8, at: 101.01)
    expect(current.isHeldObservation && CMPhysicalObjectReacquirer.adds.count == 1 && CMPhysicalObjectReacquirer.finds.count == 1,
        "failed_history_import_does_not_block_subsequent_frozen_original_identity_search")
}
do {
    let (session, request) = setup()
    learn(session)
    let candidate = propose(session)
    let searches = CMPhysicalObjectReacquirer.finds.count
    let resets = CMPhysicalObjectReacquirer.resets
    session.beginSearch()
    expect(CMPhysicalObjectReacquirer.resets == resets, "repeated_begin_search_preserves_pending_proposal")
    learn(session, start: 90, time: 101.1)
    expect(CMPhysicalObjectReacquirer.adds.count == 1, "search_and_pending_proposal_never_learn_new_identity_views")
    expect(searchFrame(session, buffer: 13, at: 101.03).isHeldObservation
        && searchFrame(session, buffer: 14, at: 101.04).isHeldObservation
        && CMPhysicalObjectReacquirer.finds.count == searches,
           "pending_proposal_frames_hold_without_repeating_search_or_emitting_more_tags")
    expect(!session.commitRecovery(buffer: 12, rect: candidate.rect, capturedAt: 101.021)
        && !session.commitRecovery(buffer: 12, rect: candidate.rect.offsetBy(dx: 0.001, dy: 0), capturedAt: 101.02)
        && VNSequenceRequestHandler.performed.isEmpty,
           "commit_must_match_both_proposal_token_and_exact_measured_rect")
    request.cancel()
    let originalAssignments = request.inputAssignments
    expect(session.commitRecovery(buffer: 999, rect: candidate.rect, capturedAt: 101.02),
           "main_accepted_proposal_commits_without_rechecking_capture_age")
    expect(!session.isSearching && session.hasResumedTracking
        && VNSequenceRequestHandler.performed.map { $0.buffer } == [12]
        && CMPhysicalObjectPartsSession.calls.map { $0.buffer } == [12]
        && CMPhysicalObjectPartsSession.calls[0].initialization,
           "commit_uses_retained_confirmed_pixels_instead_of_later_caller_buffer")
    let child = VNTrackObjectRequest.created.last!
    expect(child !== request && child.revision == 2 && !child.isLastFrame
        && VNSequenceRequestHandler.performed.allSatisfy { $0.request !== request }
        && request.cancelCalls == 1 && request.inputAssignments == originalAssignments,
           "committed_recovery_owns_independent_v2_stream_without_reperforming_cancelled_main_request")
    expect(!session.commitRecovery(buffer: 12, rect: candidate.rect, capturedAt: 101.02)
        && VNSequenceRequestHandler.performed.count == 1,
           "same_proposal_cannot_seed_independent_trackers_twice")
    session.rejectRecovery(capturedAt: 101.02)
    expect(session.hasResumedTracking && !session.isSearching, "late_reject_cannot_undo_already_committed_recovery")
    let nextRect = candidate.rect.offsetBy(dx: -0.01, dy: 0.01)
    let actualWhole = VNDetectedObjectObservation(boundingBox: nextRect)
    VNSequenceRequestHandler.outputs[15] = actualWhole
    CMPhysicalObjectPartsSession.outputs[15] = measurement(nextRect, quality: 0.55, source: "foreground_parts_consensus")
    let full = session.observation(buffer: 15)!
    let delivered = session.measure(buffer: 15, observation: full, capturedAt: 101.05)
    expect(child.inputObservation === actualWhole && !delivered.isHeldObservation && delivered.quality == 0.55
        && delivered.previousRect == candidate.rect && !delivered.recoveredVerifiedIdentity,
           "resumed_whole_feedback_and_parts_position_use_current_measurement_without_new_identity_tag")
    CMPhysicalObjectPartsSession.outputs[16] = measurement(quality: 0.3, held: true)
    let held = searchFrame(session, buffer: 16, at: 101.06)
    expect(held.isHeldObservation && held.rect == nextRect && held.previousRect == nextRect,
           "weak_resumed_parts_hold_last_reliable_position")
    VNSequenceRequestHandler.failBuffers.insert(17)
    let absent = session.observation(buffer: 17)!
    let calls = VNSequenceRequestHandler.performed.count
    expect(absent.confidence == 0 && child.cancelCalls == 1 && request.cancelCalls == 1,
           "failed_whole_stream_only_cancels_independent_child")
    _ = session.observation(buffer: 18)
    expect(VNSequenceRequestHandler.performed.count == calls,
           "failed_child_whole_stream_is_not_reperformed_or_reseeded_on_each_frame")
    session.beginSearch()
    expect(session.isSearching && !session.hasResumedTracking && child.cancelCalls == 1
        && CMPhysicalObjectPartsSession.releases == 1,
           "new_search_retires_resumed_parts_and_preserves_frozen_identity_bank")
    expect(CMPhysicalObjectReacquirer.initializations.count == 1 && CMPhysicalObjectReacquirer.adds.count == 1,
           "repeated_loss_never_recreates_or_relearns_original_identity_on_lost_pixels")
}
do {
    let (session, _) = setup()
    let first = propose(session)
    session.rejectRecovery(capturedAt: 101.02)
    let second = propose(session, start: 20, time: 101.1)
    session.rejectRecovery(capturedAt: 101.02)
    expect(session.commitRecovery(buffer: 22, rect: second.rect, capturedAt: 101.1 + 0.02),
           "old_rejection_cannot_clear_newer_proposal")
    expect(first.rect == second.rect && CMPhysicalObjectReacquirer.finds.count == 6,
           "rejecting_proposal_requires_three_new_independent_native_search_frames")
}
do {
    let (session, request) = setup()
    learn(session)
    let local = seed.offsetBy(dx: 0.01, dy: 0)
    expect(session.nativeHistoryAddCount == 0,
        "native_history_counter_remains_zero_through_normal_ready_frame_cache")
    session.beginSearch()
    let warming = searchFrame(session, buffer: 40, at: 102)
    expect(warming.isHeldObservation && session.nativeHistoryAddCount == 1,
        "native_history_counter_increments_only_for_actual_import_after_search")
    _ = searchFrame(session, buffer: 41, at: 102.01)
    expect(session.cancelSearchForLocalRecovery(rect: local, capturedAt: 101) &&
        !session.isSearching && !session.hasResumedTracking && session.unavailableObservation.boundingBox == local &&
        session.observation(buffer: 42) == nil && session.pendingHistoryCount == 0 && session.cachedHistoryCount == 0,
        "main_approved_local_return_cancels_newer_unaccepted_search_samples_and_restores_original_route")
    expect(CMPhysicalObjectReacquirer.initializations.count == 1 && VNSequenceRequestHandler.performed.isEmpty &&
        request.cancelCalls == 0 && session.nativeHistoryAddCount == 1,
        "cancel_preserves_native_identity_and_does_not_create_or_retire_original_trackers")
    session.beginSearch()
    let old = searchFrame(session, buffer: 43, at: 101.5)
    expect(old.isHeldObservation && old.source == "verified_identity_invalid_frame_hold",
        "local_cancel_does_not_rewind_last_seen_measurement_timestamp")
    for (rect, time) in [(local, 100.99), (local, Double.nan), (CGRect.zero, 103)] {
        expect(!session.cancelSearchForLocalRecovery(rect: rect, capturedAt: time) && session.isSearching,
            "invalid_or_reliably_older_local_cancel_cannot_clear_search")
    }
    expect(session.cancelSearchForLocalRecovery(rect: local, capturedAt: 103),
        "fresh_local_return_cancels_search_after_rejected_cancel_attempts")
}
do {
    let (session, _) = setup()
    learn(session)
    expect(session.cancelSearchForLocalRecovery(rect: seed, capturedAt: 101) && !session.isSearching &&
        session.cachedHistoryCount == 0 && session.pendingHistoryCount == 0,
        "local_return_can_cancel_mailbox_transition_before_capture_queue_begins_search")
}
do {
    let (session, _) = setup()
    let candidate = propose(session)
    expect(session.cancelSearchForLocalRecovery(rect: seed, capturedAt: 101.03) &&
        !session.commitRecovery(buffer: 12, rect: candidate.rect, capturedAt: 101.02),
        "local_return_invalidates_pending_global_proposal")
}
do {
    let (session, _) = setup()
    let candidate = propose(session)
    _ = session.commitRecovery(buffer: 12, rect: candidate.rect, capturedAt: 101.02)
    expect(!session.cancelSearchForLocalRecovery(rect: seed, capturedAt: 101.03) && session.hasResumedTracking,
        "old_native_cancel_cannot_revert_an_already_committed_independent_tracking_route")
}
for invalid in [Double.nan, .infinity, -.infinity, 101.0] {
    let (session, _) = setup()
    session.beginSearch()
    _ = searchFrame(session, buffer: 10, at: 101)
    let count = CMPhysicalObjectReacquirer.finds.count
    let rejected = searchFrame(session, buffer: 11, at: invalid)
    expect(rejected.isHeldObservation && CMPhysicalObjectReacquirer.finds.count == count,
           "nonfinite_or_duplicate_search_frame_cannot_advance_backend_confirmation_\(invalid)")
}
for result: [String: Any] in [
    ["accepted": true, "quality": 0.89, "recovered_verified_identity": true, "bbox": [0.4, 0.4, 0.1, 0.1]],
    ["accepted": true, "quality": Double.nan, "recovered_verified_identity": true, "bbox": [0.4, 0.4, 0.1, 0.1]],
    ["accepted": true, "quality": 0.99, "bbox": [0.4, 0.4, 0.1, 0.1]],
    ["accepted": true, "quality": 0.99, "recovered_verified_identity": true, "bbox": [0.4, 0.4, -0.1, 0.1]],
    ["accepted": true, "quality": 0.99, "recovered_verified_identity": true, "bbox": [0.95, 0.4, 0.1, 0.1]]
] {
    let (session, _) = setup()
    session.beginSearch()
    CMPhysicalObjectReacquirer.findResults[10] = result
    let rejected = searchFrame(session, buffer: 10, at: 101)
    expect(rejected.isHeldObservation && !rejected.recoveredVerifiedIdentity && session.isSearching
        && !session.commitRecovery(buffer: 10, rect: seed, capturedAt: 101),
           "malformed_or_weak_native_candidate_cannot_create_committable_proposal")
}
do {
    let (session, _) = setup()
    let proposal = propose(session)
    VNSequenceRequestHandler.failBuffers.insert(12)
    CMPhysicalObjectPartsSession.outputs[12] = measurement(proposal.rect, quality: 0.3, held: true)
    expect(session.commitRecovery(buffer: 12, rect: proposal.rect, capturedAt: 101.02)
        && session.hasResumedTracking && !session.isSearching,
           "accepted_main_state_commits_even_when_independent_whole_initialization_fails")
    let next = searchFrame(session, buffer: 13, at: 101.03)
    expect(next.isHeldObservation && !next.recoveredVerifiedIdentity,
           "failed_new_tracking_models_produce_hold_instead_of_fabricating_identity_confirmation")
}
do {
    CMPhysicalObjectReacquirer.reset()
    let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: seed))
    var session: CMPhysicalObjectRecoverySession? = CMPhysicalObjectRecoverySession(request: request, buffer: 0, selection: seed)
    let proposal = propose(session!)
    _ = session!.commitRecovery(buffer: 12, rect: proposal.rect, capturedAt: 101.02)
    let child = VNTrackObjectRequest.created.last!
    session = nil
    expect(child.cancelCalls == 1 && child.isLastFrame && request.cancelCalls == 0
        && CMPhysicalObjectPartsSession.releases == 1,
           "deinit_releases_only_owned_child_trackers")
}
print("PhysicalObjectRecoverySessionSmoke: \(assertions) assertions, \(failures) failures")
print("Scope: exact recovery-session routing with native reacquisition, Vision and image parts represented by explicit doubles.")
exit(failures == 0 ? 0 : 1)
