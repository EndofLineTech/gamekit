#!/usr/bin/env python3
"""Reproduce the generic, JSON-parameterized DXGI adapter with LLVM-MinGW."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

from stage_driver_trial import stamp_builtin

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not args.output.parent.is_dir() or args.output.exists():
        parser.error("Output must be new and its parent must exist")
    with tempfile.TemporaryDirectory() as temporary:
        raw = Path(temporary) / "dxgi.dll"
        subprocess.run([args.compiler, "-shared", "-O2", "-s", "-fno-strict-aliasing",
                        "-Wall", "-Wextra", "-Werror", "-Wno-cast-function-type",
                        "-DGAMEKIT_PROFILE_DRIVER", "-Wl,--no-insert-timestamp",
                        "-Wl,--image-base,0x22bf90000",
                        str(ROOT / "Sources/HelldiversDriverVersion/dxgi.c"),
                        str(ROOT / "Sources/HelldiversDriverVersion/dxgi.def"),
                        "-o", str(raw), "-ldxguid", "-luuid"], check=True, timeout=120)
        data = stamp_builtin(raw.read_bytes())
        with args.output.open("xb") as output:
            output.write(data)
    print(hashlib.sha256(data).hexdigest())


if __name__ == "__main__":
    main()
