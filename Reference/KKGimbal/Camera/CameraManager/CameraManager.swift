// Tracking-only excerpt of CameraManager.swift.
// The original host camera class is not included. See docs/INTEGRATION.md.
import Foundation
import UIKit
import AVFoundation
import Vision

enum CMTrackingDetectionStrategy {
    case face
    case human
}

enum CMTrackingCandidateKind: String {
    case face
    case human
}

struct CMTrackingCandidate {
    let kind: CMTrackingCandidateKind
    let visionRect: CGRect
    let previewRect: CGRect
}

enum CMTrackingYawRestrictionPhase {
    case monitoring
    case paused
    case probing
}

class CameraManager: NSObject {
    lazy var objectTrackingCoordinator = ObjectTrackingCoordinator(onUpdate: { [weak self] snapshot in
        self?.consumePhysicalObjectSnapshot(snapshot)
    }, mode: .discoveryOnly)
    private let rearTrackingMaxDisplayedZoomScale = CGFloat(2.0)
    private let frontTrackingMaxDisplayedZoomScale = CGFloat(1.5)
var currentTrackingZoomUpperLimit: CGFloat {
        guard isAnyTrackingActive else {
            return maxZoomScale
        }

        switch lensType {
        case .back:
            let deviceScale = isUsingWideCamera
                ? rearTrackingMaxDisplayedZoomScale * 2.0
                : rearTrackingMaxDisplayedZoomScale
            return min(maxZoomScale, deviceScale)
        case .front:
            return min(maxZoomScale, frontTrackingMaxDisplayedZoomScale)
        case .slow:
            return maxZoomScale
        }
    }
    var physicalObjectBackend: ObjectDetectionBackend = ObjectDetectionBackend(
        rawValue: UserDefaults.standard.string(forKey: "physicalObjectBackend") ?? ""
    ) ?? .mediaPipeCPU
    var physicalObjectSnapshot: ObjectTrackingSnapshot?
    var physicalObjectLayers: [CALayer] = []
    var physicalObjectWatchdog: Timer?
    var physicalObjectObservers: [NSObjectProtocol] = []
    var physicalObjectLastPositionAt: TimeInterval = 0
    // Main-thread clocks: camera arrival is independent of Vision completion.
    // These only keep an already-stopped confirmation session alive.
    var physicalObjectLastCameraFrameAt: TimeInterval = 0
    var physicalObjectLastResultConsumedAt: TimeInterval = 0
    var physicalObjectFollowStartedAt: TimeInterval = 0
    var physicalObjectPreparingSelection = false
    #if DEBUG
    // Confined to dataOutputQueue; request identity prevents stale refinement
    // work from being applied after a stop or a new manual selection.
    var physicalObjectPreparedSelectionRequest: VNTrackObjectRequest?
    var physicalObjectForegroundSelectionRequest: ObjectIdentifier?
    var physicalObjectForegroundSelectionDiagnostics: [String: Any] = [:]
    var physicalObjectForegroundPartsSession: CMPhysicalObjectPartsSession?
    var physicalObjectSnapshotPartsSession: CMPhysicalObjectSnapshotPartsSession?
    var physicalObjectRecoverySession: CMPhysicalObjectRecoverySession?
    var physicalObjectRecoveryPreparedRequest: ObjectIdentifier?
    let physicalObjectRecoveryMailbox = CMPhysicalObjectRecoveryMailbox()
    #endif
    var physicalObjectFollowSafety = CMPhysicalObjectFollowSafety()
    // Capture-queue confined; cancellation enqueues identity-bound cleanup.
    var physicalObjectPatchSession: CMPhysicalObjectPatchSession?
    var physicalObjectPhotoSession: CMPhysicalObjectPhotoSession?
    var physicalObjectPhotoSearchRequest: (request: VNTrackObjectRequest, after: TimeInterval)? // physicalObjectStateLock
    var physicalObjectApprovedMovingFrame: (request: VNTrackObjectRequest, time: TimeInterval)? // physicalObjectStateLock
    var physicalObjectPhotoCaptureFailed = false // main thread
    #if DEBUG
    var physicalObjectFollowRecorder: CMPhysicalObjectFollowRecorder? // physicalObjectStateLock
    #endif
    var physicalObjectLastFollowLogAt: TimeInterval = 0
    var physicalObjectOverlayExpired = false
    var physicalObjectIsFollowing = false
    var physicalObjectIsDrawingSelection = false
    var physicalObjectNeedsReselection = false
    var physicalObjectDiscoveryFailed = false
    var physicalObjectHadCommandChannel = false
    var physicalObjectCaptureClockSource: String? // capture queue only
    var physicalObjectPreviewBounds = CGRect.zero

