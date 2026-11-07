//
//  CameraManager+GestureRecognizerDelegate.swift
//  KKGimbal
//

import Foundation
import KKGestureSDK

extension CameraManager: KKGestureRecognizerDelegate {

    public func gestureRecognizer(
        _ recognizer: KKGestureRecognizer,
        didOutput result: KKGestureRecognitionResult
    ) {
        // 关闭开关时，丢弃关闭前已经进入 MediaPipe/Vision 队列的在途结果。
        // 否则旧回调可能在 reset 之后重新累计并触发拍照或跟踪。
        guard isVGesEnable else { return }

        // 生产环境仅记录限频后的语义结果，不记录图像、关键点、手部位置
        // 或逐帧时间戳。用于 EMAS 排查识别源、置信度和业务状态。
        let logTime = Date()
        if !result.observations.isEmpty,
           (lastGestureRecognitionLogTime == nil
                || logTime.timeIntervalSince(
                    lastGestureRecognitionLogTime!
                ) >= 1.0) {
            lastGestureRecognitionLogTime = logTime
            let details = result.observations.map {
                "\($0.gesture.rawValue):"
                    + String(format: "%.2f", $0.confidence)
            }.joined(separator: ",")
            kkLog(
                "event=gesture_detected source=\(result.source.rawValue) "
                    + "session=\(result.sessionIdentifier) "
                    + "gestures=\(details) "
                    + "tracking=\(isAnyTrackingActive)"
            )
        }

        // 跟踪开启后张掌负责停止；没有点击锁定时，OK 可以重新指定
        // 优先人物；V 仍可触发拍摄，且拍摄后保持当前跟踪。
        if isAnyTrackingActive {
            handleTrackingGestureOutput(result)
            return
        }

        handleIdleGestureOutput(result)
    }

    public func gestureRecognizer(
        _ recognizer: KKGestureRecognizer,
        didFailWith error: Error
    ) {
        guard isVGesEnable else { return }

        let now = Date()
        guard lastGestureErrorLogTime == nil
                || now.timeIntervalSince(lastGestureErrorLogTime!) >= 2.0 else {
            return
        }
        lastGestureErrorLogTime = now
        kkWarn(
            "event=gesture_recognition_failed "
                + "description=\(error.localizedDescription)"
        )
    }

    private func handleTrackingGestureOutput(
        _ result: KKGestureRecognitionResult
    ) {
        let allowsOKTargetSelection = isFaceTrackingMode
            && !hasManualTrackingTargetLock

        // V、OK 和张掌分别累计，一种手势的异步空结果不会清空
        // 另一种手势的有效证据。
        if triggerShutterIfConfirmed(from: result, state: "tracking") {
            return
        }

        if allowsOKTargetSelection,
           isOKGestureConfirmed(from: result) {
            let gestureOwnerHandCenter = result.observations
                .filter { $0.gesture == .ok }
                .max(by: { $0.confidence < $1.confidence })?
                .normalizedHandCenter
            prepareGestureTrackingTargetPriority(
                normalizedHandCenter: gestureOwnerHandCenter
            )
            requireNeutralReleaseBeforeGestureTrackStop(
                reason: "ok_target_priority"
            )
            kkLog(
                "event=gesture_triggered gesture=ok "
                    + "action=track_target_priority state=tracking"
            )
            return
        }

        let raisedOpenPalmObservations = eligibleTrackingStopPalmObservations(
            in: result
        )

        if gestureTrackStopRequiresNeutralRelease,
           triggerFastTrackingStopAfterOKIfConfirmed(
                from: result,
                eligibleObservations: raisedOpenPalmObservations
           ) {
            stopTrackingForOpenPalm(reason: "ok_to_open_palm")
            return
        }

        guard isGestureTrackStopArmed(after: result) else { return }

        let stopResult = KKGestureRecognitionResult(
            observations: raisedOpenPalmObservations,
            source: result.source,
            timestampMilliseconds: result.timestampMilliseconds,
            sessionIdentifier: result.sessionIdentifier
        )
        if gestureTrackStopCommandStateMachine.ingest(
            stopResult,
            enabledGestures: [.openPalm]
        ) == .openPalm {
            stopTrackingForOpenPalm(reason: "stable_open_palm")
            return
        }
    }

