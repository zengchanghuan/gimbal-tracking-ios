# Contributing

Describe the concrete tracking failure, capture geometry, platform, source revision and expected behavior. Prefer a minimal synthetic fixture; do not attach private screen recordings, face images, device identifiers or credentials without permission.

Run `swift test`, `python3 scripts/check.py` and `python3 scripts/verify_nanotrack.py` on macOS before submitting a change. `python3 scripts/check.py --vision` additionally exercises Apple Vision with synthetic images and is environment-dependent. Native changes need an iOS Objective-C++ build with OpenCV; camera/ReplayKit/BLE changes need device validation.

Keep coordinate conventions, monotonic timestamps, target identity checks and stale-command invalidation explicit. Distinguish policy fixtures, image replay, native device tests and physical motor acceptance in reports. A deterministic test pass is not a tracking-accuracy benchmark.

Project-owned contributions use the root MIT license. Preserve existing authorship and third-party licenses. Do not add model weights without provenance, redistribution terms and a pinned digest.
