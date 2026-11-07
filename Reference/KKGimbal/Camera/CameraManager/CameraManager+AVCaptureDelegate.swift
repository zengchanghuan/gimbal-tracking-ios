//
//  CameraManager+AVCaptureDelegate.swift
//  KKCamera
//
//  Created by Kang on 7/18/23.
//

import Vision
import AVFoundation
import ImageIO
import KKGestureSDK

extension CameraManager: AVCapturePhotoCaptureDelegate,
                         AVCaptureVideoDataOutputSampleBufferDelegate,
                         AVCaptureAudioDataOutputSampleBufferDelegate,
                         AVCaptureFileOutputRecordingDelegate {
    
    // 代理回调: 音视频流
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let mediaType = getMeidaType(with: sampleBuffer) else { return }

        if mediaType == kCMMediaType_Video, isAwaitingCameraSwitchFrame,
           connection === videoConnection {
            DispatchQueue.main.async {
                guard self.isAwaitingCameraSwitchFrame,
                      connection === self.videoConnection else { return }
                self.isAwaitingCameraSwitchFrame = false
                // 原地切换输入时 isPreviewing 可能始终为 true，用新连接首帧结束快照。
                self.delegate?.cameraManager?(self, previewDidChanged: true)
            }
        }
        
//        kkLog("~~~ output:\(output), connection:\(connection)")
        
        // 手势识别。全景模式下强制关闭，避免与拼接管线争用算力。
        if mediaType == kCMMediaType_Video,
           isVGesEnable,
           captureMode != .panorama,
           isPrimaryGestureVideoOutput(output) {
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
               let recognizer = preparedGestureRecognizer {
                let orientation = gestureImageOrientation(
                    for: connection,
                    pixelBuffer: pixelBuffer
                )
                // 自动人脸跟踪期间保留 OK：没有手动锁定时，做 OK 的
                // 人物可以成为优先目标。点击锁定后关闭 OK，确保用户
                // 选择始终拥有最高优先级。V/张掌识别不受此开关影响。
                let shouldRecognizeOK = !isPhysicalObjectTrackingActive && currentTrackingRequest == nil
                    && (!isFaceTrackingMode || !hasManualTrackingTargetLock)
                recognizer.setOKGestureRecognitionEnabled(
                    shouldRecognizeOK
                )
                let presentationTime = CMTimeConvertScale(
                    CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                    timescale: 1_000,
                    method: .roundHalfAwayFromZero
                )
                let wasAccepted = recognizer.process(
                    pixelBuffer: pixelBuffer,
                    orientation: orientation,
                    isMirrored: connection.isVideoMirrored,
                    timestampMilliseconds: Int(presentationTime.value)
                )
                if wasAccepted {
                    logGestureCameraDiagnosticsIfNeeded(
                        output: output,
                        connection: connection,
                        pixelBuffer: pixelBuffer
                    )
                }
            }

            // 逆光场景下相机对亮背景测光，人和手成为剪影，两个识别引擎
            // 都检不出手。手势开启期间以低频人脸检测驱动主体优先测光。
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                updateGestureExposureIfNeeded(
                    pixelBuffer: pixelBuffer,
                    connection: connection
                )
            }
        }
        
        if mediaType == kCMMediaType_Video, output === videoOutput,
           !isSwitchingCamera, isPhysicalObjectDiscoveryActive {
            submitPhysicalObjectFrame(sampleBuffer, connection: connection)
        }

        // 运动追踪
        if !isSwitchingCamera,
           mediaType == kCMMediaType_Video,
           output === videoOutput,
           let trackingRequest = currentTrackingRequest,
           let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let frameStartedAt = ProcessInfo.processInfo.systemUptime
            let isPhysicalObjectFrame = isPhysicalObjectTrackingActive
            let physicalObjectCapturedAt = isPhysicalObjectFrame
                ? physicalObjectCaptureTime(sampleBuffer, arrivedAt: frameStartedAt) : nil
            if isPhysicalObjectFrame, let capturedAt = physicalObjectCapturedAt,
               capturedAt < physicalObjectFollowStartedAt { return }
            if isPhysicalObjectFrame, let capturedAt = physicalObjectCapturedAt {
                // Register camera progress before Vision work. Only the main
                // queue owns heartbeat state and validates this request again.
                DispatchQueue.main.async {
                    self.recordPhysicalObjectCameraFrame(capturedAt: capturedAt, request: trackingRequest)
                }
            }
            if isPhysicalObjectFrame {
                drainPhysicalObjectRecoveryCommands(request: trackingRequest)
            }
            if isPhysicalObjectFrame, preparePhysicalObjectSelectionIfNeeded(buffer: pixelBuffer, request: trackingRequest,
                capturedAt: physicalObjectCapturedAt) {
                return // Selection analysis never sends a stale frame to control.
            }
            let physicalObjectFrameGeometry = isPhysicalObjectFrame
                ? "buffer=\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)) outputOrientation=\(connection.videoOrientation.rawValue) outputMirrored=\(connection.isVideoMirrored)"
                : ""
            // 在 Vision 处理前保存倍率，避免主线程消费时已变焦，误改本帧的原始主体尺寸。
            let frameZoom = videoInput?.device.videoZoomFactor ?? zoomScale
            let hitchcockSessionID = self.hitchcockSessionID
            let previousRect = trackingRequest.inputObservation.boundingBox
            let handleFailure: (String) -> Void = { reason in
                DispatchQueue.main.async {
                    guard self.currentTrackingRequest === trackingRequest else { return }
                    self.handleObjectTrackingFailure(reason: reason)
                }
            }
            do {
                // 框选已经转换到 videoOutput 的实际像素方向；保持 .up，不能再次旋转。
                // 只消费同一输出，避免画中画的另一摄像头用不同坐标更新同一个目标。
                let trackedObservation = try performObjectTrackingObservation(buffer: pixelBuffer, request: trackingRequest)

                // 框选切换/停止期间可能还有旧请求的最后一帧在途；旧结果不得覆盖新目标。
                guard currentTrackingRequest === trackingRequest else { return }
                
                if let observation = trackedObservation {
                    let physicalMeasurement = isPhysicalObjectFrame
                        ? physicalObjectMeasurement(buffer: pixelBuffer, request: trackingRequest,
                            observation: observation, selection: previousRect, capturedAt: physicalObjectCapturedAt) : nil
                    let measuredRect = physicalMeasurement?.rect ?? observation.boundingBox
                    let measuredPrevious = physicalMeasurement?.previousRect ?? previousRect
                    let measuredConfidence = physicalMeasurement?.quality ?? observation.confidence
                    if isPhysicalObjectFrame {
                        recordPhysicalObjectFollowImage(pixelBuffer, request: trackingRequest,
                            capturedAt: physicalObjectCapturedAt, observation: observation, measurement: physicalMeasurement)
                    }
                    guard let validBoundingBox = sanitizedTrackingBoundingBox(measuredRect) else {
                        handleFailure("invalid_bbox=\(observation.boundingBox)")
                        return
                    }

                    if captureMode == .hitchcock,
                       !CMHitchcockTrackingMath.isReliable(
                           confidence: observation.confidence,
                           rect: validBoundingBox,
                           previousRect: previousRect
                       ) {
                        handleFailure("unreliable_observation confidence=\(observation.confidence)")
                        return
                    }

                    let displayObservation: VNDetectedObjectObservation
                    if validBoundingBox.equalTo(observation.boundingBox) {
                        displayObservation = observation
                    } else {
                        // 裁剪后的副本仅用于 UI/变焦计算，不能再喂回 VNTrackObjectRequest。
                        // Apple 明确规定：非 Tracker 返回的 observation 会开始一个新 Tracker，
                        // 连续重建会触发 "Exceeded maximum allowed number of Trackers"。
                        displayObservation = VNDetectedObjectObservation(boundingBox: validBoundingBox)
                    }

                    DispatchQueue.main.async {
                        // 在 Vision 完成和主线程消费之间，用户仍可能停止、重新框选或开拍。
                        guard self.currentTrackingRequest === trackingRequest else { return }
                        if isPhysicalObjectFrame {
                            guard self.isPhysicalObjectTrackingActive, self.physicalObjectIsFollowing else { return }
                            let consumedAt = ProcessInfo.processInfo.systemUptime
                            guard let capturedAt = physicalObjectCapturedAt,
                                  capturedAt.isFinite, (0...0.25).contains(consumedAt - capturedAt) else {
                                self.invalidatePhysicalObjectRecoveryLearning(request: trackingRequest)
                                if self.usesPhysicalObjectPhotoReference {
                                    self.requestPhysicalObjectIdentitySearch(request: trackingRequest, reason: "stale_photo_frame")
                                }
                                if self.physicalObjectFollowSafety.searchingOriginalTarget {
                                    if physicalMeasurement?.recoveredVerifiedIdentity == true {
                                        self.rejectPhysicalObjectRecoveryProposal(request: trackingRequest, capturedAt: physicalObjectCapturedAt)
                                    }
                                    return
                                }
                                self.handleObjectTrackingFailure(reason: "stale_or_unmapped_object_frame")
                                return
                            }
                            // Do not initialize a new selection with queued images
                            // captured before the finger was released.
                            guard capturedAt >= self.physicalObjectFollowStartedAt else { return }
                            let wasConfirming = self.physicalObjectFollowSafety.confirmingTarget
                            let wasSearching = self.physicalObjectFollowSafety.searchingOriginalTarget
                            let confirmationTimeoutReason = self.physicalObjectFollowSafety.confirmationTimeoutReason(at: capturedAt)
                            let wasReconfirmingEdgeMatch = self.physicalObjectFollowSafety.awaitingFrameReentryMatch
                            if let reason = self.physicalObjectFollowSafety.observe(
                                rect: measuredRect, previousRect: measuredPrevious,
                                confidence: measuredConfidence, capturedAt: capturedAt,
                                isHeldObservation: physicalMeasurement?.isHeldObservation ?? false,
                                supportsCenterRecovery: physicalMeasurement?.supportsCenterRecovery ?? false,
                                recoveredOriginalTemplate: physicalMeasurement?.recoveredOriginalTemplate ?? false,
                                recoveredVerifiedIdentity: physicalMeasurement?.recoveredVerifiedIdentity ?? false,
                                recoveredPhotoReference: physicalMeasurement?.recoveredPhotoReference ?? false,
                                photoConfirmationStartedAt: physicalMeasurement?.photoConfirmationStartedAt) {
                                self.invalidatePhysicalObjectRecoveryLearning(request: trackingRequest)
                                if physicalMeasurement?.recoveredPhotoReference == true {
                                    self.requestPhysicalObjectIdentitySearch(request: trackingRequest, reason: reason)
                                }
                                self.recordPhysicalObjectFollowDecision(observation: observation, previous: measuredPrevious,
                                    capturedAt: capturedAt, geometry: physicalObjectFrameGeometry, reason: reason, measurement: physicalMeasurement)
                                kkLog("event=physical_follow_rejected reason=\(reason) confidence=\(measuredConfidence) box=\(measuredRect) previous=\(measuredPrevious) source=\(physicalMeasurement?.source ?? "vision") recoveryReference=\(self.physicalObjectFollowSafety.confidenceRecoveryReference(at: capturedAt) ?? .zero)")
                                if self.physicalObjectFollowSafety.searchingOriginalTarget {
                                    if physicalMeasurement?.recoveredVerifiedIdentity == true {
                                        self.rejectPhysicalObjectRecoveryProposal(request: trackingRequest, capturedAt: capturedAt)
                                    }
                                    if !wasSearching { self.physicalObjectRecoverySearchDidBegin(reason: reason) }
                                    self.sendTrackingCommand(state: .exit, centerPoint: .zero)
                                } else { self.handleObjectTrackingFailure(reason: reason) }
                                return
                            }
                            if !wasSearching && self.physicalObjectFollowSafety.searchingOriginalTarget {
                                self.physicalObjectRecoverySearchDidBegin(reason: confirmationTimeoutReason ?? "confirmation_timeout")
                            } else if wasSearching && !self.physicalObjectFollowSafety.searchingOriginalTarget {
                                if let measurement = physicalMeasurement, measurement.recoveredVerifiedIdentity {
                                    self.commitPhysicalObjectRecoveredIdentity(buffer: pixelBuffer, request: trackingRequest,
                                        measurement: measurement, capturedAt: capturedAt)
                                } else if physicalMeasurement?.recoveredOriginalTemplate == true {
                                    self.cancelPhysicalObjectRecoveryForLocalReturn(request: trackingRequest,
                                        rect: measuredRect, capturedAt: capturedAt)
                                }
                                self.physicalObjectRecoverySearchDidFinish()
                            }
                            self.recordPhysicalObjectFollowDecision(observation: observation, previous: measuredPrevious,
                                capturedAt: capturedAt, geometry: physicalObjectFrameGeometry, reason: nil, measurement: physicalMeasurement)
                            self.physicalObjectLastPositionAt = capturedAt
                            self.physicalObjectLastResultConsumedAt = consumedAt
                            self.logPhysicalObjectFollowFrame(observation: observation,
                                capturedAt: capturedAt, geometry: physicalObjectFrameGeometry, measurement: physicalMeasurement)
                            if self.physicalObjectFollowSafety.confirmingTarget {
                                self.invalidatePhysicalObjectRecoveryLearning(request: trackingRequest)
                                if !wasConfirming || (!wasReconfirmingEdgeMatch && self.physicalObjectFollowSafety.awaitingFrameReentryMatch) {
                                    kkLog("event=physical_follow_quality_context box=\(measuredRect) previous=\(measuredPrevious) source=\(physicalMeasurement?.source ?? "vision") recoveryReference=\(self.physicalObjectFollowSafety.confidenceRecoveryReference(at: capturedAt) ?? .zero)")
                                    self.holdPhysicalObjectObservation(confidence: measuredConfidence)
                                }
                                return
                            }
                            if wasConfirming { self.physicalObjectObservationDidRecover() }
                            // Require three distinct reliable frames before motion.
                            guard self.physicalObjectFollowSafety.ready else {
                                self.invalidatePhysicalObjectRecoveryLearning(request: trackingRequest)
                                return
                            }
                            if let measurement = physicalMeasurement, !measurement.recoveredVerifiedIdentity {
                                self.recordPhysicalObjectVerifiedAppearance(buffer: pixelBuffer, request: trackingRequest,
                                    measurement: measurement, capturedAt: capturedAt)
                            }
                        }
                        if self.captureMode == .hitchcock {
                            guard self.hitchcockSessionID == hitchcockSessionID,
                                  !self.isPreparingHitchcockZoom else { return }
                            if self.hitchcockState == .recording,
                               frameStartedAt < self.hitchcockRecordingStartedAt { return }
                            guard ProcessInfo.processInfo.systemUptime - frameStartedAt <= 0.25 else {
                                self.handleObjectTrackingFailure(reason: "stale_vision_frame")
                                return
                            }
                        }
                        self.updateTrackingLayer(with: displayObservation)

                        // 检查是否是希区柯克模式
                        if self.captureMode == .hitchcock {
                            self.updateHitchcockTracking(with: displayObservation,
                                                         capturedZoom: frameZoom,
                                                         measuredAt: frameStartedAt)
                        }
                    }
                    // 普通帧延续 Vision 原观察；原模板三帧重获后只重绑定一次。
                    applyObjectTrackingFeedback(observation: observation, measurement: physicalMeasurement,
                                                request: trackingRequest)

                } else {
                    handleFailure("empty_vision_result")
                }
                
            } catch {
                guard currentTrackingRequest === trackingRequest else { return }
                kkLog("~~~ !!! Tracking error: \(error)")
                handleFailure(error.localizedDescription)
            }
        }
        
        // 人脸跟踪
        if isFaceTrackingMode, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let exif = exifOrientation(for: connection, pixelBuffer: pixelBuffer)
            performFaceDetection(on: pixelBuffer, orientation: exif)
        }
                
        // 滤镜 (滤镜使用movieOutput录像)
        if isUsingFilter , let filterManager = filterManager {
            
            if (mediaType == kCMMediaType_Video) {
                // 传递视频下去显示或录像
                filterManager.captureOutput(output, didOutput: sampleBuffer, from: connection)
            }else if mediaType == kCMMediaType_Audio, isMovieAudioValid, isRecording {
                // 音频录像
                self.movieOutput?.processAudioBuffer(sampleBuffer)
            }
            
        }else {
            
            // 录像 (非滤镜)
            if isRecording, !isUsingHitchcockMovieOutput {
                if (mediaType == kCMMediaType_Video) {
                    // 写入
                    recorder.append(output, didOutput: sampleBuffer, from: connection)
                }else if mediaType == kCMMediaType_Audio, isMovieAudioValid {
                    recorder.append(output, didOutput: sampleBuffer, from: connection)
                }
            }
        }

    }
    
    // 代理回调: 丢帧
    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if isPhysicalObjectTrackingActive, output === videoOutput {
            objectTrackingCoordinator.recordEvent("capture_frame_dropped")
        }
    }
    
    // 代理回调: 拍照
    public func photoOutput(_ output: AVCapturePhotoOutput, willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        let processingRange = resolvedSettings.photoProcessingTimeRange
        let minimum = CMTimeGetSeconds(processingRange.start)
        let maximum = minimum + CMTimeGetSeconds(processingRange.duration)
        kkPerfLog(
            "PhotoCapture",
            "will_begin id=\(resolvedSettings.uniqueID) processing_range=\(String(format: "%.3f", minimum))-\(String(format: "%.3f", maximum))s fusion=\(resolvedSettings.isVirtualDeviceFusionEnabled)",
            startedAt: photoCaptureRequestedAt
        )
    }

    public func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        kkPerfLog("PhotoCapture", "will_capture id=\(resolvedSettings.uniqueID)", startedAt: photoCaptureRequestedAt)
    }

    public func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        kkPerfLog("PhotoCapture", "did_capture id=\(resolvedSettings.uniqueID)", startedAt: photoCaptureRequestedAt)
    }

    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {

        kkPerfLog(
            "PhotoCapture",
            "did_finish_processing id=\(photo.resolvedSettings.uniqueID) error=\(error?.localizedDescription ?? "nil")",
            startedAt: photoCaptureRequestedAt
        )

        if (output == photoOutput) {
            // fileDataRepresentation / PNG 编码可能耗时数秒，不能占住 AVFoundation
            // 的 delegate 串行回调，否则 didFinishCapture 和下一次快门都会被拖延。
            let completion = photoCompletion
            photoCompletion = nil
            pictureQueue.async {
                completion?(photo)
            }
        }else if (output == photoOutput1) {
            let completion = photoCompletion1
            photoCompletion1 = nil
            pictureQueue.async {
                completion?(photo)
            }
        }
    }

    public func photoOutput(_ output: AVCapturePhotoOutput,
                            didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                            error: Error?) {
        kkPerfLog(
            "PhotoCapture",
            "did_finish_capture id=\(resolvedSettings.uniqueID) error=\(error?.localizedDescription ?? "nil")",
            startedAt: photoCaptureRequestedAt
        )
        if output === photoOutput {
            photoCaptureRequestedAt = nil
        }
    }

    public func fileOutput(_ output: AVCaptureFileOutput,
                           didStartRecordingTo fileURL: URL,
                           from connections: [AVCaptureConnection]) {
        guard output === hitchcockMovieOutput else { return }
        kkPerfLog("NativeMovie", "did_start_recording connections=\(connections.count)")
    }

    public func fileOutput(_ output: AVCaptureFileOutput,
                           didFinishRecordingTo outputFileURL: URL,
                           from connections: [AVCaptureConnection],
                           error: Error?) {
        guard output === hitchcockMovieOutput else { return }

        let recordedSuccessfully: Bool
        if let error = error as NSError? {
            recordedSuccessfully = error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
            kkPerfLog("NativeMovie", "did_finish_recording success=\(recordedSuccessfully) error=\(error.localizedDescription)")
        } else {
            recordedSuccessfully = true
            kkPerfLog("NativeMovie", "did_finish_recording success=true")
        }

        let completion = hitchcockMovieCompletion
        hitchcockMovieCompletion = nil
        isUsingHitchcockMovieOutput = false
        completion?(recordedSuccessfully ? outputFileURL : nil)
    }
}