    private func triggerFastTrackingStopAfterOKIfConfirmed(
        from result: KKGestureRecognitionResult,
        eligibleObservations: [KKGestureObservation]
    ) -> Bool {
        let transitionResult = KKGestureRecognitionResult(
            observations: eligibleObservations,
            source: result.source,
            timestampMilliseconds: result.timestampMilliseconds,
            sessionIdentifier: result.sessionIdentifier
        )
        guard gestureTrackStopAfterOKCommandStateMachine.ingest(
            transitionResult,
            enabledGestures: [.openPalm]
        ) == .openPalm else {
            return false
        }

        gestureTrackStopRequiresNeutralRelease = false
        gestureTrackStopNeutralStartedAtMs = nil
        gestureTrackStopCommandStateMachine.reset()
        kkLog(
            "event=gesture_track_stop_armed "
                + "reason=fast_ok_to_open_palm"
        )
        return true
    }

    private func stopTrackingForOpenPalm(reason: String) {
        gestureShutterCommandStateMachine.reset()
        gestureVisionShutterCommandStateMachine.reset()
        gestureOKCommandStateMachine.reset()
        gestureTrackStopAfterOKCommandStateMachine.reset()
        kkLog(
            "event=gesture_triggered gesture=open_palm "
                + "action=track_stop state=tracking reason=\(reason)"
        )
        if isPhysicalObjectTrackingActive {
            stopPhysicalObjectTracking(reason: "open_palm")
        } else if isFaceTrackingMode {
            stopFaceTracking()
        } else if currentTrackingRequest != nil {
            stopTracking()
        }
    }

    private func triggerShutterIfConfirmed(
        from result: KKGestureRecognitionResult,
        state: String
    ) -> Bool {
        let sourceEligibleObservations = result.observations.filter {
            observation in
            observation.gesture == .victory
                && isEligibleShutterVictory(
                    observation,
                    source: result.source
                )
        }

        if result.source == .mediaPipe,
           !sourceEligibleObservations.isEmpty {
            gestureLastEligibleMediaPipeVictoryAtMs = max(
                gestureLastEligibleMediaPipeVictoryAtMs ?? Int.min,
                result.timestampMilliseconds
            )
        }

        let commandObservations: [KKGestureObservation]
        if result.source == .appleVision {
            let hasRecentMediaPipeSeed =
                gestureLastEligibleMediaPipeVictoryAtMs.map {
                    abs(result.timestampMilliseconds - $0)
                        <= gestureVictoryVisionSeedWindowMilliseconds
                } ?? false
            let standaloneObservations = sourceEligibleObservations.filter {
                isEligibleStandaloneVisionVictory($0)
            }
            commandObservations = hasRecentMediaPipeSeed
                ? sourceEligibleObservations
                : standaloneObservations
            if !sourceEligibleObservations.isEmpty,
               !hasRecentMediaPipeSeed,
               standaloneObservations.isEmpty {
                logVictoryEligibility(
                    accepted: false,
                    reason: "waiting_for_consensus_or_large_hand",
                    confidence: sourceEligibleObservations[0].confidence,
                    handCenter:
                        sourceEligibleObservations[0].normalizedHandCenter,
                    handBounds:
                        sourceEligibleObservations[0]
                            .normalizedHandBoundingBox,
                    requiredTopY: 0.24,
                    source: result.source,
                    reference: "frame"
                )
            }
        } else {
            commandObservations = sourceEligibleObservations
        }

        if gestureShutterRequiresNeutralRelease {
            if !commandObservations.isEmpty {
                gestureShutterLastEligibleAtMs = max(
                    gestureShutterLastEligibleAtMs ?? Int.min,
                    result.timestampMilliseconds
                )
                return false
            }

            guard let lastEligibleAtMs = gestureShutterLastEligibleAtMs,
                  result.timestampMilliseconds - lastEligibleAtMs
                    >= gestureShutterNeutralReleaseMilliseconds else {
                return false
            }
            gestureShutterRequiresNeutralRelease = false
            gestureShutterLastEligibleAtMs = nil
            gestureLastEligibleMediaPipeVictoryAtMs = nil
            gestureShutterCommandStateMachine.reset()
            gestureVisionShutterCommandStateMachine.reset()
        }

        let shutterResult = KKGestureRecognitionResult(
            observations: commandObservations,
            source: result.source,
            timestampMilliseconds: result.timestampMilliseconds,
            sessionIdentifier: result.sessionIdentifier
        )
        let stateMachine = result.source == .mediaPipe
            ? gestureShutterCommandStateMachine
            : gestureVisionShutterCommandStateMachine
        guard stateMachine.ingest(
            shutterResult,
            enabledGestures: [.victory]
        ) == .victory else {
            return false
        }

        gestureShutterRequiresNeutralRelease = true
        gestureShutterLastEligibleAtMs = result.timestampMilliseconds
        gestureShutterCommandStateMachine.reset()
        gestureVisionShutterCommandStateMachine.reset()
        // 快门与 OK 是互斥命令，拍摄后不应继续消费拍摄前的 OK 候选。
        gestureOKCommandStateMachine.reset()
        kkLog(
            "event=gesture_triggered gesture=victory "
                + "action=shutter state=\(state) "
                + "source=\(result.source.rawValue)"
        )
        // 视频中再次确认 V 也要交给快门处理停止；上面的松手保护
        // 保证持续保持同一个 V 不会把刚启动的录像立即结束。
        delegate?.cameraManagerShutter?(self)
        return true
    }

