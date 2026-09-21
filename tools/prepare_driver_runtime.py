#!/usr/bin/env python3
"""Build and stage driver-version-1 beside text-input-1, without prefix edits."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from package_local import digest, publish, validate_destination
from prepare_text_input_runtime import BASE_HASHES, ARTIFACT_HASHES, DLL, require_digest
from stage_driver_trial import renamed_dxgi, stamp_builtin
from driver_profile import DEFAULT, driver_profile, header

SHIM = "Contents/SharedSupport/wine/lib/gamekit/helldivers-dxgi.dll"
ORIGINAL = "Contents/SharedSupport/wine/lib/wine/x86_64-windows/dxgm.dll"
SHIM_HASH = "5ccd55cf94faaab72dcdef651aaccc7907c3eef46d0ecb1cb0f5de204940d2b2"
ORIGINAL_HASH = "5e80d3584e304ae1258aa13a1cf12830641dc2694988e670b7c7b5749f215c5c"
ROOT = Path(__file__).resolve().parents[1]


def build(output):
    validate_destination(output)
    with tempfile.TemporaryDirectory(prefix=".driver-build-", dir=output.parent) as temporary:
        raw = Path(temporary) / "dxgi.dll"
        parameters = Path(temporary) / "parameters.h"
        header(parameters, driver_profile())
        subprocess.run(["x86_64-w64-mingw32-gcc", "-shared", "-O2", "-s", "-fno-strict-aliasing",
                        "-include", str(parameters),
                        "-Wall", "-Wextra", "-Werror", "-Wno-cast-function-type", "-Wl,--no-insert-timestamp",
                        "-Wl,--image-base,0x22bf90000",  # Pin ld's otherwise output-path-dependent preferred base.
                        str(ROOT / "Sources/HelldiversDriverVersion/dxgi.c"),
                        str(ROOT / "Sources/HelldiversDriverVersion/dxgi.def"), "-o", str(raw), "-ldxguid", "-luuid"],
                       check=True, timeout=120)
        stamped = Path(temporary) / "helldivers-dxgi.dll"
        stamped.write_bytes(stamp_builtin(raw.read_bytes()))
        require_digest(stamped, SHIM_HASH)
        publish(stamped, output)
    print("Shim SHA256:", digest(output))


def validate_source(source):
    if source.is_symlink() or not source.is_dir():
        raise ValueError("Expected text-input-1 runtime directory")
    for relative, value in BASE_HASHES.items():
        path = source / relative
        if not path.resolve().is_relative_to(source.resolve()):
            raise ValueError("Runtime component escapes source")
        require_digest(path, ARTIFACT_HASHES["msctf.dll"] if relative == DLL else value)


def prepare(source, destination, shim):
    validate_destination(destination)
    if destination.parent.absolute() != destination.parent.resolve() or destination.resolve().is_relative_to(source.resolve()):
        raise ValueError("Use a separate canonical destination")
    validate_source(source)
    require_digest(shim, SHIM_HASH)
    with tempfile.TemporaryDirectory(prefix=".driver-version-", dir=destination.parent) as temporary:
        bundle = Path(temporary) / destination.name
        subprocess.run(["/bin/cp", "-cR", str(source), str(bundle)], check=True, timeout=120)
        validate_source(bundle)
        target = bundle / SHIM
        target.parent.mkdir()  # refuse any pre-existing or redirected payload dir
        shutil.copyfile(shim, target)
        original = bundle / ORIGINAL
        with original.open("xb") as output:
            output.write(renamed_dxgi((bundle / ORIGINAL.replace("dxgm.dll", "dxgi.dll")).read_bytes()))
        (bundle / "Contents/SharedSupport/wine/lib/wine/x86_64-unix/dxgm.so").symlink_to("../../external/libd3dshared.dylib")
        require_digest(target, SHIM_HASH)
        require_digest(original, ORIGINAL_HASH)
        materials = bundle / "Contents/Resources/GamekitDriverVersionSources"
        materials.mkdir()
        for name in ("dxgi.c", "dxgi.def"):
            shutil.copyfile(ROOT / "Sources/HelldiversDriverVersion" / name, materials / name)
        shutil.copyfile(ROOT / "tools/prepare_driver_runtime.py", materials / "prepare_driver_runtime.py")
        shutil.copyfile(ROOT / "tools/driver_profile.py", materials / "driver_profile.py")
        shutil.copyfile(DEFAULT, materials / "legacy-driver-version-1.json")
        shutil.copyfile(ROOT / "docs/helldivers-driver-runtime.md", materials / "BUILD.md")
        parameters = driver_profile()
        manifest = {"schemaVersion": 1, "revision": "driver-version-1", "compatibilityVersion": ".".join(map(str, parameters["replacementVersion"])),
                    "scope": f"AppID {parameters['appId']} only; derived loader DXGI; no prefix mutation",
                    "shimSHA256": SHIM_HASH, "renamedOriginalSHA256": ORIGINAL_HASH,
                    "sourceFiles": {p.name: digest(p) for p in sorted(materials.iterdir())}}
        (materials / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        validate_source(source)
        validate_source(bundle)
        publish(bundle, destination)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-only", type=Path)
    for name in ("source", "destination", "shim"):
        parser.add_argument("--" + name, type=Path)
    args = parser.parse_args()
    if args.build_only:
        build(args.build_only)
    elif args.source and args.destination and args.shim:
        print(json.dumps(prepare(args.source, args.destination, args.shim), indent=2))
    else:
        parser.error("Supply --build-only or --source/--destination/--shim")


if __name__ == "__main__":
    main()
