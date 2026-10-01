#!/usr/bin/env python3
"""Build a no-clobber, explicitly unnotarized Gamekit dev-preview DMG."""

import argparse
import datetime
import json
import os
import pathlib
import re
import subprocess
import tempfile

from tools import package_local


def validate_version(tag, info):
    match = re.fullmatch(r"v(\d+\.\d+\.\d+)-dev\.(\d+)", tag)
    if not match or not 1 <= int(match.group(2)) <= 999:
        raise ValueError("Expected a numbered development prerelease tag")
    if info.get("CFBundleShortVersionString") != match.group(1) or info.get("CFBundleVersion") != str(int(match.group(2)) + 1):
        raise ValueError("The preview tag does not match the app marketing/build version")


def clean_dev_source(root):
    if package_local.command("git", "-C", str(root), "status", "--porcelain"):
        raise ValueError("Refuse to package dirty release sources")
    head = package_local.command("git", "-C", str(root), "rev-parse", "HEAD")
    dev = package_local.command("git", "-C", str(root), "rev-parse", "origin/dev")
    branch = package_local.command("git", "-C", str(root), "branch", "--show-current")
    if branch != "dev" or head != dev:
        raise ValueError("Build the preview from clean dev at origin/dev")
    return head


def prepare_payload(local_package, payload, root, tag):
    guide = root / "docs/releases" / f"{tag}-install.txt"
    notes = root / "docs/releases" / f"{tag}.md"
    if not guide.is_file() or guide.is_symlink() or not notes.is_file() or notes.is_symlink():
        raise ValueError("Missing tracked preview installation and release notes")
    if not (root / "LICENSE").is_file():
        raise ValueError("Missing Gamekit source license")
    payload.mkdir()
    package_local.command("/usr/bin/ditto", str(local_package / "Gamekit.app"), str(payload / "Gamekit.app"))
    (payload / "Applications").symlink_to("/Applications", target_is_directory=True)
    documentation = payload / "Documentation"
    documentation.mkdir()
    for entry in local_package.iterdir():
        if entry.name == "Gamekit.app":
            continue
        if entry.is_symlink():
            raise ValueError("Packaged documentation must not redirect")
        package_local.command("/usr/bin/ditto", str(entry), str(documentation / entry.name))
    package_local.command("/usr/bin/ditto", str(root / "LICENSE"), str(documentation / "LICENSE"))
    package_local.command("/usr/bin/ditto", str(guide), str(payload / "READ-ME-FIRST.txt"))
    package_local.validate_guide_links(documentation)


def verify_dmg(dmg, temporary, expected_executable_sha256):
    package_local.command("/usr/bin/hdiutil", "verify", str(dmg))
    mount = temporary / "mounted"
    mount.mkdir()
    try:
        package_local.command("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
                              "-mountpoint", str(mount), str(dmg))
        applications = mount / "Applications"
        if not applications.is_symlink() or os.readlink(applications) != "/Applications":
            raise ValueError("The mounted image must link to /Applications")
        app = mount / "Gamekit.app"
        package_local.validate_app(app)
        package_local.command("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
        if package_local.digest(app / "Contents/MacOS/Gamekit") != expected_executable_sha256:
            raise ValueError("The mounted app does not match the signed source package")
        if not (mount / "READ-ME-FIRST.txt").is_file() or not (mount / "Documentation/LICENSE").is_file():
            raise ValueError("The mounted image is missing installation or license guidance")
        package_local.validate_guide_links(mount / "Documentation")
    finally:
        if os.path.ismount(mount):
            package_local.command("/usr/bin/hdiutil", "detach", "-quiet", str(mount))


def package(app, destination, tag, root):
    package_local.validate_destination(destination)
    info = package_local.validate_app(app)
    validate_version(tag, info)
    source_commit = clean_dev_source(root)
    # This preview must never be confused with a Developer ID/notarized release.
    signature = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=2", str(app)],
                               capture_output=True, text=True, check=True)
    if "Signature=adhoc" not in signature.stderr:
        raise ValueError("The dev preview expects an ad-hoc signed app")
    notes = root / "docs/releases" / f"{tag}.md"
    with tempfile.TemporaryDirectory(prefix=".gamekit-dev-preview-", dir=destination.parent) as path:
        temporary = pathlib.Path(path)
        local_package = temporary / "source-package"
        package_local.package(app, local_package, root)
        source = json.loads((local_package / "build-manifest.json").read_text(encoding="utf-8"))
        if source["sourceDirty"] or source["sourceCommit"] != source_commit:
            raise ValueError("Packaged application and clean source revision differ")
        payload = temporary / "payload"
        prepare_payload(local_package, payload, root, tag)
        stage = temporary / "preview"
        stage.mkdir()
        dmg = stage / f"Gamekit-{tag}.dmg"
        package_local.command("/usr/bin/hdiutil", "create", "-srcfolder", str(payload),
                              "-format", "UDZO", "-volname", f"Gamekit {tag}", str(dmg))
        verify_dmg(dmg, temporary, source["executableSHA256"])
        package_local.command("/usr/bin/ditto", str(notes), str(stage / "RELEASE_NOTES.md"))
        manifest = {
            "schemaVersion": 1,
            "tag": tag,
            "status": "unnotarized development preview",
            "sourceCommit": source_commit,
            "sourceTreeSHA256": source["sourceTreeSHA256"],
            "appVersion": source["appVersion"],
            "appBuild": source["appBuild"],
            "minimumOS": source["minimumOS"],
            "architecture": source["architecture"],
            "signing": "ad-hoc",
            "notarized": False,
            "externalRuntimeBundled": False,
            "appExecutableSHA256": source["executableSHA256"],
            "dmgSHA256": package_local.digest(dmg),
            "dmgBytes": dmg.stat().st_size,
            "releaseNotesSHA256": package_local.digest(stage / "RELEASE_NOTES.md"),
            "builtAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        }
        (stage / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        package_local.validate_destination(destination)
        package_local.publish(stage, destination)
    print(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--tag", required=True)
    options = parser.parse_args()
    package(options.app, options.output, options.tag, pathlib.Path(__file__).resolve().parents[1])


if __name__ == "__main__":
    main()
