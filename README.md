# Gimbal Tracking for iOS

从实际 iOS 云台应用提取的跟踪源码：**物体跟踪、人脸与人形跟踪、手动目标跟踪，以及 ReplayKit 跨应用人脸跟踪**。

[English](README.en.md) · [接入说明](docs/INTEGRATION.md) · [架构与边界](docs/ARCHITECTURE.md) · [第三方声明](THIRD_PARTY_NOTICES.md) · [验证记录](docs/VALIDATION.md)

## 包含什么

| 能力 | 实现 | 使用方式 |
| --- | --- | --- |
| 人脸跟踪 | Apple Vision 检测、序列跟踪、周期校验、短时丢失处理 | Swift Package 的 `FaceTracker` |
| 跟随控制 | 目标确认、死区、防抖、限速、过期帧停止、Yaw/Pitch 输出 | Swift Package 的 `FollowController` |
| 物体发现 | Core ML YOLOv3 / 可选 MediaPipe EfficientDet | `ObjectDetector` 与检测协调器源码 |
| 实物跟踪 | NanoTrack V2、固定初始模板、外观验证、重捕获、前景部件融合 | `NativeTracking/` 与相机集成参考 |
| 人脸/人形选择与手动目标 | 自动选人、手动锁定、Vision 选框、坐标转换、跟随控制 | `Reference/KKGimbal/Camera/` |
| 跨应用跟踪 | ReplayKit → 本机帧通道 → Vision → 云台控制 | `Reference/GimbalScreenFollowBroadcast/` 与主 App 参考 |

首版采用**可构建的 Swift 核心库 + 原应用集成参考**的形式。Swift Package 可直接使用；`Reference/` 中保留的 CameraManager、UI 和 BLE 接口需要接入宿主应用，不能单独当作完整 App 构建。NanoTrack 的 Objective-C++ 部分通过 Xcode 源码接入，需要 OpenCV。

## 快速开始

环境：macOS、完整 Xcode、Swift 5.9+；核心库最低 iOS 15 / macOS 13。摄像头和跨应用跟踪的实际行为需要 iPhone 验证。

```bash
git clone https://github.com/zengchanghuan/gimbal-tracking-ios.git
cd gimbal-tracking-ios
swift test
swift run tracking-demo
python3 scripts/check.py
python3 scripts/verify_nanotrack.py
```

`tracking-demo` 运行确定性的目标轨迹与丢失回放，打印控制输出，不连接硬件。

在 Xcode 的 Package Dependencies 中添加仓库 URL，选择 `GimbalTracking` 产品：

```swift
import Foundation
import GimbalTracking

var controller = FollowController()
let now = ProcessInfo.processInfo.systemUptime
let command = controller.observe(
    boxes: [TrackingBox(CGRect(x: 0.65, y: 0.4, width: 0.2, height: 0.2))],
    frameID: 1, capturedAt: now, now: now
)
```

单帧不会立即确认目标。后续调用需要提供真实的新图像结果、递增帧号和采集时刻。所有 box 都是图像左下原点的归一化坐标；预览镜像与设备控制方向由宿主明确转换。完整的人脸管线与 NanoTrack 接入步骤见[接入说明](docs/INTEGRATION.md)。

## 目录

```text
Sources/GimbalTracking/    Swift 核心、Vision、Core ML、控制器及公开 API
NativeTracking/           NanoTrack / OpenCV 外观验证与恢复
Models/                   NanoTrack 权重、模型来源、许可及可选检测模型下载脚本
Reference/                相机、目标选择、ReplayKit、UI、BLE 集成参考
Examples/TrackingDemo/    无硬件的控制器回放示例
Tests/                    公开 API 回归
scripts/                  源码回归、模型校验、OpenCV 构建
docs/                     架构、接入、验证范围和源文件清单
```

## 使用边界

- 这是图像跟踪与云台跟随实现，不能据此推断任意物体、遮挡、光照和设备均可靠。物体恢复仍需要可辨识的外观证据。
- 目标丢失、采集停止、帧过期、会话变化或蓝牙断开时，宿主必须停止运动并清除待发送旧指令。控制器输出单位沿用原硬件协议，不是角度或角速度。
- 跨应用模式处理用户主动开启 ReplayKit 广播的画面；参考实现仅支持竖屏，后台执行受 iOS 生命周期约束。需要你自己的 App Group、签名和蓝牙实现。
- 自动化回归覆盖代码与策略，不等同于摄像头、BLE、物理电机或长期性能验收。当前验证范围见 [VALIDATION.md](docs/VALIDATION.md)。

## 许可证

项目自有代码按 [MIT](LICENSE) 发布。NanoTrack 权重及其上游实现、OpenCV、MediaPipe 和可选检测模型保留各自条款，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。本仓库保留原文件作者署名；未包含原应用完整 Git 历史、签名配置、账号数据、产品资源或实拍测试素材。
