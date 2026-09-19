"""Stage the pinned DXMT query/legacy-sharing candidate beside the stock payload."""
import argparse
import json
from pathlib import Path
import shutil
from qualify_graphics_backends import digest

PINS = {
    "x86_64-windows/d3d11.dll": "08f9d86cf985b2f0310140aa0c7179b303f73dd4f82d2b9c06d622ae88ef4276",
    "x86_64-windows/dxgi.dll": "140e9d59c09de2dfddc81bfa44ffea550c2fb7f7c234c52d7efb7ee138451487",
    "i386-windows/d3d11.dll": "faae57658d3a3510ef5a2acf32f0d260a747133fe37262cc2d08ef7664688f6e",
    "i386-windows/dxgi.dll": "24db0dc467490dcd0b85b3f33c1ce64ec4a0e974f9ca859cb2fbcd5ff7e8a24b",
}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--payloads", type=Path, required=True)
    parser.add_argument("--sources-only", action="store_true", help="Attach source notices to an already verified candidate without changing DLLs")
    args = parser.parse_args()
    source = args.payloads / "dxmt-0.80-1"
    target = args.payloads / "dxmt-0.80-compat2"
    if args.payloads.resolve() != args.payloads.absolute():
        raise ValueError("Redirected destination")
    if args.sources_only:
        if target.is_symlink() or any(digest(target / name) != expected for name, expected in PINS.items()):
            raise ValueError("Installed candidate digest mismatch")
        shutil.copytree(Path(__file__).resolve().parents[1] / "Sources/DXMTCompatibility", target / "GamekitSources")
        return
    if target.exists() or target.is_symlink() or args.payloads.resolve() != args.payloads.absolute():
        raise ValueError("Refusing existing/redirected destination")
    files = {}
    for relative, expected in PINS.items():
        arch, name = relative.split("/")
        path = args.source / ("build" if arch == "x86_64-windows" else "build32") / "src" / name[:-4] / name
        if path.is_symlink() or digest(path) != expected:
            raise ValueError("Candidate module digest mismatch")
        files[relative] = path
    shutil.copytree(source, target, symlinks=True)
    for relative, path in files.items():
        destination = target / relative
        destination.unlink()
        shutil.copy2(path, destination)
    (target / "query-fix-provenance.json").write_text(json.dumps({
        "upstream": "3Shain/dxmt", "commit": "589adb780354b461645b29999cefaf533594ee99",
        "revision": "dxmt-0.80-compat2", "toolchain": "llvm-mingw-20260908-ucrt-macos-universal",
        "replacedModules": PINS,
        "unchangedUnixLibrarySHA256": "3d50d7f39c64778c71d0af2fce1cde818d09ffbce7c4f7b8ae24ae1df567c0ca",
    }, indent=2) + "\n")
    shutil.copytree(Path(__file__).resolve().parents[1] / "Sources/DXMTCompatibility", target / "GamekitSources")
    print(target)

if __name__ == "__main__":
    main()
