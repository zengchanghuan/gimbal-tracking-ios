# Gimbal Tracking for iOS

iOS tracking code extracted from a gimbal camera application: object tracking, face/person selection, manual target tracking, and ReplayKit cross-app face following.

[中文](README.md) · [Integration](docs/INTEGRATION.md) · [Architecture](docs/ARCHITECTURE.md) · [Validation](docs/VALIDATION.md)

The repository combines a buildable Swift package with integration references. The package exposes `FaceTracker`, `FollowController`, and an optional Core ML `ObjectDetector`. NanoTrack V2 and appearance recovery are Objective-C++ sources integrated through Xcode and OpenCV. Camera, UI, ReplayKit and BLE references require a host application; they are not a standalone app or a fully packaged SDK.

```bash
swift test
swift run tracking-demo
python3 scripts/check.py
python3 scripts/verify_nanotrack.py
```

Use macOS with full Xcode and Swift 5.9+. The Swift package targets iOS 15+ and macOS 13+. The example replays synthetic detections and prints commands without connecting hardware. Real camera, ReplayKit and motor behavior require device validation.

All image boxes use normalized lower-left coordinates. Timestamps use monotonic system uptime. The host must expire motion when frames stop, invalidate stale queued writes, and explicitly map coordinates and command signs for its camera and gimbal. Commands use the original device's wire units, not angular units.

The native object tracker includes fixed-template NanoTrack inference, appearance verification, original-target reacquisition and foreground-part helpers. Optional semantic discovery uses Core ML YOLOv3 or MediaPipe EfficientDet; large optional detection models are downloaded separately with pinned SHA-256 verification. NanoTrack weights are bundled with their upstream license and provenance.

Project-owned code is under [MIT](LICENSE). Third-party components retain their respective licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). No original repository history, signing credentials or live-camera recordings are included.
