#!/usr/bin/env python3
"""Privately rehearse a notarized DMG using only a local Keychain profile."""

import argparse
import datetime
import json
import os
import pathlib
import re
import tempfile
import uuid

from tools import export_developer_id, package_local


def validate_version(tag, info):
    match = re.fullmatch(r"v(\d+\.\d+\.\d+)", tag)
    if not match or info.get("CFBundleShortVersionString") != match.group(1):
        raise ValueError("Expected a stable tag matching the app marketing version")


def validate_notary_result(submission, log):
    try:
        identifier = str(uuid.UUID(submission["id"]))
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError("Missing valid notary submission ID") from error
    if (submission.get("status") != "Accepted" or log.get("status") != "Accepted"
            or str(log.get("jobId", "")).lower() != identifier
            or log.get("issues") not in (None, [])):
        raise ValueError("Notary submission rejected, incomplete or contains unresolved warnings/issues")
    return identifier


def write_rehearsal_notice(path, tag):
    path.write_text(
        f"Gamekit {tag} — PRIVATE REHEARSAL; not approved for public distribution.\n\n"
        "On macOS 27 Apple silicon, open the DMG and drag Gamekit.app to Applications.\n"
        "Documentation/USER-GUIDE.md describes an earlier ad-hoc local candidate;\n"
        "its installation/signing claims are not final signed-release guidance.\n"
        "Sikarugir Wine/template and Apple D3DMetal are separately user-obtained.\n"
        "Steam and Ubisoft Connect installers, clients and games are not included;\n"
        "Gamekit retrieves the installers from their vendors during setup.\n"
        "This ticketed artifact needs clean-Mac Gatekeeper and real gameplay acceptance\n"
        "plus an artifact-specific owner GO before any public release.\n", encoding="utf-8")


def submit_and_review(path, log_path, keychain_profile):
    response = json.loads(export_developer_id.run("/usr/bin/xcrun", "notarytool", "submit", str(path),
        "--keychain-profile", keychain_profile, "--wait", "--timeout", "1h", "--output-format", "json"))
    try:
        submission_id = str(uuid.UUID(response["id"]))
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError("Notary service returned no usable submission ID") from error
    export_developer_id.run("/usr/bin/xcrun", "notarytool", "log", submission_id, str(log_path),
                            "--keychain-profile", keychain_profile)
    log = json.loads(log_path.read_text(encoding="utf-8"))
    validate_notary_result(response, log)
    return submission_id


def verify_ticketed_app(app, team, modules):
    export_developer_id.verify_app(app, team, modules)
    export_developer_id.run("/usr/bin/xcrun", "stapler", "validate", str(app))
    export_developer_id.run("/usr/sbin/spctl", "--assess", "--type", "execute", str(app))


def prepare_payload(signed_app, payload, root, tag, team, modules):
    if not (root / "LICENSE").is_file():
        raise ValueError("Source license is missing")
    payload.mkdir()
    package_local.command("/usr/bin/ditto", str(signed_app), str(payload / "Gamekit.app"))
    verify_ticketed_app(payload / "Gamekit.app", team, modules)
    (payload / "Applications").symlink_to("/Applications", target_is_directory=True)
    docs = payload / "Documentation"
    docs.mkdir()
    package_local.copy_documentation(docs, root)
    package_local.command("/usr/bin/ditto", str(root / "LICENSE"), str(docs / "LICENSE"))
    write_rehearsal_notice(payload / "READ-ME-FIRST.txt", tag)
    package_local.validate_guide_links(docs)


def verify_mounted_dmg(dmg, temporary, signed_app, team, modules):
    export_developer_id.run("/usr/bin/hdiutil", "verify", str(dmg))
    mount = temporary / "mounted"
    mount.mkdir()
    try:
        export_developer_id.run("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
                                "-mountpoint", str(mount), str(dmg))
        link = mount / "Applications"
        if not link.is_symlink() or os.readlink(link) != "/Applications":
            raise ValueError("DMG has no safe Applications shortcut")
        app = mount / "Gamekit.app"
        verify_ticketed_app(app, team, modules)
        if not (mount / "READ-ME-FIRST.txt").is_file() or not (mount / "Documentation/LICENSE").is_file():
            raise ValueError("DMG is missing rehearsal or license guidance")
        package_local.validate_guide_links(mount / "Documentation")
        for relative in export_developer_id.mach_o_files(signed_app):
            if package_local.digest(app / relative) != package_local.digest(signed_app / relative):
                raise ValueError("Mounted signed code differs from stapled source app")
    finally:
        if os.path.ismount(mount):
            export_developer_id.run("/usr/bin/hdiutil", "detach", "-quiet", str(mount))


