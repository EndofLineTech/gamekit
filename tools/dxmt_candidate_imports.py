"""Generate a PE import library for an unchanged, pinned DXMT winemetal DLL.

Used by the source-level query investigation to rebuild PE code while retaining
the v0.80 Unix library/shader converter. This does not alter an installed payload.
"""
import argparse
from pathlib import Path
import re
import subprocess
from qualify_graphics_backends import digest

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dll", type=Path, required=True)
    parser.add_argument("--toolchain", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--arch", choices=["x64", "x86"], default="x64")
    args = parser.parse_args()
    expected = {"x64": "514245d533c750599614311a792c45ed600aef52948571d98c0fc70fd3df16e0",
                "x86": "20a6865facebdaac92b6c06fadf37d2efb5a242b22ca1c349bb57d7ad43df8e3"}
    if digest(args.dll) != expected[args.arch]:
        raise ValueError("Not the pinned v0.80 winemetal DLL")
    if args.output.exists():
        raise ValueError("Refusing to replace candidate imports")
    text = subprocess.run([str(args.toolchain / "llvm-readobj"), "--coff-exports", str(args.dll)],
                          check=True, capture_output=True, text=True).stdout
    names = re.findall(r"^  Name: ([A-Za-z_][A-Za-z_0-9@]*)$", text, re.MULTILINE)
    if not names or len(names) != len(set(names)):
        raise ValueError("Unexpected export table")
    args.output.mkdir(parents=True)
    definition = args.output / "winemetal.def"
    definition.write_text("LIBRARY winemetal.dll\nEXPORTS\n" + "\n".join(names) + "\n")
    subprocess.run([str(args.toolchain / "llvm-dlltool"), "-m", "i386:x86-64" if args.arch == "x64" else "i386", "-d", str(definition),
                    "-l", str(args.output / "libwinemetal.a")], check=True)

if __name__ == "__main__":
    main()
