# Third-party notices

The root MIT license covers project-owned code. It does not replace third-party licenses or grant additional model-weight rights. Existing source author headers are retained.

## NanoTrack / SiamTrackers

- Upstream: [HonglinChu/SiamTrackers, NanoTrack](https://github.com/HonglinChu/SiamTrackers/tree/248663fde6bf7c40190cf10ee396d5662919ecd3/NanoTrack).
- Upstream terms: [Apache-2.0](Models/NanoTrack/LICENSE).
- Bundled artifacts: `Models/NanoTrack/template.onnx`, `search.onnx`, `head.onnx`.
- Exact origin and hashes: [PROVENANCE.txt](Models/NanoTrack/PROVENANCE.txt).
- `NativeTracking/CMNanoTrackTracker.mm` ports the fixed-template crop, inference and head decoding into Objective-C++ and adds the host verification interface. `CMNanoTrackAppearance.inc` adds application-specific appearance/motion validation. These are adapted integration code, not unchanged upstream source. Retain the upstream license with distributions containing the tracker or weights.

## OpenCV

The optional native tracker requires OpenCV 4.10.0, including core, imgproc, calib3d, features2d and dnn. The build helper downloads the upstream release and builds a static XCFramework. OpenCV binaries are not included in this repository.

- [Upstream source](https://github.com/opencv/opencv/tree/4.10.0)
- [Upstream Apache-2.0 license](https://github.com/opencv/opencv/blob/4.10.0/LICENSE)

When distributing a built XCFramework, retain OpenCV's license and the notices for the third-party libraries linked into the archive. The build script merges codec/protobuf dependencies; the root MIT license does not cover those dependencies.

## Optional semantic detectors

`Models/NOTICE.md` preserves detailed provenance and limitations for EfficientDet-Lite0/Lite2 and Apple's YOLOv3/Tiny conversions. `Models/models.json` pins source URLs, byte sizes and SHA-256 digests. These weights are not bundled in this repository.

- MediaPipe Tasks Vision source/SDK: [Apache-2.0 copy](Models/MEDIAPIPE-APACHE-2.0.txt), adapter version 0.10.35.
- Darknet license statements: [LICENSE](Models/DARKNET-LICENSE.txt), [license selection](Models/DARKNET-META-LICENSE.txt), [MIT text](Models/DARKNET-MIT-LICENSE.txt).
- SDK licenses do not independently establish the applicable terms of every converted pretrained weight. Consult the publisher links and provenance in `Models/NOTICE.md` before redistribution.

Apple system frameworks are supplied by the platform; no Apple SDK binaries are redistributed here.
