#!/usr/bin/env python3
"""Run the complete production tracking command method with transport/UI spies.

Production control helpers, field declarations, safety policy, and pause method
are extracted verbatim. Transport, camera hardware, and UI are explicit doubles.
This does not validate protocol bytes, native Vision, BLE delivery, or motors.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

from PhysicalObjectFollowSafetySmoke import extract_block

ROOT = Path(__file__).resolve().parents[1]
CAMERA = ROOT / "Reference/KKGimbal/Camera/CameraManager"


def run(directory):
    files = {name: (CAMERA / name).read_text() for name in (
        "CameraManager.swift", "CameraManager+Tracking.swift", "CameraManager+ObjectRecognition.swift")}
    blocks = []
    def block(file, marker):
        code = extract_block(files[file], marker)
        blocks.append({"file": file, "marker": marker, "sha256": hashlib.sha256(code.encode()).hexdigest()})
        return code
    policy = block("CameraManager+ObjectRecognition.swift", "struct CMPhysicalObjectFollowSafety")
    methods = [block("CameraManager+Tracking.swift", marker) for marker in (
        "private var isFrontCamera: Bool", "private func trackingEffectiveZoomFactor()",
        "private func trackingControlOffset(", "private func resetTrackingStabilizerState()",
        "private func observedHorizontalRotationRate()", "private func resetTrackingYawRestrictionState()",
        "private func applyTrackingYawRestriction(", "func resetTrackingForNewSession()",
        "private func handleTrackingCenterLock(", "private func seedTrackingStabilizer(",
        "func sendTrackingCommand(state:")]
    for marker in ("func pausePhysicalObjectFollowing(reason:", "func holdPhysicalObjectControl(reason:",
                   "func physicalObjectControlDidResume()", "func holdPhysicalObjectObservation(confidence:",
                   "func physicalObjectObservationDidRecover()"):
        methods.append(block("CameraManager+ObjectRecognition.swift", marker))
    manager = files["CameraManager.swift"]
    start_marker = "    var trackingLastRawOffsetX: Int = 0"
    end_marker = "    var latestHorizontalRotationSampleUptime: TimeInterval = 0"
    if manager.count(start_marker) != 1 or manager.count(end_marker) != 1:
        raise ValueError("Expected unique production controller field range")
    fields = manager[manager.index(start_marker):manager.index(end_marker) + len(end_marker)]
    blocks.append({"file": "CameraManager.swift", "marker": "controller state fields",
                   "sha256": hashlib.sha256(fields.encode()).hexdigest()})
    template = (ROOT / "scripts/PhysicalObjectCommandSmoke.swift").read_text()
    generated = template
    for marker, code in (("// INSERT_POLICY", policy), ("// INSERT_FIELDS", fields),
                         ("// INSERT_METHODS", "\n".join(methods))):
        if generated.count(marker) != 1:
            raise ValueError(f"Expected one template marker: {marker}")
        generated = generated.replace(marker, code)
    directory.mkdir(parents=True, exist_ok=True)
    swift = directory / "main.swift"
    swift.write_text(generated)
    metadata = {
        "scope": "complete production sendTrackingCommand, control helpers and pause method with explicit boundary spies",
        "not_measured": ["protocol encoding", "native Vision", "BLE delivery", "physical motor behavior"],
        "source_files": {name: hashlib.sha256(code.encode()).hexdigest() for name, code in files.items()},
        "blocks": blocks, "fixture_sha256": hashlib.sha256(template.encode()).hexdigest(),
        "generated_sha256": hashlib.sha256(generated.encode()).hexdigest(),
    }
    with tempfile.TemporaryDirectory(prefix="physical-command-build-") as temporary:
        build = Path(temporary)
        binary = build / "smoke"
        compilation = subprocess.run(["xcrun", "swiftc", "-D", "DEBUG", "-module-cache-path", str(build / "cache"),
                                      str(swift), "-o", str(binary)], text=True, capture_output=True)
        (directory / "compile.log").write_text(compilation.stdout + compilation.stderr)
        metadata["compile_exit_status"] = compilation.returncode
        if compilation.returncode:
            (directory / "source-evidence.json").write_text(json.dumps(metadata, indent=2) + "\n")
            print(compilation.stdout + compilation.stderr, end="")
            raise SystemExit(compilation.returncode)
        result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=15)
    (directory / "result.log").write_text(result.stdout + result.stderr)
    metadata["exit_status"] = result.returncode
    (directory / "source-evidence.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(result.stdout + result.stderr, end="")
    if result.returncode:
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    if args.output_dir:
        run(args.output_dir.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix="physical-command-smoke-") as temporary:
            run(Path(temporary))
