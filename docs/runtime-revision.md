# Runtime revision — D3DMetal-capable Wine, not merely newer Wine

Date: 2026-09-15. Work: `gamekit-8sc`, unblocking `gamekit-9jv.1`.

## Decision and verification boundary

Use **WS12WineSikarugir10.0_6 + Template-1.0.11 dependencies + the complete,
unchanged Apple D3DMetal 4.0b2 overlay**. The user approved this candidate after
reviewing the upstream findings. The revised prerequisites pass in **two fresh
test prefixes** on this M4 Pro / macOS 27.0 build 26A428.

Verified: x86/x64 Windows execution, required dispatcher, D3D11/D3D12/DXGI and
GStreamer DLL loading, actual Apple framework image path, hardware D3D12 device
and command queue creation, 15-second lifetime, and clean diagnostic completion.

**Not yet verified:** rendering/presentation, Steam bootstrap/login/Library,
game compatibility, sustained stability, or macOS 28. These prerequisite passes
do not replace E2.2/E2.3 acceptance. Metal 4 remains Apple's documented default
on macOS 27 with `D3DM_MTL4` unset; this is not a measured frame-level backend test.

## What upstream research established

The user correctly asked for upstream research before a downgrade or commercial
runtime switch. The key sources are maintainer statements, rather than guessed
compatibility based on Wine's version number:

1. [GCenx issue 139, maintainer explanation](https://github.com/Gcenx/macOS_Wine_builds/issues/139#issuecomment-3368504079):
   generic WineHQ macOS packages do **not** support Apple's D3DMetal; they lack
   required integration, and the separate GPTK packages are customized Wine.
2. [GCenx issue 160, packaging change](https://github.com/Gcenx/macOS_Wine_builds/issues/160#issuecomment-4331843294):
   `11.0_1` and newer listed builds removed additional compatibility patches to
   conform to WineHQ packaging expectations. A larger version number is not a
   superset of the old runtime's Rosetta/D3DMetal behavior.
3. [Sikarugir's own README](https://github.com/Sikarugir-App/Sikarugir): explicitly
   advertises D3DMetal support for 64-bit D3D11/12 on Apple silicon.
4. [Community Steam recipe](https://github.com/mirpo/windows-steam-on-apple-silicon):
   reports current Steam working with `WS12WineSikarugir10.0_6` and template
   `1.0.11` on macOS 26.5.2. That report guided selection; it is not our own Steam
   validation or proof of 4.0b2 support. Its broad claims and workaround flags
   were not adopted without a matching local failure.
5. [Whisky community-fork issue 163](https://github.com/frankea/Whisky/issues/163):
   describes GPTK 4.0b2 loading but failing to execute in an unsuitable Wine build,
   followed by customized runtime work. Its unwinder explanation is supporting
   evidence for incomplete runtime integration, not proof of our exact pthread
   failure's cause. Later discussion also corrects earlier diagnoses.
6. [Highball report 53](https://github.com/gauthierpiarrette/highball-db/issues/53):
   reports 4.0b2 gameplay on macOS 27 with a customized CrossOver-derived engine,
   explicitly noting rendering issues and confounded variables. It establishes
   that a blanket conclusion that GPTK 4 cannot run would be unjustified.

No matching published fix for our exact `pthread_setname_np` fault was found.
The supported runtime-family distinction and our own differential tests were the
actionable findings. Testing generic Wine 11 before reading the maintainer's
support statement was a process error; do not repeat that version-number search.

## Controlled results

| Configuration | Observed result | Decision |
|---|---|---|
| GCenx GPTK 3.0-3 / Wine 7.7 + Apple 4.0b2 | Dispatcher missing; graphics DLL initialization fails with 1114 | Reject |
| Original GCenx GPTK 3.0-3 / D3DMetal 3.0 | DLL loads and hardware D3D12 device/queue probe passes | Useful control/fallback; no Steam or rendering acceptance |
| GCenx Wine Stable 11.0_1 + Apple 4.0b2 | Dispatcher and DLL loading work, but graphics worker faults; device test fails | Reject |
| GCenx Wine Devel 11.17 + Apple 4.0b2 | Same initialization fault as stable | Reject; stop testing unsupported generic builds |
| Sikarugir 10.0 revision 6 + template dependencies + Apple 4.0b2 | Architecture, DLL/media loading and hardware-device/queue checks pass twice | Select for E2 Steam evaluation |

The generic Wine 11 fault was `0xc0000005` on a worker in the probe's own Windows
process. Native symbol lookup on this boot maps address `0x7ff80c0571e3` to
`libsystem_pthread.dylib`'s `pthread_setname_np + 51`. That identifies the failure
site, not the causal patch needed. Retaining loaded modules until process exit
did not remove the failure. Even a probe printing PASS and returning zero could
have a crashing worker; the new test runner rejects those logs.

Switching to Sikarugir with its matching packaged dependencies resolved the local
failure. We have not isolated an individual source patch responsible for the fix.
Apple payload files were not patched, re-signed or downgraded.

## Pinned artifacts

| Artifact | SHA-256 |
|---|---|
| [WS12WineSikarugir10.0_6.tar.xz](https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineSikarugir10.0_6.tar.xz) | `9da7ee0cbf386522f3a9906943726d9c3c125dbbd9ab120e3cde80e88d6091b2` |
| [Template-1.0.11.tar.xz](https://github.com/Sikarugir-App/Wrapper/releases/download/v1.0/Template-1.0.11.tar.xz) | `9fa15479e7ff6abd99c1d07be285fb95f41fc6991586502427152b1f7d6ccb8a` |
| User-obtained Apple evaluation 4.0 beta 2 DMG | `6248a0edc61553790753e5e9c060b8e53c940ed197f11409dcc34a35e05becc1` |
| Installed 4.0b2 framework's actual `D3DMetal` binary | `f5b56df1b8fe8b364dd9530651a3769c8aed948bd343be3b4510604d503e2bad` |

Engine/template downloads matched GitHub release asset digests. Apple hashes
identify the user-supplied payload inspected in E1. The installed framework still
passes Apple's original code-signature verification. Template 1.0.15 was current
when researched; 1.0.11 was deliberately pinned to reproduce the documented
reference pairing. An upgrade requires renewed verification.

Rejected generic candidates are retained for investigation:

- `wine-stable-11.0_1-osx64.tar.xz`: `b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388`
- `wine-devel-11.17-osx64.tar.xz`: `c2b3a8274dbc594deaa64e40469b607cbc4aa8ef5656dec4c5f6f3dac0da770c`

## Assembly and dependency layout

Under `~/Library/Application Support/Gamekit/Runtimes/`:

```text
sikarugir10.0_6-d3dmetal4.0b2/
  Template-1.0.11.app/Contents/
    Frameworks/                          # publisher's dependency bundle
      GStreamer.framework/               # runtime 1.28.1; bundle metadata 1.28.1.1
      libfreetype.6.dylib                 # plus SDL, GnuTLS, etc.
      renderer/                          # unused stock renderer payloads retained
    SharedSupport/wine/                   # extracted wswine.bundle, renamed
      bin/wine                           # wine-10.0 (Sikarugir)
      bin/wineserver
      lib/external/                      # Apple's 4.0b2 framework and bridge
      lib/wine/                          # engine + exact Apple overlay
      version                            # wine sikarugir 10.0 (revision 6)
```

Assembly: extract the template into a new managed directory; extract the engine
into `Contents/SharedSupport`, rename its `wswine.bundle` directory to `wine`, then
merge the complete Apple `redist/lib` into that engine's `lib` with `ditto`.
Preserve every unrelated engine file, the dependency frameworks and symlinks.
Do not use or modify an existing user wrapper or prefix.

An independently re-extracted base template+engine was compared with the complete
composed app using `verify_runtime_overlay.py --lib-relative
Contents/SharedSupport/wine/lib`: **5,677 base entries, 26 overlay entries,
5,699 composed entries; zero mismatches/extras**. This also checks that the
template's dependencies stayed unchanged. Runtime size is about **1.1 GiB**;
each prerequisite prefix is about **337 MiB**.

The Sikarugir launcher and Creator UI were not executed or installed globally.
We invoke Wine directly, using the template to supply its packaged dependencies.
The source repository contains diagnostics and this recipe, not third-party
binaries. The wrapper is not wholly LGPL/open source; local use of downloaded
artifacts does not establish permission to redistribute it with Gamekit.

No CrossOver trial/license was used. The proposed system GStreamer 1.28.6
installation was not performed: the selected template already supplies the
matching framework. `gst-inspect-1.0 --version` reports 1.28.1, and the Windows
`winegstreamer.dll` probe loads it from the app's own framework directory.
Existing Rosetta and the installed ARM MinGW compiler remain the host prerequisites.

## Exact launch environment

```bash
ROOT="$HOME/Library/Application Support/Gamekit"
APP="$ROOT/Runtimes/sikarugir10.0_6-d3dmetal4.0b2/Template-1.0.11.app"
WINE="$APP/Contents/SharedSupport/wine/bin/wine"
SERVER="$APP/Contents/SharedSupport/wine/bin/wineserver"
FRAMEWORKS="$APP/Contents/Frameworks"

export WINEPREFIX="$ROOT/Environments/steam-eval-a"  # new prefix for E2.2
export DYLD_FALLBACK_LIBRARY_PATH="$APP/Contents/SharedSupport/wine/lib:$FRAMEWORKS:$FRAMEWORKS/GStreamer.framework/Libraries"
export DYLD_FALLBACK_FRAMEWORK_PATH="$APP/Contents/SharedSupport/wine/lib/external:$FRAMEWORKS"
```

Clear inherited Wine/DYLD/renderer overrides before setting these values. Use
`WINEARCH=win64` for prefix creation, `WINEDEBUG=-all` for baseline, and keep
`D3DM_MTL4`, optional MetalFX, MSync/ESync and AVX advertisement unset for this
validated baseline. No DLL override or `WINEDLLPATH_PREPEND` was needed: the
exact Apple DLLs occupy the selected engine's builtin paths.

`cmd /c ver` reports **Microsoft Windows 10.0.19043**. `bin/wine`, not `wine64`,
is the executable for this engine. This revises the E1 launch recipe. Do not run
the template's generic launch target or its internal `Contents/drive_c` shortcut;
all prefixes are external, explicit Gamekit-managed paths.

## Repeatable checks

Compile `diagnostics/prerequisite_probe.c` with both MinGW gcc target compilers,
and `diagnostics/d3d12_device_probe.cpp` with x86_64 MinGW g++:

```bash
x86_64-w64-mingw32-g++ -std=c++17 -O2 -Wall -Wextra -Werror -static \
  diagnostics/d3d12_device_probe.cpp -o "$ROOT/Diagnostics/d3d12-device-probe.exe" \
  -ld3d12 -ldxgi -ldxguid

python3 scripts/run_runtime_probe.py \
  --wine "$WINE" --prefix "$ROOT/Environments/prereq-sikarugir10-repeat" \
  --exe "$ROOT/Diagnostics/d3d12-device-probe.exe" --frameworks "$FRAMEWORKS" \
  --log "$HOME/Library/Logs/Gamekit/E2/new-device-check.log" --trace-images \
  --require 'PASS device/queue probe' \
  --require '/Contents/SharedSupport/wine/lib/external/D3DMetal.framework/Versions/A/D3DMetal'
```

The runner requires an existing dedicated prefix and a new log filename. It
clears inherited runtime overrides, records logs, enforces a timeout, and rejects
crash/failure signatures even on zero exit. A timeout cleanup only targets its
explicit prefix. This is a smoke-test helper, not the future app process manager.

Both `prereq-sikarugir10` and independently created `prereq-sikarugir10-repeat`
passed x86/x64 probes and device/queue lifetime checks. The x64 test also loads
`winegstreamer.dll` and verifies `DllGetClassObject`. Exact loaded-image traces
identify the engine-local 4.0b2 framework, not the template's unused stock renderer.
The AMD vendor/device IDs reported by DXGI are translation-layer compatibility
identifiers; the physical GPU is the M4 Pro.

Local evidence under `~/Library/Logs/Gamekit/E2/` includes
`sikarugir10-overlay-manifest.json`, `sikarugir10-*-verified.log`,
`sikarugir10-repeat-*.log`, `wine11-*.log`, `wine11-17-*.log`, and
`gptk3-device-control.log`. Keep raw logs local; public reports use normalized
results. Source tests cover overlay corruption and the zero-exit/worker-crash
false-positive case.

## Next step

Proceed to E2.2 with the revised environment, new `steam-eval-a` prefix, official
current Steam installer and the full rendering/Steam procedure. The second
prerequisite prefix does not count as E2.3's second Steam installation. If current
Steam fails, use its actual logs; do not preemptively copy community flags,
downgrade Steam, disable updates or blame authentication from unrelated reports.
The prototype's macOS 27 support limit and macOS 28 investigation remain unchanged.