    let physicalObjectStateLock = NSLock()
    var physicalObjectTrackingEnabled = false
    var physicalObjectDiscoveryEnabled = false
    var isPhysicalObjectTrackingActive: Bool {
        physicalObjectStateLock.lock()
        defer { physicalObjectStateLock.unlock() }
        return physicalObjectTrackingEnabled
    }
    var isPhysicalObjectDiscoveryActive: Bool {
        physicalObjectStateLock.lock()
        defer { physicalObjectStateLock.unlock() }
        return physicalObjectTrackingEnabled && physicalObjectDiscoveryEnabled
    }
    var isAnyTrackingActive: Bool {
        isPhysicalObjectTrackingActive || isFaceTrackingMode || currentTrackingRequest != nil
    }

    var trackingLayer: CAShapeLayer?
    var trackingCandidateLayers: [CAShapeLayer] = []
    var currentTrackingRequest: VNTrackObjectRequest?
    var sequenceHandler = VNSequenceRequestHandler()

    // 人脸跟踪相关
    var isFaceTrackingMode: Bool = false  // 是否为人脸跟踪模式
    var faceDetectionRequest: VNDetectFaceRectanglesRequest?  // 人脸检测请求
    var humanDetectionRequest: VNDetectHumanRectanglesRequest? // 人形检测请求 (Fallback)
    var lastDetectedFaceRect: CGRect?  // 最后检测到的人脸区域
    var lastDetectedHumanRect: CGRect? // 最后检测到的人形区域 (用于人脸丢失后继续跟随)
    var trackingHumanFallbackCenterX: CGFloat?
    var activeTrackingDetectionStrategy: CMTrackingDetectionStrategy?
    let trackingTargetSelectionLock = NSLock()
    var trackingTargetCandidates: [CMTrackingCandidate] = []
    var manualTrackingTargetKind: CMTrackingCandidateKind?
    var manualTrackingTargetReferenceRect: CGRect?
    var automaticTrackingTargetKind: CMTrackingCandidateKind?
    var automaticTrackingTargetReferenceRect: CGRect?
    var automaticTrackingTargetLastSeenAtMs: Int64 = 0
    // OK 手势启动跟踪时，先保存手部位置；首批人物检测结果会用它确定是谁做了手势。
    var pendingGestureTrackingHandCenter: CGPoint?
    var pendingGestureTrackingTargetDeadlineMs: Int64 = 0
    // 手势选中的人物不是点击手动锁定，但在其可识别期间优先级高于“更靠前”规则。
    var isGestureTrackingTargetPriorityActive: Bool = false
    // 仅用于稳定屏幕上的目标框；云台控制仍使用每帧实时识别坐标。
    var trackingDisplayRect: CGRect?
    var trackingDisplayKind: CMTrackingCandidateKind?
    var pendingTrackingDisplayKind: CMTrackingCandidateKind?
    var pendingTrackingDisplayKindCount: Int = 0
    // 追踪指令跳变保护：记录上一帧 Raw 偏移量，防止误检导致云台"拉飞/转圈"
    var trackingLastRawOffsetX: Int = 0
    var trackingLastRawOffsetY: Int = 0
    var trackingJumpCount: Int = 0 // 连续跳变计数器，用于解除死锁
    
    // ⚠️ 优化：记录最后一次发送给云台的实际指令值，用于去重
    var lastSentFinalX: Int = 0
    var lastSentFinalY: Int = 0
    var lastSentState: Int = -1

