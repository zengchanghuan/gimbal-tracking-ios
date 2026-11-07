//
//  CameraManager+Gesture.swift
//  KKCamera
//
//  Created by Kang on 7/20/23.
//

extension CameraManager: UIGestureRecognizerDelegate {
    
    // MARK: - 缩放变焦

    func attachZoom(_ view: UIView) {
        DispatchQueue.main.async {
            self.zoomGesture.addTarget(self, action: #selector(CameraManager._zoomStart(_:)))
            view.addGestureRecognizer(self.zoomGesture)
            self.zoomGesture.delegate = self
        }
    }
    
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard !isPreparingWheelFunctionCamera else {
            kkLog("🎡 波轮镜头切换期间忽略预览手势")
            return false
        }
        if isPhysicalObjectTrackingActive {
            // Drawing selects the target; exposure pans and mode swipes must not
            // compete for the same drag. Their normal behavior resumes on exit.
            if gestureRecognizer === exposureGesture || gestureRecognizer === swipeLeftGesture
                || gestureRecognizer === swipeRightGesture { return false }
            if gestureRecognizer === trackingPanGesture {
                guard let view = embeddingView, let preview = previewLayer,
                      canStartPhysicalObjectTracking else { return false }
                let point = view.layer.convert(gestureRecognizer.location(in: view), to: preview)
                return preview.bounds.contains(point)
            }
            if physicalObjectIsDrawingSelection && gestureRecognizer === zoomGesture { return false }
        }
        if gestureRecognizer.isKind(of: UIPinchGestureRecognizer.self) {
            beginZoomScale = zoomScale
        }
        return true
    }

    func _zoom(_ scale: CGFloat) {
        guard !isPreparingWheelFunctionCamera,
              !isPanoramaCameraControlLocked else { return }
        let device = videoInput?.device
        
        do {
            let captureDevice = device
            try captureDevice?.lockForConfiguration()
            
            self.zoomScale = max(
                1.0,
                min(self.beginZoomScale * scale, self.currentTrackingZoomUpperLimit)
            )
            
            captureDevice?.videoZoomFactor = self.zoomScale
            
            captureDevice?.unlockForConfiguration()
            
        } catch {
            kkLog("Error locking configuration")
        }
    }
    
    // MARK: - 点击对焦 & 滑动曝光
    
