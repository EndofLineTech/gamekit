# E1.3 — Reproducible Steam feasibility procedure

Test design for `gamekit-wxz.3`, executed later by E2.1–E2.3. Nothing below has
been executed as an installation test during E1. Use the pinned artifacts and
composition in [the runtime contract](runtime-contract.md).

E2 prerequisite validation revised the engine to Sikarugir 10.0 revision 6 with
Apple 4.0b2. Commands below use [that passing revision](runtime-revision.md).
Its device/queue probe is not the clear/present rendering test specified here.

## Purpose and boundaries

Prove that this Mac can run the current Windows Steam client through the selected
Wine runtime, with Apple 4.0b2 graphics integration independently verified. Repeat
from a second fresh prefix before building the application. Steam login is an
interactive user step. The test does not download games or diagnose anti-cheat.

The independent graphics diagnostic is a small **project-owned x64 D3D12 clear /
present probe**, to be implemented as part of E2.2 test preparation. It is not an
already available executable. This avoids making a commercial game or external
binary of uncertain provenance a prerequisite for validating graphics loading.

## Evidence record (one directory per run)

Create a timestamped directory under `~/Library/Logs/Gamekit/E2/`. Record:

- OS/build, chip/RAM, Xcode and Rosetta execution result;
- original archive/installer hashes, GCenx tag and actual Wine version;
- D3DMetal source version, source signature result and final installed hashes;
- prefix/runtime absolute paths, complete non-secret environment and arguments;
- prefix Windows setting and actual installed Steam/helper build identities;
- each step's start/end time, exit code, observed outcome and log/screenshot path;
- initial/final available disk and runtime/prefix sizes;
- required deviations/overrides, with the failure each addresses.

Keep original runtime logs locally. Share a redacted diagnostic summary; exclude
Steam credentials, cookies, session files and personal Library/account details
from public PRs or the public Beads backup.

## 1. Preflight and isolated prefix

After E2.1 has installed and validated prerequisites:

```bash
ROOT="$HOME/Library/Application Support/Gamekit"
APP="$ROOT/Runtimes/sikarugir10.0_6-d3dmetal4.0b2/Template-1.0.11.app"
WINE="$APP/Contents/SharedSupport/wine/bin/wine"
SERVER="$APP/Contents/SharedSupport/wine/bin/wineserver"
FRAMEWORKS="$APP/Contents/Frameworks"
PREFIX="$ROOT/Environments/steam-eval-a"

/usr/bin/arch -x86_64 /usr/bin/uname -m
"$WINE" --version
```

Both commands must succeed. Before creating a prefix, confirm its path is absent
and its parent is the intended managed directory. Create only that prefix. Do not
reuse an existing installation, `~/.wine`, or macOS Steam data. Record the exact
environment; unset inherited `WINEPREFIX`, `WINEDLLOVERRIDES`, `WINEDLLPATH`,
`DYLD_LIBRARY_PATH`, `DYLD_FALLBACK_LIBRARY_PATH` and optional D3DMetal override
variables unless they are explicitly part of the test recipe.

```bash
export DYLD_FALLBACK_LIBRARY_PATH="$APP/Contents/SharedSupport/wine/lib:$FRAMEWORKS:$FRAMEWORKS/GStreamer.framework/Libraries"
export DYLD_FALLBACK_FRAMEWORK_PATH="$APP/Contents/SharedSupport/wine/lib/external:$FRAMEWORKS"
WINEPREFIX="$PREFIX" WINEARCH=win64 "$WINE" wineboot -u
WINEPREFIX="$PREFIX" "$WINE" winecfg
```

In winecfg choose **Windows 10**, save and close. Capture that setting. Prefix
creation must finish without missing runtime-library failures. Verify both PE
architectures using the prefix's corresponding command executables:

```bash
file -L "$PREFIX/drive_c/windows/system32/cmd.exe" \
     "$PREFIX/drive_c/windows/syswow64/cmd.exe"
WINEPREFIX="$PREFIX" "$WINE" 'C:\windows\system32\cmd.exe' /c ver
WINEPREFIX="$PREFIX" "$WINE" 'C:\windows\syswow64\cmd.exe' /c ver
```

The files must identify as x64 and x86 respectively, and both invocations must
succeed. If the selected build uses a different layout, inspect it and document
an equivalent actual-PE execution test rather than skipping the 32-bit gate.

## 2. Independent D3D12 diagnostic

Implement and retain `d3d12-probe.cpp` with the E2 evidence/test source. It must:

1. Create a Win32 window and hardware DXGI adapter (explicitly reject WARP).
2. Create a D3D12 device with feature level 11_0, command queue and flip swapchain.
3. Transition the backbuffer, clear it to a known visible color, transition back,
   submit commands, present and wait on a fence correctly.
4. Repeat for at least 120 frames while processing messages; keep the window
   alive for at least 15 seconds so loaded-image diagnostics can be captured.
5. Print adapter name, device creation results, frame count, HRESULT failures and
   exit status. Return nonzero on graphics creation/submission failure.

No shaders, assets or shader-converter installation are necessary for a clear.
Build with the ARM-hosted cross-compiler installed for this diagnostic:

