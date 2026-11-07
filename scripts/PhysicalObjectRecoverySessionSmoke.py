#!/usr/bin/env python3
"""Extract the recovery session and test identity-bank and proposal/commit routing, not images."""
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
production_path = ROOT / 'Reference/KKGimbal/Camera/CameraManager/CameraManager+ObjectRecognition.swift'
parser.add_argument('--source', type=Path, default=production_path)
parser.add_argument('--output-dir', type=Path, default=Path('/tmp/gimbal-recovery-session-smoke'))
args = parser.parse_args()
production = production_path.read_text()
source = args.source.read_text()
wrapper = extract_block(source, 'final class CMPhysicalObjectRecoverySession')
# Keep the real session policy; represent only platform image allocation/rendering
# with independent pixel IDs. Pixel resize/copy performance is a device check.
copy_helper = extract_block(wrapper, 'private enum TrustedPixelCopy')
tested_wrapper = wrapper.replace(copy_helper, '''private enum TrustedPixelCopy {
    static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? { CMTrustedPixelFixture.copy(source) }
}''')
types = '\n'.join(extract_block(production, marker) for marker in ['struct CMPhysicalObjectMeasurement', 'struct CMPhysicalObjectFollowSafety'])
parts = extract_block(production, 'final class CMPhysicalObjectPartsSession')
template = (ROOT / 'scripts/PhysicalObjectRecoverySessionSmoke.swift').read_text()
generated = template.replace('// INSERT_MEASUREMENT_AND_SAFETY', types).replace(
    '// INSERT_WHOLE_OBSERVATION', extract_block(parts, 'func wholeObservation(request:')).replace(
    '// INSERT_CONTINUITY', extract_block(parts, 'static func continuous(')).replace('// INSERT_RECOVERY_SESSION', tested_wrapper)
args.output_dir.mkdir(parents=True, exist_ok=True)
swift = args.output_dir / 'main.swift'
swift.write_text(generated)
metadata = {'scope': 'exact recovery session with production measurement/Safety/whole-observation/continuity helpers',
    'not_measured': ['native identity recognition', 'Vision', 'pixel geometry', 'CoreImage copy cost and buffer lifetime', 'camera age', 'BLE', 'physical motors'],
    'source_path': str(args.source), 'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
    'wrapper_sha256': hashlib.sha256(wrapper.encode()).hexdigest(),
    'production_path': str(production_path), 'production_sha256': hashlib.sha256(production.encode()).hexdigest(),
    'fixture_sha256': hashlib.sha256(template.encode()).hexdigest(),
    'generated_sha256': hashlib.sha256(generated.encode()).hexdigest()}
with tempfile.TemporaryDirectory(prefix='recovery-session-build-') as temporary:
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