extension CameraManager: AVCaptureMetadataOutputObjectsDelegate {
    /**
     Called when a QR code is detected.
     */
    public func metadataOutput(_: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from _: AVCaptureConnection) {
        // Check if there is a registered handler.
        guard let handler = qrCodeDetectionHandler
            else { return }
        
        // Get the detection result.
        let stringValues = metadataObjects
            .compactMap { $0 as? AVMetadataMachineReadableCodeObject }
            .compactMap { $0.stringValue }
        
        guard let stringValue = stringValues.first
            else { return }
        
        handler(.success(stringValue))
    }
}

public extension CameraManager {

    /// Only the camera displayed full-screen may update the recognizer state.
    /// Feeding PiP and main-camera frames into one Vision ROI state makes the
    /// crop jump between two unrelated coordinate spaces.
    func isPrimaryGestureVideoOutput(_ output: AVCaptureOutput) -> Bool {
        guard output is AVCaptureVideoDataOutput else { return false }

        let hasActiveSecondaryOutput: Bool
        if let secondaryOutput = videoOutput1 {
            hasActiveSecondaryOutput = session?.outputs.contains {
                $0 === secondaryOutput
            } ?? false
        } else {
            hasActiveSecondaryOutput = false
        }

        if hasActiveSecondaryOutput, pipDevicePosition == .back {
            return output === videoOutput1
        }
        return output === videoOutput
    }

