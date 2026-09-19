"""Isolated qualification of the researched DXVK 3.1 macOS fork and its paired MVK."""
import argparse
import json
from pathlib import Path
import subprocess
from qualify_graphics_backends import digest

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--winebuild", type=Path, required=True)
    parser.add_argument("--legacy-dlls", action="store_true", help="Keep the qualified legacy DXVK DLLs; compare only the newer MoltenVK")
    args = parser.parse_args()
    if digest(args.archive) != "8b37482116da0136b2b4feaa0118f9441bcf148b9532de474edc5a89c3e55687":
        raise ValueError("Archive digest mismatch")
    if args.output.exists():
        raise ValueError("Refusing existing candidate")
    args.output.mkdir(parents=True)
    subprocess.run(["tar", "-xf", str(args.archive), "-C", str(args.output)], check=True)
    payload = args.output / "dxvk-macos-v3.1"
    root = args.output / "fixed"
    root.mkdir()
    bundle = root / "Candidate.app"
    subprocess.run(["/bin/cp", "-cR", str(args.base / "Candidate.app"), str(bundle)], check=True)
    hashes = json.loads((args.base / "qualification.json").read_text())
    for arch in ([] if args.legacy_dlls else ["x86_64-windows", "i386-windows"]):
        for name in ["d3d11.dll", "dxgi.dll", "d3d10core.dll"]:
            relative = f"Contents/SharedSupport/wine/lib/wine/{arch}/{name}"
            target = bundle / relative
            target.unlink()
            subprocess.run(["/bin/cp", "-c", str(payload / arch / name), str(target)], check=True)
            subprocess.run([str(args.winebuild), "--builtin", str(target)], check=True)
            hashes[relative] = digest(target)
    relative = "Contents/SharedSupport/wine/lib/libMoltenVK.dylib"
    target = bundle / relative
    subprocess.run(["/bin/cp", "-c", str(payload / "libMoltenVK.dylib"), str(target)], check=True)
    hashes[relative] = digest(target)
    (root / "qualification.json").write_text(json.dumps(hashes, indent=2) + "\n")
    print(root)

if __name__ == "__main__":
    main()