    /// Vision 可独立放行的 V 必须是超高置信、大手框。跟踪中还要求手
    /// 靠近当前人物；空闲时没有可靠人物框，则进一步提高尺寸要求。
    private func isEligibleStandaloneVisionVictory(
        _ observation: KKGestureObservation
    ) -> Bool {
        guard observation.confidence
                >= gestureVictoryVisionStandaloneMinimumConfidence,
              let handCenter = observation.normalizedHandCenter,
              let handBounds = observation.normalizedHandBoundingBox,
              handBounds.height
                >= gestureVictoryVisionStandaloneMinimumHandHeight else {
            return false
        }

        if let faceRect = lastDetectedFaceRect {
            let maximumHorizontalDistance = max(
                0.20,
                faceRect.width * 1.35
            )
            let minimumVerticalY = max(
                0,
                faceRect.minY - faceRect.height * 1.40
            )
            let maximumVerticalY = min(
                1,
                faceRect.maxY + faceRect.height * 0.80
            )
            return abs(handCenter.x - faceRect.midX)
                    <= maximumHorizontalDistance
                && handCenter.y >= minimumVerticalY
                && handCenter.y <= maximumVerticalY
        }

        if let humanRect = lastDetectedHumanRect {
            let expandedHumanRect = humanRect.insetBy(
                dx: -humanRect.width * 0.15,
                dy: -humanRect.height * 0.08
            )
            return expandedHumanRect.contains(handCenter)
        }

        return handBounds.height
            >= gestureVictoryVisionStandaloneIdleHandHeight
    }

    private func isOKGestureConfirmed(
        from result: KKGestureRecognitionResult
    ) -> Bool {
        // OK 只由 Apple Vision 几何分类器产生。MediaPipe 的空结果
        // 不参与 OK 时间线，避免真实 OK 回调被判为过期。
        guard result.source == .appleVision else { return false }
        let okResult = KKGestureRecognitionResult(
            observations: result.observations.filter { $0.gesture == .ok },
            source: result.source,
            timestampMilliseconds: result.timestampMilliseconds,
            sessionIdentifier: result.sessionIdentifier
        )
        return gestureOKCommandStateMachine.ingest(
            okResult,
            enabledGestures: [.ok]
        ) == .ok
    }

    /// 两个识别源都先独立验证 21 点 V 几何；App 再用各自置信度、
    /// 手框尺寸和上沿位置排除远处类手轮廓。普通 Vision V 还必须在
    /// 业务层获得近期 MediaPipe 命中；只有超高置信、足够大的近人手框
    /// 才能不等待 MediaPipe。
    private func isEligibleShutterVictory(
        _ observation: KKGestureObservation,
        source: KKGestureRecognitionSource
    ) -> Bool {
        let minimumConfidence = source == .mediaPipe
            ? gestureVictoryMinimumConfidence
            : gestureVictoryVisionMinimumConfidence
        guard observation.confidence >= minimumConfidence else {
            logVictoryEligibility(
                accepted: false,
                reason: "low_confidence",
                confidence: observation.confidence,
                handCenter: observation.normalizedHandCenter,
                requiredTopY: 0.24,
                source: source,
                reference: "frame"
            )
            return false
        }
        guard let handCenter = observation.normalizedHandCenter else {
            logVictoryEligibility(
                accepted: false,
                reason: "missing_hand_center",
                confidence: observation.confidence,
                handCenter: nil,
                requiredTopY: 0.24,
                source: source,
                reference: "frame"
            )
            return false
        }

        let handBounds = observation.normalizedHandBoundingBox
        let handTopY = handBounds?.maxY ?? handCenter.y
        let handHeight = handBounds?.height ?? 0
        var requiredTopY = CGFloat(0.24)
        var requiredHeight = gestureVictoryMinimumHandHeight
        var reference = "frame"

        if let faceRect = lastDetectedFaceRect {
            reference = "face"
            requiredTopY = max(
                0.18,
                faceRect.minY - max(0.03, faceRect.height * 0.20)
            )
            requiredHeight = max(
                requiredHeight,
                faceRect.height * 0.24
            )
        } else if let humanRect = lastDetectedHumanRect {
            reference = "human"
            requiredTopY = max(
                0.20,
                humanRect.minY + humanRect.height * 0.28
            )
        }

        let hasUsableBounds = handBounds != nil
        let accepted = handCenter.y >= gestureVictoryMinimumHandCenterY
            && handTopY >= min(0.88, requiredTopY)
            && (!hasUsableBounds || handHeight >= requiredHeight)
        let reason: String
        if handCenter.y < gestureVictoryMinimumHandCenterY {
            reason = "center_too_low"
        } else if handTopY < min(0.88, requiredTopY) {
            reason = "top_below_subject"
        } else if hasUsableBounds && handHeight < requiredHeight {
            reason = "hand_too_small"
        } else {
            reason = "eligible"
        }
        logVictoryEligibility(
            accepted: accepted,
            reason: reason,
            confidence: observation.confidence,
            handCenter: handCenter,
            handBounds: handBounds,
            requiredTopY: requiredTopY,
            requiredHeight: requiredHeight,
            source: source,
            reference: reference
        )
        return accepted
    }

