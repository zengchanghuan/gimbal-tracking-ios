# Initial extraction validation

Checked on 2026-11-07 against the 1.1.5 source baseline recorded in `SOURCE_MANIFEST.json`.

Environment: Apple Silicon macOS, Xcode 27.2 (27B52), Swift 6.4.2 in Swift 5 language mode. iOS compile checks targeted arm64 iOS 15 with the installed iPhoneOS SDK. Compatibility with every older Xcode release has not been measured.

| Check | Result | Scope |
| --- | --- | --- |
| Swift Package build and public API tests | 3 tests passed | Original D1 hold bytes, confirmation, duplicate frames, target loss, stale frames and reset |
| Controller replay example | Passed | Off-center target generates bounded control; loss returns hold |
| ScreenFollowCoreSmoke | 457 assertions passed | Controller, packet framing, freshness and stability fixtures |
| ScreenFollowCadenceSmoke | Passed across 24 trajectories | Frame admission and cadence under synthetic source timing |
| ScreenFollowSourceTimingSmoke | 10 assertions passed | Old/new telemetry wire compatibility |
| ScreenFollowStoreSmoke | 20 assertions passed | Missing/corrupt/expired session invitation and retry |
| ScreenFollowDetectorComputeSmoke | 64 assertions passed | Injected compute selection, failure and CPU fallback |
| PhysicalObjectFollowSafetySmoke | 2,581 assertions passed | Production safety decisions with fixture observations |
| PhysicalObjectCommandSmoke | 160 assertions passed | Production command shaping and hold with transport/UI doubles |
| PhysicalObjectRecoverySessionSmoke | 138 assertions passed | Recovery evidence routing with image/Vision doubles |
| PhysicalObjectSnapshotPartsSmoke | 208 assertions passed | Session routing and part-fusion safety with doubles |
| PhysicalObjectPartsSmoke | 32 assertions passed | Geometric part fusion policy |
| iOS Swift module compilation | Passed | All package Swift sources, iOS target |
| Native tracker syntax compilation | Passed | Both Objective-C++ implementations with OpenCV headers |
| Physical session helper type checking | Passed | Swift session helpers with their real Objective-C interfaces |
| NanoTrack model integrity | 3/3 matched | SHA-256 against the retained provenance |
| Broadcast plist and entitlement templates | Passed | Property-list syntax, placeholder app identity |

The native checks used the source application's existing OpenCV 4.10 headers. The exported OpenCV build helper was adapted and shell-syntax checked; a fresh full OpenCV dependency build was not run during extraction. Native checks do not establish final app linkage.

The first store test still expected the original product's Chinese localization. The extraction changed the product wording and the assertion to an actionable generic English fallback; session expiration semantics were preserved and the suite then passed. Existing `usesCPUOnly` API deprecation warnings remain in the compute-policy test.

## Reproduce

```bash
swift test
swift run tracking-demo
python3 scripts/check.py
python3 scripts/verify_nanotrack.py

# After building OpenCV, or with --opencv-headers pointing to your existing build:
python3 scripts/check_native.py

# Optional extra image-based fixtures, not run as part of the initial extraction:
python3 scripts/check.py --vision
```

The optional Vision fixtures, fresh optional-model downloads, complete reference host app build, ReplayKit capture, camera accuracy, BLE delivery, physical motor response, sustained performance and App Store signing were **not** revalidated for this extraction. The reference host files are integration material, not a standalone app target. Do not read prior application test comments or deterministic fixture counts as acceptance evidence for a new host/device.

The GitHub Actions workflow runs package tests, deterministic regressions, model verification and the replay example. Its current status is available from the repository Actions page; local results above are independent of hosted CI availability.
