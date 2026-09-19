"""Rebuild the pinned DXMT/DXVK PE compatibility modules.

Use a clean recursive checkout at the pinned revision, LLVM-MinGW 20260908,
Meson 1.11.2, Ninja 1.13.2, Xcode 27's Metal Toolchain, and Wine 10 winebuild.
DXVK also requires glslangValidator 16.6.0; DXMT retains its stock Unix ABI.
No installation or primary-prefix modification is performed.
"""
import argparse
import os
from pathlib import Path
import subprocess

REVISIONS = {"dxmt": "589adb780354b461645b29999cefaf533594ee99", "dxvk": "8f1e28deed3ad30802f7e1bdff428ec14e6e7817"}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--backend", choices=["dxmt", "dxvk"], default="dxmt")
    parser.add_argument("--toolchain", type=Path)
    parser.add_argument("--wine-build", type=Path)
    parser.add_argument("--stock-payload", type=Path)
    parser.add_argument("--export-patch", type=Path, help="Maintainer-only snapshot of the reviewed source changes")
    parser.add_argument("--refresh-export", action="store_true", help="Explicitly replace the maintainer's existing generated patch")
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    source = args.source.resolve()
    if subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip() != REVISIONS[args.backend]:
        raise ValueError("Expected pinned backend source revision")
    if args.export_patch:
        if args.export_patch.exists() and not args.refresh_export:
            raise ValueError("Refusing to overwrite source patch")
        diff = subprocess.check_output(["git", "diff", "--no-ext-diff", "--binary"], cwd=source)
        if not diff:
            raise ValueError("No source changes")
        args.export_patch.write_bytes(diff)
        return
    if not all([args.toolchain, args.wine_build]) or (args.backend == "dxmt" and not args.stock_payload):
        parser.error("--toolchain and --wine-build are required; DXMT also needs --stock-payload")
    subprocess.run(["git", "diff", "--exit-code"], cwd=source, check=True)
    patch = project / "Sources" / ("DXMTCompatibility" if args.backend == "dxmt" else "DXVKCompatibility") / "compatibility.patch"
    subprocess.run(["git", "apply", "--check", str(patch)], cwd=source, check=True)
    subprocess.run(["git", "apply", str(patch)], cwd=source, check=True)
    env = dict(os.environ, PATH=str(args.toolchain.resolve()) + os.pathsep + os.environ["PATH"])
    for arch, output, cross, windows in [("x64", "build", "build-win64.txt", "x86_64-windows"), ("x86", "build32", "build-win32.txt", "i386-windows")]:
        if args.backend == "dxvk":
            subprocess.run(["meson", "setup", "--cross-file", cross, "--buildtype", "release", "-Denable_dxgi=false", "-Denable_d3d9=false", output], cwd=source, env=env, check=True)
            subprocess.run(["ninja", "-C", output, "-j", "6"], cwd=source, env=env, check=True)
            subprocess.run([str(args.wine_build.resolve() / "tools/winebuild/winebuild"), "--builtin",
                str(source / output / "src/d3d11/d3d11.dll"), str(source / output / "src/d3d10/d3d10core.dll")], check=True)
            continue
        imports = source / ("imports-" + arch)
        subprocess.run(["python3", str(project / "tools/dxmt_candidate_imports.py"), "--arch", arch,
            "--dll", str(args.stock_payload.resolve() / windows / "winemetal.dll"), "--toolchain", str(args.toolchain.resolve()), "--output", str(imports)], check=True)
        subprocess.run(["meson", "setup", "--cross-file", cross,
            "-Dcandidate_winemetal_import=" + str(imports / "libwinemetal.a"), "-Dwine_build_path=" + str(args.wine_build.resolve()),
            "-Dwine_builtin_dll=true", "-Denable_nvapi=false", "-Denable_nvngx=false", "--buildtype", "release", output], cwd=source, env=env, check=True)
        subprocess.run(["ninja", "-C", output, "-j", "6", "src/d3d11/d3d11.dll.postproc", "src/dxgi/dxgi.dll.postproc"], cwd=source, env=env, check=True)

if __name__ == "__main__":
    main()