    func attachFocus(_ view: UIView) {
        DispatchQueue.main.async {
            self.focusGesture.addTarget(self, action: #selector(CameraManager._focusStart(_:)))
            view.addGestureRecognizer(self.focusGesture)
            self.focusGesture.delegate = self
        }
    }

    func attachExposure(_ view: UIView) {
        DispatchQueue.main.async {
            self.exposureGesture.addTarget(self, action: #selector(CameraManager._exposureStart(_:)))
            view.addGestureRecognizer(self.exposureGesture)
            self.exposureGesture.delegate = self
            // 单击优先判定为对焦；只有移动幅度足以让 tap 失败后，才进入曝光滑动。
            // 避免轻微手抖触发 pan，并在旧的 lastFocusPoint 位置重画对焦框。
            self.exposureGesture.require(toFail: self.focusGesture)
            self.exposureGesture.require(toFail: self.swipeLeftGesture)
            self.exposureGesture.require(toFail: self.swipeRightGesture)
        }
    }

    func attachSwipeGes(_ view: UIView) {
        DispatchQueue.main.async {
            self.swipeLeftGesture.addTarget(self, action: #selector(CameraManager._swipeStart(_:)))
            self.swipeRightGesture.addTarget(self, action: #selector(CameraManager._swipeStart(_:)))
            view.addGestureRecognizer(self.swipeLeftGesture)
            view.addGestureRecognizer(self.swipeRightGesture)
            self.swipeLeftGesture.direction = [.left]
            self.swipeLeftGesture.delegate = self
            self.swipeRightGesture.direction = [.right]
            self.swipeRightGesture.delegate = self
        }
    }

    // MARK: - 框选追踪

    func attachTrackingPan(_ view: UIView) {
        DispatchQueue.main.async {
            self.trackingPanGesture.addTarget(self, action: #selector(CameraManager._trackingPanStart(_:)))
            view.addGestureRecognizer(self.trackingPanGesture)
            self.trackingPanGesture.delegate = self
            self.trackingPanGesture.isEnabled = false
        }
    }
}

private extension CameraManager {
    
    @objc func _zoomStart(_ recognizer: UIPinchGestureRecognizer) {
        guard let view = embeddingView, let previewLayer = previewLayer
            else { return }
        guard !isPanoramaCameraControlLocked else { return }
        
        // 希区柯克模式下禁用手动变焦
        if captureMode == .hitchcock && 
           (hitchcockState == .selecting || hitchcockState == .ready || hitchcockState == .recording) {
            return
        }
        
        var allTouchesOnPreviewLayer = true
        let numTouch = recognizer.numberOfTouches
        
        for i in 0 ..< numTouch {
            let location = recognizer.location(ofTouch: i, in: view)
            let convertedTouch = previewLayer.convert(location, from: previewLayer.superlayer)
            if !previewLayer.contains(convertedTouch) {
                allTouchesOnPreviewLayer = false
                break
            }
        }
        if allTouchesOnPreviewLayer {
            _zoom(recognizer.scale)
        }
    }
    
    @objc func _focusStart(_ recognizer: UITapGestureRecognizer) {
        guard let gestureView = recognizer.view else { return }
        // 先保存手指坐标，再通知控制器关闭抽屉/滤镜面板。这样即便回调触发了
        // 同一轮布局更新，视觉对焦框仍然落在用户实际点击的位置。
        let touchPointInView = recognizer.location(in: gestureView)

        self.delegate?.cameraManager?(self, tapAction: recognizer)

        // tapAction 仍先通知控制器关闭设置抽屉；全景准备/拍摄阶段不再改 AF/AE。
        guard !isPanoramaCameraControlLocked else {
            kkLog("🎯 全景参数锁定期间忽略点击对焦")
            return
        }

        // 自动跟踪期间，单击候选框优先用于锁定人物；点在候选框之外仍保留原有对焦行为。
        if isFaceTrackingMode,
           let previewLayer {
            let pointInPreview = gestureView.layer.convert(
                touchPointInView,
                to: previewLayer
            )
            if selectAutoTrackingTarget(at: pointInPreview) {
                return
            }
        }
        
        let device = videoInput?.device
        
        discardGestureExposureStateForManualControl()
        _changeExposureMode(mode: .continuousAutoExposure)
        translationY = 0
        exposureValue = 0.5
        
        if let validDevice = device,
            let validPreviewLayer = pipDevicePosition == .front ? previewLayer : previewLayer1 {
            let pointInPreviewLayer = gestureView.layer.convert(touchPointInView, to: validPreviewLayer)
            guard validPreviewLayer.bounds.contains(pointInPreviewLayer) else {
                kkLog("🎯 忽略预览区域外点击 view=\(touchPointInView) preview=\(pointInPreviewLayer)")
                return
            }
            let pointOfInterest = validPreviewLayer.captureDevicePointConverted(fromLayerPoint: pointInPreviewLayer)
            stopBLEFocus()
            recordUserAutoFocusPoint(pointOfInterest)

            // 硬件 POI 继续使用 AVCaptureVideoPreviewLayer 的坐标转换；视觉框则直接
            // 使用手指在手势容器中的坐标，避免预览层、滤镜层和比例裁切层之间串用坐标。
            _showFocusRectangleAtPoint(touchPointInView, inLayer: gestureView.layer)
            lastFocusPoint = pointInPreviewLayer
            kkLog(
                "🎯 点击对焦坐标 view=\(touchPointInView) preview=\(pointInPreviewLayer) " +
                "poi=\(pointOfInterest) previewFrame=\(validPreviewLayer.frame) " +
                "previewBounds=\(validPreviewLayer.bounds) filter=\(isUsingFilter)"
            )

            let requestedFocusMode = focusMode
            let requestedExposureMode = exposureMode
            // 排在此前已提交的波轮手动焦距之后，确保点击 AF 是最后一次设备写入。
            sessionQueue.async {
                do {
                    try validDevice.lockForConfiguration()

                    if validDevice.isFocusPointOfInterestSupported {
                        validDevice.focusPointOfInterest = pointOfInterest
                    }

                    if validDevice.isExposurePointOfInterestSupported {
                        validDevice.exposurePointOfInterest = pointOfInterest
                    }

                    if validDevice.isFocusModeSupported(requestedFocusMode) {
                        validDevice.focusMode = requestedFocusMode
                    }

                    if validDevice.isExposureModeSupported(requestedExposureMode) {
                        validDevice.exposureMode = requestedExposureMode
                    }

                    validDevice.unlockForConfiguration()
                } catch {
                    kkLog(error)
                }
            }
        }
    }
    
    // 调换镜头
    func _togglePiP() {
        stopPhysicalObjectTracking(reason: "pip_changed")
        
        guard let previewLayer = previewLayer, let previewLayer1 = previewLayer1 else { return }
                
        // Disable animations so the views move immediately
        CATransaction.begin()
        UIView.setAnimationsEnabled(false)
        CATransaction.setDisableActions(true)
        
        let frame = previewLayer.frame
        previewLayer.frame = previewLayer1.frame
        previewLayer1.frame = frame
        
        if pipDevicePosition == .front {
            previewLayer.zPosition = 10
            previewLayer1.zPosition = 1
            pipDevicePosition = .back
        } else {
            previewLayer.zPosition = 1
            previewLayer1.zPosition = 10
            pipDevicePosition = .front
        }
        
        CATransaction.commit()
        UIView.setAnimationsEnabled(true)
        CATransaction.setDisableActions(false)
    }
    
    @objc func _swipeStart(_ recognizer: UISwipeGestureRecognizer) {
        self.delegate?.cameraManager?(self, swipeAction: recognizer)
    }
    
     func _showFocusRectangleAtPoint(_ focusPoint: CGPoint, inLayer layer: CALayer, withBrightness brightness: Float? = nil) {
        let finalLayer = layer
        
        if let lastFocusRectangle = lastFocusRectangle {
            lastFocusRectangle.removeFromSuperlayer()
            self.lastFocusRectangle = nil
        }
        
        let size = CGSize(width: 75, height: 75)
        let rect = CGRect(origin: CGPoint(x: focusPoint.x - size.width / 2.0, y: focusPoint.y - size.height / 2.0), size: size)
        
        let endPath = UIBezierPath(rect: rect)
        endPath.move(to: CGPoint(x: rect.minX + size.width / 2.0, y: rect.minY))
        endPath.addLine(to: CGPoint(x: rect.minX + size.width / 2.0, y: rect.minY + 5.0))
        endPath.move(to: CGPoint(x: rect.maxX, y: rect.minY + size.height / 2.0))
        endPath.addLine(to: CGPoint(x: rect.maxX - 5.0, y: rect.minY + size.height / 2.0))
        endPath.move(to: CGPoint(x: rect.minX + size.width / 2.0, y: rect.maxY))
        endPath.addLine(to: CGPoint(x: rect.minX + size.width / 2.0, y: rect.maxY - 5.0))
        endPath.move(to: CGPoint(x: rect.minX, y: rect.minY + size.height / 2.0))
        endPath.addLine(to: CGPoint(x: rect.minX + 5.0, y: rect.minY + size.height / 2.0))
        if brightness != nil {
            endPath.move(to: CGPoint(x: rect.minX + size.width + size.width / 4, y: rect.minY))
            endPath.addLine(to: CGPoint(x: rect.minX + size.width + size.width / 4, y: rect.minY + size.height))
            
            endPath.move(to: CGPoint(x: rect.minX + size.width + size.width / 4 - size.width / 16, y: rect.minY + size.height - CGFloat(brightness!) * size.height))
            endPath.addLine(to: CGPoint(x: rect.minX + size.width + size.width / 4 + size.width / 16, y: rect.minY + size.height - CGFloat(brightness!) * size.height))
        }
        
        let startPath = UIBezierPath(cgPath: endPath.cgPath)
        let scaleAroundCenterTransform = CGAffineTransform(translationX: -focusPoint.x, y: -focusPoint.y).concatenating(CGAffineTransform(scaleX: 2.0, y: 2.0).concatenating(CGAffineTransform(translationX: focusPoint.x, y: focusPoint.y)))
        startPath.apply(scaleAroundCenterTransform)
        
        let shapeLayer = CAShapeLayer()
        shapeLayer.path = endPath.cgPath
        shapeLayer.fillColor = UIColor.clear.cgColor
        shapeLayer.strokeColor = UIColor(red: 1, green: 0.83, blue: 0, alpha: 0.95).cgColor
        shapeLayer.lineWidth = 1.0
        
        finalLayer.addSublayer(shapeLayer)
        lastFocusRectangle = shapeLayer
        
        CATransaction.begin()
        
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeOut))
        
        CATransaction.setCompletionBlock {
            if shapeLayer.superlayer != nil {
                shapeLayer.removeFromSuperlayer()
                self.lastFocusRectangle = nil
            }
        }
        if brightness == nil {
            let appearPathAnimation = CABasicAnimation(keyPath: "path")
            appearPathAnimation.fromValue = startPath.cgPath
            appearPathAnimation.toValue = endPath.cgPath
            shapeLayer.add(appearPathAnimation, forKey: "path")
            
            let appearOpacityAnimation = CABasicAnimation(keyPath: "opacity")
            appearOpacityAnimation.fromValue = 0.0
            appearOpacityAnimation.toValue = 1.0
            shapeLayer.add(appearOpacityAnimation, forKey: "opacity")
        }
        
        let disappearOpacityAnimation = CABasicAnimation(keyPath: "opacity")
        disappearOpacityAnimation.fromValue = 1.0
        disappearOpacityAnimation.toValue = 0.0
        disappearOpacityAnimation.beginTime = CACurrentMediaTime() + 0.8
        disappearOpacityAnimation.fillMode = CAMediaTimingFillMode.forwards
        disappearOpacityAnimation.isRemovedOnCompletion = false
        shapeLayer.add(disappearOpacityAnimation, forKey: "opacity")
        
        CATransaction.commit()
    }

    @objc func _exposureStart(_ gestureRecognizer: UIPanGestureRecognizer) {
        guard !isPanoramaCameraControlLocked else { return }
        guard gestureRecognizer.view != nil else { return }
        let view = gestureRecognizer.view!

        if gestureRecognizer.state == .began {
            discardGestureExposureStateForManualControl()
        }
        
        let translation = gestureRecognizer.translation(in: view)
        let currentTranslation = translationY + Float(translation.y)
        let clampedTranslation = min(max(currentTranslation, -400), 400)
        if gestureRecognizer.state == .ended || gestureRecognizer.state == .cancelled {
            translationY = clampedTranslation
        }
        if clampedTranslation < 0 {
            // up - brighter
            exposureValue = 0.5 + abs(clampedTranslation) / 400 / 2
        } else {
            // down - lower
            exposureValue = 0.5 - clampedTranslation / 400 / 2
        }
        let appliedBias = _changeExposureTargetBias(value: exposureValue)
        
        // UI Visualization
        if gestureRecognizer.state == .began {
            let validPreviewLayer = pipDevicePosition == .front ? previewLayer : previewLayer1
            startPanPointInPreviewLayer = view.layer.convert(gestureRecognizer.location(in: view), to: validPreviewLayer)
            kkLog(
                "🎯 曝光滑动开始 view=\(gestureRecognizer.location(in: view)) " +
                "lastFocusPreview=\(String(describing: lastFocusPoint))"
            )
        } else if gestureRecognizer.state == .ended || gestureRecognizer.state == .cancelled {
            kkLog(
                "event=camera_exposure_pan_finished translation_y=\(clampedTranslation) " +
                "normalized=\(exposureValue) target_bias=\(String(describing: appliedBias)) " +
                "limit_ev=\(manualExposureBiasLimit)"
            )
        }
        
        if let lastFocusPoint = self.lastFocusPoint,
           let validPreviewLayer = pipDevicePosition == .front ? previewLayer : previewLayer1,
           let view = embeddingView {
            let focusPointInView = validPreviewLayer.convert(lastFocusPoint, to: view.layer)
            _showFocusRectangleAtPoint(focusPointInView, inLayer: view.layer, withBrightness: exposureValue)
        }
    }
    
    // Available modes:
    // .Locked .AutoExpose .ContinuousAutoExposure .Custom
    func _changeExposureMode(mode: AVCaptureDevice.ExposureMode) {
        let device = videoInput?.device
        if device?.exposureMode == mode {
            do {
                try device?.lockForConfiguration()
                device?.setExposureTargetBias(0)
                device?.unlockForConfiguration()
            } catch  {
                return
            }
            return
        }
        
        do {
            try device?.lockForConfiguration()
            
            if device?.isExposureModeSupported(mode) == true {
                device?.exposureMode = mode
            }
            device?.setExposureTargetBias(0)
            device?.unlockForConfiguration()
            
        } catch {
            return
        }
    }
    
    @discardableResult
    func _changeExposureTargetBias(value: Float) -> Float? {
        guard cameraIsSetup, value.isFinite, let videoDevice = videoInput?.device else {
            return nil
        }

        let normalizedValue = min(max(value, 0), 1)
        let minimumBias = max(videoDevice.minExposureTargetBias, -manualExposureBiasLimit)
        let maximumBias = min(videoDevice.maxExposureTargetBias, manualExposureBiasLimit)
        var bias: Float
        if normalizedValue > 0.5 {
            bias = maximumBias * (normalizedValue - 0.5) * 2
        } else {
            bias = minimumBias * (0.5 - normalizedValue) * 2
        }
        bias = min(max(bias, minimumBias), maximumBias)

        do {
            try videoDevice.lockForConfiguration()
            guard videoInput?.device === videoDevice else {
                videoDevice.unlockForConfiguration()
                return nil
            }
            if videoDevice.isExposureModeSupported(.continuousAutoExposure) {
                videoDevice.exposureMode = .continuousAutoExposure
            }
            videoDevice.setExposureTargetBias(bias)
            videoDevice.unlockForConfiguration()
            return bias
        } catch {
            return nil
        }
    }

    // 追踪框选手势回调
    // 对齐 Android TargetRectView：拖动时实时绘制橡皮筋矩形，松手后若尺寸 >=50pt 则触发目标选中
    @objc func _trackingPanStart(_ recognizer: UIPanGestureRecognizer) {
        guard let view = embeddingView, let previewLayer = previewLayer else { return }

        // 自动初始化追踪层（如果尚未初始化）
        if trackingLayer == nil {
            setupTrackingLayer()
        }
        guard let tLayer = trackingLayer else { return }

        let locationInView = recognizer.location(in: view)
        let pointInPreview = view.layer.convert(locationInView, to: previewLayer)

        switch recognizer.state {
        case .began:
            if isPhysicalObjectTrackingActive { beginPhysicalObjectSelection() }
            tLayer.strokeColor = UIColor.white.cgColor
            if captureMode == .hitchcock,
               hitchcockState == .selecting || hitchcockState == .recording {
                // 对齐 Android：用户一开始实际框选，就立即停止黄色演示并清掉说明。
                hideHitchcockInstructions()
            }
            trackingStartPoint = pointInPreview
            drawingPath = nil
        case .changed:
            // 对齐 Android TargetRectView.onTouchEvent(ACTION_MOVE)：
            // 实时显示从起点到当前手指的橡皮筋矩形，而非自由路径
            guard let startPoint = trackingStartPoint else { return }
            let rubberRect = CGRect(
                x: min(startPoint.x, pointInPreview.x),
                y: min(startPoint.y, pointInPreview.y),
                width: abs(pointInPreview.x - startPoint.x),
                height: abs(pointInPreview.y - startPoint.y)
            )
            tLayer.path = UIBezierPath(rect: rubberRect).cgPath
        case .ended:
            guard let startPoint = trackingStartPoint else { return }
            let rectInPreview = CGRect(
                x: min(startPoint.x, pointInPreview.x),
                y: min(startPoint.y, pointInPreview.y),
                width: abs(pointInPreview.x - startPoint.x),
                height: abs(pointInPreview.y - startPoint.y)
            )

            // Keep the old gesture threshold outside the new small-object workflow.
            let minimumSide: CGFloat = isPhysicalObjectTrackingActive ? 12 : 50
            if rectInPreview.width < minimumSide || rectInPreview.height < minimumSide {
                tLayer.path = nil
                trackingStartPoint = nil
                cancelPhysicalObjectSelection()
                return
            }

            // 与跟踪结果绘制使用同一条转换链，保留预览裁剪及视频输出的方向/镜像。
            guard let normalizedRect = trackingVisionBoundingBox(forPreviewRect: rectInPreview) else {
                tLayer.path = nil
                trackingStartPoint = nil
                cancelPhysicalObjectSelection()
                return
            }

            // 检查是否是希区柯克模式
            if isPhysicalObjectTrackingActive {
                if !confirmPhysicalObjectSelection(rect: normalizedRect) {
                    tLayer.path = nil
                    cancelPhysicalObjectSelection()
                }
            } else if captureMode == .hitchcock &&
                (hitchcockState == .selecting || hitchcockState == .recording) {
                // 希区柯克模式：开拍前框选，以及录制中失去目标后的重新框选。
                startHitchcockTracking(with: normalizedRect)
            } else {
                // 普通模式：重新开始追踪
                if isFaceTrackingMode {
                    stopFaceTracking()
                    setupTrackingLayer()
                }
                if startTracking(rect: normalizedRect) != nil {
                    NotificationCenter.default.post(name: .objectTrackingStartedByGesture, object: nil)
                }
            }

            trackingStartPoint = nil
        case .cancelled, .failed:
            tLayer.path = nil
            trackingStartPoint = nil
            cancelPhysicalObjectSelection()
        default:
            break
        }
    }
}
