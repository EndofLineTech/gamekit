#!/usr/bin/env python3
"""Read-only check that composition preserves Wine and exactly copies Apple files."""

import argparse
import hashlib
import json
from pathlib import Path


def identity(path):
    if path.is_symlink():
        return {"symlink": str(path.readlink())}
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"sha256": digest.hexdigest()}


def inventory(root):
    return {str(path.relative_to(root)): identity(path)
            for path in sorted(root.rglob("*")) if path.is_symlink() or path.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-app", type=Path, required=True)
    parser.add_argument("--overlay-lib", type=Path, required=True)
    parser.add_argument("--composed-app", type=Path, required=True)
    parser.add_argument("--lib-relative", type=Path, default=Path("Contents/Resources/wine/lib"))
    args = parser.parse_args()
    for root in (args.base_app, args.overlay_lib, args.composed_app):
        if not root.is_dir():
            parser.error(f"Missing input directory: {root}")
    base = inventory(args.base_app)
    overlay = inventory(args.overlay_lib)
    actual = inventory(args.composed_app)
    if args.lib_relative.is_absolute() or ".." in args.lib_relative.parts:
        parser.error("Library path must be relative to the runtime root")
    lib = str(args.lib_relative) + "/"
    framework = lib + "external/D3DMetal.framework/"
    # The old framework was moved aside completely; other Wine files stay intact.
    expected = {path: value for path, value in base.items() if not path.startswith(framework)}
    expected.update({lib + path: value for path, value in overlay.items()})
    mismatches = [path for path, value in expected.items() if actual.get(path) != value]
    extras = sorted(set(actual) - set(expected))
    report = {"ok": not mismatches and not extras, "base_entries": len(base),
              "overlay_entries": len(overlay), "composed_entries": len(actual),
              "mismatches": mismatches, "unexpected_entries": extras,
              "overlay_manifest": overlay}
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report["ok"] else 1)


if __name__ == "__main__":
    main()