    // 人脸跟踪会有异步回调（Vision completion），这里用会话ID防止 stop 后旧回调继续发 D1 指令造成“指令错乱”
    var faceTrackingSessionId: Int64 = 0
    // 人形跟踪连续丢失计数器，用于运动惯性 (Coasting)
    var humanTrackingLostCount: Int = 0

    // 人脸跟踪开启时，暂停手势识别以降低负载（避免 hang/killed 干扰云台跟随验证）
    var gestureEnableBeforeFaceTracking: Bool? = nil

    // 跟踪指令平滑/限速（对齐 Android：连续帧更稳定，避免抖动/误检导致云台乱动）
    var trackingFilteredX: Double = 0
    var trackingFilteredY: Double = 0
    var trackingFilterInited: Bool = false
    var trackingLastOutputX: Int = 0
    var trackingLastOutputY: Int = 0
    var trackingLastLogTimeMs: Int64 = 0
    var trackingLastSendLogTimeMs: Int64 = 0
    var trackingZoomActive: Bool = false
    var trackingZoomLastLogTimeMs: Int64 = 0
    var trackingZoomReferenceFactor: Double = 1.0
    // 人脸/人形检测器的框在切换瞬间可能位于不同坐标，先短暂稳定再恢复云台输出。
    var trackingStrategyHoldUntilMs: Int64 = 0
    var trackingNeedsSeedAfterStrategyChange: Bool = false
    // 希区柯克从“准备”进入“录制”时，首帧锁定当前构图；后续只跟随相对位移，
    // 避免目标不在画面正中或连续变焦时把绝对偏移误当成云台运动量。
    var trackingNeedsInitialSeed: Bool = false
    var hitchcockCompositionBaselineX: Int?
    var hitchcockCompositionBaselineY: Int?
    var hitchcockSessionID = UUID()
    var isPreparingHitchcockZoom = false
    var hitchcockRecordingStartedAt: TimeInterval = 0
    var pendingTrackingFaceRect: CGRect?
    var pendingTrackingFaceCount: Int = 0
    var pendingTrackingHumanRect: CGRect?
    var pendingTrackingHumanCount: Int = 0
    var trackingConsecutiveFaceMissCount: Int = 0
    var trackingNoTargetHoldSent: Bool = false
    var trackingVisionInputLogged: Bool = false
    var trackingPendingHoldLastLogTimeMs: Int64 = 0
    var trackingDetectionLastPerformanceLogMs: Int64 = 0
    var trackingHumanRejectLastLogTimeMs: Int64 = 0
    var trackingFaceMotionAcceptLastLogTimeMs: Int64 = 0
    var trackingCenterLocked: Bool = false
    var trackingCenterLockLastLogTimeMs: Int64 = 0
    var trackingLastControlUpdateTimeMs: Int64 = 0
    var trackingPreviousDetectedRawX: Int = 0
    var trackingPreviousDetectedRawY: Int = 0
    var trackingPreviousDetectedTimeMs: Int64 = 0

    // 水平旋转受限保护：跟踪仍保持识别，只暂停 Yaw 输出并周期性探测是否已经恢复。
    var trackingYawRestrictionPhase: CMTrackingYawRestrictionPhase = .monitoring
    var trackingYawRestrictionDirection: Int = 0
    var trackingYawRestrictionCandidateStartedAtMs: Int64 = 0
    var trackingYawRestrictionReferenceError: Int = 0
    var trackingYawRestrictionPausedAtMs: Int64 = 0
    var trackingYawRestrictionProbeStartedAtMs: Int64 = 0
    var trackingYawRestrictionProbeReferenceError: Int = 0

    // 手机固定在云台上，绕重力方向的角速度可作为 Yaw 轴是否真的在转的独立证据。
    // Core Motion 回调与 Vision 跟踪不在同一队列，读写必须加锁。
    let deviceMotionStateLock = NSLock()
    var latestHorizontalRotationRate: Double = 0
    var latestHorizontalRotationSampleUptime: TimeInterval = 0

    // Android 对齐模式：先验证“数据流转/坐标/符号/轴交换”是否一致，再做平滑/限速调优
    #if DEBUG
    var trackingUseAndroidReference: Bool = true
    #else
    var trackingUseAndroidReference: Bool = false
    #endif

}
