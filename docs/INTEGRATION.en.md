# Integration

[中文](INTEGRATION.md) · **English**

## 1. Swift Package

Add `https://github.com/zengchanghuan/gimbal-tracking-ios.git` through Xcode's Package Dependencies and select the `GimbalTracking` library. The package uses only Apple frameworks by default. Public APIs are in `Sources/GimbalTracking/PublicAPI.swift`; other types retain internal visibility.

The macOS executable demonstrates the controller without camera access:

```bash
swift run tracking-demo
```

A minimal face-analysis/control wrapper follows. Own the entire instance on one serial analysis queue; acquire the image and capture timestamp in your camera pipeline.

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

The caller handles errors by stopping motion and resetting its session. It also sets a frame-expiry watchdog and validates the current session immediately before a BLE write. `.hold` means zero motion. A `nil` result means the frame was ignored, not renewed permission to keep moving. `yawSign`/`pitchSign` must match your camera mirroring and hardware. Command units are protocol units, not degrees or angular velocity.

## 2. Native object tracking

The Objective-C++ tracker is distributed as source, outside the Swift Package target.

1. Build OpenCV using `bash scripts/build_opencv.sh`. This requires full Xcode, CMake, Python 3, network access and sufficient build space. It builds device/simulator archives and writes `Dependencies/OpenCV/OpenCVStitching.xcframework`.
2. Add that XCFramework to the host app target. Add `NativeTracking/*.mm` to Compile Sources, retain the `.inc` files beside them, and add the two headers to the project. Set C++ language standard to C++17 and enable Objective-C ARC.
3. Add the selected XCFramework slice's `Headers/opencv4` directory to Header Search Paths. Link the Apple frameworks referenced by the sources and the C++ runtime; the static OpenCV archive also requires `libz` for codec dependencies. Keep the third-party notices accompanying your build.
4. Import `CMNanoTrackTracker.h` and `CMPhysicalObjectPatchTracker.h` in the app's Objective-C bridging header.
5. Add `Models/NanoTrack` as a folder resource named **NanoTrack**, preserving `template.onnx`, `search.onnx` and `head.onnx` beneath it. The loader searches `Bundle.main/NanoTrack`; placing the files flat in the bundle or only inside an SPM resource bundle will not work.
6. Run `python3 scripts/verify_nanotrack.py` before packaging.

The native API uses normalized Vision rectangles. A `candidate(in:)` result is a proposal. Preserve application identity checks before `acceptVerifiedRect(_:)` or `approveMovingFrame(at:)`; see `CameraManager+ObjectRecognition.swift`. Do not route an unverified candidate directly to motors.

For the complete original physical-object control flow, integrate the reference camera extension and its state into your own camera host. The thin Swift package facade intentionally does not claim to wrap this whole flow.

## 3. Camera face, human and manual-target tracking

Read these files together:

- `Reference/KKGimbal/Camera/CameraManager/CameraManager+FaceTracking.swift`: auto selection, manual locks, human fallback and gesture-owner selection input.
- `CameraManager+Tracking.swift`: preview geometry, manual selection, Vision requests and native camera control shaping.
- `CameraManager+ObjectRecognition.swift`: physical tracking sessions, confirmation/recovery, frame watchdog and selection UI.
- `CameraManager.swift`: tracking-state declarations extracted from the host.
- `CameraManager+AVCaptureDelegate.swift`: original capture routing, retained as context.
- `CameraManager+Gesture.swift`, `CameraManager+GestureRecognizerDelegate.swift`: drag selection, tap selection and optional gesture-driven start/stop routing.

The reference extensions still refer to host properties, delegates, localized strings, camera modes and the BLE manager. Supply your own implementations of those boundaries. They also include optional Hitchcock/gesture hooks; the full recording UI, gesture SDK, app configuration and other camera features are not exported.

When integrating reference sources, compile the relevant files from `Sources/GimbalTracking/` into the same host module so their internal types are available. Do not also compile a second copy through SPM. Package consumers should use the public facade instead.

## 4. Optional semantic object discovery

```bash
python3 Models/download_models.py
python3 Models/download_models.py --verify-only
```

The downloader retrieves all pinned baseline/quality artifacts and refuses changed bytes. Check `Models/NOTICE.md` for publisher terms and source sizes first. The quality configuration uses YOLOv3 FP16 and EfficientDet-Lite2; the default package does not download or bundle them automatically.

For Core ML, add `YOLOv3FP16.mlmodel` to the host app target so Xcode compiles `YOLOv3FP16.mlmodelc` into the main bundle, then initialize `ObjectDetector`. A missing model throws an error. The `ObjectDetectionModelPreset=baseline` Info.plist option selects the documented Tiny model instead.

For MediaPipe, use source integration and add `MediaPipeTasksVision` 0.10.35 to the same target using CocoaPods. `MediaPipeObjectDetector.swift` and its factory branch compile only when that module is available. Add the selected `.tflite` model to the host bundle. GPU inference requires a physical device and compatible pixel buffers; there is no silent backend substitution.

## 5. Cross-app ReplayKit tracking

This is a host-app plus Broadcast Upload Extension integration, not an SPM-only capability.

1. Create your own iOS app and Broadcast Upload Extension targets. Copy the Swift files in `Reference/GimbalScreenFollowBroadcast/` into the extension. Use its Info.plist/entitlements as templates, with your own signing identities.
2. Set your own shared App Group in both targets' entitlements and `ScreenFollowConstants.appGroup` in `ScreenFollowModels.swift`. Set `ScreenFollowConstants.extensionBundleID` to the extension bundle identifier. The supplied `com.example...` identifiers are placeholders.
3. Compile `ScreenFollowModels.swift` and `ScreenFollowStore.swift` into both targets. The main target also needs `ScreenFollowController.swift`, `ScreenFollowFaceAnalyzer.swift` and the main-app integration reference. Keep extension-safe code separate from UIKit/UIApplication-dependent main-app code.
4. Adapt `ScreenFollowMainAccess.swift` to your existing BLE session owner. Its `KKBLEManager` calls are a required integration boundary. Preserve session exclusion, freshness checks, thermal/background expiry handling and stop delivery.
5. Replace the setup UI's host dependencies (`HomeFeatureEntryButton`, localization helpers, product artwork and settings UI). Set `KKScreenFollowEnabled` to the string `YES` if retaining the supplied feature gate.
6. Explain screen capture to the user and use the system broadcast picker. Configure only the background modes your host actually uses. Validate the complete lifecycle on a device with your provisioning profiles.

The reference extension sends bounded JPEG frames over a loopback connection with session identity and one in-flight frame/ACK. Analysis and BLE remain in the main app. It currently expects portrait streaming; rotation, capture gaps, background expiration and disconnected BLE must stop movement. The host's camera path must release ownership while cross-app tracking owns the session.

## 6. Hardware transport

`FollowCommand.encodedD1Packet()` exposes the original D1 packet encoding, including saturation. It is not a universal gimbal protocol. The camera reference uses its own original scale/front-camera transformation in `Reference/KKGimbal/BLE/ProtocolParser.swift`.

The BLE reference contains tracking-specific session and queue logic but omits scanning, reconnect, firmware upgrade and the full ATT serializer. Adapt it to your transport and check authorization at the actual write. Test hold/exit, disconnect, reconnect, backpressure and expiry before motor use.
