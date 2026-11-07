//
//  CameraManager+Tracking.swift
//  KKGimbal
//
//  Created by Kevin Tan on 2024/6/21.
//

import Foundation
import Vision
import UIKit
import AVFoundation

extension CameraManager {
    
    // MARK: - 跟踪状态管理
    
    /// 是否为前置摄像头
    private var isFrontCamera: Bool {
        return lensType == .front
    }
    
    // MARK: - UI 跟踪层管理
    
    // 对齐 Android TargetRectView drawRect(mTouchRect, Color.WHITE)：
    // 初始颜色为白色（对应拖动选框阶段），目标确认后再切换为追踪锁定色
    func setupTrackingLayer() {
        clearTrackingLayer()
        trackingLayer = CAShapeLayer()
        guard let trackingLayer = trackingLayer else { return }
        trackingLayer.strokeColor = UIColor.white.cgColor
        trackingLayer.lineWidth = 2.0
        trackingLayer.fillColor = UIColor.clear.cgColor
        previewLayer?.addSublayer(trackingLayer)
    }

    func showDefaultTrackingFrame() {
        let drawFrame = { [weak self] in
            guard let self = self,
                  let previewLayer = self.previewLayer else { return }

            if self.trackingLayer == nil {
                self.setupTrackingLayer()
            }

            let bounds = previewLayer.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }

            let side = min(bounds.width, bounds.height) * 0.36
            let rect = CGRect(
                x: bounds.midX - side / 2.0,
                y: bounds.midY - side / 2.0,
                width: side,
                height: side
            )

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.trackingLayer?.strokeColor = UIColor.white.cgColor
            self.trackingLayer?.path = UIBezierPath(rect: rect).cgPath
            CATransaction.commit()
        }

