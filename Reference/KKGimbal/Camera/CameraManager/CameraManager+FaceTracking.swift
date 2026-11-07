//
//  CameraManager+FaceTracking.swift
//  KKGimbal
//
//  Created by Kevin Tan
//

import Foundation
import Vision
import UIKit
import AVFoundation
import ImageIO

extension CameraManager {
    
    // MARK: - Face selection helpers (Android风格：选择与上一帧最接近的人脸)
    
    /// 计算两个归一化Rect的相交比（近似Android的“与上一帧最接近”逻辑）
    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull || inter.isEmpty { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        if unionArea <= 0 { return 0 }
        return interArea / unionArea
    }

    private func manualTrackingTargetSnapshot() -> (kind: CMTrackingCandidateKind, rect: CGRect)? {
        trackingTargetSelectionLock.lock()
        defer { trackingTargetSelectionLock.unlock() }
        guard let kind = manualTrackingTargetKind,
              let rect = manualTrackingTargetReferenceRect else {
            return nil
        }
        return (kind, rect)
    }

    var hasManualTrackingTargetLock: Bool {
        trackingTargetSelectionLock.lock()
        defer { trackingTargetSelectionLock.unlock() }
        return manualTrackingTargetKind != nil
            && manualTrackingTargetReferenceRect != nil
    }

    private func refreshManualTrackingTargetReference(
        kind: CMTrackingCandidateKind,
        rect: CGRect
    ) {
        trackingTargetSelectionLock.lock()
        if manualTrackingTargetKind != nil {
            manualTrackingTargetKind = kind
            manualTrackingTargetReferenceRect = rect
        }
        trackingTargetSelectionLock.unlock()
    }

    private func automaticTrackingTargetSnapshot() -> (kind: CMTrackingCandidateKind, rect: CGRect)? {
        trackingTargetSelectionLock.lock()
        defer { trackingTargetSelectionLock.unlock() }
        guard let kind = automaticTrackingTargetKind,
              let rect = automaticTrackingTargetReferenceRect else {
            return nil
        }
        return (kind, rect)
    }

    private func refreshAutomaticTrackingTargetReference(
        kind: CMTrackingCandidateKind,
        rect: CGRect
    ) {
        trackingTargetSelectionLock.lock()
        automaticTrackingTargetKind = kind
        automaticTrackingTargetReferenceRect = rect
        automaticTrackingTargetLastSeenAtMs = trackingSelectionNowMs()
        trackingTargetSelectionLock.unlock()
    }

    private func clearAutomaticTrackingTargetReference() {
        trackingTargetSelectionLock.lock()
        automaticTrackingTargetKind = nil
        automaticTrackingTargetReferenceRect = nil
        automaticTrackingTargetLastSeenAtMs = 0
        pendingGestureTrackingHandCenter = nil
        pendingGestureTrackingTargetDeadlineMs = 0
        isGestureTrackingTargetPriorityActive = false
        trackingTargetSelectionLock.unlock()
    }

    private var automaticTrackingSwitchAreaRatio: CGFloat { 1.20 }
    private var automaticTrackingTargetLossGraceMilliseconds: Int64 { 500 }
    private var pendingGestureTrackingTargetLifetimeMilliseconds: Int64 { 2_000 }

    private func trackingSelectionNowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    /// Called immediately after OK starts face tracking. The first reliable
    /// person detections associate this hand location with its owner.
    func prepareGestureTrackingTargetPriority(
        normalizedHandCenter: CGPoint?
    ) {
        trackingTargetSelectionLock.lock()
        pendingGestureTrackingHandCenter = normalizedHandCenter
        pendingGestureTrackingTargetDeadlineMs = normalizedHandCenter == nil
            ? 0
            : trackingSelectionNowMs()
                + pendingGestureTrackingTargetLifetimeMilliseconds
        isGestureTrackingTargetPriorityActive = false
        trackingTargetSelectionLock.unlock()

        if normalizedHandCenter != nil {
            kkLog("🖐️ 已获取 OK 手势位置，等待关联人物")
        } else {
            kkLog("⚠️ OK 手势缺少手部位置，按普通自动模式启动跟踪")
        }
    }

    private func pendingGestureTrackingHandCenterSnapshot() -> CGPoint? {
        let nowMs = trackingSelectionNowMs()
        trackingTargetSelectionLock.lock()
        defer { trackingTargetSelectionLock.unlock() }

        guard pendingGestureTrackingTargetDeadlineMs >= nowMs else {
            pendingGestureTrackingHandCenter = nil
            pendingGestureTrackingTargetDeadlineMs = 0
            return nil
        }
        return pendingGestureTrackingHandCenter
    }

    private func gestureTrackingTargetSnapshot()
        -> (kind: CMTrackingCandidateKind, rect: CGRect)? {
        trackingTargetSelectionLock.lock()
        defer { trackingTargetSelectionLock.unlock() }
        guard isGestureTrackingTargetPriorityActive,
              let kind = automaticTrackingTargetKind,
              let rect = automaticTrackingTargetReferenceRect else {
            return nil
        }
        return (kind, rect)
    }

    private func activateGestureTrackingTarget(
        kind: CMTrackingCandidateKind,
        rect: CGRect
    ) {
        trackingTargetSelectionLock.lock()
        pendingGestureTrackingHandCenter = nil
        pendingGestureTrackingTargetDeadlineMs = 0
        isGestureTrackingTargetPriorityActive = true
        automaticTrackingTargetKind = kind
        automaticTrackingTargetReferenceRect = rect
        automaticTrackingTargetLastSeenAtMs = trackingSelectionNowMs()
        trackingTargetSelectionLock.unlock()
        kkLog("🖐️ OK 手势人物已优先锁定: kind=\(kind.rawValue), bbox=\(rect)")
    }

    /// Returns true during the short loss grace period. Once it expires, both
    /// normal automatic identity and gesture priority are released so any
    /// reliable person can take over.
    private func shouldReserveAutomaticTargetAfterMiss() -> Bool {
        let nowMs = trackingSelectionNowMs()
        trackingTargetSelectionLock.lock()
        let lastSeenAtMs = automaticTrackingTargetLastSeenAtMs
        let shouldReserve = lastSeenAtMs > 0
            && nowMs - lastSeenAtMs
                < automaticTrackingTargetLossGraceMilliseconds
        let releasedGesturePriority = isGestureTrackingTargetPriorityActive
            && !shouldReserve
        if !shouldReserve {
            automaticTrackingTargetKind = nil
            automaticTrackingTargetReferenceRect = nil
            automaticTrackingTargetLastSeenAtMs = 0
            isGestureTrackingTargetPriorityActive = false
        }
        trackingTargetSelectionLock.unlock()

        if releasedGesturePriority {
            kkLog("🖐️ OK 手势人物持续丢失，解除优先并恢复自动选人")
        }
        return shouldReserve
    }

    private func trackingTargetArea(_ rect: CGRect) -> CGFloat {
        return max(0, rect.width * rect.height)
    }

    private func shouldSwitchAutomaticTarget(from current: CGRect, to challenger: CGRect) -> Bool {
        let currentArea = trackingTargetArea(current)
        let challengerArea = trackingTargetArea(challenger)
        guard currentArea > 0 else { return challengerArea > 0 }
        return challengerArea >= currentArea * automaticTrackingSwitchAreaRatio
    }

