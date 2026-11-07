# 技术接入文档

**中文** · [English](INTEGRATION.en.md)

## 1. Swift Package

在 Xcode 的 Package Dependencies 中添加 `https://github.com/zengchanghuan/gimbal-tracking-ios.git`，选择 `GimbalTracking` 库。默认只依赖 Apple 系统框架。公开 API 位于 `Sources/GimbalTracking/PublicAPI.swift`，其余类型保留 internal 可见性。

macOS 命令行示例可以在不使用相机的情况下演示控制器：

```bash
swift run tracking-demo
```

下面是最小的人脸分析与控制封装。整个实例应由同一条串行分析队列持有和调用；图像与采集时间戳应在相机管线中取得。

```swift
import CoreGraphics
import Foundation
import GimbalTracking

final class FaceFollowPipeline {
    private let tracker = FaceTracker()
    private var controller = FollowController()

    func process(_ image: CGImage, frameID: UInt64,
                 capturedAt: TimeInterval, context: String) throws -> FollowCommand? {
        let result = try tracker.analyze(
            image, capturedAt: capturedAt,
            now: ProcessInfo.processInfo.systemUptime,
            context: context, confirmedTarget: controller.trackingReference)
        if result.resetsTarget { controller.reset() }
        return controller.observe(
            boxes: result.boxes, frameID: frameID,
            capturedAt: capturedAt, now: ProcessInfo.processInfo.systemUptime)
    }
}
```

调用方应在出错时停止运动并重置会话，还应设置帧过期看门狗，并在执行 BLE 写入前再次验证当前会话。`.hold` 表示零运动；`nil` 表示该帧被忽略，不会延长继续运动的授权。`yawSign`、`pitchSign` 必须与相机镜像和硬件方向匹配。控制量使用原协议单位，不是角度或角速度。

## 2. 原生实物跟踪

Objective-C++ 跟踪器以源码形式提供，不属于 Swift Package 的编译目标。

1. 运行 `bash scripts/build_opencv.sh` 构建 OpenCV。需要完整 Xcode、CMake、Python 3、网络连接和足够的构建空间。脚本构建真机与模拟器静态库，输出 `Dependencies/OpenCV/OpenCVStitching.xcframework`。
2. 将该 XCFramework 加入宿主 App target。将 `NativeTracking/*.mm` 加入 Compile Sources，保留同目录的 `.inc` 文件，并将两个头文件加入工程。将 C++ 标准设置为 C++17，启用 Objective-C ARC。
3. 将当前 XCFramework slice 的 `Headers/opencv4` 目录加入 Header Search Paths。链接源码引用的 Apple 框架和 C++ 运行时；静态 OpenCV 库的编解码依赖还需要 `libz`。分发构建产物时保留第三方声明。
4. 在 App 的 Objective-C 桥接头中导入 `CMNanoTrackTracker.h` 和 `CMPhysicalObjectPatchTracker.h`。
5. 将 `Models/NanoTrack` 作为名为 **NanoTrack** 的文件夹资源加入 App，保留其下的 `template.onnx`、`search.onnx`、`head.onnx`。加载器查找的是 `Bundle.main/NanoTrack`；将文件平铺到 bundle 根目录，或只放在 SPM 资源 bundle 中，都无法按现有路径加载。
6. 打包前运行 `python3 scripts/verify_nanotrack.py`。

原生 API 使用 Vision 归一化矩形坐标。`candidate(in:)` 返回的是候选位置；调用 `acceptVerifiedRect(_:)` 或 `approveMovingFrame(at:)` 前，必须保留应用层的目标身份验证，详见 `CameraManager+ObjectRecognition.swift`。不要将未验证的候选位置直接用于电机控制。

若要使用完整的原实物跟随流程，需要把参考相机扩展及其状态接入自己的相机宿主。精简的 Swift Package 公开接口尚未封装这条完整流程。

## 3. 相机人脸、人形与手动目标跟踪

建议结合以下文件阅读：

- `Reference/KKGimbal/Camera/CameraManager/CameraManager+FaceTracking.swift`：自动选择、手动锁定、人形回退，以及通过手势位置选择对应人物的输入。
- `CameraManager+Tracking.swift`：预览几何、手动选框、Vision 请求、相机跟随控制输出整形。
- `CameraManager+ObjectRecognition.swift`：实物跟踪会话、确认与恢复、帧看门狗、选择 UI。
- `CameraManager.swift`：从宿主提取的跟踪状态声明。
- `CameraManager+AVCaptureDelegate.swift`：保留作上下文参考的原采集分发逻辑。
- `CameraManager+Gesture.swift`、`CameraManager+GestureRecognizerDelegate.swift`：拖动选框、点击选择，以及可选的手势启动与停止分发。