        if Thread.isMainThread {
            drawFrame()
        } else {
            DispatchQueue.main.async(execute: drawFrame)
        }
    }

    func clearTrackingLayer() {
        trackingCandidateLayers.forEach { $0.removeFromSuperlayer() }
        trackingCandidateLayers.removeAll()
        trackingLayer?.path = nil
        trackingLayer?.removeFromSuperlayer()
        trackingLayer = nil
    }

    // 目标确认后将追踪框颜色切换为 Android my_green (#01D1BB)
    func switchTrackingLayerToLockedColor() {
        trackingLayer?.strokeColor = UIColor(red: 0x01/255.0, green: 0xD1/255.0, blue: 0xBB/255.0, alpha: 1.0).cgColor
    }

    /// 预览框 -> 当前视频输出的像素坐标 -> Vision 左下原点归一化坐标。
    /// metadata 是未旋转的相机坐标，不能直接当作已旋转/镜像的视频帧坐标。
    func trackingVisionBoundingBox(forPreviewRect rect: CGRect) -> CGRect? {
        guard let previewLayer = previewLayer,
              let videoOutput = videoOutput else { return nil }
        let outputBounds = videoOutput.outputRectConverted(
            fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        guard !outputBounds.isNull, !outputBounds.isInfinite,
              outputBounds.width > 0, outputBounds.height > 0 else { return nil }

        let metadataRect = previewLayer.metadataOutputRectConverted(fromLayerRect: rect)
        let outputRect = videoOutput.outputRectConverted(fromMetadataOutputRect: metadataRect)
        return sanitizedTrackingBoundingBox(CGRect(
            x: (outputRect.minX - outputBounds.minX) / outputBounds.width,
            y: 1 - (outputRect.maxY - outputBounds.minY) / outputBounds.height,
            width: outputRect.width / outputBounds.width,
            height: outputRect.height / outputBounds.height
        ))
    }

    /// 与框选严格互逆；预览裁剪、视频帧方向及两条连接各自的镜像均由 AVFoundation 处理。
    func trackingPreviewRect(forVisionBoundingBox boundingBox: CGRect) -> CGRect? {
        guard let previewLayer = previewLayer,
              let videoOutput = videoOutput else { return nil }
        let outputBounds = videoOutput.outputRectConverted(
            fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        guard !outputBounds.isNull, !outputBounds.isInfinite,
              outputBounds.width > 0, outputBounds.height > 0 else { return nil }

        let outputRect = CGRect(
            x: outputBounds.minX + boundingBox.minX * outputBounds.width,
            y: outputBounds.minY + (1 - boundingBox.maxY) * outputBounds.height,
            width: boundingBox.width * outputBounds.width,
            height: boundingBox.height * outputBounds.height
        )
        let metadataRect = videoOutput.metadataOutputRectConverted(fromOutputRect: outputRect)
        return previewLayer.layerRectConverted(fromMetadataOutputRect: metadataRect)
    }

    /// 将 Vision 跟踪框限制在合法的归一化坐标内。
    /// 框越界、尺寸为 0 或无限值会让 VNTrackObjectRequest 持续抛出 Code=9。
    func sanitizedTrackingBoundingBox(_ rect: CGRect) -> CGRect? {
        let standardized = rect.standardized
        guard standardized.minX.isFinite,
              standardized.minY.isFinite,
              standardized.width.isFinite,
              standardized.height.isFinite else {
            return nil
        }

        // 避免贴到 0/1 边界后因浮点误差被 Vision 判定为非法框。
        let validBounds = CGRect(x: 0.001, y: 0.001, width: 0.998, height: 0.998)
        let clipped = standardized.intersection(validBounds)
        // The object workflow supports small manually selected items. Preserve
        // the existing 1% gate for the other camera modes.
        let minimumSide: CGFloat = isPhysicalObjectTrackingActive ? 0.002 : 0.01
        guard !clipped.isNull,
              !clipped.isEmpty,
              clipped.width >= minimumSide,
              clipped.height >= minimumSide else {
            return nil
        }
        return clipped
    }

    @discardableResult
    func startTracking(rect: CGRect, preservingPhysicalObjectMode: Bool = false) -> CGRect? {
        if !preservingPhysicalObjectMode {
            stopPhysicalObjectTracking(reason: "manual_tracking_started")
        }
        guard let trackingRect = sanitizedTrackingBoundingBox(rect) else {
            kkLog("⚠️ 拒绝非法目标框: \(rect)")
            return nil
        }

        if isFaceTrackingMode {
            stopFaceTracking()
        }
        if trackingLayer == nil {
            setupTrackingLayer()
        }

        // 先取消并释放旧请求。只置 nil 会让 Vision 的内部 Tracker 继续占用资源，
        // 多次框选后可能触发 "Exceeded maximum allowed number of Trackers"。
        releaseCurrentObjectTrackingRequest()
        resetTrackingForNewSession()
        let observation = VNDetectedObjectObservation(boundingBox: trackingRect)
        let trackingRequest = VNTrackObjectRequest(detectedObjectObservation: observation)
        // Revision 2 在当前测试机上会触发 VNObjectTrackerRevision2Type 资源上限。
        // Revision 1 支持 accurate 级别，并且与当前单目标跟踪场景更匹配。
        trackingRequest.revision = VNTrackObjectRequestRevision1
        trackingRequest.trackingLevel = .accurate
        currentTrackingRequest = trackingRequest
        // 确认时就画出实际交给 Vision 的框，避免保留手势上一帧的路径直到首个结果到达。
        if let previewRect = trackingPreviewRect(forVisionBoundingBox: trackingRect) {
            trackingLayer?.path = UIBezierPath(rect: previewRect).cgPath
        }
        // 目标确认，切换为锁定色 (#01D1BB)
        switchTrackingLayerToLockedColor()
        NotificationCenter.default.post(
            name: .trackingStateChanged,
            object: self,
            userInfo: [
                "isTracking": true,
                // 希区柯克复用 Vision Tracker，但不能同步为普通目标跟踪 UI。
                "mode": captureMode == .hitchcock ? "hitchcock"
                    : (preservingPhysicalObjectMode ? "physicalObject" : "object")
            ]
        )
        return trackingRect
    }

    /// 取消当前 VNTrackObjectRequest，并为下一次框选建立全新的序列上下文。
    /// 请求可能正在 dataOutputQueue 上完成最后一帧，因此 AVCapture 回调还会通过对象身份
    /// 校验丢弃旧结果，避免旧请求反过来清理新目标。
    func releaseCurrentObjectTrackingRequest() {
        let request = currentTrackingRequest
        currentTrackingRequest = nil
        request?.isLastFrame = true
        request?.cancel()
        releasePhysicalObjectPatchSession(request: request)
        sequenceHandler = VNSequenceRequestHandler()
    }

    /// Vision 跟踪请求失效后立即停止云台沿上一条指令继续运动。
    /// 希区柯克保留录像状态并允许重新框选；普通目标跟踪则退出本次跟踪。
    func handleObjectTrackingFailure(reason: String) {
        guard currentTrackingRequest != nil else { return }

        if isPhysicalObjectTrackingActive {
            pausePhysicalObjectFollowing(reason: reason)
            return
        }

        if captureMode == .hitchcock {
            handleHitchcockTrackingFailure(reason: reason)
            return
        }

        releaseCurrentObjectTrackingRequest()
        sendTrackingCommand(state: .exit, centerPoint: .zero)
        kkLog("🛑 Vision 目标跟踪失效，已停止云台: \(reason)")

        DispatchQueue.main.async {
            self.trackingPanGesture.isEnabled = false
            self.clearTrackingLayer()
            NotificationCenter.default.post(
                name: .trackingExited,
                object: self,
                userInfo: ["mode": "object", "reason": reason]
            )
        }
    }
    
    func stopTracking(notificationMode: String = "object") {
        stopPhysicalObjectTracking(reason: "tracking_stopped")
        // 发送退出跟踪指令
        sendTrackingCommand(state: .exit, centerPoint: .zero)
        
        releaseCurrentObjectTrackingRequest()
        trackingPanGesture.isEnabled = false
        clearTrackingLayer()
        NotificationCenter.default.post(
            name: .trackingExited,
            object: self,
            userInfo: ["mode": notificationMode]
        )
    }
    
    func updateTrackingLayer(with observation: VNDetectedObjectObservation) {
        // 人脸跟踪模式下，禁止“目标跟踪”同时发云台指令（会打架导致乱动）
        if isFaceTrackingMode { return }
        guard let previewLayer = previewLayer else { return }
        guard let rect = trackingPreviewRect(forVisionBoundingBox: observation.boundingBox) else { return }
        trackingLayer?.path = UIBezierPath(rect: rect).cgPath
        
        // 计算跟踪中心点
        let centerPoint = CGPoint(x: rect.midX, y: rect.midY)

        // 希区柯克框选完成后仍需让 Vision 持续更新目标框，但在真正开始录像前
        // 不允许下发运动坐标，否则用户一松手云台就会立即转动。
        if captureMode == .hitchcock && hitchcockState != .recording {
            return
        }

        // 每次回调都发送跟踪指令
        sendTrackingCommand(state: .normal, centerPoint: centerPoint)
    }
    
    // MARK: - 跟踪指令发送

    func markTrackingZoomActive() {
        guard isFaceTrackingMode else { return }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if !trackingZoomActive {
            trackingZoomActive = true
            trackingZoomLastLogTimeMs = nowMs
            kkLog("🔎 变焦中启用受限目标跟踪: zoom=\(String(format: "%.2f", zoomScale))")
        } else if nowMs - trackingZoomLastLogTimeMs > 1000 {
            trackingZoomLastLogTimeMs = nowMs
            kkLog("🔎 变焦持续中，保持受限目标跟踪: zoom=\(String(format: "%.2f", zoomScale))")
        }
    }

    func markTrackingZoomStopped() {
        guard trackingZoomActive else { return }

        trackingZoomActive = false
        trackingZoomLastLogTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
        kkLog("✅ 变焦停止，继续沿用跟踪滤波: zoom=\(String(format: "%.2f", zoomScale))")
    }

    private func trackingEffectiveZoomFactor() -> Double {
        // ramp 期间 zoomScale 是终点，使用硬件当前倍率才能消除尚未完成的变焦位移。
        let zoom = captureMode == .hitchcock ? (videoInput?.device.videoZoomFactor ?? zoomScale) : zoomScale
        let deviceZoom = max(1.0, Double(zoom))
        let displayedZoom = isUsingWideCamera ? deviceZoom / 2.0 : deviceZoom
        return max(0.5, displayedZoom)
    }

    private func trackingControlOffset(rawValue: Int, zoomFactor: Double) -> Int {
        let compensation = trackingZoomReferenceFactor / max(0.5, zoomFactor)
        let compensatedValue = Int((Double(rawValue) * compensation).rounded())
        return max(-1000, min(1000, compensatedValue))
    }

    private func resetTrackingStabilizerState() {
        trackingLastRawOffsetX = 0
        trackingLastRawOffsetY = 0
        trackingJumpCount = 0
        trackingFilteredX = 0
        trackingFilteredY = 0
        trackingFilterInited = false
        trackingLastOutputX = 0
        trackingLastOutputY = 0
        trackingLastControlUpdateTimeMs = 0
        trackingPreviousDetectedRawX = 0
        trackingPreviousDetectedRawY = 0
        trackingPreviousDetectedTimeMs = 0
        lastSentFinalX = 0
        lastSentFinalY = 0
        lastSentState = -1
    }

    private func observedHorizontalRotationRate() -> Double? {
        deviceMotionStateLock.lock()
        let rate = latestHorizontalRotationRate
        let sampleUptime = latestHorizontalRotationSampleUptime
        deviceMotionStateLock.unlock()

        guard sampleUptime > 0,
              ProcessInfo.processInfo.systemUptime - sampleUptime <= 0.3 else {
            return nil
        }
        return rate
    }

    private func resetTrackingYawRestrictionState() {
        trackingYawRestrictionPhase = .monitoring
        trackingYawRestrictionDirection = 0
        trackingYawRestrictionCandidateStartedAtMs = 0
        trackingYawRestrictionReferenceError = 0
        trackingYawRestrictionPausedAtMs = 0
        trackingYawRestrictionProbeStartedAtMs = 0
        trackingYawRestrictionProbeReferenceError = 0
    }

    private func postTrackingYawRestrictionChanged(isRestricted: Bool) {
        NotificationCenter.default.post(
            name: .trackingYawRestrictionChanged,
            object: self,
            userInfo: [
                "isRestricted": isRestricted,
                "axis": "yaw",
                "source": "trackingInferred"
            ]
        )
    }

    /// App 侧没有电机堵转/机械限位回包，因此结合两个相互独立的信号推断：
    /// 1. 目标长期停留在画面同一侧，且控制器持续要求较大的 Yaw 输出；
    /// 2. 手机陀螺仪确认云台没有发生水平转动。
    ///
    /// 触发后只把水平输出置零，Vision 识别和垂直跟随继续运行。暂停一段时间后
    /// 进行短时、限幅的恢复探测；检测到真实转动或目标回到安全区域便自动恢复。
    private func applyTrackingYawRestriction(
        rawX: Int,
        intendedOutputX: Int,
        nowMs: Int64
    ) -> Int {
        let errorMagnitude = abs(rawX)
        let direction = rawX == 0 ? 0 : (rawX > 0 ? 1 : -1)
        let horizontalRotationRate = observedHorizontalRotationRate()

        let activationError = 620
        let recoveryError = 430
        let minimumDemand = 110
        let meaningfulProgress = 80
        let movingRate = 0.045 // rad/s，约 2.6°/s
        let detectionDurationMs: Int64 = 2_000
        let pauseDurationMs: Int64 = 1_500
        let probeDurationMs: Int64 = 800
        let probeOutputLimit = 180

        // BLE 不可用时无法把“没有转动”归因到机械受限；保持识别并暂停水平输出，
        // 连接恢复后再走受限状态的自动探测流程。
        guard KKBLEManager.shared.isCommandChannelReady else {
            trackingYawRestrictionCandidateStartedAtMs = 0
            trackingYawRestrictionReferenceError = 0
            trackingYawRestrictionDirection = direction
            if trackingYawRestrictionPhase != .monitoring {
                trackingYawRestrictionPhase = .paused
                trackingYawRestrictionPausedAtMs = nowMs
                return 0
            }
            return intendedOutputX
        }

        switch trackingYawRestrictionPhase {
        case .monitoring:
            let hasLargeDemand = errorMagnitude >= activationError
                && abs(intendedOutputX) >= minimumDemand
                && direction != 0
            let isActuallyMoving = (horizontalRotationRate ?? 0) >= movingRate

            guard hasLargeDemand, !isActuallyMoving else {
                trackingYawRestrictionDirection = 0
                trackingYawRestrictionCandidateStartedAtMs = 0
                trackingYawRestrictionReferenceError = 0
                return intendedOutputX
            }

            if trackingYawRestrictionCandidateStartedAtMs == 0
                || trackingYawRestrictionDirection != direction {
                trackingYawRestrictionDirection = direction
                trackingYawRestrictionCandidateStartedAtMs = nowMs
                trackingYawRestrictionReferenceError = errorMagnitude
                return intendedOutputX
            }

            // 误差确实在缩小时，说明云台正在追赶，只重新开始观察窗口，不触发受限。
            if errorMagnitude <= trackingYawRestrictionReferenceError - meaningfulProgress {
                trackingYawRestrictionCandidateStartedAtMs = nowMs
                trackingYawRestrictionReferenceError = errorMagnitude
                return intendedOutputX
            }

            guard nowMs - trackingYawRestrictionCandidateStartedAtMs >= detectionDurationMs else {
                return intendedOutputX
            }

            trackingYawRestrictionPhase = .paused
            trackingYawRestrictionPausedAtMs = nowMs
            trackingYawRestrictionProbeStartedAtMs = 0
            trackingYawRestrictionProbeReferenceError = 0
            postTrackingYawRestrictionChanged(isRestricted: true)
            kkLog(
                "🛑 推断云台水平旋转受限，暂停Yaw输出: rawX=\(rawX), outputX=\(intendedOutputX), gyro=\(String(format: "%.3f", horizontalRotationRate ?? -1))rad/s"
            )
            return 0

        case .paused:
            if errorMagnitude <= recoveryError
                || (direction != 0 && direction != trackingYawRestrictionDirection) {
                resetTrackingYawRestrictionState()
                postTrackingYawRestrictionChanged(isRestricted: false)
                kkLog("✅ 目标回到安全区域，恢复Yaw跟随: rawX=\(rawX)")
                return intendedOutputX
            }

            guard nowMs - trackingYawRestrictionPausedAtMs >= pauseDurationMs else {
                return 0
            }

            trackingYawRestrictionPhase = .probing
            trackingYawRestrictionProbeStartedAtMs = nowMs
            trackingYawRestrictionProbeReferenceError = errorMagnitude
            let limitedOutput = max(-probeOutputLimit, min(probeOutputLimit, intendedOutputX))
            kkLog("🧭 云台水平旋转受限后开始恢复探测: rawX=\(rawX), outputX=\(limitedOutput)")
            return limitedOutput

        case .probing:
            let hasStartedMoving = (horizontalRotationRate ?? 0) >= movingRate
            let errorHasImproved = errorMagnitude
                <= trackingYawRestrictionProbeReferenceError - meaningfulProgress
            if hasStartedMoving || errorHasImproved || errorMagnitude <= recoveryError {
                resetTrackingYawRestrictionState()
                postTrackingYawRestrictionChanged(isRestricted: false)
                kkLog(
                    "✅ 云台水平旋转恢复，继续跟随: rawX=\(rawX), gyro=\(String(format: "%.3f", horizontalRotationRate ?? -1))rad/s"
                )
                return intendedOutputX
            }

            guard nowMs - trackingYawRestrictionProbeStartedAtMs < probeDurationMs else {
                trackingYawRestrictionPhase = .paused
                trackingYawRestrictionPausedAtMs = nowMs
                kkLog("⏸️ 云台水平恢复探测未检测到运动，继续暂停Yaw输出")
                return 0
            }

            return max(-probeOutputLimit, min(probeOutputLimit, intendedOutputX))
        }
    }

    func resetTrackingForNewSession() {
        resetAutoTrackingTargetSelection()
        trackingStrategyHoldUntilMs = 0
        trackingNeedsSeedAfterStrategyChange = false
        trackingNeedsInitialSeed = false
        hitchcockCompositionBaselineX = nil
        hitchcockCompositionBaselineY = nil
        pendingTrackingFaceRect = nil
        pendingTrackingFaceCount = 0
        pendingTrackingHumanRect = nil
        pendingTrackingHumanCount = 0
        trackingConsecutiveFaceMissCount = 0
        trackingNoTargetHoldSent = false
        trackingVisionInputLogged = false
        trackingPendingHoldLastLogTimeMs = 0
        trackingDetectionLastPerformanceLogMs = 0
        trackingHumanRejectLastLogTimeMs = 0
        trackingFaceMotionAcceptLastLogTimeMs = 0
        trackingHumanFallbackCenterX = nil
        trackingCenterLocked = false
        trackingCenterLockLastLogTimeMs = 0
        trackingZoomActive = false
        trackingZoomLastLogTimeMs = 0
        // 希区柯克以 UI 1x 为固定控制增益；4x 起拍不能把高倍抖动当作 1x 位移。
        trackingZoomReferenceFactor = captureMode == .hitchcock ? 1.0 : trackingEffectiveZoomFactor()
        resetTrackingYawRestrictionState()
        resetTrackingStabilizerState()
    }

    func markTrackingTargetAcquired() {
        if trackingNoTargetHoldSent {
            trackingNoTargetHoldSent = false
            trackingCenterLocked = false
            resetTrackingStabilizerState()
            kkLog("♻️ 目标重新识别，清除丢失前的坐标与输出基准")
            return
        }
        trackingNoTargetHoldSent = false
    }

    func holdTrackingAtCenterForNoTarget(reason: String) {
        guard isFaceTrackingMode else { return }
        guard !trackingNoTargetHoldSent else { return }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        guard nowMs - ProtocolParser.shared.lastTrackingSendTime > 50 else { return }

        ProtocolParser.shared.setTracking(
            centerX: 0,
            centerY: 0,
            state: TrackingState.normal.rawValue,
            isFront: isFrontCamera
        )
        trackingNoTargetHoldSent = true
        trackingCenterLocked = false
        trackingHumanFallbackCenterX = nil
        resetTrackingStabilizerState()
        lastSentFinalX = 0
        lastSentFinalY = 0
        lastSentState = Int(TrackingState.normal.rawValue)
        kkLog("🛑 未确认可靠目标，发送居中保持指令: reason=\(reason)")
    }

    private func handleTrackingCenterLock(
        rawX: Int,
        rawY: Int,
        controlX: Int,
        controlY: Int,
        nowMs: Int64
    ) -> Bool {
        guard isFaceTrackingMode else {
            trackingCenterLocked = false
            return false
        }

        // 进入阈值小、退出阈值大，避免目标在边界附近反复启停。
        let enterThresholdX = 110
        let enterThresholdY = 130
        let exitThresholdX = 150
        let exitThresholdY = 190
        let absoluteX = abs(rawX)
        let absoluteY = abs(rawY)

        if trackingCenterLocked {
            if absoluteX >= exitThresholdX || absoluteY >= exitThresholdY {
                trackingCenterLocked = false
                resetTrackingStabilizerState()
                trackingPreviousDetectedRawX = controlX
                trackingPreviousDetectedRawY = controlY
                trackingPreviousDetectedTimeMs = nowMs
                kkLog("🔓 目标离开中心锁定区，恢复跟随: raw=(\(rawX),\(rawY))")
                return false
            }
        } else if absoluteX <= enterThresholdX && absoluteY <= enterThresholdY {
            trackingCenterLocked = true
            trackingCenterLockLastLogTimeMs = nowMs
            kkLog("🔒 目标进入中心锁定区，停止云台输出: raw=(\(rawX),\(rawY))")
        } else {
            return false
        }

        // 一进入中心区就清掉旧方向惯性；若仍在 50ms 节流窗口，下一帧再补发零偏移。
        trackingLastRawOffsetX = rawX
        trackingLastRawOffsetY = rawY
        trackingJumpCount = 0
        trackingFilteredX = 0
        trackingFilteredY = 0
        trackingFilterInited = false
        trackingLastOutputX = 0
        trackingLastOutputY = 0
        trackingLastControlUpdateTimeMs = 0

        let normalState = Int(TrackingState.normal.rawValue)
        let needsCenterCommand = lastSentFinalX != 0
            || lastSentFinalY != 0
            || lastSentState != normalState
        if needsCenterCommand && nowMs - ProtocolParser.shared.lastTrackingSendTime > 50 {
            ProtocolParser.shared.setTracking(
                centerX: 0,
                centerY: 0,
                state: TrackingState.normal.rawValue,
                isFront: isFrontCamera
            )
            lastSentFinalX = 0
            lastSentFinalY = 0
            lastSentState = normalState
        }

        if nowMs - trackingCenterLockLastLogTimeMs >= 2000 {
            trackingCenterLockLastLogTimeMs = nowMs
            kkLog("🔒 目标保持在中心锁定区: raw=(\(rawX),\(rawY))")
        }
        return true
    }

    func softenTrackingOutputForPendingTarget(
        reason: String,
        decay: Double,
        maxHorizontalMagnitude: Int? = nil,
        maxVerticalMagnitude: Int? = nil
    ) {
        guard isFaceTrackingMode else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        guard nowMs - ProtocolParser.shared.lastTrackingSendTime > 50 else { return }

        let appliedDecay = max(0.0, min(0.95, decay))
        func decayedValue(_ value: Int, maximumMagnitude: Int?) -> Int {
            var next = Int((Double(value) * appliedDecay).rounded())
            if let maximumMagnitude {
                let limit = max(0, maximumMagnitude)
                next = max(-limit, min(limit, next))
            }
            return abs(next) < 4 ? 0 : next
        }

        let nextX = decayedValue(lastSentFinalX, maximumMagnitude: maxHorizontalMagnitude)
        let nextY = decayedValue(lastSentFinalY, maximumMagnitude: maxVerticalMagnitude)
        guard nextX != lastSentFinalX || nextY != lastSentFinalY else { return }

        ProtocolParser.shared.setTracking(
            centerX: nextX * 3,
            centerY: nextY * 3,
            state: TrackingState.normal.rawValue,
            isFront: isFrontCamera
        )
        lastSentFinalX = nextX
        lastSentFinalY = nextY
        lastSentState = Int(TrackingState.normal.rawValue)
        trackingLastOutputX = nextX
        trackingLastOutputY = nextY
        trackingFilteredX *= appliedDecay
        trackingFilteredY *= appliedDecay
        trackingLastControlUpdateTimeMs = nowMs
        // 短时漏检减速到零不等于目标已彻底丢失；这里不改 trackingNoTargetHoldSent。
        // 只有 holdTrackingAtCenterForNoTarget 才设置该标志。

        if nowMs - trackingPendingHoldLastLogTimeMs >= 1000 {
            trackingPendingHoldLastLogTimeMs = nowMs
            let decayText = String(format: "%.2f", appliedDecay)
            kkLog("🫧 目标切换/短暂丢失，平滑减速: reason=\(reason), decay=\(decayText), output=(\(nextX * 3),\(nextY * 3))")
        }
    }

    func beginTrackingStrategyTransition(from previous: CMTrackingDetectionStrategy, to next: CMTrackingDetectionStrategy) {
        // 人脸框与人形框现在统一在预览坐标系中，保留 EMA 输出即可平滑衔接。
        // 只重置原始跳变基准，避免不同检测器的框尺寸差异被当作异常跳变。
        trackingStrategyHoldUntilMs = 0
        trackingNeedsSeedAfterStrategyChange = false
        trackingLastRawOffsetX = 0
        trackingLastRawOffsetY = 0
        trackingJumpCount = 0
        trackingPreviousDetectedRawX = 0
        trackingPreviousDetectedRawY = 0
        trackingPreviousDetectedTimeMs = 0

        let previousName = previous == .face ? "人脸" : "人形"
        let nextName = next == .face ? "人脸" : "人形"
        kkLog("🌊 跟踪检测器平滑切换 \(previousName) -> \(nextName)，保留滤波状态")
    }

    private func seedTrackingStabilizer(rawX: Int, rawY: Int, sendX: Int, sendY: Int) {
        let seedX = Double(sendX) / 3.0
        let seedY = Double(sendY) / 3.0
        trackingLastRawOffsetX = rawX
        trackingLastRawOffsetY = rawY
        trackingJumpCount = 0
        trackingFilteredX = seedX
        trackingFilteredY = seedY
        trackingFilterInited = true
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        trackingLastControlUpdateTimeMs = nowMs
        trackingPreviousDetectedRawX = sendX
        trackingPreviousDetectedRawY = sendY
        trackingPreviousDetectedTimeMs = nowMs
        // 新目标只建立滤波基准，云台控制量从 0 开始爬升，避免首包猛转。
        trackingLastOutputX = 0
        trackingLastOutputY = 0
    }
    
    /// 发送跟踪指令到云台
    func sendTrackingCommand(state: TrackingState, centerPoint: CGPoint,
                             physicalObjectContext: PhysicalObjectTrackingWriteContext? = nil) {
        let currentTime = Int64(Date().timeIntervalSince1970 * 1000)
        
        guard let previewLayer = previewLayer else {
            kkLog("预览层未初始化，无法发送跟踪指令")
            return
        }
        
        // 将屏幕坐标转换为协议所需的坐标系统
        let previewBounds = previewLayer.bounds
        
        let w = max(1.0, previewBounds.width)
        let h = max(1.0, previewBounds.height)
        
        let centerXRaw = Int((centerPoint.x / w) * 2000.0 - 1000.0)   // [-1000, 1000]
        let centerYRaw = Int((centerPoint.y / h) * 2000.0 - 1000.0)   // [-1000, 1000]
        
        // ⚠️ 轴映射：sendX 控制 Yaw, sendY 控制 Pitch。
        // 变焦会按倍率放大屏幕偏移；换算为近似角度误差后再进入控制器，避免高倍变焦放大抖动。
        let effectiveZoomFactor = trackingEffectiveZoomFactor()
        let absoluteControlX = trackingControlOffset(rawValue: centerXRaw, zoomFactor: effectiveZoomFactor)
        let absoluteControlY = trackingControlOffset(rawValue: centerYRaw, zoomFactor: effectiveZoomFactor)
        
        // 打印原始计算值（节流）
        #if DEBUG
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if nowMs - trackingLastLogTimeMs > 500 {
            kkLog("跟踪原始值 - Raw: (\(centerXRaw), \(centerYRaw))")
            trackingLastLogTimeMs = nowMs
        }
        #endif

        if state != .normal {
            ProtocolParser.shared.setTracking(centerX: 0, centerY: 0, state: state.rawValue, isFront: isFrontCamera,
                                             physicalObjectContext: physicalObjectContext)
            trackingZoomActive = false
            resetTrackingForNewSession()
            return
        }

        var sendX = absoluteControlX
        var sendY = absoluteControlY
        if isPhysicalObjectTrackingActive {
            guard physicalObjectIsFollowing, physicalObjectFollowSafety.ready else { return }
            let connected = KKBLEManager.shared.isCommandChannelReady
            guard connected else {
                // A visual preview is not a delivered motor command. Do not
                // accumulate output or deduplication state while BLE is down;
                // the first connected frame must start from zero and send the
                // current target even if its position has not changed.
                resetTrackingStabilizerState()
                return
            }
            let wasMotionPaused = physicalObjectFollowSafety.motionPaused
            if let reason = physicalObjectFollowSafety.control(
                rawX: centerXRaw, rawY: centerYRaw, at: ProcessInfo.processInfo.systemUptime,
                commandedX: connected && lastSentState == Int(TrackingState.normal.rawValue) && lastSentFinalX != 0,
                commandedY: connected && lastSentState == Int(TrackingState.normal.rawValue) && lastSentFinalY != 0) {
                kkLog("event=physical_follow_control_paused reason=\(reason) raw=(\(centerXRaw),\(centerYRaw)) output=(\(lastSentFinalX),\(lastSentFinalY))")
                holdPhysicalObjectControl(reason: reason)
                return
            }
            guard !physicalObjectFollowSafety.motionPaused else { return }
            if wasMotionPaused { physicalObjectControlDidResume() }
            // One centered axis must remain still while the other follows.
            if physicalObjectFollowSafety.heldX {
                sendX = 0
                trackingFilteredX = 0
                trackingLastOutputX = 0
            }
            if physicalObjectFollowSafety.heldY {
                sendY = 0
                trackingFilteredY = 0
                trackingLastOutputY = 0
            }
        }
        if captureMode == .hitchcock && hitchcockState == .recording {
            // 希区柯克要保持用户框选时的构图，不应把目标相对画面中心的初始偏移
            // 直接下发给云台。absoluteControl 已消除了当前变焦倍率，再减去首帧基准，
            // 可同时过滤“目标不居中”和连续变焦产生的假位移。
            if hitchcockCompositionBaselineX == nil ||
                hitchcockCompositionBaselineY == nil ||
                trackingNeedsInitialSeed {
                hitchcockCompositionBaselineX = absoluteControlX
                hitchcockCompositionBaselineY = absoluteControlY
            }
            sendX = absoluteControlX - (hitchcockCompositionBaselineX ?? absoluteControlX)
            sendY = absoluteControlY - (hitchcockCompositionBaselineY ?? absoluteControlY)
        }

        let previousDetectedRawX = trackingPreviousDetectedRawX
        let previousDetectedRawY = trackingPreviousDetectedRawY
        let rawDetectionElapsedMs = trackingPreviousDetectedTimeMs > 0
            ? currentTime - trackingPreviousDetectedTimeMs
            : 0
        trackingPreviousDetectedRawX = sendX
        trackingPreviousDetectedRawY = sendY
        trackingPreviousDetectedTimeMs = currentTime

        if trackingNeedsInitialSeed {
            seedTrackingStabilizer(
                rawX: sendX,
                rawY: sendY,
                sendX: sendX,
                sendY: sendY
            )
            trackingNeedsInitialSeed = false
            kkLog("🌱 希区柯克录制首帧锁定构图基准: raw=(\(centerXRaw),\(centerYRaw)), baseline=(\(absoluteControlX),\(absoluteControlY))")
            return
        }

        if trackingNeedsSeedAfterStrategyChange {
            if currentTime < trackingStrategyHoldUntilMs {
                return
            }

            seedTrackingStabilizer(
                rawX: centerXRaw,
                rawY: centerYRaw,
                sendX: sendX,
                sendY: sendY
            )
            trackingNeedsSeedAfterStrategyChange = false
            kkLog("🌱 检测器切换后的稳定首帧仅用于滤波种子: raw=(\(centerXRaw),\(centerYRaw))")
            return
        }

        if handleTrackingCenterLock(
            rawX: centerXRaw,
            rawY: centerYRaw,
            controlX: sendX,
            controlY: sendY,
            nowMs: currentTime
        ) {
            return
        }

        // ⚠️ 优化：计算层节流。ProtocolParser 已经是 50ms 节流了，
        // 变焦期间沿用同一节流窗口，防止 D1 指令挤压 BLE withResponse 队列。
        if currentTime - ProtocolParser.shared.lastTrackingSendTime < 50 {
            return
        }

        // ⚠️ 跳变保护
        let maxRawJumpThreshold = 450 
        if isFaceTrackingMode {
            if trackingLastRawOffsetX == 0 && trackingLastRawOffsetY == 0 {
                trackingLastRawOffsetX = centerXRaw
                trackingLastRawOffsetY = centerYRaw
                trackingJumpCount = 0
            } else if abs(centerXRaw - trackingLastRawOffsetX) > maxRawJumpThreshold
                        || abs(centerYRaw - trackingLastRawOffsetY) > maxRawJumpThreshold {
                trackingJumpCount += 1
                if trackingJumpCount < 3 {
                    #if DEBUG
                    kkLog("⚠️ 跟踪跳变过大，丢弃本帧(\(trackingJumpCount)/3) - 上帧:(\(trackingLastRawOffsetX),\(trackingLastRawOffsetY)), 本帧:(\(centerXRaw),\(centerYRaw))")
                    #endif
                    return
                } else {
                    #if DEBUG
                    kkLog("🔄 连续跳变达到阈值，重置滤波器但不下发异常坐标")
                    #endif
                    seedTrackingStabilizer(
                        rawX: centerXRaw,
                        rawY: centerYRaw,
                        sendX: sendX,
                        sendY: sendY
                    )
                    return
                }
            } else {
                trackingLastRawOffsetX = centerXRaw
                trackingLastRawOffsetY = centerYRaw
                trackingJumpCount = 0
            }
        }

        // ===== 跟踪稳定化输出（深度优化）=====
        
        // 0. 距离自适应策略
        let faceArea = (lastDetectedFaceRect?.width ?? 0.1) * (lastDetectedFaceRect?.height ?? 0.1)
        let isFarDistance = faceArea < 0.012 
        
        // 1. 归一化输入
        func predictedApproachRaw(current: Int, previous: Int, elapsedMs: Int64) -> Int {
            guard elapsedMs >= 60, elapsedMs <= 350,
                  current != 0, previous != 0,
                  (current > 0) == (previous > 0) else {
                return current
            }

            let reduction = abs(previous) - abs(current)
            let minimumReduction = max(24, Int((Double(abs(previous)) * 0.12).rounded()))
            guard reduction >= minimumReduction else { return current }

            let predictionHorizonMs = min(120.0, max(70.0, Double(elapsedMs) * 0.65))
            let velocity = Double(current - previous) / Double(elapsedMs)
            let projected = Double(current) + velocity * predictionHorizonMs
            guard projected * Double(current) > 0 else { return 0 }

            let projectedMagnitude = min(Double(abs(current)), abs(projected))
            let roundedMagnitude = Int(projectedMagnitude.rounded())
            return current > 0 ? roundedMagnitude : -roundedMagnitude
        }

        let hasHorizontalTrendSample = rawDetectionElapsedMs >= 60
            && rawDetectionElapsedMs <= 350
            && sendX != 0
            && previousDetectedRawX != 0
            && (sendX > 0) == (previousDetectedRawX > 0)
        let horizontalMagnitudeDelta = abs(sendX) - abs(previousDetectedRawX)
        let horizontalTrendThreshold = max(
            18,
            Int((Double(abs(previousDetectedRawX)) * 0.08).rounded())
        )
        let horizontalMovingAway = hasHorizontalTrendSample
            && horizontalMagnitudeDelta >= horizontalTrendThreshold
        let horizontalApproaching = hasHorizontalTrendSample
            && -horizontalMagnitudeDelta >= horizontalTrendThreshold

        func predictedOutwardRaw(current: Int, previous: Int, elapsedMs: Int64) -> Int {
            guard horizontalMovingAway else { return current }

            // 检测和 BLE 都有延迟。仅在目标明确向外移动时加入短前馈，
            // 回中心阶段仍交给上面的预测刹车，避免重新引入过冲。
            let predictionHorizonMs = min(48.0, max(30.0, Double(elapsedMs) * 0.28))
            let velocity = Double(current - previous) / Double(elapsedMs)
            let projected = Double(current) + velocity * predictionHorizonMs
            guard projected * Double(current) > 0,
                  abs(projected) > Double(abs(current)) else {
                return current
            }

            let leadCap = min(55.0, max(18.0, Double(abs(current)) * 0.10))
            let lead = min(abs(projected) - Double(abs(current)), leadCap)
            let predictedMagnitude = Int((Double(abs(current)) + lead).rounded())
            return current > 0 ? predictedMagnitude : -predictedMagnitude
        }

        let approachPredictedRawX = predictedApproachRaw(
            current: sendX,
            previous: previousDetectedRawX,
            elapsedMs: rawDetectionElapsedMs
        )
        let predictedRawX = horizontalMovingAway
            ? predictedOutwardRaw(
                current: sendX,
                previous: previousDetectedRawX,
                elapsedMs: rawDetectionElapsedMs
            )
            : approachPredictedRawX
        let predictedRawY = predictedApproachRaw(
            current: sendY,
            previous: previousDetectedRawY,
            elapsedMs: rawDetectionElapsedMs
        )
        let trendBrakeApplied = approachPredictedRawX != sendX || predictedRawY != sendY
        let horizontalLeadApplied = predictedRawX != approachPredictedRawX
        let inputX = Double(predictedRawX) / 3.0
        let inputY = Double(predictedRawY) / 3.0
        let controlElapsedMs: Int64
        if trackingLastControlUpdateTimeMs > 0 {
            controlElapsedMs = max(60, min(180, currentTime - trackingLastControlUpdateTimeMs))
        } else {
            // 趋势刹车已经限制回中心过冲，水平轴可以稍快建立首个有效速度。
            controlElapsedMs = 120
        }
        trackingLastControlUpdateTimeMs = currentTime
        let responseScale = Double(controlElapsedMs) / 100.0

        // 2. EMA 滤波
        if !trackingFilterInited {
            trackingFilteredX = inputX
            trackingFilteredY = inputY
            trackingFilterInited = true
            trackingLastOutputX = 0
            trackingLastOutputY = 0
        } else {
            // 方向反转时先衰减旧方向惯性，再由 EMA 平滑跨过中心。
            if (inputX > 5 && trackingFilteredX < -5) || (inputX < -5 && trackingFilteredX > 5) {
                trackingFilteredX *= 0.35
            }
            if (inputY > 5 && trackingFilteredY < -5) || (inputY < -5 && trackingFilteredY > 5) {
                trackingFilteredY *= 0.35
            }

            let magnitude = max(abs(inputX), abs(inputY))
            let baseAlpha: Double
            if isFarDistance {
                baseAlpha = magnitude >= 100 ? 0.50 : 0.42
            } else {
                baseAlpha = magnitude >= 100 ? 0.42 : 0.32
            }

            // 固定 alpha 会让 200ms 一帧的旧设备比 100ms 一帧多一倍滞后；换算为等效时间常数。
            let horizontalAlphaBoost: Double
            if horizontalMovingAway {
                horizontalAlphaBoost = 0.10
            } else if horizontalApproaching {
                horizontalAlphaBoost = 0.0
            } else {
                horizontalAlphaBoost = 0.04
            }
            let baseAlphaX = min(0.68, baseAlpha + horizontalAlphaBoost)
            let alphaX = 1.0 - pow(1.0 - baseAlphaX, responseScale)
            let alphaY = 1.0 - pow(1.0 - baseAlpha, responseScale)
            trackingFilteredX = trackingFilteredX + alphaX * (inputX - trackingFilteredX)
            trackingFilteredY = trackingFilteredY + alphaY * (inputY - trackingFilteredY)
        }

        // 3. 非线性增益
        func applyGainCurve(_ v: Double) -> Double {
            let absV = abs(v)
            // ⚠️ 提升灵敏度：增加基础增益
            let distanceBonus = isFarDistance ? 1.35 : 1.15
            if absV < 30 { return v * 1.25 * distanceBonus } 
            let limit = 333.0
            let gain = 1.05 * distanceBonus
            let gamma = isFarDistance ? 1.0 : 1.05
            let x = v / limit
            let curved = (x == 0) ? 0.0 : (copysign(pow(abs(x), gamma), x))
            return curved * limit * gain
        }
        
        var outputX = applyGainCurve(trackingFilteredX)
        var outputY = applyGainCurve(trackingFilteredY)

        // 4. 步进限制
        // 按真实检测间隔换算步进：检测慢时保持相同的每秒追赶速度，检测快时仍维持细腻小步。
        let horizontalErrorMagnitude = abs(predictedRawX)
        let verticalErrorMagnitude = abs(predictedRawY)
        let baseMaxStepY: Double
        if verticalErrorMagnitude >= 650 {
            baseMaxStepY = isFarDistance ? 54.0 : 48.0
        } else if verticalErrorMagnitude >= 400 {
            baseMaxStepY = isFarDistance ? 44.0 : 38.0
        } else {
            baseMaxStepY = isFarDistance ? 30.0 : 22.0
        }
        let baseMaxStepX: Double
        if horizontalErrorMagnitude >= 650 {
            // 目标已接近画面边缘时，普通软启动来不及追上，直接进入快速捕获档。
            baseMaxStepX = isFarDistance ? 60.0 : 56.0
        } else if horizontalErrorMagnitude >= 400 {
            baseMaxStepX = isFarDistance ? 46.0 : 42.0
        } else if horizontalMovingAway {
            baseMaxStepX = isFarDistance ? 36.0 : 26.0
        } else if horizontalApproaching {
            baseMaxStepX = isFarDistance ? 30.0 : 22.0
        } else {
            baseMaxStepX = isFarDistance ? 32.0 : 24.0
        }
        let maxStepX = baseMaxStepX * responseScale
        let maxStepY = baseMaxStepY * responseScale
        outputX = Double(trackingLastOutputX) + max(-maxStepX, min(maxStepX, outputX - Double(trackingLastOutputX)))
        outputY = Double(trackingLastOutputY) + max(-maxStepY, min(maxStepY, outputY - Double(trackingLastOutputY)))

        // 云台和检测都存在延迟，接近中心时不能继续放大旧误差，否则会在下一帧到来前越过目标。
        // 输出必须与当前误差同向，且越接近中心，允许的比例越小。
        var approachBrakeApplied = false
        func applyCurrentErrorEnvelope(output: Double, input: Double, isHorizontal: Bool) -> Double {
            guard input != 0 else {
                approachBrakeApplied = approachBrakeApplied || output != 0
                return 0
            }
            guard output * input > 0 else {
                approachBrakeApplied = approachBrakeApplied || output != 0
                return 0
            }

            let absoluteInput = abs(input)
            let outputRatio: Double
            if isHorizontal {
                // Android 直接控制约等于 raw / 5。iOS 保留更快的爬升速度，
                // 但稳态水平输出限制在约 raw / 4.2~4.5，避免检测延迟下持续过追。
                if absoluteInput < 90 {
                    outputRatio = 0.68
                } else if absoluteInput < 150 {
                    outputRatio = 0.72
                } else {
                    outputRatio = 0.66
                }
            } else if absoluteInput < 90 {
                outputRatio = 0.68
            } else if absoluteInput < 150 {
                outputRatio = 0.84
            } else {
                outputRatio = 0.95
            }

            let limit = absoluteInput * outputRatio
            if abs(output) > limit {
                approachBrakeApplied = true
            }
            return copysign(min(abs(output), limit), input)
        }

        outputX = applyCurrentErrorEnvelope(output: outputX, input: inputX, isHorizontal: true)
        outputY = applyCurrentErrorEnvelope(output: outputY, input: inputY, isHorizontal: false)

        var finalX = Int(outputX.rounded())
        var finalY = Int(outputY.rounded())

        // 5. 最终指令修饰 (软启动逻辑)
        let horizontalDeadZone = isFarDistance ? 4 : 6
        let verticalDeadZone = isFarDistance ? 6 : 8
        let minKick = 42 
        
        func finalizeCommand(_ v: Int, deadZone: Int) -> Int {
            let absV = abs(v)
            if absV < deadZone { return 0 }
            
            let scaledV = v * 3
            let absScaledV = abs(scaledV)
            
            // ⚠️ 软启动优化：提升最小启动力，确保能带动物理电机
            if absScaledV < minKick {
                if absV <= (deadZone + 1) {
                    return v > 0 ? (minKick/3) : -(minKick/3) // 约 14
                } else {
                    return v > 0 ? (minKick/2) : -(minKick/2) // 约 21
                }
            }
            return v
        }

        finalX = finalizeCommand(finalX, deadZone: horizontalDeadZone)
        finalY = finalizeCommand(finalY, deadZone: verticalDeadZone)

        // 最小启动力不能反过来突破当前误差包络；不足以可靠驱动电机的小轴直接保持静止。
        finalX = Int(applyCurrentErrorEnvelope(output: Double(finalX), input: inputX, isHorizontal: true).rounded())
        finalY = Int(applyCurrentErrorEnvelope(output: Double(finalY), input: inputY, isHorizontal: false).rounded())
        if abs(finalX * 3) < minKick { finalX = 0 }
        if abs(finalY * 3) < minKick { finalY = 0 }

        // 协议有效偏移是 10000 ± 300；ProtocolParser 还会除以 3，
        // 因此这里的最终控制量必须限制在 ±300，避免误检把云台拉到极限。
        finalX = max(-300, min(300, finalX))
        finalY = max(-300, min(300, finalY))
        finalX = applyTrackingYawRestriction(
            rawX: centerXRaw,
            intendedOutputX: finalX,
            nowMs: currentTime
        )
        trackingLastOutputX = finalX
        trackingLastOutputY = finalY

        // ⚠️ 深度优化：指令去重与最小变化门槛
        // 1. 如果指令值变化极小（<= 1个单位，即协议坐标里的 3 个单位），判定为噪声，不发送。
        // 2. 如果状态也没变，则直接拦截。
        let diffX = abs(finalX - lastSentFinalX)
        let diffY = abs(finalY - lastSentFinalY)
        
        if diffX <= 1 && diffY <= 1 && state.rawValue == lastSentState {
            return
        }
        
        lastSentFinalX = finalX
        lastSentFinalY = finalY
        lastSentState = Int(state.rawValue)

        #if DEBUG
        let sendLogNowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if sendLogNowMs - trackingLastSendLogTimeMs > 500 {
            let distStr = isFarDistance ? "[远距离]" : "[标准]"
            let horizontalTrend = horizontalMovingAway ? "away" : (horizontalApproaching ? "approach" : "steady")
            let captureTier = horizontalErrorMagnitude >= 650 ? "extreme" : (horizontalErrorMagnitude >= 400 ? "large" : "normal")
            let zoomingText = trackingZoomActive ? "active" : "idle"
            kkLog("\(distStr) 🚀 发送跟踪指令: (\(finalX*3), \(finalY*3)), pred=(\(predictedRawX),\(predictedRawY)), dt=\(controlElapsedMs)ms, step=(\(Int(maxStepX.rounded())),\(Int(maxStepY.rounded()))), brake=\(approachBrakeApplied), trendBrake=\(trendBrakeApplied), xTrend=\(horizontalTrend), lead=\(horizontalLeadApplied), capture=\(captureTier), zoom=\(String(format: "%.2f", effectiveZoomFactor)), zoomRef=\(String(format: "%.2f", trackingZoomReferenceFactor)), zooming=\(zoomingText)")
            trackingLastSendLogTimeMs = sendLogNowMs
        }
        #endif

        ProtocolParser.shared.setTracking(
            centerX: finalX * 3,
            centerY: finalY * 3,
            state: state.rawValue,
            isFront: isFrontCamera,
            // Android 在希区柯克模式使用 sTrackingScale=6，降低云台跟随增益。
            scale: captureMode == .hitchcock ? 6 : 3,
            physicalObjectContext: physicalObjectContext
        )
    }
    
    // MARK: - 跟踪状态查询
    var isTracking: Bool {
        return currentTrackingRequest != nil || isPhysicalObjectTrackingActive
    }
    
    private func sendTrackingNotifications(for state: TrackingState, centerPoint: CGPoint) {
        // 通用的跟踪状态变化通知
        NotificationCenter.default.post(
            name: .trackingStateChanged,
            object: self,
            userInfo: [
                "state": state,
                "stateRawValue": state.rawValue,
                "stateDescription": state.description,
                "centerPoint": centerPoint,
                "isFrontCamera": isFrontCamera
            ]
        )
        
        // 通用的跟踪指令发送通知
        NotificationCenter.default.post(
            name: .trackingCommandSent,
            object: self,
            userInfo: [
                "command": "setTracking",
                "state": state,
                "centerPoint": centerPoint
            ]
        )
        
        // 根据状态发送特定通知
        switch state {
        case .targetLost:
            NotificationCenter.default.post(
                name: .trackingTargetLost,
                object: self,
                userInfo: ["centerPoint": centerPoint]
            )
            
        case .reCapture:
            NotificationCenter.default.post(
                name: .trackingReCapture,
                object: self,
                userInfo: ["centerPoint": centerPoint]
            )
            
        case .exit:
            NotificationCenter.default.post(
                name: .trackingExited,
                object: self,
                userInfo: ["lastCenterPoint": centerPoint]
            )
            
        default:
            break
        }
    }
}
