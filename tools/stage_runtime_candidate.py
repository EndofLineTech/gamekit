#!/usr/bin/env python3
"""Stage a hash-pinned candidate in a fresh directory; never run vendor installers."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import shutil
import subprocess
import tarfile

from audit_runtime_candidate import relative_member


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def safe_link(path, target, hard=False):
    if PurePosixPath(target).is_absolute():
        raise ValueError("Absolute archive link")
    resolved = posixpath.normpath(target if hard else posixpath.join(str(path.parent), target))
    if resolved == ".." or resolved.startswith("../"):
        raise ValueError("Archive link escapes candidate")
    return PurePosixPath(resolved)


def extract(stream, archive_root, output):
    links, regular = [], set()
    total = 0
    with tarfile.open(fileobj=stream, mode="r|") as archive:
        for index, member in enumerate(archive):
            if index > 150000:
                raise ValueError("Too many archive members")
            if member.name == "._" + archive_root and member.isfile() and member.size <= 1024 * 1024:
                continue
            relative = relative_member(member.name, archive_root)
            if any(part.startswith("._") for part in relative.parts):
                continue  # Finder metadata does not participate in execution.
            destination = output / relative
            if member.issym() or member.islnk():
                target = str(relative_member(member.linkname, archive_root)) if member.islnk() else member.linkname
                safe_link(relative, target, member.islnk())
                links.append((relative, target, member.islnk()))
            elif member.isdir():
                destination.mkdir(parents=True, exist_ok=True)
            elif member.isfile() and member.size <= 2 * 1024**3:
                total += member.size
                if total > 32 * 1024**3:
                    raise ValueError("Candidate exceeds extraction budget")
                destination.parent.mkdir(parents=True, exist_ok=True)
                with destination.open("xb") as target:
                    shutil.copyfileobj(archive.extractfile(member), target, 1024 * 1024)
                destination.chmod(member.mode & 0o777)  # Never restore privilege bits.
                regular.add(str(relative))
            else:
                raise ValueError("Unsupported archive member")
    # No link exists while archive content is being written. Parents of links
    # must also be ordinary directories, preventing symlink-chain escapes.
    for relative, target, hard in sorted(links, key=lambda item: len(item[0].parts), reverse=True):
        destination = output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists() or destination.is_symlink():
            raise ValueError("Link conflicts with archive content")
        if hard:
            if target not in regular:
                raise ValueError("Hard link is not to a regular archived file")
            os.link(output / target, destination, follow_symlinks=False)
        else:
            destination.symlink_to(target)
    for relative, _, _ in links:
        if not (output / relative).resolve().is_relative_to(output.resolve()):
            raise ValueError("Resolved link escapes candidate")
    return total, len(regular), len(links)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True, type=Path)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    profile = json.loads(args.profile.read_text())
    if args.output.exists() or args.output.is_symlink() or not args.output.parent.is_dir():
        parser.error("Use a fresh output beside an existing parent")
    if digest(args.archive) != profile["archiveSHA256"]:
        raise ValueError("Archive digest mismatch")
    if shutil.disk_usage(args.output.parent).free < 20 * 1024**3:
        raise ValueError("Insufficient isolated-staging headroom")
    args.output.mkdir()
    process = subprocess.Popen(["zstd", "--long=31", "-dc", str(args.archive)], stdout=subprocess.PIPE)
    try:
        total, files, links = extract(process.stdout, profile["archiveRoot"], args.output)
        if process.wait(timeout=60):
            raise ValueError("Decompression failed")
    finally:
        process.stdout.close()
        if process.poll() is None:
            process.kill(); process.wait()
    verified = 0
    for line in (args.output / "metadata/SHA256SUMS").read_text().splitlines():
        expected, name = line.split("  ", 1)
        path = args.output / name
        if not path.resolve().is_relative_to(args.output.resolve()) or not path.is_file() or digest(path) != expected:
            raise ValueError("Payload receipt mismatch: " + name)
        verified += 1
    receipt = {"candidate": profile["candidate"], "archiveSHA256": profile["archiveSHA256"],
               "regularBytes": total, "regularFiles": files, "links": links, "verifiedFiles": verified,
               "installerExecuted": False, "binaryExecuted": False}
    (args.output / "gamekit-intake.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
