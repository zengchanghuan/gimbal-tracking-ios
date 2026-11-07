#!/usr/bin/env python3
"""Compile-check iOS Swift and native tracking sources; does not link or run hardware."""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--opencv-headers', type=Path, default=ROOT / 'Dependencies/OpenCV/OpenCVStitching.xcframework/ios-arm64/Headers/opencv4')
args = parser.parse_args()
if not (args.opencv_headers / 'opencv2/dnn.hpp').is_file():
    raise SystemExit('Build OpenCV first, or supply --opencv-headers pointing to Headers/opencv4.')
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()

def run(command):
    subprocess.run(list(map(str, command)), cwd=ROOT, check=True)

with tempfile.TemporaryDirectory(prefix='gimbal-tracking-native-') as directory:
    tmp = Path(directory)
    common = ['xcrun', 'swiftc', '-swift-version', '5', '-sdk', sdk, '-target', 'arm64-apple-ios15.0', '-module-cache-path', tmp / 'cache']
    run([*common, '-parse-as-library', '-emit-module', '-module-name', 'GimbalTracking',
         *sorted((ROOT / 'Sources/GimbalTracking').glob('*.swift')), '-o', tmp / 'GimbalTracking.swiftmodule'])
    run(['xcrun', 'clang++', '-fsyntax-only', '-std=c++17', '-fobjc-arc', '-isysroot', sdk,
         '-target', 'arm64-apple-ios15.0', '-I', args.opencv_headers,
         ROOT / 'NativeTracking/CMNanoTrackTracker.mm', ROOT / 'NativeTracking/CMPhysicalObjectPatchTracker.mm'])
    # Check the full physical-session helpers with real imported native interfaces.
    # The camera extension itself still requires the host camera implementation.
    source = (ROOT / 'Reference/KKGimbal/Camera/CameraManager/CameraManager+ObjectRecognition.swift').read_text()
    sessions = source.split('extension CameraManager {', 1)[0] + '\nfunc kkLog(_ message: String) {}\n'
    swift = tmp / 'PhysicalSessions.swift'
    swift.write_text(sessions)
    bridge = tmp / 'Bridge.h'
    bridge.write_text(''.join('#import "' + str(ROOT / 'NativeTracking' / header) + '"\n'
                              for header in ['CMNanoTrackTracker.h', 'CMPhysicalObjectPatchTracker.h']))
    run([*common, '-typecheck', '-import-objc-header', bridge, swift])
print('iOS Swift module, Objective-C++ syntax, and physical-session type checks passed.')
