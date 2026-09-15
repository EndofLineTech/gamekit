# E2.1 — Prerequisite installation and validation

Date: 2026-09-15. Bead: `gamekit-9jv.1`. **Initial result: blocked on runtime ABI
compatibility (`gamekit-8sc`).** Prerequisites were installed and tested; the
selected composition cannot yet be accepted for Steam.

**Follow-up:** the [runtime revision](runtime-revision.md) records the approved
Sikarugir-based replacement, which passes the prerequisite gates with Apple
4.0b2. This document preserves the original failure evidence rather than
describing the current selected runtime.

## Installed and observed

| Component | Result |
|---|---|
| Host | macOS 27.0 build 26A428, M4 Pro, 24 GB, Xcode 27.0 build 27A266a |
| Free space before installation | About 142 GiB; above the 15 GiB project allowance |
| Rosetta | Installed after explicit user license acceptance; receipt `1.0.0.0.1788432274` |
| Translation check | `arch -x86_64 uname -m` returns `x86_64` |
| ARM Homebrew cross-compiler | `mingw-w64 14.0.0_3`; both x86_64 and i686 GCC report 16.2.0 |
| Newly installed compiler dependencies | gmp 6.3.0, isl 0.28, mpfr 4.2.2, libmpc 1.4.1 |
| Existing compiler dependency | zstd 1.5.7_1 reused |
| Runtime archive identity | GCenx 3.0-3, SHA-256 matches the E1 contract |
| Actual Wine version | `wine-7.7 (Game Porting Toolkit 1.1)`; historical label, distinct from graphics version |
| Installed graphics | Apple D3DMetal 4.0b2, source 33024000000000; signature remains valid |
| Composed runtime footprint | Approximately 808 MiB |
| Initial prerequisite prefix | Approximately 344 MiB; separate from future Steam prefixes |
| Artifact storage at measurement | Approximately 316 MiB, including original archive/image and retained old framework |
| MinGW installation footprint | Approximately 1.4 GB reported by Homebrew |

Rosetta used `softwareupdate --install-rosetta --agree-to-license` only after the
user explicitly accepted the license. Compiler installation used existing ARM
Homebrew with auto-update and automatic cleanup disabled. No Intel Homebrew,
standalone graphics dependency, CrossOver, Wine patch, or Steam installation was
performed. No SIP or global Gatekeeper changes were needed.

## Local layout

All paths below are relative to `~/Library/Application Support/Gamekit/`:

```text
Artifacts/game-porting-toolkit-3.0-3.tar.xz
Artifacts/Evaluation environment for Windows games 4.0 beta 2.dmg
Artifacts/D3DMetal-3.0.framework                 # retained old framework
Runtimes/gcenx-3.0-3-d3dmetal-4.0b2/Game Porting Toolkit.app
Environments/prereq-check                       # failed candidate's test prefix
Environments/prereq-base3-control                # diagnostic control only
Diagnostics/prerequisite-x64.exe
Diagnostics/prerequisite-x86.exe
Diagnostics/load-macos-library
```

The `.staging` runtime directory was renamed to the planned final path after the
static composition check. That path's existence does **not** indicate readiness;
execution testing subsequently rejected it. Preserve it for reproduction until
the blocker is resolved. Existing macOS Steam and Beads data were not used as
test environments.

## Composition verification

The original GCenx archive was rehashed, extracted to a new staging directory,
and its old D3DMetal framework moved aside. Apple's complete `redist/lib` was
merged into the working copy using `ditto`. Core Wine directories were retained.

`scripts/verify_runtime_overlay.py` compared every regular file hash and symlink
target in the base, overlay and composed app:

- **5,478 base entries**, **26 overlay entries**, **5,478 composed entries**;
- **zero mismatches or unexpected entries**;
- exact Apple framework and DLL bytes preserved; no re-signing was necessary;
- `codesign --verify --deep --strict` passes for the copied Apple framework;
- the app has a provenance xattr, but no quarantine adjustment was needed.

The 26-entry overlay includes the x86_64 Unix-side `.so` symlinks pointing to
`external/libd3dshared.dylib`, as well as the Windows DLLs and framework. Merely
listing regular files would omit these necessary symlinks.

Before any future signing, use this checker to establish source-byte provenance.
Signing changes bytes, so it must be recorded separately rather than represented
as an exact unchanged overlay. This run required no signing changes.

## Execution checks