    private func logVictoryEligibility(
        accepted: Bool,
        reason: String,
        confidence: Float,
        handCenter: CGPoint?,
        handBounds: CGRect? = nil,
        requiredTopY: CGFloat,
        requiredHeight: CGFloat = 0,
        source: KKGestureRecognitionSource,
        reference: String
    ) {
        #if DEBUG
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        guard nowMs - gestureTrackingVictoryEligibilityLastLogTimeMs >= 500 else {
            return
        }
        gestureTrackingVictoryEligibilityLastLogTimeMs = nowMs
        let hand = handCenter.map {
            String(format: "%.3f,%.3f", $0.x, $0.y)
        } ?? "none"
        let bounds = handBounds.map {
            String(
                format: "%.3f,%.3f,%.3f,%.3f",
                $0.minX,
                $0.minY,
                $0.width,
                $0.height
            )
        } ?? "none"
        kkLog(
            String(
                format: "event=gesture_victory_candidate accepted=%@ reason=%@ source=%@ confidence=%.3f hand=%@ bounds=%@ requiredTopY=%.3f requiredHeight=%.3f reference=%@",
                accepted ? "true" : "false",
                reason,
                source.rawValue,
                confidence,
                hand,
                bounds,
                requiredTopY,
                requiredHeight,
                reference
            )
        )
        #endif
    }

    private func handleIdleGestureOutput(
        _ result: KKGestureRecognitionResult
    ) {
        if triggerShutterIfConfirmed(from: result, state: "idle") {
            return
        }

        guard isOKGestureConfirmed(from: result) else { return }
        let gestureOwnerHandCenter = result.observations
            .filter { $0.gesture == .ok }
            .max(by: { $0.confidence < $1.confidence })?
            .normalizedHandCenter
        kkLog(
            "event=gesture_triggered gesture=ok "
                + "action=track_start state=idle"
        )
        if captureMode != .hitchcock,
           currentTrackingRequest == nil,
           !isAnyTrackingActive {
            setupTrackingLayer()
            startFaceTracking()
            prepareGestureTrackingTargetPriority(
                normalizedHandCenter: gestureOwnerHandCenter
            )
            requireNeutralReleaseBeforeGestureTrackStop(
                reason: "ok_track_start"
            )
        }
    }

    /// OK 后优先等待手离开画面，防止放手过程误停。如果不放手而是
    /// 直接展开为高置信、明显举起的大手掌，则可直接解锁并快速停止。
    private func requireNeutralReleaseBeforeGestureTrackStop(reason: String) {
        gestureTrackStopRequiresNeutralRelease = true
        gestureTrackStopNeutralStartedAtMs = nil
        gestureShutterCommandStateMachine.reset()
        gestureVisionShutterCommandStateMachine.reset()
        gestureOKCommandStateMachine.reset()
        gestureTrackStopCommandStateMachine.reset()
        gestureTrackStopAfterOKCommandStateMachine.reset()
        kkLog(
            "event=gesture_track_stop_disarmed reason=\(reason) "
                + "waiting_for=neutral_release"
        )
    }

    private func eligibleTrackingStopPalmObservations(
        in result: KKGestureRecognitionResult
    ) -> [KKGestureObservation] {
        result.observations.filter { observation in
            observation.gesture == .openPalm
                && observation.confidence >= gestureTrackStopMinimumConfidence
                && isRaisedTrackingStopPalm(observation)
        }
    }

