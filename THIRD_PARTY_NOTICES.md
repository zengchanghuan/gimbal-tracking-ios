# 第三方声明

**中文** · [English](THIRD_PARTY_NOTICES.en.md)

根目录的 MIT 许可证适用于项目自有代码，不替代第三方许可证，也不授予额外的模型权重使用权。源码中原有的作者署名已保留。

## NanoTrack / SiamTrackers

- 上游：[HonglinChu/SiamTrackers，NanoTrack](https://github.com/HonglinChu/SiamTrackers/tree/248663fde6bf7c40190cf10ee396d5662919ecd3/NanoTrack)。
- 上游条款：[Apache-2.0 原文](Models/NanoTrack/LICENSE)。
- 随仓库提供的文件：`Models/NanoTrack/template.onnx`、`search.onnx`、`head.onnx`。
- 精确来源与哈希：[PROVENANCE.txt](Models/NanoTrack/PROVENANCE.txt)。
- `NativeTracking/CMNanoTrackTracker.mm` 将固定模板裁剪、推理和预测头解码移植到 Objective-C++，并增加宿主验证接口。`CMNanoTrackAppearance.inc` 增加应用专用的外观与运动验证。这些是经过适配的集成代码，并非未经修改的上游源码。分发包含跟踪器或权重的产物时，应保留上游许可证。

## OpenCV

可选的原生跟踪器需要 OpenCV 4.10.0，包括 core、imgproc、calib3d、features2d 和 dnn 模块。构建脚本下载上游版本并构建静态 XCFramework。本仓库不包含 OpenCV 二进制文件。

- [上游源码](https://github.com/opencv/opencv/tree/4.10.0)
- [上游 Apache-2.0 许可证](https://github.com/opencv/opencv/blob/4.10.0/LICENSE)

分发构建后的 XCFramework 时，应保留 OpenCV 许可证，以及链接到静态库中的第三方库声明。构建脚本会合并编解码与 protobuf 依赖，根目录 MIT 许可证不覆盖这些依赖。

## 可选语义检测器

`Models/NOTICE.md` 保留 EfficientDet-Lite0/Lite2 和 Apple YOLOv3/Tiny 转换模型的详细来源与限制，原始记录为英文。`Models/models.json` 固定来源 URL、字节数和 SHA-256 摘要。这些权重未随仓库提供。

- MediaPipe Tasks Vision 源码与 SDK：[Apache-2.0 副本](Models/MEDIAPIPE-APACHE-2.0.txt)，适配版本为 0.10.35。
- Darknet 许可声明：[LICENSE](Models/DARKNET-LICENSE.txt)、[许可选择](Models/DARKNET-META-LICENSE.txt)、[MIT 原文](Models/DARKNET-MIT-LICENSE.txt)。
- SDK 许可证不能单独证明每份转换后预训练权重的适用条款。再分发前，应查阅 `Models/NOTICE.md` 中的发布方链接与来源记录。

Apple 系统框架由平台提供，本仓库未再分发 Apple SDK 二进制文件。