    func logGestureCameraDiagnosticsIfNeeded(
        output: AVCaptureOutput,
        connection: AVCaptureConnection,
        pixelBuffer: CVPixelBuffer
    ) {
        #if DEBUG
        let now = Date()
        guard lastGestureCameraDiagnosticLogTime == nil
                || now.timeIntervalSince(
                    lastGestureCameraDiagnosticLogTime!
                ) >= 2.0 else {
            return
        }
        lastGestureCameraDiagnosticLogTime = now

        let device = videoInput?.device
        let position: String
        switch device?.position {
        case .front:
            position = "front"
        case .back:
            position = "back"
        default:
            position = "unknown"
        }
        let outputName = output === videoOutput1 ? "videoOutput1" : "videoOutput"
        let deviceType = device?.deviceType.rawValue ?? "unknown"
        let fieldOfView = device?.activeFormat.videoFieldOfView ?? 0
        let zoomFactor = device?.videoZoomFactor ?? 0
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        kkLog(
            "📷 [GestureSDK] input=\(outputName) "
                + "camera=\(position)/\(deviceType) "
                + "buffer=\(width)x\(height) "
                + "fov=\(String(format: "%.1f", fieldOfView)) "
                + "zoom=\(String(format: "%.2f", zoomFactor)) "
                + "orientation=\(connection.videoOrientation.rawValue) "
                + "mirrored=\(connection.isVideoMirrored)"
        )
        #endif
    }
    
