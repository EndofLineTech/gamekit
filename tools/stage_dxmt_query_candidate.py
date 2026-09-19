"""Snapshot rebuilt PE modules or stage them into a disposable qualified runtime."""
import argparse
import json
from pathlib import Path
import shutil
from qualify_graphics_backends import digest

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--base-candidate", type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError("Refusing to overwrite a candidate")
    files = {name: args.build / f"src/{name}/{name}.dll" for name in ["d3d11", "dxgi"]}
    for path in files.values():
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 128 * 1024 * 1024:
            raise ValueError("Unexpected rebuilt module")
    args.output.mkdir(parents=True)
    if args.base_candidate:
        hashes = json.loads((args.base_candidate / "qualification.json").read_text())
        bundle = args.output / "Candidate.app"
        shutil.copytree(args.base_candidate / "Candidate.app", bundle, symlinks=True)
        for name, source in files.items():
            relative = f"Contents/SharedSupport/wine/lib/wine/x86_64-windows/{name}.dll"
            target = bundle / relative
            target.unlink()
            shutil.copy2(source, target)
            hashes[relative] = digest(target)
        (args.output / "qualification.json").write_text(json.dumps(hashes, indent=2) + "\n")
    else:
        for name, source in files.items():
            target = args.output / f"src/{name}/{name}.dll"
            target.parent.mkdir(parents=True)
            shutil.copy2(source, target)
    print(args.output)

if __name__ == "__main__":
    main()