    /// 用手部关键点的整体框判断主动举掌。脸前举掌不再被拒绝；
    /// 但手掌上沿必须到达脸部/头肩高度，且手框足够大，才会进入快速确认。
    private func isRaisedTrackingStopPalm(
        _ observation: KKGestureObservation
    ) -> Bool {
        guard let handCenter = observation.normalizedHandCenter else {
            return false
        }

        let handBounds = observation.normalizedHandBoundingBox
        let handTopY = handBounds?.maxY ?? handCenter.y
        let handHeight = handBounds?.height ?? 0
        var requiredTopY = CGFloat(0.30)
        var requiredHeight = gestureTrackStopMinimumHandHeight
        var reference = "frame"

        if let faceRect = lastDetectedFaceRect {
            reference = "face"
            requiredTopY = max(
                0.20,
                faceRect.minY - max(0.02, faceRect.height * 0.10)
            )
            requiredHeight = max(
                requiredHeight,
                faceRect.height * 0.35
            )
        } else if let humanRect = lastDetectedHumanRect {
            reference = "human"
            requiredTopY = max(
                0.24,
                humanRect.minY + humanRect.height * 0.45
            )
        }

        let hasUsableBounds = handBounds != nil
        let accepted = handCenter.y >= gestureTrackStopMinimumHandCenterY
            && handTopY >= min(0.90, requiredTopY)
            && (!hasUsableBounds || handHeight >= requiredHeight)
        let rejectionReason: String
        if handCenter.y < gestureTrackStopMinimumHandCenterY {
            rejectionReason = "center_too_low"
        } else if handTopY < min(0.90, requiredTopY) {
            rejectionReason = "top_below_subject"
        } else if hasUsableBounds && handHeight < requiredHeight {
            rejectionReason = "hand_too_small"
        } else {
            rejectionReason = "eligible"
        }
        logTrackingStopPalmEligibility(
            accepted: accepted,
            reason: rejectionReason,
            confidence: observation.confidence,
            handCenter: handCenter,
            handBounds: handBounds,
            requiredTopY: requiredTopY,
            requiredHeight: requiredHeight,
            reference: reference
        )
        return accepted
    }

    private func logTrackingStopPalmEligibility(
        accepted: Bool,
        reason: String,
        confidence: Float,
        handCenter: CGPoint,
        handBounds: CGRect?,
        requiredTopY: CGFloat,
        requiredHeight: CGFloat,
        reference: String
    ) {
        #if DEBUG
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        guard nowMs - gestureTrackStopEligibilityLastLogTimeMs >= 500 else {
            return
        }
        gestureTrackStopEligibilityLastLogTimeMs = nowMs
        let bounds = handBounds.map {
            String(
                format: "%.3f,%.3f,%.3f,%.3f",
                $0.minX,
                $0.minY,
                $0.width,
                $0.height
            )
        } ?? "none"
        kkLog(
            String(
                format: "event=gesture_track_stop_candidate accepted=%@ reason=%@ confidence=%.3f hand=%.3f,%.3f bounds=%@ requiredTopY=%.3f requiredHeight=%.3f reference=%@",
                accepted ? "true" : "false",
                reason,
                confidence,
                handCenter.x,
                handCenter.y,
                bounds,
                requiredTopY,
                requiredHeight,
                reference
            )
        )
        #endif
    }

    private func isGestureTrackStopArmed(
        after result: KKGestureRecognitionResult
    ) -> Bool {
        guard gestureTrackStopRequiresNeutralRelease else { return true }

        guard result.observations.isEmpty else {
            gestureTrackStopNeutralStartedAtMs = nil
            return false
        }

        if let neutralStartedAtMs = gestureTrackStopNeutralStartedAtMs {
            guard result.timestampMilliseconds - neutralStartedAtMs
                    >= gestureTrackStopNeutralReleaseMilliseconds else {
                return false
            }

            gestureTrackStopRequiresNeutralRelease = false
            gestureTrackStopNeutralStartedAtMs = nil
            gestureShutterCommandStateMachine.reset()
            gestureVisionShutterCommandStateMachine.reset()
            gestureOKCommandStateMachine.reset()
            gestureTrackStopCommandStateMachine.reset()
            gestureTrackStopAfterOKCommandStateMachine.reset()
            kkLog(
                "event=gesture_track_stop_armed reason=neutral_release"
            )
            return true
        }

        gestureTrackStopNeutralStartedAtMs = result.timestampMilliseconds
        return false
    }
}
