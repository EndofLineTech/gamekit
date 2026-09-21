#!/usr/bin/env python3
"""Remove only stopped, receipt-backed disposable probe prefixes; retain evidence."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--scanner", required=True, type=Path)
    parser.add_argument("--workspace", required=True, type=Path)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("outputs", nargs="+", type=Path)
    args = parser.parse_args()
    workspace = args.workspace.resolve(strict=True)
    runtime = args.runtime.resolve(strict=True)
    candidate = json.loads((runtime / "gamekit-intake.json").read_text())["candidate"]
    subprocess.run([str(args.scanner.resolve(strict=True)), str(runtime)], check=True, timeout=15)
    targets = []
    for supplied in args.outputs:
        root = supplied.resolve(strict=True)
        if supplied.is_symlink() or root.parent != workspace or root == runtime:
            raise ValueError("Not an isolated qualification directory")
        result = json.loads((root / "result.json").read_text())
        uuid.UUID(result["session"])
        if result.get("serverWaitExit") != 0 or result.get("candidate") != candidate:
            raise ValueError("No successful server shutdown receipt")
        for name in ("prefix", "home", "tmp"):
            target = root / name
            if target.is_symlink() or (target.exists() and not target.is_dir()):
                raise ValueError("Disposable directory identity changed")
            if target.exists():
                targets.append(target)
    print(json.dumps({"apply": args.apply, "targets": [str(path) for path in targets]}, indent=2))
    if args.apply:
        subprocess.run([str(args.scanner.resolve(strict=True)), str(runtime)], check=True, timeout=15)
        for target in targets:
            shutil.rmtree(target)
        for root in {target.parent for target in targets}:
            (root / "cleanup.json").write_text(json.dumps({"prefixRemoved": True, "candidateProcesses": 0, "evidenceRetained": True}) + "\n")


if __name__ == "__main__":
    main()
