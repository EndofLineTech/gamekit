"""Stage disposable backend candidates; never change the accepted runtime/prefix.

Preliminary qualification tool, not a product installer. Inputs are locally
downloaded pinned upstream archives. The resulting copies are used only by the
opt-in backend render test.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tarfile

ARCHIVES = {
    "dxmt": ("dxmt-v0.80-builtin.tar.gz", "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d", "v0.80"),
    "dxvk": ("dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz", "810b1e5caf8ce975b784fae866a130ad23fa0ea233b0e5609cbc4a45f3ef6f00", "dxvk-macOS-async-v1.10.3-20230507-repack-builtin"),
}

def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()

def member(archive, name):
    item = archive.getmember(name)
    if not item.isfile() or item.size > 128 * 1024 * 1024:
        raise ValueError("Unexpected archive member")
    return archive.extractfile(item).read()

def stage(source, artifacts, wine_archive, destination):
    if destination.exists():
        raise ValueError("Refusing to overwrite candidate directory")
    if digest(wine_archive) != "9da7ee0cbf386522f3a9906943726d9c3c125dbbd9ab120e3cde80e88d6091b2":
        raise ValueError("Wine archive digest mismatch")
    for filename, expected, _ in ARCHIVES.values():
        if digest(artifacts / filename) != expected:
            raise ValueError("Backend archive digest mismatch")
    destination.mkdir(parents=True)
    for backend, (filename, _, archive_root) in ARCHIVES.items():
        bundle = destination / backend / "Candidate.app"
        shutil.copytree(source, bundle, symlinks=True)
        modules = bundle / "Contents/SharedSupport/wine/lib/wine"
        replaced = {}
        with tarfile.open(artifacts / filename) as archive:
            for arch in ("x86_64-windows", "i386-windows"):
                names = ["d3d11.dll", "d3d10core.dll"]
                if backend == "dxmt":
                    names += ["dxgi.dll", "winemetal.dll"]
                for name in names:
                    replaced[f"{arch}/{name}"] = member(archive, f"{archive_root}/{arch}/{name}")
            if backend == "dxmt":
                replaced["x86_64-unix/winemetal.so"] = member(archive, f"{archive_root}/x86_64-unix/winemetal.so")
        if backend == "dxvk":
            # DXVK-macOS deliberately omits DXGI. Use this engine's own Wine
            # DXGI, not the D3DMetal replacement or Helldivers compatibility shim.
            with tarfile.open(wine_archive) as archive:
                for arch in ("x86_64-windows", "i386-windows"):
                    replaced[f"{arch}/dxgi.dll"] = member(archive, f"wswine.bundle/lib/wine/{arch}/dxgi.dll")
        hashes = {}
        for relative, payload in replaced.items():
            path = modules / relative
            if path.exists() or path.is_symlink():
                path.unlink()
            path.write_bytes(payload)
            hashes[str(path.relative_to(bundle))] = digest(path)
        (bundle.parent / "qualification.json").write_text(json.dumps(hashes, indent=2) + "\n")
        print(bundle)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--wine-archive", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    stage(args.source, args.artifacts, args.wine_archive, args.destination)