    private func isContinuousAutomaticTarget(
        _ candidate: CGRect,
        reference: CGRect
    ) -> Bool {
        if iou(candidate, reference) >= 0.08 { return true }

        let candidateArea = trackingTargetArea(candidate)
        let referenceArea = trackingTargetArea(reference)
        guard candidateArea > 0, referenceArea > 0 else { return false }
        let areaRatio = candidateArea / referenceArea
        let allowedHorizontalDistance = max(
            0.06,
            max(candidate.width, reference.width) * 0.85
        )
        let allowedVerticalDistance = max(
            0.08,
            max(candidate.height, reference.height) * 0.90
        )
        return areaRatio >= 0.55
            && areaRatio <= 1.80
            && abs(candidate.midX - reference.midX)
                <= allowedHorizontalDistance
            && abs(candidate.midY - reference.midY)
                <= allowedVerticalDistance
    }

    private func gestureAssociationScore(
        handCenter: CGPoint,
        personRect: CGRect,
        kind: CMTrackingCandidateKind
    ) -> CGFloat {
        let horizontalDistance = abs(handCenter.x - personRect.midX)
        let verticalDistance: CGFloat
        switch kind {
        case .face:
            // Raised hands can be well below or beside the face; horizontal
            // ownership is much more stable for side-by-side people.
            verticalDistance = abs(handCenter.y - personRect.midY) * 0.20
        case .human:
            let expandedBody = personRect.insetBy(dx: -0.08, dy: -0.05)
            if expandedBody.contains(handCenter) {
                verticalDistance = 0
            } else {
                verticalDistance = abs(handCenter.y - personRect.midY) * 0.10
            }
        }
        let sizeBonus = min(0.04, trackingTargetArea(personRect) * 0.10)
        return horizontalDistance + verticalDistance - sizeBonus
    }

    private func isHumanCandidate(
        _ humanRect: CGRect,
        associatedWithFace faceRect: CGRect
    ) -> Bool {
        let coverage = faceCoverage(faceRect, inside: humanRect)
        let horizontalDistance = abs(humanRect.midX - faceRect.midX)
        let allowedHorizontalDistance = max(0.18, min(0.30, humanRect.width * 0.45))
        return coverage >= 0.15 || horizontalDistance <= allowedHorizontalDistance
    }

    private func trackingCandidateMatchScore(
        _ candidate: CMTrackingCandidate,
        selection: (kind: CMTrackingCandidateKind, rect: CGRect)
    ) -> CGFloat {
        switch (candidate.kind, selection.kind) {
        case (.face, .face), (.human, .human):
            return iou(candidate.visionRect, selection.rect)
        case (.face, .human):
            return faceCoverage(candidate.visionRect, inside: selection.rect)
        case (.human, .face):
            return faceCoverage(selection.rect, inside: candidate.visionRect)
        }
    }

    private func resetTrackingDisplayState() {
        trackingDisplayRect = nil
        trackingDisplayKind = nil
        pendingTrackingDisplayKind = nil
        pendingTrackingDisplayKindCount = 0
    }

    private func stabilizedTrackingDisplayRect(
        proposedRect: CGRect,
        kind: CMTrackingCandidateKind,
        previewBounds: CGRect
    ) -> CGRect {
        guard let currentRect = trackingDisplayRect,
              let currentKind = trackingDisplayKind else {
            trackingDisplayRect = proposedRect
            trackingDisplayKind = kind
            pendingTrackingDisplayKind = nil
            pendingTrackingDisplayKindCount = 0
            return proposedRect
        }

        if currentKind != kind {
            if pendingTrackingDisplayKind == kind {
                pendingTrackingDisplayKindCount += 1
            } else {
                pendingTrackingDisplayKind = kind
                pendingTrackingDisplayKindCount = 1
            }

            // 人脸检测偶发漏一两帧时会短暂回退成人体框。显示层先保留原框，
            // 连续确认后才切换形态，控制层仍使用实时坐标继续跟踪。
            guard pendingTrackingDisplayKindCount >= 3 else {
                return currentRect
            }
            trackingDisplayKind = kind
            pendingTrackingDisplayKind = nil
            pendingTrackingDisplayKindCount = 0
        } else {
            pendingTrackingDisplayKind = nil
            pendingTrackingDisplayKindCount = 0
        }

        let shortSide = max(1, min(previewBounds.width, previewBounds.height))
        let centerDeadband = max(3, shortSide * 0.008)
        let sizeDeadband = max(4, shortSide * 0.012)
        let centerDelta = hypot(
            proposedRect.midX - currentRect.midX,
            proposedRect.midY - currentRect.midY
        )
        let widthDelta = abs(proposedRect.width - currentRect.width)
        let heightDelta = abs(proposedRect.height - currentRect.height)

        // 静止目标的检测框仍会有数像素抖动；小幅变化不刷新 UI，避免框持续闪动。
        if centerDelta <= centerDeadband,
           widthDelta <= sizeDeadband,
           heightDelta <= sizeDeadband {
            return currentRect
        }

        // 只平滑显示框，不影响云台实时控制。目标明显移动时仍能快速跟上。
        let blend: CGFloat = 0.35
        let stabilizedRect = CGRect(
            x: currentRect.minX + (proposedRect.minX - currentRect.minX) * blend,
            y: currentRect.minY + (proposedRect.minY - currentRect.minY) * blend,
            width: currentRect.width + (proposedRect.width - currentRect.width) * blend,
            height: currentRect.height + (proposedRect.height - currentRect.height) * blend
        )
        trackingDisplayRect = stabilizedRect
        return stabilizedRect
    }

