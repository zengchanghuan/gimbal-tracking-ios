# 首版提取验证记录

**中文** · [English](VALIDATION.en.md)

验证日期为 2026-11-07，使用 `SOURCE_MANIFEST.json` 记录的 1.1.5 源码基线。

环境：Apple Silicon macOS、Xcode 27.2（27B52）、Swift 6.4.2，采用 Swift 5 语言模式。iOS 编译检查使用已安装的 iPhoneOS SDK，目标为 arm64 iOS 15。尚未逐一验证所有旧版 Xcode 的兼容性。

| 检查项 | 结果 | 覆盖范围 |
| --- | --- | --- |
| Swift Package 构建与公开 API 测试 | 3 项测试通过 | 原始 D1 保持指令字节、目标确认、重复帧、目标丢失、过期帧与重置 |
| 控制器回放示例 | 通过 | 偏离中心的目标产生有界控制量；丢失后返回保持指令 |
| ScreenFollowCoreSmoke | 457 项断言通过 | 控制器、数据包分帧、时效性与稳定性测试样例 |
| ScreenFollowCadenceSmoke | 24 条轨迹通过 | 合成源时序下的帧接纳与发送节奏 |
| ScreenFollowSourceTimingSmoke | 10 项断言通过 | 新旧遥测格式的传输兼容性 |
| ScreenFollowStoreSmoke | 20 项断言通过 | 会话准备记录缺失、损坏、过期及重试 |
| ScreenFollowDetectorComputeSmoke | 64 项断言通过 | 注入的计算后端选择、失败与 CPU 回退 |
| PhysicalObjectFollowSafetySmoke | 2,581 项断言通过 | 使用测试观测数据验证实际安全策略决策 |
| PhysicalObjectCommandSmoke | 160 项断言通过 | 实际控制输出整形与保持逻辑；传输和 UI 使用测试替身 |
| PhysicalObjectRecoverySessionSmoke | 138 项断言通过 | 恢复证据分发；图像与 Vision 使用测试替身 |
| PhysicalObjectSnapshotPartsSmoke | 208 项断言通过 | 会话分发与部件融合安全策略；使用测试替身 |
| PhysicalObjectPartsSmoke | 32 项断言通过 | 几何部件融合策略 |
| iOS Swift 模块编译 | 通过 | Package 全部 Swift 源码，iOS 目标 |
| 原生跟踪器语法编译 | 通过 | 使用 OpenCV 头文件检查两份 Objective-C++ 实现 |
| 实物会话辅助代码类型检查 | 通过 | Swift 会话辅助代码与真实 Objective-C 接口 |
| NanoTrack 模型完整性 | 3/3 匹配 | 与保留的来源记录核对 SHA-256 |
| 广播 plist 与 entitlement 模板 | 通过 | 属性列表语法、占位应用标识 |

原生检查使用源应用现有的 OpenCV 4.10 头文件。导出的 OpenCV 构建脚本已调整并通过 shell 语法检查，但本次提取未从零重新构建全部 OpenCV 依赖。原生检查不代表最终 App 链接已通过。

最初的存储测试仍期望原产品的中文本地化文案。提取时将产品提示及对应断言改为包含恢复操作说明的通用英文回退文案，保留会话过期语义，随后测试通过。计算策略测试仍有 `usesCPUOnly` API 的弃用警告。

## 复现方法

```bash
swift test
swift run tracking-demo
python3 scripts/check.py
python3 scripts/verify_nanotrack.py

# 先构建 OpenCV，或通过 --opencv-headers 指向已有构建的头文件：
python3 scripts/check_native.py

# 可选的额外图像测试，首次提取时未运行：
python3 scripts/check.py --vision
```

本次提取**未重新验证**可选 Vision 图像测试、可选模型的全新下载、完整参考宿主 App 构建、ReplayKit 采集、相机识别准确率、BLE 送达、物理电机响应、持续性能和 App Store 签名。参考宿主文件用于接入，不是独立 App target。不能将原应用测试注释或确定性测试中的断言数量，视为新宿主或新设备的验收证据。

GitHub Actions 工作流运行 Package 测试、确定性回归、模型校验和回放示例。当前线上结果可在仓库 Actions 页面查看；以上本地结果独立于托管 CI 的可用状态。
