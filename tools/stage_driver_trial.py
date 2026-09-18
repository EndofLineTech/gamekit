"""Stage a compiled DXGI trial only in an already cloned, stopped experiment.

No game files are patched. Apple's cloned DXGI gets a separate module name;
all writes use new inodes so no existing hard-linked DLL is modified in place.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct

ORIGINAL = "522a8b37216afb09e614489d88a74118076f4d7e08d2b289df6a6eb6f3e817af"
RELATIVE = "Contents/SharedSupport/wine/lib/wine/x86_64-windows/"


def renamed_dxgi(data, old=b"dxgi.dll\0", new=b"dxgm.dll\0"):
    data = bytearray(data)
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise ValueError("not PE")
    optional = pe + 24
    if struct.unpack_from("<H", data, optional)[0] != 0x20B:
        raise ValueError("not PE32+")
    sections = struct.unpack_from("<H", data, pe + 6)[0]
    table = optional + struct.unpack_from("<H", data, pe + 20)[0]

    def offset(rva):
        for index in range(sections):
            size, va, raw_size, raw = struct.unpack_from("<IIII", data, table + 40 * index + 8)
            if va <= rva < va + min(size, raw_size):
                result = raw + rva - va
                if result >= len(data):
                    break
                return result
        raise ValueError("RVA outside file-backed section")

    exports = offset(struct.unpack_from("<I", data, optional + 112)[0])
    name = offset(struct.unpack_from("<I", data, exports + 12)[0])
    if data[name:name + 9] != old or len(new) != len(old):
        raise ValueError("unexpected export module name")
    data[name:name + 9] = new
    return bytes(data)


def stamp_builtin(data):
    data = bytearray(data)
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if pe < 0x60 or data[pe:pe + 4] != b"PE\0\0":
        raise ValueError("PE overlaps builtin marker or invalid signature")
    data[0x40:0x60] = b"Wine builtin DLL" + bytes(16)
    return bytes(data)


def fresh_write(path, data):
    temporary = path.with_name(path.name + ".trial-new")
    with temporary.open("xb") as output:
        output.write(data)
    os.replace(temporary, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("shim", type=Path)
    parser.add_argument("--per-game-native", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    # Deliberately restricted to this experiment, never a production bundle.
    if root.name != "p92-driver-experiment" or root.parent.name != ".build":
        raise ValueError("not the designated private experiment")
    manifest = root / "trial-hashes.json"
    if manifest.exists() and not args.per_game_native:
        raise ValueError("already staged")
    if (root / "Gamekit/Metadata/Lifecycle/steam.json").exists():
        raise ValueError("Steam receipt still present; stop the experiment first")
    runtime = root / "Runtime.app"
    dll = runtime / RELATIVE / "dxgi.dll"
    if args.per_game_native:
        renamed = (runtime / RELATIVE / "dxgm.dll").read_bytes()
        original = renamed_dxgi(renamed, b"dxgm.dll\0", b"dxgi.dll\0")
        if hashlib.sha256(original).hexdigest() != ORIGINAL:
            raise ValueError("renamed original cannot be verified")
        fresh_write(dll, original)
        fresh_write(root / "Gamekit/Environments/steam/drive_c/windows/system32/dxgi.dll", args.shim.read_bytes())
        fresh_write(manifest, json.dumps({RELATIVE + "dxgi.dll": ORIGINAL,
            RELATIVE + "dxgm.dll": hashlib.sha256(renamed).hexdigest()}, indent=2).encode() + b"\n")
        launchers = root / "Gamekit/Launchers"
        if launchers.exists():
            archive = root / "Launchers-builtin-trial"
            if archive.exists():
                raise ValueError("launcher archive already exists")
            launchers.rename(archive)
        print("Runtime DXGI restored; native shim staged in cloned prefix for explicit per-app overrides")
        return
    original = dll.read_bytes()
    if hashlib.sha256(original).hexdigest() != ORIGINAL:
        raise ValueError("unexpected original DXGI")
    renamed = renamed_dxgi(original)
    shim = stamp_builtin(args.shim.read_bytes())
    prefix = root / "Gamekit/Environments/steam/drive_c/windows/system32"
    for directory in (runtime / RELATIVE, prefix):
        if directory.resolve().is_relative_to(root) is False:
            raise ValueError("directory escaped trial")
        if (directory / "dxgm.dll").exists():
            raise ValueError("renamed module already exists")
        fresh_write(directory / "dxgm.dll", renamed)
        fresh_write(directory / "dxgi.dll", shim)
    unix = runtime / "Contents/SharedSupport/wine/lib/wine/x86_64-unix"
    (unix / "dxgm.so").symlink_to("../../external/libd3dshared.dylib")
    hashes = {RELATIVE + name: hashlib.sha256(data).hexdigest()
              for name, data in (("dxgi.dll", shim), ("dxgm.dll", renamed))}
    fresh_write(manifest, json.dumps(hashes, indent=2).encode() + b"\n")
    print(json.dumps(hashes, indent=2))


if __name__ == "__main__":
    main()
