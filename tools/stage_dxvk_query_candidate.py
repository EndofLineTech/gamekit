"""Stage rebuilt DXVK PE modules into an isolated paired-MoltenVK runtime."""
import argparse
import json
from pathlib import Path
import subprocess
from qualify_graphics_backends import digest

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--winebuild", type=Path, required=True)
    parser.add_argument("--arch", choices=["x64", "x86"], default="x64")
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError("Refusing existing candidate")
    args.output.mkdir(parents=True)
    bundle = args.output / "Candidate.app"
    subprocess.run(["/bin/cp", "-cR", str(args.base / "Candidate.app"), str(bundle)], check=True)
    hashes = json.loads((args.base / "qualification.json").read_text())
    for directory, name in [("d3d11", "d3d11.dll"), ("d3d10", "d3d10core.dll")]:
        relative = "Contents/SharedSupport/wine/lib/wine/" + ("x86_64-windows" if args.arch == "x64" else "i386-windows") + "/" + name
        target = bundle / relative
        target.unlink()
        subprocess.run(["/bin/cp", "-c", str(args.build / "src" / directory / name), str(target)], check=True)
        subprocess.run([str(args.winebuild), "--builtin", str(target)], check=True)
        hashes[relative] = digest(target)
    relative = "Contents/SharedSupport/wine/lib/libMoltenVK.dylib"
    target = bundle / relative
    subprocess.run(["/bin/cp", "-c", str(bundle / "Contents/Frameworks/moltenvkcx/libMoltenVK.dylib"), str(target)], check=True)
    hashes[relative] = digest(target)
    (args.output / "qualification.json").write_text(json.dumps(hashes, indent=2) + "\n")

if __name__ == "__main__":
    main()
