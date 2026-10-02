#!/usr/bin/env python3
"""Build and export a local Developer ID archive; never handle credential secrets."""

import argparse
import datetime
import json
import pathlib
import plistlib
import re
import subprocess
import tempfile

from tools import package_local


MACH_O_MAGICS = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
                 b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe",
                 b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe"}
MODULES = "Contents/Resources/GamekitCore_GamekitCore.bundle/Contents/Resources"
MODULE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\.so\Z")
TEAM_ID = re.compile(r"[A-Z0-9]{10}\Z")


def run(*args, cwd=None):
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def digest(path):
    return package_local.digest(path)


def identity_for_team(team):
    if not TEAM_ID.fullmatch(team):
        raise ValueError("Expected a ten-character Developer ID team identifier")
    output = run("/usr/bin/security", "find-identity", "-v", "-p", "codesigning")
    identities = re.findall(r'^\s*\d+\) ([0-9A-F]{40}) "Developer ID Application: [^"\n]+ \(' + team + r'\)"$',
                            output, re.MULTILINE)
    if len(identities) != 1:
        raise ValueError("Expected exactly one valid local Developer ID Application identity for the selected team")
    return identities[0]


def clean_source(root):
    if run("git", "status", "--porcelain", cwd=root):
        raise ValueError("Distribution archive requires clean committed source")
    return run("git", "rev-parse", "HEAD", cwd=root)