```bash
x86_64-w64-mingw32-g++ -std=c++17 -O2 -static \
  d3d12-probe.cpp -o d3d12-probe.exe -ld3d12 -ldxgi -luser32 -lgdi32
file d3d12-probe.exe
shasum -a 256 d3d12-probe.exe
```

The source will define a normal `main` and report to stdout. Record any actual
toolchain/link adjustments; do not download an unrelated replacement probe.

Run in the same prefix with diagnostic module logging:

```bash
WINEPREFIX="$PREFIX" WINEDEBUG=+loaddll "$WINE" d3d12-probe.exe
```

Capture stdout/stderr and the corresponding D3DMetal system-log messages. While
running, identify the **native host process PID** belonging to this prefix and
probe (do not assume a Windows PID or shell launcher PID is the right process).
Use `vmmap <host-pid>` or `lsof -p <host-pid>` to capture the actual mapped
`D3DMetal.framework` path. Correlate with `D3DM` / `D3DMetal` logs and the verified
4.0b2 framework at that path. If process inspection is denied, find an equivalent
ordinary loaded-library diagnostic; do not disable SIP to pass this gate.

Pass requires **all** of: visible correct output, successful frame submission,
zero exit, and evidence of the selected 4.0b2 D3DMetal loaded into that process.
Presence of files on disk, an API success code, or a Steam window is insufficient.

Leave `D3DM_MTL4` unset for the baseline, preserving Apple's documented macOS 27
default. Explicitly distinguish “documented default” from “observed Metal 4
backend” in the report. If available logs expose backend selection, retain them.
A comparison with `D3DM_MTL4=0` is permitted for diagnosis but is not a passing
Metal 4-default baseline if only that comparison works.

## 3. Install Steam and observe bootstrap

Use the official Valve HTTPS `SteamSetup.exe` and record its fresh hash/PE type.
Use the normal interactive installer initially, not guessed silent flags:

```bash
WINEPREFIX="$PREFIX" WINEDEBUG=-all "$WINE" "$ROOT/Artifacts/SteamSetup.exe"
```

Choose the standard installation location inside the managed virtual C: drive.
Allow Steam to download/update/restart. Installer process exit is not Steam
readiness: follow its handoff and capture updater/UI outcomes. Inspect the actual
installed `steam.exe` path rather than assuming `Program Files` versus
`Program Files (x86)`. Record the installed client and helper architectures.

Use a 15-minute **no-progress** threshold for initial triage, not a claim that a
slow download is incompatibility. If stalled, retain timestamps, logs and network
observations and classify the failure. Download progress may justify extending
the run; a window that remains blank is not a successful installation.

## 4. User login and usable Library

The user enters credentials and completes Steam Guard in Steam itself. Verify:

- login UI is visible and accepts keyboard/mouse input;
- updater reaches a usable client, with no persistent blank web-helper surface;
- the user's Library renders and navigation responds;
- no repeated process crash/restart loop during a five-minute idle/navigation run.

Do not automate credentials or store them in Gamekit. Do not install a game as
part of this gate. Record privacy-safe evidence and the client build identifier.

## 5. Exit, relaunch, and process ownership

Use Steam's normal Exit action first. Allow 30 seconds for shutdown; record any
remaining processes owned by this prefix. If it hangs, classify a graceful-exit
failure before using recovery. Recovery may use only the matching runtime and
explicit prefix:

```bash
WINEPREFIX="$PREFIX" "$SERVER" -k
```

Never use global `killall wine`, `killall Steam`, or reset another prefix. A forced
shutdown does not count as a graceful-exit pass. Relaunch using the discovered
Steam executable path, for example after assigning the verified `STEAM_EXE`:

```bash
WINEPREFIX="$PREFIX" WINEDEBUG=-all "$WINE" "$STEAM_EXE"
```

Verify Library rendering again, then repeat normal exit/relaunch for three
cycles. Record whether login persists; a required normal user login is distinct
from failed persistence or an unusable client. Check that existing macOS Steam,
its Library files and unrelated Wine processes were unaffected.

## 6. Fresh-prefix reproduction and decision

For E2.3, set `PREFIX` to the previously absent `steam-eval-b` and repeat steps
1–5 using the same runtime and verified installer. Reusing a populated prefix
does not satisfy reproduction. Steam's live updater may change between runs;
record both installed builds and investigate any resulting difference.

**GO to E3** only when both fresh-prefix runs pass architecture checks, Steam
bootstrap/login/Library, normal shutdown and relaunch, and the independent
graphics gate passes with the selected configuration. Record the minimal recipe,
all observed versions, overrides (including none), and measured disk usage.

**NO-GO** if any required gate fails. Preserve evidence; identify whether the
failure is download/authentication, Wine/architecture, Steam web UI, graphics or
lifecycle. Keep E2 acceptance open and E3 blocked. Present a revised runtime
choice or focused investigation instead of silently substituting CrossOver,
older Steam, a different graphics layer, or unverified launch flags.

Runtime migrations and overrides must be retested against two fresh prefixes.
The E1 documents are complete when this procedure is specified; the project is
not “Steam-compatible” until E2 supplies the actual evidence.