这些参考扩展仍引用宿主属性、代理、本地化字符串、相机模式和 BLE 管理器，需要你实现相应接口。代码还包含可选的希区柯克效果与手势接口；完整录制 UI、手势 SDK、应用配置及其他相机功能未随源码导出。

接入参考源码时，应将 `Sources/GimbalTracking/` 中相关文件编译到同一宿主模块，使其 internal 类型可见。不要同时通过 SPM 再编译一份相同源码。直接使用 Package 的项目应调用公开 API。

## 4. 可选的语义物体发现

```bash
python3 Models/download_models.py
python3 Models/download_models.py --verify-only
```

下载脚本会取得所有已固定版本的基线与质量配置模型，并拒绝哈希不匹配的内容。请先查看 `Models/NOTICE.md` 中的发布方条款与文件大小。质量配置使用 YOLOv3 FP16 和 EfficientDet-Lite2；默认 Package 不会自动下载或打包这些模型。

使用 Core ML 时，将 `YOLOv3FP16.mlmodel` 加入宿主 App target，让 Xcode 将其编译为主 bundle 中的 `YOLOv3FP16.mlmodelc`，然后初始化 `ObjectDetector`。模型缺失会抛出错误。Info.plist 的 `ObjectDetectionModelPreset=baseline` 配置可切换为文档所述的 Tiny 模型。

使用 MediaPipe 时，采用源码接入，并通过 CocoaPods 将 `MediaPipeTasksVision` 0.10.35 加入同一 target。仅当该模块可用时，`MediaPipeObjectDetector.swift` 及其工厂分支才参与编译。将选定的 `.tflite` 模型加入宿主 bundle。GPU 推理需要真机和兼容的像素缓冲区；系统不会静默改用其他后端。

## 5. ReplayKit 跨应用跟踪

这一能力需要宿主 App 与 Broadcast Upload Extension 配合，不能仅靠添加 SPM 依赖启用。

1. 创建自己的 iOS App 与 Broadcast Upload Extension target，将 `Reference/GimbalScreenFollowBroadcast/` 中的 Swift 文件复制到扩展。以其中的 Info.plist 和 entitlements 为模板，使用自己的签名配置。
2. 在两个 target 的 entitlements，以及 `ScreenFollowModels.swift` 的 `ScreenFollowConstants.appGroup` 中配置自己的共享 App Group。将 `ScreenFollowConstants.extensionBundleID` 设为扩展的 Bundle ID。提供的 `com.example...` 均为占位标识符。
3. 将 `ScreenFollowModels.swift` 和 `ScreenFollowStore.swift` 编译到两个 target。主 target 还需要 `ScreenFollowController.swift`、`ScreenFollowFaceAnalyzer.swift` 和主应用集成参考代码。扩展可用的代码应与依赖 UIKit、UIApplication 的主应用代码分开。
4. 将 `ScreenFollowMainAccess.swift` 适配到现有 BLE 会话管理器。对 `KKBLEManager` 的调用是必须实现的集成接口。保留会话互斥、时效性检查、温度与后台执行过期处理，以及停止指令发送逻辑。
5. 替换设置 UI 对宿主的依赖，包括 `HomeFeatureEntryButton`、本地化辅助方法、产品图片和设置界面。若保留原功能开关，将 `KKScreenFollowEnabled` 设为字符串 `YES`。
6. 向用户说明屏幕采集行为，并使用系统广播选择器。只配置宿主实际使用的后台模式，使用自己的描述文件在真机验证完整生命周期。

参考扩展通过本机回环连接发送有大小限制的 JPEG 帧，并携带会话标识；帧与 ACK 机制保证最多只有一帧在途。分析与 BLE 留在主应用中。当前实现要求竖屏直播；旋转、断帧、后台执行过期和蓝牙断开都必须停止运动。跨应用跟踪占用会话时，宿主相机链路必须释放控制权。

## 6. 硬件传输

`FollowCommand.encodedD1Packet()` 提供原始 D1 数据包编码，包括数值限幅。它不是通用云台协议。相机参考链路在 `Reference/KKGimbal/BLE/ProtocolParser.swift` 中使用自身的原始缩放与前置相机方向转换。

BLE 参考代码包含跟踪专用的会话与队列逻辑，但未包含扫描、重连、固件升级和完整 ATT 写入串行化机制。应将其适配到自己的传输层，并在实际写入时检查授权。驱动电机前，验证保持、退出、断连、重连、背压和过期处理。