    private func updateTrackingDisplayFrame(
        proposedRect: CGRect,
        kind: CMTrackingCandidateKind,
        isManuallyLocked: Bool
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isFaceTrackingMode,
                  let previewLayer = self.previewLayer else { return }

            let displayRect = self.stabilizedTrackingDisplayRect(
                proposedRect: proposedRect,
                kind: kind,
                previewBounds: previewLayer.bounds
            )
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.trackingLayer?.strokeColor = isManuallyLocked
                ? UIColor(red: 0x01/255.0, green: 0xD1/255.0, blue: 0xBB/255.0, alpha: 1.0).cgColor
                : UIColor.white.cgColor
            self.trackingLayer?.path = UIBezierPath(rect: displayRect).cgPath
            CATransaction.commit()
        }
    }

    private func renderTrackingCandidates(
        _ candidates: [CMTrackingCandidate],
        activeSelection: (kind: CMTrackingCandidateKind, rect: CGRect)?,
        manualSelection: (kind: CMTrackingCandidateKind, rect: CGRect)?
    ) {
        let render = { [weak self] in
            guard let self, let previewLayer = self.previewLayer else { return }

            CATransaction.begin()
            CATransaction.setDisableActions(true)

            while self.trackingCandidateLayers.count < candidates.count {
                let layer = CAShapeLayer()
                layer.fillColor = UIColor.clear.cgColor
                layer.lineWidth = 1.5
                layer.zPosition = 1
                previewLayer.addSublayer(layer)
                self.trackingCandidateLayers.append(layer)
            }
            while self.trackingCandidateLayers.count > candidates.count {
                self.trackingCandidateLayers.removeLast().removeFromSuperlayer()
            }

            let activeIndex: Int? = activeSelection.flatMap { selection in
                candidates.enumerated().max { lhs, rhs in
                    self.trackingCandidateMatchScore(lhs.element, selection: selection)
                        < self.trackingCandidateMatchScore(rhs.element, selection: selection)
                }.flatMap { match in
                    self.trackingCandidateMatchScore(match.element, selection: selection) >= 0.04
                        ? match.offset
                        : nil
                }
            }

            let lockedColor = UIColor(
                red: 0x01 / 255.0,
                green: 0xD1 / 255.0,
                blue: 0xBB / 255.0,
                alpha: 1.0
            ).cgColor
            for (index, candidate) in candidates.enumerated() {
                let layer = self.trackingCandidateLayers[index]
                // 当前目标由 trackingLayer 单独绘制；候选层不再重复叠一层，
                // 避免两条路径异步刷新时出现亮暗闪烁。
                if index == activeIndex {
                    layer.path = nil
                    continue
                }
                layer.path = UIBezierPath(rect: candidate.previewRect).cgPath
                layer.strokeColor = UIColor.white.cgColor
            }

            self.trackingLayer?.zPosition = 2
            self.trackingLayer?.strokeColor = manualSelection == nil
                ? UIColor.white.cgColor
                : lockedColor
            CATransaction.commit()
        }

        if Thread.isMainThread {
            render()
        } else {
            DispatchQueue.main.async(execute: render)
        }
    }

    private func updateTrackingCandidates(
        faceObservations: [VNFaceObservation],
        humanObservations: [VNDetectedObjectObservation],
        orientedImageSize: CGSize
    ) {
        guard let previewLayer else { return }

        let faceCandidates = faceObservations.map {
            CMTrackingCandidate(
                kind: .face,
                visionRect: $0.boundingBox,
                previewRect: previewRect(
                    forVisionBoundingBox: $0.boundingBox,
                    orientedImageSize: orientedImageSize,
                    previewLayer: previewLayer
                )
            )
        }
        let humanCandidates = humanObservations.map {
            CMTrackingCandidate(
                kind: .human,
                visionRect: $0.boundingBox,
                previewRect: previewRect(
                    forVisionBoundingBox: $0.boundingBox,
                    orientedImageSize: orientedImageSize,
                    previewLayer: previewLayer
                )
            )
        }
        let candidates = faceCandidates + humanCandidates

        trackingTargetSelectionLock.lock()
        trackingTargetCandidates = candidates
        let manualSelection: (kind: CMTrackingCandidateKind, rect: CGRect)?
        if let kind = manualTrackingTargetKind,
           let rect = manualTrackingTargetReferenceRect {
            manualSelection = (kind, rect)
        } else {
            manualSelection = nil
        }
        let activeSelection: (kind: CMTrackingCandidateKind, rect: CGRect)?
        if let manualSelection {
            activeSelection = manualSelection
        } else if let kind = automaticTrackingTargetKind,
                  let rect = automaticTrackingTargetReferenceRect {
            activeSelection = (kind, rect)
        } else {
            activeSelection = nil
        }
        trackingTargetSelectionLock.unlock()

        renderTrackingCandidates(
            candidates,
            activeSelection: activeSelection,
            manualSelection: manualSelection
        )
    }

    /// Auto tracking keeps every reliable person selectable. Tapping a new
    /// person locks it; tapping the currently locked person returns to auto.
    func selectAutoTrackingTarget(at pointInPreview: CGPoint) -> Bool {
        guard isFaceTrackingMode else { return false }

        trackingTargetSelectionLock.lock()
        let hitPadding: CGFloat = 16
        let hits = trackingTargetCandidates.filter {
            $0.previewRect.insetBy(dx: -hitPadding, dy: -hitPadding).contains(pointInPreview)
        }
        guard let selected = hits.min(by: {
            $0.previewRect.width * $0.previewRect.height
                < $1.previewRect.width * $1.previewRect.height
        }) else {
            trackingTargetSelectionLock.unlock()
            return false
        }

        let tappedCurrentManualTarget: Bool
        if let kind = manualTrackingTargetKind,
           let rect = manualTrackingTargetReferenceRect {
            tappedCurrentManualTarget = trackingCandidateMatchScore(
                selected,
                selection: (kind, rect)
            ) >= 0.15
        } else {
            tappedCurrentManualTarget = false
        }

        if tappedCurrentManualTarget {
            manualTrackingTargetKind = nil
            manualTrackingTargetReferenceRect = nil
            let candidates = trackingTargetCandidates
            trackingTargetSelectionLock.unlock()

            renderTrackingCandidates(
                candidates,
                activeSelection: automaticTrackingTargetSnapshot(),
                manualSelection: nil
            )
            kkLog("🔓 用户再次点击当前目标，恢复自动选人")
            return true
        }

        manualTrackingTargetKind = selected.kind
        manualTrackingTargetReferenceRect = selected.visionRect
        pendingGestureTrackingHandCenter = nil
        pendingGestureTrackingTargetDeadlineMs = 0
        isGestureTrackingTargetPriorityActive = false
        let candidates = trackingTargetCandidates
        trackingTargetSelectionLock.unlock()

        renderTrackingCandidates(
            candidates,
            activeSelection: (selected.kind, selected.visionRect),
            manualSelection: (selected.kind, selected.visionRect)
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resetTrackingDisplayState()
            self.trackingDisplayRect = selected.previewRect
            self.trackingDisplayKind = selected.kind
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.trackingLayer?.path = UIBezierPath(rect: selected.previewRect).cgPath
            CATransaction.commit()
        }
        kkLog("🔒 用户锁定跟踪目标: kind=\(selected.kind.rawValue), bbox=\(selected.visionRect)")
        return true
    }

    @discardableResult
    private func clearManualTrackingTargetLock(reason: String) -> Bool {
        trackingTargetSelectionLock.lock()
        let wasLocked = manualTrackingTargetKind != nil
        manualTrackingTargetKind = nil
        manualTrackingTargetReferenceRect = nil
        let candidates = trackingTargetCandidates
        trackingTargetSelectionLock.unlock()

        guard wasLocked else { return false }
        renderTrackingCandidates(
            candidates,
            activeSelection: automaticTrackingTargetSnapshot(),
            manualSelection: nil
        )
        kkLog("🔓 手动跟踪目标锁定已解除: \(reason)")
        return true
    }

    func resetAutoTrackingTargetSelection() {
        trackingTargetSelectionLock.lock()
        trackingTargetCandidates.removeAll()
        manualTrackingTargetKind = nil
        manualTrackingTargetReferenceRect = nil
        automaticTrackingTargetKind = nil
        automaticTrackingTargetReferenceRect = nil
        automaticTrackingTargetLastSeenAtMs = 0
        pendingGestureTrackingHandCenter = nil
        pendingGestureTrackingTargetDeadlineMs = 0
        isGestureTrackingTargetPriorityActive = false
        trackingTargetSelectionLock.unlock()

        let resetLayers = { [weak self] in
            guard let self else { return }
            self.trackingCandidateLayers.forEach { $0.removeFromSuperlayer() }
            self.trackingCandidateLayers.removeAll()
            self.trackingLayer?.strokeColor = UIColor.white.cgColor
            self.resetTrackingDisplayState()
        }
        if Thread.isMainThread {
            resetLayers()
        } else {
            DispatchQueue.main.async(execute: resetLayers)
        }
    }

    private func continuityScore(_ candidate: CGRect, reference: CGRect) -> CGFloat {
        let overlap = iou(candidate, reference)
        let dx = candidate.midX - reference.midX
        let dy = candidate.midY - reference.midY
        let distance = sqrt(dx * dx + dy * dy)
        let candidateArea = candidate.width * candidate.height
        let referenceArea = reference.width * reference.height
        let largestArea = max(max(candidateArea, referenceArea), 0.0001)
        let areaSimilarity = min(candidateArea, referenceArea) / largestArea
        return overlap * 4.0 + areaSimilarity - distance * 2.0
    }

    private func isContinuousManualTarget(_ candidate: CGRect, reference: CGRect) -> Bool {
        let overlap = iou(candidate, reference)
        if overlap >= 0.04 { return true }

        let candidateArea = candidate.width * candidate.height
        let referenceArea = reference.width * reference.height
        guard candidateArea > 0, referenceArea > 0 else { return false }
        let areaRatio = candidateArea / referenceArea
        let allowedHorizontalDistance = max(0.10, max(candidate.width, reference.width) * 1.6)
        let allowedVerticalDistance = max(0.10, max(candidate.height, reference.height) * 1.4)
        return areaRatio >= 0.40
            && areaRatio <= 2.50
            && abs(candidate.midX - reference.midX) <= allowedHorizontalDistance
            && abs(candidate.midY - reference.midY) <= allowedVerticalDistance
    }
    
    // MARK: - 人脸跟踪管理
    
    /// 开始人脸跟踪
    func startFaceTracking() {
        startAutoTracking(preferredStrategy: .face)
    }

    /// 开始人形/目标跟踪，并在检测到人脸时自动切回人脸
    func startHumanTracking() {
        startAutoTracking(preferredStrategy: .human)
    }

    private func startAutoTracking(preferredStrategy: CMTrackingDetectionStrategy) {
        stopPhysicalObjectTracking(reason: "person_tracking_started")
        isFaceTrackingMode = true
        activeTrackingDetectionStrategy = nil
        resetTrackingForNewSession()
        trackingPanGesture.isEnabled = false
        faceTrackingSessionId += 1
        let sessionId = faceTrackingSessionId
        
        // 启动人脸跟踪时，确保不会有目标跟踪/希区柯克逻辑同时影响（避免云台指令“打架”）
        releaseCurrentObjectTrackingRequest()
        if captureMode == .hitchcock && hitchcockState != .idle {
            stopHitchcockMode()
        }

        showDefaultTrackingFrame()

        NotificationCenter.default.post(
            name: .trackingStateChanged,
            object: self,
            userInfo: [
                "isTracking": true,
                "mode": preferredStrategy == .face ? "face" : "human"
            ]
        )
        
        // 设置人脸检测请求
        let faceRequest = VNDetectFaceRectanglesRequest { [weak self] request, error in
            guard let self = self else { return }
            guard self.isFaceTrackingMode, self.faceTrackingSessionId == sessionId else { return }
            if let error = error {
                kkLog("人脸检测错误: \(error.localizedDescription)")
                return
            }
        }
        faceDetectionRequest = faceRequest

        // 设置人形检测请求 (用于人脸丢失后的 Fallback)
        let humanRequest = VNDetectHumanRectanglesRequest { [weak self] request, error in
            guard let self = self else { return }
            guard self.isFaceTrackingMode, self.faceTrackingSessionId == sessionId else { return }
            if let error = error {
                kkLog("人形检测错误: \(error.localizedDescription)")
                return
            }
        }
        if #available(iOS 15.0, *) {
            humanRequest.revision = VNDetectHumanRectanglesRequestRevision2
            // 前置自拍通常只能看到头肩和上半身。继续要求完整人体会在人脸偶发
            // 漏检时失去兜底目标；后置仍保留完整人体检测，避免改变已验证行为。
            humanRequest.upperBodyOnly = lensType == .front
        }
        humanDetectionRequest = humanRequest
        
        let preferredName = preferredStrategy == .face ? "人脸优先" : "人形优先"
        let outputOrientation = videoConnection?.videoOrientation.rawValue ?? -1
        let outputMirrored = videoConnection?.isVideoMirrored ?? false
        let previewOrientation = previewLayer?.connection?.videoOrientation.rawValue ?? -1
        let previewMirrored = previewLayer?.connection?.isVideoMirrored ?? false
        kkLog("🧭 跟踪坐标系: lens=\(lensType == .front ? "front" : "back"), output=(orientation:\(outputOrientation), mirrored:\(outputMirrored)), preview=(orientation:\(previewOrientation), mirrored:\(previewMirrored))")
        kkLog("✅ 自动跟踪模式已启动 (\(preferredName)，支持人脸/人形自动切换)")
    }
    
    /// 停止人脸跟踪
    func stopFaceTracking() {
        isFaceTrackingMode = false
        gestureTrackStopRequiresNeutralRelease = false
        gestureTrackStopNeutralStartedAtMs = nil
        gestureTrackStopCommandStateMachine.reset()
        gestureTrackStopAfterOKCommandStateMachine.reset()
        // 递增会话ID，使所有在途的 Vision completion 失效
        faceTrackingSessionId += 1
        faceDetectionRequest = nil
        humanDetectionRequest = nil
        lastDetectedFaceRect = nil
        lastDetectedHumanRect = nil
        activeTrackingDetectionStrategy = nil
        humanTrackingLostCount = 0
        resetAutoTrackingTargetSelection()
        
        let clearLayer = { [weak self] in
            self?.clearTrackingLayer()
        }
        if Thread.isMainThread {
            clearLayer()
        } else {
            DispatchQueue.main.async {
                clearLayer()
            }
        }
        
        // 发送退出跟踪指令
        sendTrackingCommand(state: .exit, centerPoint: .zero)

        NotificationCenter.default.post(
            name: .trackingExited,
            object: self,
            userInfo: ["mode": "face"]
        )
        
        kkLog("⏹️ 人脸跟踪模式已停止")
    }
    
    /// 处理混合检测结果 (人脸优先，人形回退)
    private func handleCombinedDetectionResults(
        faceObservations: [VNFaceObservation],
        humanObservations: [VNDetectedObjectObservation],
        orientedImageSize: CGSize
    ) {
        let faceResults = faceObservations.filter(isReliableFaceObservation)
        let humanResults = humanObservations.filter(isReliableHumanObservation)
        updateTrackingCandidates(
            faceObservations: faceResults,
            humanObservations: humanResults,
            orientedImageSize: orientedImageSize
        )
        
        // 1. 尝试匹配人脸
        if let selectedFace = selectBestFace(from: faceResults) {
            guard confirmFaceCandidate(selectedFace) else {
                softenTrackingOutputForPendingTarget(
                    reason: "faceCandidatePending",
                    decay: trackingPendingDecay(near: 0.55, far: 0.75),
                    maxHorizontalMagnitude: 65,
                    maxVerticalMagnitude: 50
                )
                return
            }

            // 找到人脸，更新人脸跟踪
            updateFaceTracking(with: selectedFace, orientedImageSize: orientedImageSize)
            humanTrackingLostCount = 0 // 重置丢失计数
            pendingTrackingHumanRect = nil
            pendingTrackingHumanCount = 0
            
            // 身份锁定与合成逻辑：
            // 策略 A：优先使用真实检测到的人体框
            if let associatedHuman = humanResults.max(by: {
                faceCoverage(selectedFace.boundingBox, inside: $0.boundingBox)
                    < faceCoverage(selectedFace.boundingBox, inside: $1.boundingBox)
            }), faceCoverage(selectedFace.boundingBox, inside: associatedHuman.boundingBox) > 0.5 {
                self.lastDetectedHumanRect = associatedHuman.boundingBox
            } else {
                // 策略 B (合成逻辑)：如果由于对比度低（黑衣重合）没检出人体，根据人脸位置合成一个“影子”人体框
                // 这样当人脸下一秒转过去时，我们已经有一个准确的参考点
                let fb = selectedFace.boundingBox
                let syntheticWidth = fb.width * 4.0
                let syntheticHeight = fb.height * 7.0 // 假设人体高度约为人脸的 7 倍
                let syntheticX = fb.midX - syntheticWidth / 2.0
                let syntheticY = (fb.maxY) - syntheticHeight // 从头顶往下算
                
                self.lastDetectedHumanRect = CGRect(
                    x: max(0, min(1, syntheticX)),
                    y: max(0, min(1, syntheticY)),
                    width: max(0.1, min(1, syntheticWidth)),
                    height: max(0.1, min(1, syntheticHeight))
                )
            }
            return
        }
        pendingTrackingFaceRect = nil
        pendingTrackingFaceCount = 0
        
        // 2. 人脸丢失，尝试人形回退 (Identity Lock)
        if let selectedHuman = selectBestHuman(from: humanResults) {
            guard confirmHumanCandidate(selectedHuman) else {
                softenTrackingOutputForPendingTarget(
                    reason: "humanCandidatePending",
                    decay: trackingPendingDecay(near: 0.50, far: 0.72),
                    maxHorizontalMagnitude: 65,
                    maxVerticalMagnitude: 50
                )
                return
            }

            updateHumanTrackingFallback(with: selectedHuman, orientedImageSize: orientedImageSize)
            humanTrackingLostCount = 0 // 重置丢失计数
            return
        }
        pendingTrackingHumanRect = nil
        pendingTrackingHumanCount = 0
        
        // 3. 运动惯性 (Coasting)：如果这一帧什么都没检出，不立即断开。
        // 保护期内按目标最后所处位置自适应减速，避免画面边缘的单帧漏检直接丢失目标。
        if (lastDetectedFaceRect != nil || lastDetectedHumanRect != nil) && humanTrackingLostCount < 10 {
            humanTrackingLostCount += 1
            let isEarlyCoasting = humanTrackingLostCount <= 4
            softenTrackingOutputForPendingTarget(
                reason: "targetTemporarilyLost",
                decay: trackingPendingDecay(
                    near: isEarlyCoasting ? 0.50 : 0.35,
                    far: isEarlyCoasting ? 0.76 : 0.55
                ),
                maxHorizontalMagnitude: isEarlyCoasting ? 70 : 40,
                maxVerticalMagnitude: isEarlyCoasting ? 50 : 35
            )
            return
        }
        
        // 4. 完全丢失目标
        handleNoTargetDetected()
    }

    private func trackingPendingDecay(near: Double, far: Double) -> Double {
        if trackingCenterLocked {
            return 0
        }

        // 画面边缘的单帧漏检最容易把目标直接丢出视野，此时保留更多追赶速度；
        // 靠近中心仍快速减速，避免把之前解决的过冲重新带回来。
        let targetWasFarFromCenter = abs(trackingLastRawOffsetX) >= 240
            || abs(trackingLastRawOffsetY) >= 320
        return targetWasFarFromCenter ? far : near
    }

    private func faceCoverage(_ faceRect: CGRect, inside humanRect: CGRect) -> CGFloat {
        let faceArea = faceRect.width * faceRect.height
        guard faceArea > 0 else { return 0 }
        let intersection = faceRect.intersection(humanRect)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return (intersection.width * intersection.height) / faceArea
    }

    private func isReliableFaceObservation(_ observation: VNFaceObservation) -> Bool {
        let rect = observation.boundingBox
        let area = rect.width * rect.height
        let aspectRatio = rect.height > 0 ? rect.width / rect.height : 0
        return observation.confidence >= 0.6
            && area >= 0.0025
            && aspectRatio >= 0.5
            && aspectRatio <= 1.8
    }

    private func isReliableHumanObservation(_ observation: VNDetectedObjectObservation) -> Bool {
        let rect = observation.boundingBox
        let area = rect.width * rect.height
        return observation.confidence >= 0.6
            && area >= 0.02
            && rect.height >= rect.width
    }

    private func isHumanCandidateContinuousWithFace(
        _ observation: VNDetectedObjectObservation,
        allowsFastEdgeFallback: Bool = false
    ) -> Bool {
        guard activeTrackingDetectionStrategy == .face,
              let faceRect = lastDetectedFaceRect else {
            return true
        }

        let humanRect = observation.boundingBox
        let coverage = faceCoverage(faceRect, inside: humanRect)
        let horizontalDistance = abs(humanRect.midX - faceRect.midX)
        let allowedHorizontalDistance = max(0.18, min(0.30, humanRect.width * 0.45))
        let previousHumanOverlap = lastDetectedHumanRect.map { iou(humanRect, $0) } ?? 0
        let isNearHorizontalEdge = humanRect.minX <= 0.10 || humanRect.maxX >= 0.90
        let isFastEdgeFallback = allowsFastEdgeFallback
            && trackingConsecutiveFaceMissCount <= 4
            && previousHumanOverlap >= 0.05
            && isNearHorizontalEdge
        let isContinuous = coverage >= 0.15
            || horizontalDistance <= allowedHorizontalDistance
            || isFastEdgeFallback

        if isFastEdgeFallback,
           coverage < 0.15,
           horizontalDistance > allowedHorizontalDistance {
            kkLog(String(format: "🏃 接受快速横移人形兜底: faceX=%.3f, humanX=%.3f, distance=%.3f, humanIoU=%.2f, misses=%d", faceRect.midX, humanRect.midX, horizontalDistance, previousHumanOverlap, trackingConsecutiveFaceMissCount))
        }

        if !isContinuous {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            if nowMs - trackingHumanRejectLastLogTimeMs >= 1000 {
                trackingHumanRejectLastLogTimeMs = nowMs
                kkLog(String(format: "🚧 拒绝跨目标人形候选: faceX=%.3f, humanX=%.3f, distance=%.3f, coverage=%.2f", faceRect.midX, humanRect.midX, horizontalDistance, coverage))
            }
        }
        return isContinuous
    }

    private func confirmFaceCandidate(_ observation: VNFaceObservation) -> Bool {
        if trackingNoTargetHoldSent {
            pendingTrackingFaceRect = nil
            pendingTrackingFaceCount = 0
            return true
        }

        if activeTrackingDetectionStrategy == .face, lastDetectedFaceRect != nil {
            pendingTrackingFaceRect = nil
            pendingTrackingFaceCount = 0
            return true
        }

        if activeTrackingDetectionStrategy == .human,
           let humanRect = lastDetectedHumanRect,
           faceCoverage(observation.boundingBox, inside: humanRect) >= 0.15 {
            pendingTrackingFaceRect = nil
            pendingTrackingFaceCount = 0
            return true
        }

        let rect = observation.boundingBox
        if let pendingRect = pendingTrackingFaceRect, iou(pendingRect, rect) >= 0.35 {
            pendingTrackingFaceCount += 1
        } else {
            pendingTrackingFaceRect = rect
            pendingTrackingFaceCount = 1
        }

        // Vision 结果已经经过置信度、面积和连续框 IoU 校验，两帧足以确认；
        // 旧设备单帧常需 100~200ms，四帧会显著增加首次跟随延迟。
        let requiredCount = 2
        guard pendingTrackingFaceCount >= requiredCount else { return false }
        let area = rect.width * rect.height
        kkLog(String(format: "✅ 连续%d帧确认人脸候选: confidence=%.2f, area=%.4f, bbox=(%.3f,%.3f,%.3f,%.3f)", requiredCount, observation.confidence, area, rect.minX, rect.minY, rect.width, rect.height))
        pendingTrackingFaceRect = nil
        pendingTrackingFaceCount = 0
        return true
    }

    private func confirmHumanCandidate(_ observation: VNDetectedObjectObservation) -> Bool {
        if trackingNoTargetHoldSent {
            pendingTrackingHumanRect = nil
            pendingTrackingHumanCount = 0
            return true
        }

        if activeTrackingDetectionStrategy == .human, lastDetectedHumanRect != nil {
            pendingTrackingHumanRect = nil
            pendingTrackingHumanCount = 0
            return true
        }

        if activeTrackingDetectionStrategy == .face,
           let humanRect = lastDetectedHumanRect,
           (isContinuousManualTarget(observation.boundingBox, reference: humanRect)
                || isHumanCandidateContinuousWithFace(observation, allowsFastEdgeFallback: true)) {
            pendingTrackingHumanRect = nil
            pendingTrackingHumanCount = 0
            return true
        }

        let rect = observation.boundingBox
        if let pendingRect = pendingTrackingHumanRect, iou(pendingRect, rect) >= 0.35 {
            pendingTrackingHumanCount += 1
        } else {
            pendingTrackingHumanRect = rect
            pendingTrackingHumanCount = 1
        }

        let requiredCount = activeTrackingDetectionStrategy == .face && lastDetectedHumanRect != nil ? 2 : 3
        guard pendingTrackingHumanCount >= requiredCount else { return false }
        let area = rect.width * rect.height
        kkLog(String(format: "✅ 连续%d帧确认人形候选: confidence=%.2f, area=%.4f, bbox=(%.3f,%.3f,%.3f,%.3f)", requiredCount, observation.confidence, area, rect.minX, rect.minY, rect.width, rect.height))
        pendingTrackingHumanRect = nil
        pendingTrackingHumanCount = 0
        return true
    }
    
    /// 从多个人脸中选择最合适的一个
    private func selectBestFace(from results: [VNFaceObservation]) -> VNFaceObservation? {
        guard !results.isEmpty else { return nil }

        if let manualTarget = manualTrackingTargetSnapshot() {
            switch manualTarget.kind {
            case .face:
                guard let matchedFace = results.max(by: {
                    continuityScore($0.boundingBox, reference: manualTarget.rect)
                        < continuityScore($1.boundingBox, reference: manualTarget.rect)
                }), isContinuousManualTarget(
                    matchedFace.boundingBox,
                    reference: manualTarget.rect
                ) else {
                    return nil
                }
                return matchedFace

            case .human:
                guard let associatedFace = results.max(by: {
                    faceCoverage($0.boundingBox, inside: manualTarget.rect)
                        < faceCoverage($1.boundingBox, inside: manualTarget.rect)
                }), faceCoverage(
                    associatedFace.boundingBox,
                    inside: manualTarget.rect
                ) >= 0.25 else {
                    return nil
                }
                return associatedFace
            }
        }

        if let handCenter = pendingGestureTrackingHandCenterSnapshot(),
           let gestureOwner = results.min(by: {
               gestureAssociationScore(
                   handCenter: handCenter,
                   personRect: $0.boundingBox,
                   kind: .face
               ) < gestureAssociationScore(
                   handCenter: handCenter,
                   personRect: $1.boundingBox,
                   kind: .face
               )
           }) {
            activateGestureTrackingTarget(
                kind: .face,
                rect: gestureOwner.boundingBox
            )
            return gestureOwner
        }

        let largestFace = results.max(by: { a, b in
            (a.boundingBox.width * a.boundingBox.height) < (b.boundingBox.width * b.boundingBox.height)
        })!
        guard let automaticTarget = automaticTrackingTargetSnapshot() else {
            return largestFace
        }
        let hasGesturePriority = gestureTrackingTargetSnapshot() != nil

        let currentFace: VNFaceObservation?
        switch automaticTarget.kind {
        case .face:
            let candidate = results.max(by: {
                continuityScore($0.boundingBox, reference: automaticTarget.rect)
                    < continuityScore($1.boundingBox, reference: automaticTarget.rect)
            })
            currentFace = candidate.flatMap {
                isContinuousAutomaticTarget(
                    $0.boundingBox,
                    reference: automaticTarget.rect
                ) ? $0 : nil
            }

        case .human:
            let candidate = results.max(by: {
                faceCoverage($0.boundingBox, inside: automaticTarget.rect)
                    < faceCoverage($1.boundingBox, inside: automaticTarget.rect)
            })
            currentFace = candidate.flatMap {
                faceCoverage($0.boundingBox, inside: automaticTarget.rect) >= 0.15 ? $0 : nil
            }
        }

        guard let currentFace else {
            if !hasGesturePriority,
               automaticTarget.kind == .face,
               shouldSwitchAutomaticTarget(
                   from: automaticTarget.rect,
                   to: largestFace.boundingBox
               ) {
                // 明显更靠前的新人物仍按既定规则立即接管。
                return largestFace
            }
            // 普通目标与 OK 手势目标都容忍约 0.5 秒漏检，避免两个人
            // 距离接近时因为单帧人脸缺失就在左右人物之间跳转。
            return shouldReserveAutomaticTargetAfterMiss()
                ? nil
                : largestFace
        }

        // OK 手势人物可识别期间优先级高于“更靠前”规则。
        if hasGesturePriority { return currentFace }

        // 面积差小于 20% 时保持当前人物；明显更靠前的目标仍可立即接管。
        return shouldSwitchAutomaticTarget(
            from: currentFace.boundingBox,
            to: largestFace.boundingBox
        ) ? largestFace : currentFace
    }

    /// 从多个人形中选择最合适的一个
    private func selectBestHuman(from results: [VNDetectedObjectObservation]) -> VNDetectedObjectObservation? {
        guard !results.isEmpty else { return nil }

        if let manualTarget = manualTrackingTargetSnapshot() {
            switch manualTarget.kind {
            case .human:
                guard let matchedHuman = results.max(by: {
                    continuityScore($0.boundingBox, reference: manualTarget.rect)
                        < continuityScore($1.boundingBox, reference: manualTarget.rect)
                }), isContinuousManualTarget(
                    matchedHuman.boundingBox,
                    reference: manualTarget.rect
                ) else {
                    return nil
                }
                return matchedHuman

            case .face:
                guard let associatedHuman = results.max(by: {
                    faceCoverage(manualTarget.rect, inside: $0.boundingBox)
                        < faceCoverage(manualTarget.rect, inside: $1.boundingBox)
                }), faceCoverage(
                    manualTarget.rect,
                    inside: associatedHuman.boundingBox
                ) >= 0.25 else {
                    return nil
                }
                return associatedHuman
            }
        }

        if let handCenter = pendingGestureTrackingHandCenterSnapshot(),
           let gestureOwner = results.min(by: {
               gestureAssociationScore(
                   handCenter: handCenter,
                   personRect: $0.boundingBox,
                   kind: .human
               ) < gestureAssociationScore(
                   handCenter: handCenter,
                   personRect: $1.boundingBox,
                   kind: .human
               )
           }) {
            activateGestureTrackingTarget(
                kind: .human,
                rect: gestureOwner.boundingBox
            )
            return gestureOwner
        }

        let largestHuman = results.max(by: { a, b in
            (a.boundingBox.width * a.boundingBox.height) < (b.boundingBox.width * b.boundingBox.height)
        })!
        guard let automaticTarget = automaticTrackingTargetSnapshot() else {
            return largestHuman
        }
        let hasGesturePriority = gestureTrackingTargetSnapshot() != nil

        let currentHuman: VNDetectedObjectObservation?
        switch automaticTarget.kind {
        case .human:
            let candidate = results.max(by: {
                continuityScore($0.boundingBox, reference: automaticTarget.rect)
                    < continuityScore($1.boundingBox, reference: automaticTarget.rect)
            })
            currentHuman = candidate.flatMap {
                isContinuousAutomaticTarget(
                    $0.boundingBox,
                    reference: automaticTarget.rect
                ) ? $0 : nil
            }

        case .face:
            let candidate = results.max(by: {
                faceCoverage(automaticTarget.rect, inside: $0.boundingBox)
                    < faceCoverage(automaticTarget.rect, inside: $1.boundingBox)
            })
            currentHuman = candidate.flatMap {
                isHumanCandidate($0.boundingBox, associatedWithFace: automaticTarget.rect) ? $0 : nil
            }
        }

        guard let currentHuman else {
            if !hasGesturePriority,
               automaticTarget.kind == .human,
               shouldSwitchAutomaticTarget(
                   from: automaticTarget.rect,
                   to: largestHuman.boundingBox
               ) {
                return largestHuman
            }
            return shouldReserveAutomaticTargetAfterMiss()
                ? nil
                : largestHuman
        }

        if hasGesturePriority { return currentHuman }

        return shouldSwitchAutomaticTarget(
            from: currentHuman.boundingBox,
            to: largestHuman.boundingBox
        ) ? largestHuman : currentHuman
    }

    private func setActiveTrackingDetectionStrategy(_ strategy: CMTrackingDetectionStrategy) {
        guard activeTrackingDetectionStrategy != strategy else { return }
        let previousStrategy = activeTrackingDetectionStrategy
        activeTrackingDetectionStrategy = strategy

        let modeName = strategy == .face ? "人脸" : "人形"
        if let previousStrategy = previousStrategy {
            beginTrackingStrategyTransition(from: previousStrategy, to: strategy)
        }
        kkLog("🔁 自动切换到\(modeName)跟踪")
    }

    private func previewRect(
        forVisionBoundingBox boundingBox: CGRect,
        orientedImageSize: CGSize,
        previewLayer: AVCaptureVideoPreviewLayer
    ) -> CGRect {
        let bounds = previewLayer.bounds
        guard orientedImageSize.width > 0,
              orientedImageSize.height > 0,
              bounds.width > 0,
              bounds.height > 0 else {
            return .zero
        }

        // Vision 的坐标已按 EXIF 转正，原点在左下角；这里只翻转 Y，并处理预览的裁切。
        let normalizedRect = CGRect(
            x: boundingBox.minX,
            y: 1.0 - boundingBox.maxY,
            width: boundingBox.width,
            height: boundingBox.height
        )

        if previewLayer.videoGravity == .resize {
            return CGRect(
                x: bounds.minX + normalizedRect.minX * bounds.width,
                y: bounds.minY + normalizedRect.minY * bounds.height,
                width: normalizedRect.width * bounds.width,
                height: normalizedRect.height * bounds.height
            )
        }

        let widthScale = bounds.width / orientedImageSize.width
        let heightScale = bounds.height / orientedImageSize.height
        let scale = previewLayer.videoGravity == .resizeAspect
            ? min(widthScale, heightScale)
            : max(widthScale, heightScale)
        let displayedWidth = orientedImageSize.width * scale
        let displayedHeight = orientedImageSize.height * scale
        let displayedOriginX = bounds.midX - displayedWidth / 2.0
        let displayedOriginY = bounds.midY - displayedHeight / 2.0

        return CGRect(
            x: displayedOriginX + normalizedRect.minX * displayedWidth,
            y: displayedOriginY + normalizedRect.minY * displayedHeight,
            width: normalizedRect.width * displayedWidth,
            height: normalizedRect.height * displayedHeight
        )
    }

    /// 更新人脸跟踪
    private func updateFaceTracking(with faceObservation: VNFaceObservation, orientedImageSize: CGSize) {
        guard let previewLayer = previewLayer else { return }

        let boundingBox = faceObservation.boundingBox
        let didChangeStrategy = activeTrackingDetectionStrategy != .face
        trackingHumanFallbackCenterX = nil
        setActiveTrackingDetectionStrategy(.face)
        lastDetectedFaceRect = boundingBox
        refreshManualTrackingTargetReference(kind: .face, rect: boundingBox)
        refreshAutomaticTrackingTargetReference(kind: .face, rect: boundingBox)
        let isManuallyLocked = manualTrackingTargetSnapshot() != nil
        
        let area = boundingBox.width * boundingBox.height
        if area < 0.001 { return }
        
        let rect = previewRect(
            forVisionBoundingBox: boundingBox,
            orientedImageSize: orientedImageSize,
            previewLayer: previewLayer
        )
        let centerPoint = CGPoint(x: rect.midX, y: rect.midY)

        if didChangeStrategy {
            kkLog("🎯 人脸坐标映射: vision=\(boundingBox), previewRect=\(rect), previewBounds=\(previewLayer.bounds), center=\(centerPoint)")
        }

        guard isFaceTrackingMode else { return }
        markTrackingTargetAcquired()
        self.sendTrackingCommand(state: .normal, centerPoint: centerPoint)
        
        updateTrackingDisplayFrame(
            proposedRect: rect,
            kind: .face,
            isManuallyLocked: isManuallyLocked
        )
    }
    
    /// 人形回退跟踪 (当人背过身时)
    private func updateHumanTrackingFallback(
        with humanObservation: VNDetectedObjectObservation,
        orientedImageSize: CGSize
    ) {
        guard let previewLayer = previewLayer else { return }

        let boundingBox = humanObservation.boundingBox
        let didChangeStrategy = activeTrackingDetectionStrategy != .human
        let previousRawX = trackingLastRawOffsetX
        let hadPreviousTarget = trackingFilterInited || lastDetectedFaceRect != nil
        setActiveTrackingDetectionStrategy(.human)
        lastDetectedHumanRect = boundingBox
        lastDetectedFaceRect = nil // 标记人脸已丢失
        refreshManualTrackingTargetReference(kind: .human, rect: boundingBox)
        refreshAutomaticTrackingTargetReference(kind: .human, rect: boundingBox)
        let isManuallyLocked = manualTrackingTargetSnapshot() != nil
        
        let visualRect = previewRect(
            forVisionBoundingBox: boundingBox,
            orientedImageSize: orientedImageSize,
            previewLayer: previewLayer
        )
        
        // 人形框比人脸框宽很多，检测器切换时其中点可能横跨画面。
        // 用上一目标中心作为锚点，每帧最多移动预览宽度的 8%，保持目标身份和控制连续性。
        if didChangeStrategy, hadPreviousTarget, previewLayer.bounds.width > 0 {
            let normalizedPreviousX = CGFloat(previousRawX + 1000) / 2000.0
            trackingHumanFallbackCenterX = previewLayer.bounds.minX
                + normalizedPreviousX * previewLayer.bounds.width
        }
        let previousCenterX = trackingHumanFallbackCenterX ?? visualRect.midX
        let maximumCenterStep = max(18.0, previewLayer.bounds.width * 0.08)
        let horizontalDelta = max(
            -maximumCenterStep,
            min(maximumCenterStep, visualRect.midX - previousCenterX)
        )
        let continuousCenterX = previousCenterX + horizontalDelta
        trackingHumanFallbackCenterX = continuousCenterX

        let centerPoint = CGPoint(
            x: continuousCenterX,
            y: visualRect.minY + visualRect.height * 0.15
        )

        if didChangeStrategy {
            kkLog("🎯 人形坐标映射: vision=\(boundingBox), previewRect=\(visualRect), previewBounds=\(previewLayer.bounds), center=\(centerPoint)")
        }

        guard isFaceTrackingMode else { return }
        markTrackingTargetAcquired()
        self.sendTrackingCommand(state: .normal, centerPoint: centerPoint)
        
        updateTrackingDisplayFrame(
            proposedRect: visualRect,
            kind: .human,
            isManuallyLocked: isManuallyLocked
        )
    }
    
    /// 处理完全丢失目标的情况
    private func handleNoTargetDetected() {
        clearManualTrackingTargetLock(reason: "selectedTargetLost")
        clearAutomaticTrackingTargetReference()
        holdTrackingAtCenterForNoTarget(reason: "noReliableTarget")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.isFaceTrackingMode else { return }
            self.resetTrackingDisplayState()
            self.showDefaultTrackingFrame()
            self.lastDetectedFaceRect = nil
            self.lastDetectedHumanRect = nil
            self.humanTrackingLostCount = 0
        }
    }

    private func logTrackingDetectionPerformance(
        startedAt: CFAbsoluteTime,
        faceFinishedAt: CFAbsoluteTime,
        finishedAt: CFAbsoluteTime,
        humanRan: Bool
    ) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        guard nowMs - trackingDetectionLastPerformanceLogMs >= 2000 else { return }

        trackingDetectionLastPerformanceLogMs = nowMs
        let faceMs = Int(((faceFinishedAt - startedAt) * 1000.0).rounded())
        let totalMs = Int(((finishedAt - startedAt) * 1000.0).rounded())
        let humanMs = max(0, totalMs - faceMs)
        let strategyName = activeTrackingDetectionStrategy == .human ? "human" : "face"
        kkLog("⏱️ 跟踪检测耗时: face=\(faceMs)ms, human=\(humanMs)ms, total=\(totalMs)ms, humanRan=\(humanRan), faceMisses=\(trackingConsecutiveFaceMissCount), strategy=\(strategyName)")
    }
    
    /// 在视频帧中执行检测
    func performFaceDetection(on pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        guard isFaceTrackingMode, 
              let faceRequest = faceDetectionRequest,
              let humanRequest = humanDetectionRequest else {
            return
        }
        let sessionId = faceTrackingSessionId
        
        let bufferWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let bufferHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let orientationSwapsDimensions: Bool
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            orientationSwapsDimensions = true
        default:
            orientationSwapsDimensions = false
        }
        let orientedImageSize = orientationSwapsDimensions
            ? CGSize(width: bufferHeight, height: bufferWidth)
            : CGSize(width: bufferWidth, height: bufferHeight)

        if !trackingVisionInputLogged {
            trackingVisionInputLogged = true
            let previewGravity = previewLayer?.videoGravity.rawValue ?? "nil"
            kkLog("🧭 Vision输入: buffer=\(Int(bufferWidth))x\(Int(bufferHeight)), exif=\(orientation.rawValue), oriented=\(Int(orientedImageSize.width))x\(Int(orientedImageSize.height)), gravity=\(previewGravity)")
        }

        let detectionStart = CFAbsoluteTimeGetCurrent()
        let faceHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])

        do {
            // 对齐 Android：先做人脸检测，仅在人脸不可用时才运行更重的人形检测。
            try faceHandler.perform([faceRequest])
            guard isFaceTrackingMode, faceTrackingSessionId == sessionId else { return }
            let faceFinishedAt = CFAbsoluteTimeGetCurrent()
            let faceObservations = faceRequest.results ?? []
            let reliableFaces = faceObservations.filter(isReliableFaceObservation)
            let hasUsableFace = selectBestFace(from: reliableFaces) != nil
            if hasUsableFace {
                trackingConsecutiveFaceMissCount = 0
            } else {
                trackingConsecutiveFaceMissCount = min(1000, trackingConsecutiveFaceMissCount + 1)
            }

            // 已锁定人脸时，人形兜底隔帧运行。后置摄像头的人脸检测约 100~160ms，
            // 每个漏检帧都追加人形检测会把下一次人脸采样拖到约 300ms，快速移动时反而更容易丢目标。
            if !hasUsableFace,
               lensType != .front,
               activeTrackingDetectionStrategy == .face,
               trackingConsecutiveFaceMissCount % 2 == 1 {
                let detectionFinishedAt = CFAbsoluteTimeGetCurrent()
                let isFirstMiss = trackingConsecutiveFaceMissCount == 1
                softenTrackingOutputForPendingTarget(
                    reason: isFirstMiss ? "singleFaceMiss" : "faceMissBetweenHumanScans",
                    decay: trackingPendingDecay(
                        near: isFirstMiss ? 0.55 : 0.60,
                        far: isFirstMiss ? 0.82 : 0.86
                    ),
                    maxHorizontalMagnitude: 75,
                    maxVerticalMagnitude: 55
                )
                logTrackingDetectionPerformance(
                    startedAt: detectionStart,
                    faceFinishedAt: faceFinishedAt,
                    finishedAt: detectionFinishedAt,
                    humanRan: false
                )
                return
            }

            var humanObservations: [VNDetectedObjectObservation] = []
            var humanRan = false
            if !hasUsableFace {
                guard isFaceTrackingMode, faceTrackingSessionId == sessionId else { return }
                let humanHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
                try humanHandler.perform([humanRequest])
                guard isFaceTrackingMode, faceTrackingSessionId == sessionId else { return }
                humanObservations = humanRequest.results ?? []
                humanRan = true
            }
            let detectionFinishedAt = CFAbsoluteTimeGetCurrent()

            guard isFaceTrackingMode, faceTrackingSessionId == sessionId else { return }
            self.handleCombinedDetectionResults(
                faceObservations: faceObservations,
                humanObservations: humanObservations,
                orientedImageSize: orientedImageSize
            )

            logTrackingDetectionPerformance(
                startedAt: detectionStart,
                faceFinishedAt: faceFinishedAt,
                finishedAt: detectionFinishedAt,
                humanRan: humanRan
            )
        } catch {
            guard isFaceTrackingMode, faceTrackingSessionId == sessionId else { return }
            kkLog("AI检测执行失败: \(error.localizedDescription)")
        }
    }
    
    // MARK: - 人脸跟踪辅助方法
    
    /// 检查是否正在进行人脸跟踪
    var isFaceTrackingActive: Bool {
        return isFaceTrackingMode && faceDetectionRequest != nil
    }
    
    /// 获取当前检测到的人脸数量（调试用）
    var detectedFaceCount: Int {
        return lastDetectedFaceRect != nil ? 1 : 0
    }
}
