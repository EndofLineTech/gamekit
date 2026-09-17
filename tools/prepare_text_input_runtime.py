#!/usr/bin/env python3
"""Prepare a side-by-side local runtime revision with matching LGPL sources."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

from package_local import digest, publish, validate_destination


ENGINE = "Contents/SharedSupport/wine/"
DLL = ENGINE + "lib/wine/x86_64-windows/msctf.dll"
BASE_HASHES = {
    ENGINE + "bin/wine": "1b992a3e0bc5f2a058a24f923832aaa6e464d44766fb0ad13054797e02060d10",
    ENGINE + "bin/wineserver": "6dfe1f9d2d8a67cc6a09a57966f5ef88fd461abe7321d6fb0d4a1672e8ff0350",
    ENGINE + "lib/external/D3DMetal.framework/Versions/A/D3DMetal": "f5b56df1b8fe8b364dd9530651a3769c8aed948bd343be3b4510604d503e2bad",
    ENGINE + "lib/external/libd3dshared.dylib": "1582e7ceef7f495df4bebf7f06a49aef130233f8a2e9a8971e35affafeb76ec0",
    ENGINE + "lib/wine/x86_64-windows/d3d11.dll": "303b2bb41efa30c890e2e93d39c3d3c565c8557e069eee832f2cb8a37bd4ec26",
    ENGINE + "lib/wine/x86_64-windows/d3d12.dll": "1b7a02cb37ec6b484e2aaa76b5ec9cbb47e63aeec29dbe087d5d1589a3347cfb",
    ENGINE + "lib/wine/x86_64-windows/dxgi.dll": "522a8b37216afb09e614489d88a74118076f4d7e08d2b289df6a6eb6f3e817af",
    DLL: "0a6bfe7985f109652bb7b5ca3aebe80082c04558a6716ca1c170a45c18368aa0",
}
ARTIFACT_HASHES = {
    "msctf.dll": "bb8db266526cff89c2bc6a436482b24c632c13596c1864adb4cb2e42e58fca8b",
    "wine-10.0.tar.gz": "b3edf134a5698d55bd210f11c3ae833c943abcece75810f6aa8cbd7a9f293ff7",
    "ctffunc.idl": "b93d84a52481c5252652212bc5490ca3a50d27c675716e4621a368a519c05e30",
}


def require_digest(path, expected):
    if path.is_symlink() or not path.is_file() or digest(path) != expected:
        raise ValueError(f"Unexpected artifact: {path.name}")


def validate_base(bundle):
    if bundle.is_symlink() or not bundle.is_dir():
        raise ValueError("Expected the original runtime directory")
    for relative, expected in BASE_HASHES.items():
        path = bundle / relative
        if not path.resolve().is_relative_to(bundle.resolve()):
            raise ValueError("Runtime artifact escapes its bundle")
        require_digest(path, expected)


def prepare(source, destination, dll, archive, idl):
    validate_destination(destination)
    if destination.parent.absolute() != destination.parent.resolve():
        raise ValueError("Destination parent must be canonical")
    if destination.resolve().is_relative_to(source.resolve()):
        raise ValueError("Destination must be separate from the original runtime")
    validate_base(source)
    inputs = {"msctf.dll": dll, "wine-10.0.tar.gz": archive, "ctffunc.idl": idl}
    for name, path in inputs.items():
        require_digest(path, ARTIFACT_HASHES[name])
    root = Path(__file__).resolve().parents[1]
    patch = root / "diagnostics/wine10-msctf-backport.patch"
    require_digest(patch, "e5c0f03beba1093ae01aea456686a397278a6a0b48e93e664077d4f80c23994e")
    guide = root / "docs/helldivers-text-input-backport.md"
    with tempfile.TemporaryDirectory(prefix=".text-input-", dir=destination.parent) as stage_name:
        bundle = Path(stage_name) / destination.name
        subprocess.run(["/bin/cp", "-cR", str(source), str(bundle)], check=True, timeout=120)
        validate_base(bundle)
        # Break any copied link before replacing the component.
        (bundle / DLL).unlink()
        shutil.copyfile(dll, bundle / DLL)
        require_digest(bundle / DLL, ARTIFACT_HASHES["msctf.dll"])
        materials = bundle / "Contents/Resources/GamekitTextInputSources"
        if materials.parent.resolve() != materials.parent.absolute():
            raise ValueError("Provenance parent must not redirect")
        materials.mkdir()  # refuse pre-existing or redirected provenance material
        for name in ("wine-10.0.tar.gz", "ctffunc.idl"):
            shutil.copyfile(inputs[name], materials / name)
            require_digest(materials / name, ARTIFACT_HASHES[name])
        shutil.copyfile(patch, materials / patch.name)
        require_digest(materials / patch.name, "e5c0f03beba1093ae01aea456686a397278a6a0b48e93e664077d4f80c23994e")
        shutil.copyfile(guide, materials / "BUILD.md")
        with tarfile.open(materials / "wine-10.0.tar.gz", "r:gz") as sources:
            license_file = sources.extractfile("wine-wine-10.0/COPYING.LIB")
            if license_file is None:
                raise ValueError("Wine source license is missing")
            (materials / "COPYING.LIB").write_bytes(license_file.read())
        manifest = {
            "schemaVersion": 1,
            "componentRevision": "text-input-1",
            "baseRuntime": "Sikarugir10.0_6/D3DMetal4.0b2",
            "wineSourceCommit": "b073859675060c9211fcbccfd90e4e87520dc2c2",
            "dllSHA256": ARTIFACT_HASHES["msctf.dll"],
            "license": "LGPL-2.1-or-later",
            "sourceFiles": {item.name: digest(item) for item in sorted(materials.iterdir())},
        }
        (materials / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        # Recheck inputs at publication; the original is never modified.
        validate_base(source)
        for relative, expected in BASE_HASHES.items():
            require_digest(bundle / relative, ARTIFACT_HASHES["msctf.dll"] if relative == DLL else expected)
        publish(bundle, destination)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for argument in ("source", "destination", "dll", "archive", "idl"):
        parser.add_argument("--" + argument, type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.source, args.destination, args.dll, args.archive, args.idl), indent=2))


if __name__ == "__main__":
    main()