def sign_profile_modules(resources, sign):
    """Sign pinned Mach-O resources and derive packaged JSON hashes from signed bytes."""
    profiles = {}
    modules = {}
    directory = resources / "LauncherProfiles"
    module_directory = resources / "RuntimeModules"
    paths = sorted(directory.glob("*.json"))
    if not paths or directory.is_symlink() or module_directory.is_symlink() or not module_directory.is_dir():
        raise ValueError("Expected contained launcher profiles and runtime modules")
    for path in paths:
        if path.is_symlink():
            raise ValueError("Launcher profile must be a regular file")
        profile = json.loads(path.read_text(encoding="utf-8"))
        profiles[path] = profile
        module = profile.get("runtimeModule")
        if module is None:
            continue
        if not isinstance(module, dict) or not isinstance(module.get("resource"), str):
            raise ValueError("Malformed runtime module profile")
        name = module["resource"]
        if not MODULE_NAME.fullmatch(name):
            raise ValueError("Invalid runtime module resource name")
        source = module_directory / name
        if source.is_symlink() or not source.is_file():
            raise ValueError("Runtime module must be a contained regular file")
        original = digest(source)
        if module.get("replacementSHA256") != original:
            raise ValueError("Runtime module does not match its JSON profile hash")
        modules[name] = source
    available = {path.name for path in module_directory.glob("*.so")}
    if available != set(modules):
        raise ValueError("unreferenced or missing runtime module resource")
    evidence = {}
    for name, source in sorted(modules.items()):
        original = digest(source)
        sign(source)
        signed = digest(source)
        if signed == original:
            raise ValueError("Module signing did not change the ad-hoc source bytes")
        evidence[name] = {"sourceSHA256": original, "signedSHA256": signed}
    for path, profile in profiles.items():
        module = profile.get("runtimeModule")
        if module is not None:
            module["replacementSHA256"] = evidence[module["resource"]]["signedSHA256"]
            path.write_text(json.dumps(profile, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return evidence


def sync_export_profiles(resources, evidence):
    """Xcode re-signs nested Mach-O on export: re-pin the actual exported bytes."""
    profiles = {}
    seen = set()
    if not evidence or (resources / "LauncherProfiles").is_symlink() or (resources / "RuntimeModules").is_symlink():
        raise ValueError("Expected contained signed modules and launcher profiles")
    for path in sorted((resources / "LauncherProfiles").glob("*.json")):
        if path.is_symlink():
            raise ValueError("Launcher profile must be a regular file")
        profile = json.loads(path.read_text(encoding="utf-8"))
        module = profile.get("runtimeModule")
        if module is not None:
            if not isinstance(module, dict) or module.get("resource") not in evidence:
                raise ValueError("Unexpected exported runtime module")
            if module.get("replacementSHA256") != evidence[module["resource"]]["signedSHA256"]:
                raise ValueError("Export profile differs from archive-signed module")
            seen.add(module["resource"])
        profiles[path] = profile
    if seen != set(evidence):
        raise ValueError("Export lost a launcher profile for a signed module")
    result = {}
    for name, receipt in sorted(evidence.items()):
        if not MODULE_NAME.fullmatch(name):
            raise ValueError("Invalid runtime module resource name")
        path = resources / "RuntimeModules" / name
        if path.is_symlink() or not path.is_file():
            raise ValueError("Exported module must be a regular file")
        result[name] = {**receipt, "exportedSHA256": digest(path)}
    for path, profile in profiles.items():
        module = profile.get("runtimeModule")
        if module is not None:
            module["replacementSHA256"] = result[module["resource"]]["exportedSHA256"]
            path.write_text(json.dumps(profile, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return result


def mach_o_files(app):
    contents = app / "Contents"
    result = set()
    for path in contents.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as binary:
            if binary.read(4) in MACH_O_MAGICS:
                result.add(str(path.relative_to(app)))
    return result


def signature_details(path, team, *, executable):
    detail = subprocess.run(("/usr/bin/codesign", "-dv", "--verbose=4", str(path)),
                            check=True, capture_output=True, text=True).stderr
    if ("Signature=adhoc" in detail or f"TeamIdentifier={team}" not in detail
            or f"Authority=Developer ID Application: " not in detail
            or f"({team})" not in detail or "Timestamp=" not in detail):
        raise ValueError("Missing Developer ID Application team or secure timestamp")
    if executable and "flags=0x10000(runtime)" not in detail:
        raise ValueError("Executable is missing Hardened Runtime")
    entitlements = subprocess.run(("/usr/bin/codesign", "-d", "--entitlements", "-", str(path)),
                                  check=True, capture_output=True, text=True).stdout
    if "get-task-allow" in entitlements or "com.apple.security.cs." in entitlements:
        raise ValueError("Unsupported shipping entitlement")
    if not executable and "[Dict]" in entitlements:
        raise ValueError("Library has executable entitlements")
    return detail


def verify_app(app, team, module_names):
    package_local.validate_app(app)
    resources = app / MODULES
    expected = {"Contents/MacOS/Gamekit", "Contents/MacOS/GamekitProcessCounters",
                "Contents/Frameworks/WineGameIdentity.dylib"}
    expected.update(f"{MODULES}/RuntimeModules/{name}" for name in module_names)
    if mach_o_files(app) != expected:
        raise ValueError("Unexpected or missing shipped Mach-O code")
    for relative in sorted(expected):
        signature_details(app / relative, team, executable=relative.startswith("Contents/MacOS/"))
        run("/usr/bin/codesign", "--verify", "--strict", str(app / relative))
        architecture = "arm64" if relative.startswith("Contents/MacOS/") else "x86_64"
        if run("/usr/bin/lipo", "-archs", str(app / relative)) != architecture:
            raise ValueError("Unexpected architecture in signed code")
    for path in (resources / "LauncherProfiles").glob("*.json"):
        module = json.loads(path.read_text(encoding="utf-8")).get("runtimeModule")
        if module is not None:
            name = module["resource"]
            if name not in module_names or digest(resources / "RuntimeModules" / name) != module["replacementSHA256"]:
                raise ValueError("Packaged launcher JSON does not pin its signed module")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    run(str(app / "Contents/MacOS/GamekitProcessCounters"), "--self-test")


def finalize_archive(archive, exported, options, root, team, identity):
    app = archive / "Products/Applications/Gamekit.app"
    package_local.validate_app(app)
    resources = app / MODULES

    def sign_module(path):
        run("/usr/bin/codesign", "--force", "--sign", identity, "--timestamp", str(path))
        signature_details(path, team, executable=False)

    modules = sign_profile_modules(resources, sign_module)
    run("/usr/bin/codesign", "--force", "--sign", identity, "--timestamp", "--options", "runtime", str(app))
    verify_app(app, team, modules)
    run("/usr/bin/xcodebuild", "-exportArchive", "-archivePath", str(archive),
        "-exportOptionsPlist", str(options), "-exportPath", str(exported), cwd=root)
    finished = exported / "Gamekit.app"
    package_local.validate_app(finished)
    archive_profiles = resources / "LauncherProfiles"
    exported_profiles = finished / MODULES / "LauncherProfiles"
    if ({p.name: json.loads(p.read_text(encoding="utf-8")) for p in archive_profiles.glob("*.json")}
            != {p.name: json.loads(p.read_text(encoding="utf-8")) for p in exported_profiles.glob("*.json")}):
        raise ValueError("Xcode export changed launcher execution parameters")
    for name in modules:
        signature_details(finished / MODULES / "RuntimeModules" / name, team, executable=False)
    export_modules = sync_export_profiles(finished / MODULES, modules)
    run("/usr/bin/codesign", "--force", "--sign", identity, "--timestamp", "--options", "runtime", str(finished))
    verify_app(finished, team, export_modules)
    return finished, export_modules


def export(root, output, team):
    package_local.validate_destination(output)
    commit = clean_source(root)
    identity = identity_for_team(team)
    with tempfile.TemporaryDirectory(prefix=".gamekit-developer-id-", dir=output.parent) as temporary:
        stage = pathlib.Path(temporary)
        archive = stage / "Gamekit.xcarchive"
        exported = stage / "export"
        options = stage / "ExportOptions.plist"
        options.write_bytes(plistlib.dumps({"method": "developer-id", "destination": "export",
                                           "signingStyle": "manual", "signingCertificate": identity, "teamID": team}))
        run("xcodegen", "generate", "--spec", "project.yml", cwd=root)
        run("/usr/bin/xcodebuild", "-project", "Gamekit.xcodeproj", "-scheme", "Gamekit",
            "-configuration", "Distribution", "-destination", "platform=macOS,arch=arm64",
            "-derivedDataPath", str(stage / "derived"), "-archivePath", str(archive),
            f"GAMEKIT_DISTRIBUTION_TEAM={team}", "archive", cwd=root)
        finished, modules = finalize_archive(archive, exported, options, root, team, identity)
        if clean_source(root) != commit:
            raise ValueError("Source changed while building the distribution candidate")
        manifest = {"schemaVersion": 1, "status": "Developer ID candidate; notarization and runtime acceptance pending",
                    "sourceCommit": commit, "sourceTreeSHA256": package_local.source_fingerprint(root), "teamID": team,
                    "shippedCodeSHA256": {str(path.relative_to(finished)): digest(path) for path in sorted(
                        (finished / relative for relative in mach_o_files(finished)), key=str)},
                    "signedModules": modules, "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    "runtimeBundled": False, "notarized": False}
        (exported / "signing-manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        package_local.publish(exported, output)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--team", required=True, help="Local Developer ID Application team identifier")
    options = parser.parse_args()
    print(export(pathlib.Path(__file__).resolve().parents[1], options.output.resolve(), options.team))


if __name__ == "__main__":
    main()