`diagnostics/prerequisite_probe.c` was compiled for both Windows architectures
with the installed MinGW tools using `-std=c11 -O2 -Wall -Wextra -Werror -static`.
The x64 probe checks D3D11, D3D12 and DXGI DLL loading and expected API exports.
It does not create a graphics device or render frames.

1. Explicit `WINEPREFIX=.../Environments/prereq-check`, `WINEARCH=win64` and
   `wine64 wineboot -u` create/update the isolated prefix successfully.
2. The x86 PE executable runs, reports `pointer_bits=32` and exits **0**.
3. The x64 PE executable runs and reports `pointer_bits=64`, but reports
   `wine_unix_call_dispatcher=absent`. All three graphics DLL loads fail with
   error **1114**, and the diagnostic exits **1**.
4. An x86_64 macOS diagnostic built with Xcode successfully `dlopen`s the exact
   installed D3DMetal framework. Native framework loading works independently of
   Wine; this does not establish working Windows graphics integration.
5. As a controlled comparison only, the unmodified original GCenx app with
   D3DMetal **3.0** runs the same x64 DLL-loading test successfully in a separate
   fresh prefix. It is not substituted as the project's graphics runtime.

### Root-cause evidence

Wine `+module` and `+relay` diagnostics isolate the failure in D3D11 process
attachment. The relevant normalized call sequence is:

```text
d3d11.dll PROCESS_ATTACH
GetModuleHandleW("ntdll.dll") -> valid module
GetProcAddress(ntdll, "__wine_unix_call_dispatcher") -> NULL
d3d11.dll PROCESS_ATTACH -> FALSE
LdrLoadDll -> 0xc0000142
LoadLibraryA -> NULL; GetLastError -> 1114
```

The expected graphics bytes are present, the bridge's `libd3dshared.dylib` loads,
and native framework loading works. The missing Wine interface is a concrete
ABI incompatibility in the chosen composition. No graphics device, rendering,
Steam compatibility, or macOS 28 support has been validated.

The preserved local logs are in `~/Library/Logs/Gamekit/E2/`:
`prereq-wineboot.log`, `prereq-x64.log`, `prereq-x64-module.log`,
`prereq-x64-relay.log`, and `prereq-base3-control.log`. The relay log is verbose;
keep it local and use the normalized evidence above in public reports.

## Reproduction

Build the probes from repository source into an existing diagnostic directory:

```bash
DIAG="$HOME/Library/Application Support/Gamekit/Diagnostics"
x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror -static \
  diagnostics/prerequisite_probe.c -o "$DIAG/prerequisite-x64.exe"
i686-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror -static \
  diagnostics/prerequisite_probe.c -o "$DIAG/prerequisite-x86.exe"
xcrun clang -arch x86_64 -Wall -Wextra -Werror \
  diagnostics/load_macos_library.c -o "$DIAG/load-macos-library"

ROOT="$HOME/Library/Application Support/Gamekit"
APP="$ROOT/Runtimes/gcenx-3.0-3-d3dmetal-4.0b2/Game Porting Toolkit.app"
WINE="$APP/Contents/Resources/wine/bin/wine64"
WINEPREFIX="$ROOT/Environments/prereq-check" WINEDEBUG=-all \
  "$WINE" "$DIAG/prerequisite-x64.exe"  # expected failure for this candidate
WINEPREFIX="$ROOT/Environments/prereq-check" WINEDEBUG=-all \
  "$WINE" "$DIAG/prerequisite-x86.exe"  # expected success
"$DIAG/load-macos-library" \
  "$APP/Contents/Resources/wine/lib/external/D3DMetal.framework/Versions/A/D3DMetal"
```

For the file-overlay check, supply the independently extracted original app and
mounted Apple `redist/lib` to `scripts/verify_runtime_overlay.py --base-app ...
--overlay-lib ... --composed-app ...`. It performs no writes.

## Next action and OS horizon

`gamekit-8sc` must select and validate an approved Wine runtime that exports the
required interface and supports the Apple 4.0b2 bridge. An available export alone
is not sufficient: rerun the loader and actual graphics tests. Keep E2.1 blocked
and Steam installation (E2.2) waiting until prerequisite checks pass. The installed
Rosetta/compiler and verified Apple artifacts remain useful for that investigation.

Independently, Apple's general Rosetta retirement after macOS 27 requires a
long-term runtime decision. `gamekit-6v1` tracks that investigation; see the
[runtime contract's OS support horizon](runtime-contract.md#os-support-horizon).
