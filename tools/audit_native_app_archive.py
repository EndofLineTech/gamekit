#!/usr/bin/env python3
"""Read binary architecture and plist metadata from a pinned app ZIP, without execution."""
import argparse
from collections import Counter
import json
from pathlib import Path, PurePosixPath
import plistlib
import zipfile
import tempfile
import shutil
from contextlib import ExitStack

from audit_runtime_candidate import binary_kind
from stage_runtime_candidate import digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    profile = json.loads(args.profile.read_text())
    if args.output.exists() or digest(args.archive) != profile["archiveSHA256"]:
        raise ValueError("Use matching archive and fresh report path")
    binaries, plists = [], []
    counts = Counter()
    logical = 0
    with ExitStack() as stack:
        archive = stack.enter_context(zipfile.ZipFile(args.archive))
        entries = archive.infolist()
        if len(entries) == 1 and entries[0].filename.lower().endswith(".zip"):
            if entries[0].file_size > 2 * 1024**3:
                raise ValueError("Nested ZIP exceeds intake limit")
            nested = stack.enter_context(tempfile.TemporaryFile(dir=args.output.parent))
            with archive.open(entries[0]) as source:
                shutil.copyfileobj(source, nested, 1024 * 1024)
            nested.seek(0)
            archive = stack.enter_context(zipfile.ZipFile(nested))
        for member in archive.infolist():
            path = PurePosixPath(member.filename)
            if path.is_absolute() or ".." in path.parts:
                raise ValueError("Unsafe ZIP member")
            logical += member.file_size
            if logical > 32 * 1024**3:
                raise ValueError("Archive too large")
            if member.is_dir():
                continue
            with archive.open(member) as source:
                prefix = source.read(65536)
                kind = binary_kind(prefix)
                if kind:
                    counts[kind] += 1
                    binaries.append({"path": member.filename, "kind": kind, "bytes": member.file_size})
                if path.name == "Info.plist" and member.file_size <= 65536:
                    value = plistlib.loads(prefix)
                    plists.append({"path": member.filename, "identifier": value.get("CFBundleIdentifier"),
                                   "version": value.get("CFBundleShortVersionString"), "executable": value.get("CFBundleExecutable")})
    report = {"candidate": profile["candidate"], "sha256": profile["archiveSHA256"],
              "logicalBytes": logical, "binaryCounts": dict(counts), "binaries": binaries,
              "bundles": plists, "executionPerformed": False}
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report[key] for key in ("candidate", "logicalBytes", "binaryCounts", "bundles", "executionPerformed")}, indent=2))


if __name__ == "__main__":
    main()