    // 处理multi视频帧
    func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, fromOutput videoDataOutput: AVCaptureVideoDataOutput, connection: AVCaptureConnection) -> CMSampleBuffer? {

        var fullScreenSampleBuffer: CMSampleBuffer?
        var pipSampleBuffer: CMSampleBuffer?
        var finalVideoSampleBuffer: CMSampleBuffer?
        
        if pipDevicePosition == .back && videoDataOutput == self.videoOutput {
            pipSampleBuffer = sampleBuffer
        } else if pipDevicePosition == .back && videoDataOutput == self.videoOutput1 {
            fullScreenSampleBuffer = sampleBuffer
        } else if pipDevicePosition == .front && videoDataOutput == self.videoOutput {
            fullScreenSampleBuffer = sampleBuffer
        } else if pipDevicePosition == .front && videoDataOutput == self.videoOutput1 {
            pipSampleBuffer = sampleBuffer
        }
        
        if let pipSampleBuffer = pipSampleBuffer {
            // 处理小屏帧
            processPiPSampleBuffer(pipSampleBuffer)
        }
        
        if let fullScreenSampleBuffer = fullScreenSampleBuffer {
            // 处理全屏帧
            finalVideoSampleBuffer = processFullScreenSampleBuffer(fullScreenSampleBuffer, fromOutput: videoDataOutput, connection: connection)
        }

        return finalVideoSampleBuffer
    }
    
    // 处理全屏帧
    func processFullScreenSampleBuffer(_ fullScreenSampleBuffer: CMSampleBuffer, fromOutput videoDataOutput: AVCaptureVideoDataOutput, connection: AVCaptureConnection) -> CMSampleBuffer? {
        guard renderingEnabled else {
            return nil
        }
        
        // 全屏帧
        guard let fullScreenPixelBuffer = CMSampleBufferGetImageBuffer(fullScreenSampleBuffer),
            let formatDescription = CMSampleBufferGetFormatDescription(fullScreenSampleBuffer) else {
                return nil
        }
             
        // 小屏帧
        guard let pipSampleBuffer = currentPiPSampleBuffer,
            let pipPixelBuffer = CMSampleBufferGetImageBuffer(pipSampleBuffer) else {
                return nil
        }
        
//        let ciimage1 = CIImage(cvPixelBuffer: fullScreenPixelBuffer)
//        let image1 = UIImage(ciImage: ciimage1)
//        let ciimage2 = CIImage(cvPixelBuffer: pipPixelBuffer)
//        let image2 = UIImage(ciImage: ciimage2)
        
        if !videoMixer.isPrepared {
            videoMixer.prepare(with: formatDescription, outputRetainedBufferCountHint: 3)
        }
        
        videoMixer.pipFrame = normalizedPipFrame
        
        // Mix the full screen pixel buffer with the pip pixel buffer
        // When the PIP is the back camera, the primaryPixelBuffer is the front camera
        guard let mixedPixelBuffer = videoMixer.mix(fullScreenPixelBuffer: fullScreenPixelBuffer,
                                                    pipPixelBuffer: pipPixelBuffer,
                                                    fullScreenPixelBufferIsFrontCamera: pipDevicePosition == .back) else {
                                                        kkLog("Unable to combine video")
                                                        return nil
        }
        
        guard let outputFormatDescription = videoMixer.outputFormatDescription else { return nil }

        guard let finalVideoSampleBuffer = createVideoSampleBufferWithPixelBuffer(mixedPixelBuffer,
                                                                                   formatDescription: outputFormatDescription,
                                                                                   presentationTime: CMSampleBufferGetPresentationTimeStamp(fullScreenSampleBuffer)) else {
            kkLog("!!! Error: Unable to create sample buffer from pixelbuffer")
            return nil
        }
        
//        let ciimage3 = CIImage(cvPixelBuffer: CMSampleBufferGetImageBuffer(finalVideoSampleBuffer)!)
//        let image3 = UIImage(ciImage: ciimage3)
        
        return finalVideoSampleBuffer
    }
    
    func createVideoSampleBufferWithPixelBuffer(_ pixelBuffer: CVPixelBuffer, formatDescription: CMFormatDescription, presentationTime: CMTime) -> CMSampleBuffer? {
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        
        let err = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pixelBuffer,
                                                     dataReady: true,
                                                     makeDataReadyCallback: nil,
                                                     refcon: nil,
                                                     formatDescription: formatDescription,
                                                     sampleTiming: &timingInfo,
                                                     sampleBufferOut: &sampleBuffer)
        if sampleBuffer == nil {
            kkLog("Error: Sample buffer creation failed (error code: \(err))")
        }
        
        return sampleBuffer
    }
    
    // 处理小屏帧
    func processPiPSampleBuffer(_ pipSampleBuffer: CMSampleBuffer) {
        guard renderingEnabled else {
            return
        }
        
        currentPiPSampleBuffer = pipSampleBuffer
    }
    
    // MARK: - GestureExposure：手势期间的逆光曝光补偿

    /// 手势开启期间，每隔约 1 秒做一次轻量人脸检测，把曝光兴趣点移到
    /// 人脸中心（主体优先测光）。逆光时背景过亮导致人物欠曝成剪影，
    /// MediaPipe/Vision 均无法检出手部关键点；让人物恢复正常曝光后，
    /// 手部关键点才有可用的成像输入。
    ///
    /// 真机验证表明仅移动测光点不足以抵消强逆光（AE 对 POI 只是加权），
    /// 因此叠加闭环曝光补偿：以人脸区域实测亮度为反馈，判定逆光时按步
    /// 提升 exposureTargetBias（限幅 +2 EV），场景恢复后按步退回。
    ///
    /// 约束：
    /// - 用户手动曝光（EV 滑动产生非零 exposureTargetBias）期间不介入，
    ///   避免与滑动曝光同时修改同一个偏置。
    /// - 人脸连续丢失后恢复中心测光与原始偏置，手势会话重置时同样恢复。
    /// - 目前手势输入均为竖屏 `.up` 缓冲；其余方向的坐标回映射未经
    ///   真机验证，直接跳过，避免把曝光点设到错误位置。
    func updateGestureExposureIfNeeded(
        pixelBuffer: CVPixelBuffer,
        connection: AVCaptureConnection
    ) {
        guard !hasManualExposureBias else { return }
        guard videoInput?.device.exposureMode != .custom else { return }
        guard exifOrientation(for: connection, pixelBuffer: pixelBuffer) == .up else {
            return
        }

        let now = Date()
        guard !isGestureExposureDetectionRunning,
              lastGestureExposureDetectionTime == nil
                || now.timeIntervalSince(
                    lastGestureExposureDetectionTime!
                ) >= 1.0 else {
            return
        }
        lastGestureExposureDetectionTime = now
        isGestureExposureDetectionRunning = true

        gestureExposureQueue.async { [weak self] in
            guard let self else { return }
            defer { self.isGestureExposureDetectionRunning = false }

            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: .up,
                options: [:]
            )
            do {
                try handler.perform([request])
            } catch {
                return
            }

            let largestFace = (request.results ?? []).max {
                $0.boundingBox.width * $0.boundingBox.height
                    < $1.boundingBox.width * $1.boundingBox.height
            }
            self.applyGestureExposure(
                faceBoundingBox: largestFace?.boundingBox,
                pixelBuffer: pixelBuffer,
                isMirrored: connection.isVideoMirrored
            )
        }
    }

    /// 仅在 `gestureExposureQueue` 上调用。
    private func applyGestureExposure(
        faceBoundingBox: CGRect?,
        pixelBuffer: CVPixelBuffer,
        isMirrored: Bool
    ) {
        guard !hasManualExposureBias else { return }
        guard let faceBoundingBox else {
            gestureExposureFaceMissCount += 1
            if gestureExposureFaceMissCount >= 3 {
                restoreGestureExposure(reason: "face_lost")
            }
            return
        }
        gestureExposureFaceMissCount = 0

        guard let device = videoInput?.device,
              device.isExposurePointOfInterestSupported,
              device.exposureMode != .custom else {
            return
        }

        // 入口守卫已限定为竖屏 .up 缓冲。POI 坐标系是未
        // 旋转的传感器空间：横屏、Home 键在右、(0,0) 为左上。竖屏画面 =
        // 传感器图像顺时针旋转 90°，反推得 sensorX = portraitY(左上原点)、
        // sensorY = 1 - portraitX。Vision 框为左下原点，midY 需先翻转。
        // 前置输出经过水平镜像后，portraitX 与传感器 Y 的关系反转，
        // sensorY 应改为 portraitX；继续使用后置公式会把测光点放到画面对侧。
        // （metadataOutputRectConverted 在本输出配置下返回角点退化值，弃用。）
        let point = CGPoint(
            x: min(max(1 - faceBoundingBox.midY, 0), 1),
            y: min(
                max(
                    isMirrored
                        ? faceBoundingBox.midX
                        : 1 - faceBoundingBox.midX,
                    0
                ),
                1
            )
        )

        // 小幅移动不重设测光点，避免 AE 频繁重收敛造成画面亮度呼吸。
        let pointNeedsUpdate = appliedGestureExposurePoint.map {
            abs($0.x - point.x) >= 0.05 || abs($0.y - point.y) >= 0.05
        } ?? true

        let biasDecision = nextExposureBias(
            device: device,
            faceBoundingBox: faceBoundingBox,
            pixelBuffer: pixelBuffer
        )
        guard pointNeedsUpdate || biasDecision?.newBias != nil else { return }
        guard !hasManualExposureBias else { return }

        do {
            try device.lockForConfiguration()
            guard !hasManualExposureBias, videoInput?.device === device else {
                device.unlockForConfiguration()
                return
            }
            if pointNeedsUpdate {
                device.exposurePointOfInterest = point
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }
            if let newBias = biasDecision?.newBias {
                device.setExposureTargetBias(newBias)
            }
            device.unlockForConfiguration()

            if pointNeedsUpdate {
                appliedGestureExposurePoint = point
            }
            if let biasDecision, let newBias = biasDecision.newBias {
                if gestureExposureOriginalBias == nil {
                    gestureExposureOriginalBias = biasDecision.baseline
                }
                appliedGestureExposureBias = newBias
            }

            #if DEBUG
            Swift.print(
                "🔆 [GestureExposure] mirrored=\(isMirrored) face=("
                    + String(
                        format: "%.2f, %.2f",
                        faceBoundingBox.midX,
                        faceBoundingBox.midY
                    )
                    + ") poi=("
                    + String(format: "%.2f, %.2f", point.x, point.y)
                    + ")"
            )
            #endif

            var message = "event=gesture_exposure_updated "
                + "point_updated=\(pointNeedsUpdate)"
            if let biasDecision {
                message += String(
                    format: " face_luma=%.0f frame_luma=%.0f",
                    biasDecision.faceLuma,
                    biasDecision.frameLuma
                )
                if let newBias = biasDecision.newBias {
                    message += String(format: " bias_ev=%+.1f", newBias)
                }
            }
            kkLog(message)
        } catch {
            kkWarn(
                "event=gesture_exposure_failed operation=apply "
                    + "description=\(error.localizedDescription)"
            )
        }
    }

    /// 逆光闭环补偿决策：以人脸区域实测亮度为反馈，每秒最多调整一步
    /// 曝光偏置。`newBias == nil` 表示本次无需改动。仅在
    /// `gestureExposureQueue` 上调用。
    private func nextExposureBias(
        device: AVCaptureDevice,
        faceBoundingBox: CGRect,
        pixelBuffer: CVPixelBuffer
    ) -> (newBias: Float?, baseline: Float, faceLuma: Double, frameLuma: Double)? {
        guard let faceLuma = Self.meanLuma(
            in: pixelBuffer,
            normalizedRect: faceBoundingBox
        ), let frameLuma = Self.meanLuma(
            in: pixelBuffer,
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1)
        ) else {
            return nil
        }

        // 偏置被外部（EV 滑杆）改动过则让位，不与手动操作互相覆盖。
        let currentBias = device.exposureTargetBias
        if let applied = appliedGestureExposureBias,
           abs(applied - currentBias) > 0.05 {
            return (nil, currentBias, faceLuma, frameLuma)
        }

        let baseline = gestureExposureOriginalBias ?? currentBias
        let compensation = currentBias - baseline
        let maxCompensation = min(2.0, device.maxExposureTargetBias - baseline)
        let step: Float = 0.4

        var newCompensation = compensation
        if faceLuma < 95, frameLuma - faceLuma > 25 {
            // 逆光：人脸偏暗且明显暗于全画面，加一步正偏置。
            newCompensation = min(compensation + step, maxCompensation)
        } else if faceLuma > 140 || frameLuma - faceLuma <= 10 {
            // 人脸已够亮或场景不再逆光：按步退回，避免亮度跳变。
            newCompensation = max(compensation - step, 0)
        }

        guard abs(newCompensation - compensation) > 0.01 else {
            return (nil, baseline, faceLuma, frameLuma)
        }
        return (baseline + newCompensation, baseline, faceLuma, frameLuma)
    }

    /// 在 32BGRA 缓冲上做 16×16 稀疏网格采样，返回平均亮度（0～255）。
    /// `normalizedRect` 为 Vision 归一化坐标（左下原点）。
    private static func meanLuma(
        in pixelBuffer: CVPixelBuffer,
        normalizedRect: CGRect
    ) -> Double? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer)
                == kCVPixelFormatType_32BGRA else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let clamped = normalizedRect.intersection(
            CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        guard !clamped.isEmpty, width > 0, height > 0 else { return nil }

        let x0 = Int(clamped.minX * CGFloat(width))
        let x1 = max(x0 + 1, Int(clamped.maxX * CGFloat(width)))
        // Vision 左下原点 → 像素行（顶部为 0）。
        let y0 = Int((1 - clamped.maxY) * CGFloat(height))
        let y1 = max(y0 + 1, Int((1 - clamped.minY) * CGFloat(height)))

        let grid = 16
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var total = 0.0
        for row in 0..<grid {
            let y = min(height - 1, y0 + (y1 - y0) * row / grid)
            for col in 0..<grid {
                let x = min(width - 1, x0 + (x1 - x0) * col / grid)
                let offset = y * bytesPerRow + x * 4
                let blue = Double(pixels[offset])
                let green = Double(pixels[offset + 1])
                let red = Double(pixels[offset + 2])
                total += 0.114 * blue + 0.587 * green + 0.299 * red
            }
        }
        return total / Double(grid * grid)
    }

    /// 恢复中心测光与原始曝光偏置。仅在 `gestureExposureQueue` 上调用。
    func restoreGestureExposure(reason: String) {
        gestureExposureFaceMissCount = 0
        if hasManualExposureBias {
            appliedGestureExposurePoint = nil
            appliedGestureExposureBias = nil
            gestureExposureOriginalBias = nil
            return
        }
        guard appliedGestureExposurePoint != nil
                || appliedGestureExposureBias != nil else {
            gestureExposureOriginalBias = nil
            return
        }
        appliedGestureExposurePoint = nil
        let hadBias = appliedGestureExposureBias != nil
        let originalBias = gestureExposureOriginalBias
        appliedGestureExposureBias = nil
        gestureExposureOriginalBias = nil

        guard let device = videoInput?.device,
              device.isExposurePointOfInterestSupported,
              device.exposureMode != .custom else {
            return
        }
        do {
            try device.lockForConfiguration()
            device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
            if hadBias, let originalBias {
                device.setExposureTargetBias(originalBias)
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
            kkLog(
                "event=gesture_exposure_restored reason=\(reason)"
            )
        } catch {
            kkWarn(
                "event=gesture_exposure_failed operation=restore "
                    + "description=\(error.localizedDescription)"
            )
        }
    }

    /// 用户开始手动调整 EV 时，只丢弃手势识别曝光的内部基线；真实设备偏置
    /// 由曝光滑动在同一时刻接管。同步等待此前的检测任务退出，避免旧任务
    /// 在手动值之后再次覆盖设备偏置。
    func discardGestureExposureStateForManualControl() {
        gestureExposureQueue.sync {
            gestureExposureFaceMissCount = 0
            appliedGestureExposurePoint = nil
            appliedGestureExposureBias = nil
            gestureExposureOriginalBias = nil
        }
    }

    func gestureImageOrientation(
        for connection: AVCaptureConnection,
        pixelBuffer: CVPixelBuffer
    ) -> KKImageOrientation {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        switch connection.videoOrientation {
        case .portrait:
            return height > width ? .up : .right
        case .portraitUpsideDown:
            return height > width ? .down : .left
        case .landscapeRight:
            return .up
        case .landscapeLeft:
            return .down
        @unknown default:
            return height > width ? .up : .right
        }
    }
}
