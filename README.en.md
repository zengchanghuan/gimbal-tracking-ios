# Gimbal Tracking for iOS

iOS tracking code extracted from a gimbal camera application: **object tracking, face/person tracking, manual target tracking, and ReplayKit cross-app face following**.

[中文](README.md) · **English** · [Integration](docs/INTEGRATION.en.md) · [Architecture](docs/ARCHITECTURE.en.md) · [Third-party notices](THIRD_PARTY_NOTICES.en.md) · [Validation](docs/VALIDATION.en.md) · [Contributing](CONTRIBUTING.en.md)

## Included capabilities

| Capability | Implementation | Integration |
| --- | --- | --- |
| Face tracking | Apple Vision detection, sequence tracking, periodic validation and brief-loss handling | Swift Package `FaceTracker` |
| Follow control | Target confirmation, dead zones, stabilization, slew limits, stale-frame stops and yaw/pitch output | Swift Package `FollowController` |
| Object discovery | Core ML YOLOv3 / optional MediaPipe EfficientDet | `ObjectDetector` and detector coordinator sources |
| Physical object tracking | NanoTrack V2, a fixed initial template, appearance verification, reacquisition and foreground-part fusion | `NativeTracking/` and camera integration references |
| Face/person selection and manual targets | Automatic selection, manual locks, Vision rectangles, coordinate conversion and follow control | `Reference/KKGimbal/Camera/` |
| Cross-app following | ReplayKit → local frame channel → Vision → gimbal control | `Reference/GimbalScreenFollowBroadcast/` and main-app references |

The initial release combines a **buildable Swift core library with original app integration references**. The Swift Package is directly usable. CameraManager, UI and BLE interfaces in `Reference/` need a host application and do not form a standalone app. The Objective-C++ NanoTrack component is integrated as Xcode source and requires OpenCV.

## Quick start

Requirements: macOS, full Xcode and Swift 5.9+. The core library targets iOS 15+ / macOS 13+. Actual camera and cross-app behavior require iPhone validation.

```bash
git clone https://github.com/zengchanghuan/gimbal-tracking-ios.git
cd gimbal-tracking-ios
swift test
swift run tracking-demo
python3 scripts/check.py
python3 scripts/verify_nanotrack.py
```

`tracking-demo` replays a deterministic target trajectory and target loss, printing control output without connecting hardware.

Add the repository URL in Xcode's Package Dependencies and select the `GimbalTracking` product:

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

A single frame does not immediately confirm a target. Subsequent calls must supply real observations from new images, increasing frame IDs and capture timestamps. All boxes use normalized image coordinates with a lower-left origin; the host explicitly handles preview mirroring and hardware control direction. See the [integration guide](docs/INTEGRATION.en.md) for a complete face pipeline and NanoTrack setup.

## Repository layout

```text
Sources/GimbalTracking/    Swift core, Vision, Core ML, controllers and public API
NativeTracking/           NanoTrack / OpenCV appearance verification and recovery
Models/                   NanoTrack weights, provenance, licenses and optional detector downloader
Reference/                Camera, target selection, ReplayKit, UI and BLE integration references
Examples/TrackingDemo/    Controller replay without hardware
Tests/                    Public API regressions
scripts/                  Source regressions, model verification and OpenCV build
docs/                     Architecture, integration, validation scope and source manifest
```

## Operating limits

- This is an image-tracking and gimbal-following implementation. It does not establish reliability for every object, occlusion, lighting condition or device. Object recovery still requires distinguishable appearance evidence.
- The host must stop movement and clear stale queued commands when a target is lost, capture stops, frames expire, sessions change or BLE disconnects. Controller output uses the original hardware's protocol units, not degrees or angular velocity.
- Cross-app mode processes frames from a ReplayKit broadcast explicitly started by the user. The reference supports portrait orientation, and background execution is constrained by the iOS lifecycle. You need your own App Group, signing and BLE implementation.
- Automated regressions cover code and policy; they are not camera, BLE, physical motor or sustained-performance acceptance tests. See [VALIDATION.en.md](docs/VALIDATION.en.md) for the measured scope.

## License

Project-owned code is under [MIT](LICENSE). NanoTrack weights and upstream implementation, OpenCV, MediaPipe and optional detection models retain their respective terms; see [THIRD_PARTY_NOTICES.en.md](THIRD_PARTY_NOTICES.en.md). Original source author headers are retained. The repository does not include the original app's full Git history, signing configuration, account data, product assets or live-camera test recordings.
