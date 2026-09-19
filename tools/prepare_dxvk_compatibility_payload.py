"""Stage the pinned DXVK query-completion fix alongside its original payload."""
import argparse
import json
from pathlib import Path
import shutil
from qualify_graphics_backends import digest

PINS = {
    "x86_64-windows/d3d11.dll": "82ec183f211309cd0852898aa4ec377884abb8175021f3ba3118e0b0433724e3",
    "x86_64-windows/d3d10core.dll": "57bda05c9ea6dcb167831b7d83b464a90b8645aeccbda39acc53c9ee59d61404",
    "i386-windows/d3d11.dll": "363728dcf294d4e1a145ecee5c361ed3d7f6d0591d96036fb56f7b36d7636920",
    "i386-windows/d3d10core.dll": "17bcdb55448bc0db4f830bdb34c21398a25ca4b75613c804ee9fcc82a8fc2a79",
}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--payloads", type=Path, required=True)
    args = parser.parse_args()
    source = args.payloads / "dxvk-macos-1.10.3-20230507-1"
    target = args.payloads / "dxvk-macos-1.10.3-compat2"
    if target.exists() or target.is_symlink() or args.payloads.resolve() != args.payloads.absolute():
        raise ValueError("Refusing existing/redirected destination")
    files = {}
    for relative, expected in PINS.items():
        arch, name = relative.split("/")
        path = args.source / ("build" if arch == "x86_64-windows" else "build32") / "src" / ("d3d11" if name == "d3d11.dll" else "d3d10") / name
        if path.is_symlink() or digest(path) != expected:
            raise ValueError("Candidate module digest mismatch")
        files[relative] = path
    shutil.copytree(source, target, symlinks=True)
    for relative, path in files.items():
        destination = target / relative
        destination.unlink()
        shutil.copy2(path, destination)
    (target / "query-fix-provenance.json").write_text(json.dumps({
        "upstream": "Gcenx/DXVK-macOS", "commit": "8f1e28deed3ad30802f7e1bdff428ec14e6e7817",
        "revision": "dxvk-macos-1.10.3-compat2", "replacedModules": PINS,
    }, indent=2) + "\n")
    shutil.copytree(Path(__file__).resolve().parents[1] / "Sources/DXVKCompatibility", target / "GamekitSources")
    print(target)

if __name__ == "__main__":
    main()
