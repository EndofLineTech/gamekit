#!/usr/bin/env python3
"""Run an isolated Wine diagnostic; never infer success from exit status alone."""

import argparse
import json
import os
from pathlib import Path
import subprocess


def assess(returncode, text, required):
    failures = [line for line in text.splitlines() if any(
        marker in line.lower() for marker in
        ("unhandled page fault", "unhandled exception", "fail ", "fail:")
    )]
    missing = [marker for marker in required if marker not in text]
    return {"ok": returncode == 0 and not failures and not missing,
            "exit_code": returncode, "failure_lines": failures, "missing_markers": missing}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wine", type=Path, required=True)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--frameworks", type=Path)
    parser.add_argument("--require", action="append", required=True)
    parser.add_argument("--trace-images", action="store_true")
    parser.add_argument("--timeout", type=int, default=90)
    args = parser.parse_args()
    if not args.wine.is_file() or not args.exe.is_file():
        parser.error("Wine and probe executables must exist")
    if not args.prefix.is_dir():
        parser.error("Create the dedicated test prefix before running the probe")
    if not args.log.parent.is_dir() or args.timeout <= 0:
        parser.error("Log parent must exist and timeout must be positive")

    env = dict(os.environ)
    for key in list(env):
        if key.startswith(("WINE", "DYLD_", "D3DM_", "ROSETTA_")):
            del env[key]
    env.update(WINEPREFIX=str(args.prefix.resolve()), WINEDEBUG="-all")
    if args.frameworks:
        frameworks = args.frameworks.resolve()
        lib = args.wine.resolve().parent.parent / "lib"
        env["DYLD_FALLBACK_LIBRARY_PATH"] = ":".join(map(str, (
            lib, frameworks, frameworks / "GStreamer.framework/Libraries")))
        env["DYLD_FALLBACK_FRAMEWORK_PATH"] = f"{lib / 'external'}:{frameworks}"
    if args.trace_images:
        env["DYLD_PRINT_LIBRARIES"] = "1"
        env["WINEDEBUG"] = "+loaddll"

    timed_out = False
    # Exclusive creation preserves prior diagnostic evidence.
    with args.log.open("x") as output:
        try:
            result = subprocess.run([str(args.wine), str(args.exe)], env=env,
                                    stdout=output, stderr=subprocess.STDOUT, timeout=args.timeout)
            returncode = result.returncode
        except subprocess.TimeoutExpired:
            timed_out = True
            returncode = None
            # Stop only processes belonging to this explicitly selected prefix.
            subprocess.run([str(args.wine.parent / "wineserver"), "-k"], env=env,
                           stdout=output, stderr=subprocess.STDOUT, timeout=15, check=False)
    report = assess(returncode, args.log.read_text(errors="replace"), args.require)
    report.update(timed_out=timed_out, log=str(args.log), prefix=str(args.prefix))
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report["ok"] else 1)


if __name__ == "__main__":
    main()
