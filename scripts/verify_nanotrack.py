#!/usr/bin/env python3
"""Verify the bundled upstream NanoTrack model bytes; performs no network requests."""
from pathlib import Path
import hashlib

directory = Path(__file__).resolve().parents[1] / 'Models/NanoTrack'
digests = {
    'template.onnx': '9b0034c3ce464af75eff207fdfdeb0f51a8c79510b2802357c8cfc7071671cfe',
    'search.onnx': '530bdd0cd00f19afab79a863e71ba71e3312395a5dc9151af675082bdaaa2fc4',
    'head.onnx': '0d8c0637be849f092cc7236cae02e55c8b9455ebe37ba50601d6115db4247cd9',
}
for name, expected in digests.items():
    actual = hashlib.sha256((directory / name).read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f'Model integrity check failed: {name}')
    print(f'OK {name}')