def rehearse(root, output, tag, team, keychain_profile):
    package_local.validate_destination(output)
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ValueError("Expected a stable release tag for private rehearsal")
    if not keychain_profile or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", keychain_profile):
        raise ValueError("Expected a named local notarytool Keychain profile")
    source = export_developer_id.clean_source(root)
    with tempfile.TemporaryDirectory(prefix=".gamekit-notarized-", dir=output.parent) as name:
        temporary = pathlib.Path(name)
        signed = temporary / "signed"
        export_developer_id.export(root, signed, team)
        signed_manifest = json.loads((signed / "signing-manifest.json").read_text(encoding="utf-8"))
        if signed_manifest["sourceCommit"] != source or signed_manifest["teamID"] != team:
            raise ValueError("Signing source or team changed")
        app = signed / "Gamekit.app"
        validate_version(tag, package_local.validate_app(app))
        modules = signed_manifest["signedModules"]
        export_developer_id.verify_app(app, team, modules)
        upload = temporary / "Gamekit.zip"
        export_developer_id.run("/usr/bin/ditto", "-c", "-k", "--keepParent", str(app), str(upload))
        stage = temporary / "rehearsal"
        stage.mkdir()
        app_id = submit_and_review(upload, stage / "app-notary-log.json", keychain_profile)
        export_developer_id.run("/usr/bin/xcrun", "stapler", "staple", str(app))
        verify_ticketed_app(app, team, modules)
        payload = temporary / "payload"
        prepare_payload(app, payload, root, tag, team, modules)
        dmg = stage / f"Gamekit-{tag}-rehearsal.dmg"
        export_developer_id.run("/usr/bin/hdiutil", "create", "-srcfolder", str(payload), "-format", "UDZO",
                                "-volname", f"Gamekit {tag} rehearsal", str(dmg))
        dmg_id = submit_and_review(dmg, stage / "dmg-notary-log.json", keychain_profile)
        export_developer_id.run("/usr/bin/xcrun", "stapler", "staple", str(dmg))
        export_developer_id.run("/usr/bin/xcrun", "stapler", "validate", str(dmg))
        verify_mounted_dmg(dmg, temporary, app, team, modules)
        if export_developer_id.clean_source(root) != source:
            raise ValueError("Source changed during notarization rehearsal")
        manifest = {"schemaVersion": 1, "status": "private notarized rehearsal; public acceptance pending",
                    "tagCandidate": tag, "sourceCommit": source, "sourceTreeSHA256": signed_manifest["sourceTreeSHA256"],
                    "teamID": team, "signing": "Developer ID Application; Hardened Runtime on executables; secure timestamps",
                    "appSubmissionID": app_id, "dmgSubmissionID": dmg_id,
                    "appNotaryLog": "app-notary-log.json", "dmgNotaryLog": "dmg-notary-log.json",
                    "notaryWarnings": 0, "appStapled": True, "dmgStapled": True,
                    "shippedCodeSHA256": {relative: package_local.digest(app / relative) for relative in sorted(
                        export_developer_id.mach_o_files(app))},
                    "dmgSHA256": package_local.digest(dmg), "dmgBytes": dmg.stat().st_size,
                    "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    "runtimeBundled": False, "vendorClientsBundled": False, "publicReleaseApproved": False}
        (stage / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        package_local.validate_destination(output)
        package_local.publish(stage, output)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--team", required=True)
    parser.add_argument("--keychain-profile", required=True)
    options = parser.parse_args()
    print(rehearse(pathlib.Path(__file__).resolve().parents[1], options.output.resolve(), options.tag,
                   options.team, options.keychain_profile))


if __name__ == "__main__":
    main()
