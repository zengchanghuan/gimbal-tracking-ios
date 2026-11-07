#!/usr/bin/env python3
"""Exercise the current production physical-object follow safety policy.

The Swift policy is extracted verbatim, not reimplemented. Inputs include
synthetic observations and recorded raw positions from the 2026-10-19 incident.
This is a policy regression, not a new camera, Vision, BLE, or motor measurement.
Usage: python3 scripts/PhysicalObjectFollowSafetySmoke.py [--output-dir PATH]
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "Reference/KKGimbal/Camera/CameraManager/CameraManager+ObjectRecognition.swift"
FIXTURE = ROOT / "scripts/PhysicalObjectFollowSafetySmoke.swift"
MARKER = "struct CMPhysicalObjectFollowSafety"
INSERT = "// INSERT_PRODUCTION_POLICY"


def extract_block(source, marker):
    if source.count(marker) != 1:
        raise ValueError(f"Expected exactly one production declaration: {marker}")
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth and end < len(source):
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    if depth:
        raise ValueError("Unbalanced production declaration")
    return source[start:end]


def run(directory):
    source = POLICY.read_text()
    policy = extract_block(source, MARKER)
    template = FIXTURE.read_text()
    if template.count(INSERT) != 1:
        raise ValueError("Expected exactly one fixture insertion marker")
    generated = template.replace(INSERT, policy)
    directory.mkdir(parents=True, exist_ok=True)
    swift = directory / "main.swift"
    swift.write_text(generated)
    metadata = {
        "scope": "production policy with synthetic observations and recorded raw-position replay",
        "not_measured": ["native Vision", "camera geometry", "BLE", "physical motor behavior"],
        "production_path": str(POLICY.relative_to(ROOT)),
        "production_sha256": hashlib.sha256(source.encode()).hexdigest(),
        "policy_sha256": hashlib.sha256(policy.encode()).hexdigest(),
        "fixture_sha256": hashlib.sha256(template.encode()).hexdigest(),
        "generated_sha256": hashlib.sha256(generated.encode()).hexdigest(),
    }
    with tempfile.TemporaryDirectory(prefix="physical-follow-safety-build-") as temporary:
        build = Path(temporary)
        binary = build / "smoke"
        compilation = subprocess.run(
            ["xcrun", "swiftc", "-module-cache-path", str(build / "cache"),
             str(swift), "-o", str(binary)], text=True, capture_output=True)
        (directory / "compile.log").write_text(compilation.stdout + compilation.stderr)
        metadata["compile_exit_status"] = compilation.returncode
        if compilation.returncode:
            (directory / "source-evidence.json").write_text(json.dumps(metadata, indent=2) + "\n")
            print(compilation.stdout + compilation.stderr, end="")
            raise SystemExit(compilation.returncode)
        result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=30)
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
        with tempfile.TemporaryDirectory(prefix="physical-follow-safety-smoke-") as temporary:
            run(Path(temporary))
