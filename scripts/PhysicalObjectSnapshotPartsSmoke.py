#!/usr/bin/env python3
"""Extract the production DEBUG snapshot session and test policy/routing with explicit image doubles."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from PhysicalObjectFollowSafetySmoke import extract_block

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output-dir', type=Path, default=Path('/tmp/gimbal-snapshot-parts-smoke'))
args = parser.parse_args()
production_path = ROOT / 'Reference/KKGimbal/Camera/CameraManager/CameraManager+ObjectRecognition.swift'
production = production_path.read_text()
source = production
wrapper = extract_block(source, 'final class CMPhysicalObjectSnapshotPartsSession')
types = '\n'.join(extract_block(production, marker) for marker in [
    'struct CMPhysicalObjectMeasurement', 'final class CMPhysicalObjectPatchSession', 'struct CMPhysicalObjectFollowSafety'])
parts = extract_block(production, 'final class CMPhysicalObjectPartsSession')
continuity = extract_block(parts, 'static func continuous(')
template = (ROOT / 'scripts/PhysicalObjectSnapshotPartsSmoke.swift').read_text()
generated = template.replace('// INSERT_NATIVE_TYPES', types).replace('// INSERT_PART_CONTINUITY', continuity).replace(
    '// INSERT_SNAPSHOT_SESSION', wrapper)
args.output_dir.mkdir(parents=True, exist_ok=True)
swift = args.output_dir / 'main.swift'
swift.write_text(generated)
metadata = {'scope': 'exact production wrapper with extracted native Swift routing, part continuity and Safety',
    'not_measured': ['native Vision', 'appearance tracking', 'camera timing', 'BLE', 'physical motor behavior'],
    'source_path': str(production_path), 'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
    'wrapper_sha256': hashlib.sha256(wrapper.encode()).hexdigest(),
    'production_path': str(production_path), 'production_sha256': hashlib.sha256(production.encode()).hexdigest(),
    'fixture_sha256': hashlib.sha256(template.encode()).hexdigest(),
    'generated_sha256': hashlib.sha256(generated.encode()).hexdigest()}
with tempfile.TemporaryDirectory(prefix='snapshot-parts-build-') as temporary:
    binary = Path(temporary) / 'smoke'
    compiled = subprocess.run(['xcrun', 'swiftc', '-D', 'DEBUG', '-module-cache-path', str(Path(temporary) / 'cache'),
        str(swift), '-o', str(binary)], text=True, capture_output=True)
    (args.output_dir / 'compile.log').write_text(compiled.stdout + compiled.stderr)
    metadata['compile_exit_status'] = compiled.returncode
    if compiled.returncode:
        print(compiled.stdout + compiled.stderr)
        result_code = compiled.returncode
    else:
        result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=30)
        (args.output_dir / 'result.log').write_text(result.stdout + result.stderr)
        print(result.stdout + result.stderr, end='')
        result_code = result.returncode
    metadata['exit_status'] = result_code
(args.output_dir / 'source-evidence.json').write_text(json.dumps(metadata, indent=2) + '\n')
sys.exit(result_code)
