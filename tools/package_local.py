#!/usr/bin/env python3
"""Package a built local Gamekit app, refusing overwrite and recording identity."""

import argparse
import ctypes
import datetime
import hashlib
import json
import pathlib
import os
import plistlib
import subprocess
import tempfile


def command(*arguments):
    return subprocess.check_output(arguments, text=True, stderr=subprocess.STDOUT).strip()


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def source_fingerprint(root):
    paths = []
    for name in ("App", "Sources", "tools"):
        directory = root / name
        if directory.exists():
            paths.extend(path for path in directory.rglob("*") if path.is_file() and not path.is_symlink()
                         and "__pycache__" not in path.parts)
    paths.extend(root / name for name in ("project.yml", "Package.swift", "Makefile") if (root / name).is_file())
    counter_source = root / "diagnostics/process_counters.c"
    if counter_source.is_file() and not counter_source.is_symlink():
        paths.append(counter_source)
    records = {str(path.relative_to(root)): digest(path) for path in sorted(paths)}
    return hashlib.sha256(json.dumps(records, sort_keys=True).encode()).hexdigest()


def validate_app(app):
    if app.is_symlink() or not app.is_dir():
        raise ValueError("Expected a built application directory, not a symlink")
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != "tech.endofline.gamekit" or info.get("CFBundleExecutable") != "Gamekit":
        raise ValueError("Unexpected application identity")
    binary = app / "Contents/MacOS/Gamekit"
    if binary.is_symlink() or not binary.is_file():
        raise ValueError("Expected the native Gamekit executable")
    helper = app / "Contents/Frameworks/WineGameIdentity.dylib"
    if helper.parent.is_symlink() or helper.is_symlink() or not helper.is_file():
        raise ValueError("Expected the embedded Wine game identity helper")
    counter = app / "Contents/MacOS/GamekitProcessCounters"
    if counter.parent.is_symlink() or counter.is_symlink() or not counter.is_file():
        raise ValueError("Expected the embedded read-only process counter helper")
    if (app / "Contents/SharedSupport/wine").exists():
        raise ValueError("The local package must not bundle the external Wine runtime")
    return info


def validate_destination(destination):
    if destination.exists() or destination.is_symlink():
        raise FileExistsError("Package output already exists; choose a new destination")
    if not destination.parent.is_dir():
        raise ValueError("Package parent directory must exist")


def publish(stage, destination):
    library = ctypes.CDLL(None, use_errno=True)
    rename = library.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(stage), os.fsencode(destination), 0x00000004) != 0:  # RENAME_EXCL, sys/stdio.h
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(destination))


def package(app, destination, root):
    validate_destination(destination)
    info = validate_app(app)
    command("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    binary = app / "Contents/MacOS/Gamekit"
    if command("/usr/bin/lipo", "-archs", str(binary)) != "arm64":
        raise ValueError("Expected the arm64 prototype build")
    helper = app / "Contents/Frameworks/WineGameIdentity.dylib"
    if command("/usr/bin/lipo", "-archs", str(helper)) != "x86_64":
        raise ValueError("Expected the x86_64 Wine-side identity helper")
    counter = app / "Contents/MacOS/GamekitProcessCounters"
    if command("/usr/bin/lipo", "-archs", str(counter)) != "arm64":
        raise ValueError("Expected the arm64 process counter helper")
    command(str(counter), "--self-test")
    manifest = {
        "schemaVersion": 1,
        "status": "local-candidate; release acceptance recorded separately",
        "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "appVersion": info.get("CFBundleShortVersionString"),
        "appBuild": info.get("CFBundleVersion"),
        "minimumOS": info.get("LSMinimumSystemVersion"),
        "architecture": "arm64",
        "executableSHA256": digest(binary),
        "wineIdentityHelper": {"path": "Contents/Frameworks/WineGameIdentity.dylib",
                                "architecture": "x86_64", "sha256": digest(helper)},
        "processCounterHelper": {"path": "Contents/MacOS/GamekitProcessCounters",
                                 "architecture": "arm64", "sha256": digest(counter)},
        "sourceCommit": command("git", "-C", str(root), "rev-parse", "HEAD"),
        "sourceDirty": bool(command("git", "-C", str(root), "status", "--porcelain")),
        "sourceTreeSHA256": source_fingerprint(root),
        "hostOS": command("/usr/bin/sw_vers", "-productVersion"),
        "hostOSBuild": command("/usr/bin/sw_vers", "-buildVersion"),
        "xcode": command("/usr/bin/xcodebuild", "-version"),
        "swift": command("/usr/bin/swift", "--version"),
        "xcodegen": command("xcodegen", "--version"),
        "signing": "ad-hoc; personal local execution",
        "runtimeBundled": False,
    }
    with (root / "docs/validated-versions.json").open(encoding="utf-8") as handle:
        manifest["validatedRecipe"] = json.load(handle)
    with tempfile.TemporaryDirectory(prefix=".gamekit-package-", dir=str(destination.parent)) as temporary:
        stage = pathlib.Path(temporary) / "candidate"
        stage.mkdir()
        copied = stage / "Gamekit.app"
        command("/usr/bin/ditto", str(app), str(copied))
        command("/usr/bin/codesign", "--verify", "--deep", "--strict", str(copied))
        if digest(copied / "Contents/MacOS/Gamekit") != manifest["executableSHA256"]:
            raise ValueError("Copied application identity changed")
        if digest(copied / manifest["wineIdentityHelper"]["path"]) != manifest["wineIdentityHelper"]["sha256"]:
            raise ValueError("Copied Wine identity helper changed")
        if digest(copied / manifest["processCounterHelper"]["path"]) != manifest["processCounterHelper"]["sha256"]:
            raise ValueError("Copied process counter helper changed")
        (stage / "build-manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        command("/usr/bin/ditto", str(root / "docs/user-guide.md"), str(stage / "USER-GUIDE.md"))
        for guide in ("helldivers-driver-runtime.md", "helldivers-driver-warning-research.md", "debug-performance-capture.md", "helldivers-startup-hitches.md", "per-game-graphics-backends.md", "cold-steam-game-launch.md", "graphics-backends.md", "graphics-backend-research.md"):
            command("/usr/bin/ditto", str(root / "docs" / guide), str(stage / guide))
        for source in ("DXMTCompatibility", "DXVKCompatibility"):
            command("/usr/bin/ditto", str(root / "Sources" / source), str(stage / "renderer-sources" / source))
        # A no-clobber directory move; existing output is never removed or replaced.
        validate_destination(destination)
        publish(stage, destination)
    print(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    options = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    package(options.app, options.output, root)


if __name__ == "__main__":
    main()
