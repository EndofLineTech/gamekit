"""Install pinned DXMT/DXVK modules alongside existing runtimes, without prefix edits.

Requires downloaded upstream archives and the original Sikarugir engine archive.
Existing payloads are never overwritten. Gamekit verifies every module before use.
"""
import argparse
import json
from pathlib import Path
import tarfile
from qualify_graphics_backends import ARCHIVES, digest, member

WINE_SHA256 = "9da7ee0cbf386522f3a9906943726d9c3c125dbbd9ab120e3cde80e88d6091b2"
REVISIONS = {"dxmt": "dxmt-0.80-1", "dxvk": "dxvk-macos-1.10.3-20230507-1"}

def prepare(artifacts, wine_archive, destination):
    if digest(wine_archive) != WINE_SHA256:
        raise ValueError("Wine archive digest mismatch")
    for filename, expected, _ in ARCHIVES.values():
        if digest(artifacts / filename) != expected:
            raise ValueError("Backend archive digest mismatch")
    if destination.is_symlink() or destination.resolve() != destination.absolute():
        raise ValueError("Destination must have no symlink components")
    for revision in REVISIONS.values():
        if (destination / revision).exists() or (destination / revision).is_symlink():
            raise ValueError("Refusing to replace existing backend payload")
    for backend, (filename, expected, archive_root) in ARCHIVES.items():
        root = destination / REVISIONS[backend]
        root.mkdir(parents=True, exist_ok=False)
        hashes = {}
        def write(relative, data):
            path = root / relative
            path.parent.mkdir(exist_ok=True)
            with path.open("xb") as output:
                output.write(data)
            hashes[relative] = digest(path)
        with tarfile.open(artifacts / filename) as archive:
            for arch in ["x86_64-windows", "i386-windows"]:
                for name in ["d3d11.dll", "d3d10core.dll"] + (["dxgi.dll", "winemetal.dll"] if backend == "dxmt" else []):
                    write(f"{arch}/{name}", member(archive, f"{archive_root}/{arch}/{name}"))
            if backend == "dxmt":
                write("x86_64-unix/winemetal.so", member(archive, f"{archive_root}/x86_64-unix/winemetal.so"))
        if backend == "dxvk":
            with tarfile.open(wine_archive) as archive:
                for arch in ["x86_64-windows", "i386-windows"]:
                    write(f"{arch}/dxgi.dll", member(archive, f"wswine.bundle/lib/wine/{arch}/dxgi.dll"))
        (root / "provenance.json").write_text(json.dumps({"backend": backend, "archive": filename,
            "archiveSHA256": expected, "wineArchiveSHA256": WINE_SHA256, "modules": hashes}, indent=2) + "\n")
        print(root)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--wine-archive", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    prepare(args.artifacts, args.wine_archive, args.destination)
