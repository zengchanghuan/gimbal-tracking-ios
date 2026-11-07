#!/usr/bin/env python3
"""Restore the exact reviewed model bytes, or verify them without networking."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
import urllib.request


def matches(path, artifact):
    if not path.is_file() or path.stat().st_size != artifact["bytes"]:
        return False
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest() == artifact["sha256"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true", help="No downloads or file changes")
    args = parser.parse_args()
    directory = Path(__file__).resolve().parent
    manifest = json.loads((directory / "models.json").read_text())
    for artifact in manifest["artifacts"]:
        destination = directory / artifact["file"]
        if matches(destination, artifact):
            print(f"OK {artifact['file']} {artifact['sha256']}")
            continue
        if args.verify_only:
            raise SystemExit(f"Missing or incorrect bytes: {destination}")
        if not artifact["url"].startswith("https://"):
            raise SystemExit("Only HTTPS model sources are supported")
        descriptor, temporary_name = tempfile.mkstemp(prefix=".model-download-", dir=directory)
        temporary_path = Path(temporary_name)
        try:
            with os.fdopen(descriptor, "wb") as target:
                with urllib.request.urlopen(artifact["url"], timeout=180) as response:
                    for block in iter(lambda: response.read(1024 * 1024), b""):
                        target.write(block)
            if not matches(temporary_path, artifact):
                raise SystemExit(f"Source content changed; refusing to install {artifact['file']}")
            os.replace(temporary_path, destination)
            print(f"Installed {artifact['file']} {artifact['sha256']}")
        finally:
            temporary_path.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
