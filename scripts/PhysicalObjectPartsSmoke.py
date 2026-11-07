#!/usr/bin/env python3
"""Test the extracted DEBUG part-fusion policy; this does not measure image tracking."""
import argparse
import json
from pathlib import Path
import tempfile
import PhysicalObjectFollowSafetySmoke as harness

ROOT = Path(__file__).resolve().parents[1]
harness.FIXTURE = ROOT / 'scripts/PhysicalObjectPartsSmoke.swift'
original_extract = harness.extract_block

def fusion_source(source, marker):
    session = original_extract(source, 'final class CMPhysicalObjectPartsSession')
    observation = original_extract(session, 'struct Observation')
    fuse = '\n'.join(original_extract(session, marker) for marker in ['static func project(', 'static func permitsSinglePart(', 'static func continuous(', 'static func fuse('])
    return 'enum CMPhysicalObjectPartsSession {\n' + observation + '\n' + fuse + '\n}'

harness.extract_block = fusion_source

def run(directory):
    harness.run(directory)
    evidence = directory / 'source-evidence.json'
    metadata = json.loads(evidence.read_text())
    metadata['scope'] = 'extracted DEBUG part fusion with synthetic geometry and confidence observations'
    metadata['not_measured'] = ['foreground segmentation', 'native Vision', 'camera timing', 'BLE', 'physical motor behavior']
    evidence.write_text(json.dumps(metadata, indent=2) + '\n')

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output-dir', type=Path)
args = parser.parse_args()
if args.output_dir:
    run(args.output_dir.resolve())
else:
    with tempfile.TemporaryDirectory(prefix='physical-parts-smoke-') as temporary:
        run(Path(temporary))
