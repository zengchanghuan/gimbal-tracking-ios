#!/usr/bin/env python3
"""Run source-level regressions on macOS. --vision also runs real CPU Vision fixtures."""
from pathlib import Path
import argparse
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / 'Sources/GimbalTracking'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--vision', action='store_true')
args = parser.parse_args()

def run(command):
    print('+ ' + ' '.join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), cwd=ROOT, check=True)

with tempfile.TemporaryDirectory(prefix='gimbal-tracking-check-') as tmp:
    build = Path(tmp)
    core = [CORE / n for n in ['ScreenFollowModels.swift', 'ScreenFollowController.swift', 'ScreenFollowStore.swift']]
    cases = ['ScreenFollowCoreSmoke', 'ScreenFollowCadenceSmoke', 'ScreenFollowSourceTimingSmoke',
             'ScreenFollowStoreSmoke', 'ScreenFollowDetectorComputeSmoke']
    if args.vision:
        cases += ['ScreenFollowVisionSmoke', 'ScreenFollowAsyncVisionSmoke']
    for case in cases:
        sources = core + ([CORE / 'ScreenFollowFaceAnalyzer.swift'] if 'Vision' in case or 'DetectorCompute' in case else [])
        binary = build / case
        run(['xcrun', 'swiftc', '-module-cache-path', build / 'cache', *sources, ROOT / 'scripts' / (case + '.swift'), '-o', binary])
        run([binary])
    for case in ['PhysicalObjectFollowSafetySmoke', 'PhysicalObjectCommandSmoke',
                 'PhysicalObjectRecoverySessionSmoke', 'PhysicalObjectSnapshotPartsSmoke', 'PhysicalObjectPartsSmoke']:
        run([sys.executable, ROOT / 'scripts' / (case + '.py'), '--output-dir', build / case])
    if args.vision:
        run([sys.executable, ROOT / 'scripts/ObjectTrackingCoordinatorSmoke.py'])
print('All requested regressions passed. Hardware and live-camera behavior are outside this suite.')
