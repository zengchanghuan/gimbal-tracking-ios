#!/usr/bin/env python3
"""Compile production coordinator/policy/logger with fixture detection and real Vision.

No camera, BLE, trained-model accuracy, or iPhone performance is simulated here.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "Sources/GimbalTracking"
SOURCES = [MODULE / name for name in (
    "ObjectDetectionTypes.swift", "ObjectTrackingPolicy.swift",
    "ObjectTrackingDiagnostics.swift", "ObjectTrackingCoordinator.swift",
)] + [ROOT / "scripts/ObjectTrackingCoordinatorSmoke.swift"]

with tempfile.TemporaryDirectory(prefix="object-tracking-smoke-") as directory:
    temporary = Path(directory)
    binary = temporary / "smoke"
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(temporary / "cache"),
                    *map(str, SOURCES), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=90)
