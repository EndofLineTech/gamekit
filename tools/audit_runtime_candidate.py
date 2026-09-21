#!/usr/bin/env python3
"""Verify a split runtime archive and inventory binary headers without executing it."""
import argparse
from collections import Counter
import fnmatch
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import struct
import subprocess
import tarfile

CPU = {0x0100000C: "arm64", 0x01000007: "x86_64", 7: "i386", 12: "arm"}
PE = {0x014C: "i386", 0x8664: "amd64-or-arm64ec", 0xAA64: "arm64", 0xA641: "arm64ec", 0xA64E: "arm64x"}


def binary_kind(data):
    if len(data) >= 8 and data[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce"):
        endian = "<" if data[0] in (0xCF, 0xCE) else ">"
        return "Mach-O:" + CPU.get(struct.unpack_from(endian + "I", data, 4)[0], "unknown")
    if len(data) >= 8 and data[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        count = struct.unpack_from(">I", data, 4)[0]
        stride = 32 if data[3] == 0xBF else 20
        if count > 32 or len(data) < 8 + count * stride:
            return "fat-or-java:unclassified"
        return "Mach-O-fat:" + ",".join(CPU.get(struct.unpack_from(">I", data, 8 + i * stride)[0], "unknown") for i in range(count))
    if len(data) >= 64 and data[:2] == b"MZ":
        offset = struct.unpack_from("<I", data, 60)[0]
        if offset + 6 <= len(data) and data[offset:offset + 4] == b"PE\0\0":
            return "PE:" + PE.get(struct.unpack_from("<H", data, offset + 4)[0], "unknown")
        return "MZ:unclassified"
    if data[:4] == b"\x7fELF":
        return "ELF"
    return None


def relative_member(name, root):
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != root:
        raise ValueError("Archive path escapes its declared root: " + name)
    return PurePosixPath(*path.parts[1:])


def inspect(stream, root, patterns, output):
    counts = Counter()
    binaries, links, selected = [], [], []
    logical = 0
    with tarfile.open(fileobj=stream, mode="r|") as archive:
        for index, member in enumerate(archive):
            if index > 150000:
                raise ValueError("Unexpected archive member count")
            if member.name == "._" + root and member.isfile() and member.size <= 1024 * 1024:
                continue  # macOS tar's top-level AppleDouble metadata, not payload.
            relative = relative_member(member.name, root)
            name = str(relative)
            if member.issym() or member.islnk():
                links.append({"path": name, "target": member.linkname, "kind": "symbolic" if member.issym() else "hard"})
                continue  # Inspection never materializes archive links.
            if member.isdir():
                continue
            if not member.isfile() or member.size > 2 * 1024**3:
                raise ValueError("Unsupported archive member: " + member.name)
            logical += member.size
            if logical > 32 * 1024**3:
                raise ValueError("Unexpected archive size")
            source = archive.extractfile(member)
            prefix = source.read(min(member.size, 65536))
            kind = binary_kind(prefix)
            if kind:
                counts[kind] += 1
                binaries.append({"path": name, "kind": kind, "bytes": member.size})
            if any(fnmatch.fnmatchcase(name, pattern) for pattern in patterns):
                if member.size > 512 * 1024**2:
                    raise ValueError("Selected inspection member too large")
                destination = output / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                with destination.open("xb") as target:
                    target.write(prefix)
                    shutil.copyfileobj(source, target, 1024 * 1024)
                selected.append(name)
    return {"logicalRegularBytes": logical, "binaryCounts": dict(counts), "binaries": binaries, "links": links, "selected": selected}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--assets", type=Path)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    profile = json.loads(args.profile.read_text())
    if profile["schemaVersion"] != 1 or args.output.exists() or not (args.assets or args.archive):
        parser.error("Use schema 1 and a fresh output directory")
    args.output.mkdir()
    archive_path = args.archive or args.output / "candidate.tar.zst"
    whole = hashlib.sha256()
    if args.archive:
        with archive_path.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                whole.update(block)
    else:
        with archive_path.open("xb") as assembled:
            for part in profile["parts"]:
                if Path(part["name"]).name != part["name"]:
                    raise ValueError("Invalid asset name")
                digest = hashlib.sha256()
                with (args.assets / part["name"]).open("rb") as source:
                    for block in iter(lambda: source.read(1024 * 1024), b""):
                        digest.update(block); whole.update(block); assembled.write(block)
                if digest.hexdigest() != part["sha256"]:
                    raise ValueError("Part digest mismatch: " + part["name"])
    if whole.hexdigest() != profile["archiveSHA256"]:
        raise ValueError("Assembled archive digest mismatch")
    with (args.output / "zstd.log").open("wb") as error:
        process = subprocess.Popen(["zstd", "--long=31", "-dc", str(archive_path)], stdout=subprocess.PIPE, stderr=error)
        try:
            report = inspect(process.stdout, profile["archiveRoot"], profile["inspectMembers"], args.output / "members")
            if process.wait(timeout=60) != 0:
                raise ValueError("Archive decompression failed")
        finally:
            process.stdout.close()
            if process.poll() is None:
                process.kill(); process.wait()
    report.update(candidate=profile["candidate"], archiveSHA256=whole.hexdigest(), executionPerformed=False)
    (args.output / "inventory.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report[key] for key in ("candidate", "archiveSHA256", "logicalRegularBytes", "binaryCounts", "executionPerformed")}, indent=2))


if __name__ == "__main__":
    main()
