# 贡献指南

**中文** · [English](CONTRIBUTING.en.md)

请描述具体的跟踪故障、采集几何条件、运行平台、源码版本和预期行为。优先提供最小的合成测试样例；未经许可，不要附带私密录屏、人脸图片、设备标识符或凭据。

提交修改前，请在 macOS 运行 `swift test`、`python3 scripts/check.py` 和 `python3 scripts/verify_nanotrack.py`。`python3 scripts/check.py --vision` 会额外使用合成图像测试 Apple Vision，其行为依赖运行环境。原生代码修改需要结合 OpenCV 进行 iOS Objective-C++ 构建；涉及相机、ReplayKit 或 BLE 的修改需要真机验证。

请明确保留坐标约定、单调时间戳、目标身份验证和旧指令失效机制。在报告中区分策略测试样例、图像回放、真机原生测试与物理电机验收。确定性测试通过不代表跟踪准确率达到某个基准。

项目自有代码的贡献采用根目录的 MIT 许可证。保留现有作者署名与第三方许可。新增模型权重时，需要提供来源、再分发条款和固定的哈希摘要。
