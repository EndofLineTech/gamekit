# E2 — Windows Steam feasibility and reproduction

Date: 2026-09-15. Beads: `gamekit-9jv.2` and `gamekit-9jv.3`.

## Status

**E2.2 and E2.3 passed; the user accepted E2 as complete.** Rendering, installation,
automatic updates, login, Library stability and three-cycle lifecycle checks
succeeded in two independently created prefixes. This is a GO for the native-app
foundation, not a claim of general game compatibility.

## Configuration and isolation

- Host: M4 Pro, macOS 27.0 build 26A428; Rosetta installed.
- Runtime: the [validated Sikarugir 10.0 revision 6 / Apple 4.0b2 composition](runtime-revision.md).
- New prefix: `~/Library/Application Support/Gamekit/Environments/steam-eval-a`.
- Windows setting: `cmd /c ver` reports Microsoft Windows 10.0.19043. Both
  system32 (PE32+ x64) and syswow64 (PE32 x86) command executables run successfully.
- Wine and wineserver use explicit paths and the documented dependency fallback
  paths. No inherited Wine/DYLD/D3DMetal overrides were used; optional tuning
  variables remain unset.
- Existing macOS Steam data and the prerequisite-test prefixes were not reused.
- Logs: `~/Library/Logs/Gamekit/E2/steam-eval-a-20260915/` plus Steam's own logs
  within this prefix. Logs and authenticated account/session data remain local.

## Independent D3D12 rendering gate — passed

`diagnostics/d3d12_render_probe.cpp` creates a hardware D3D12 device, a 640×360
flip-discard swapchain, render targets, command allocator/list, fence and readback
buffer. It clears, copies, fences and presents repeatedly for at least 120 calls
and 15 seconds, then verifies the final GPU output at nine pixel positions.

Observed results:

- Compiled with MinGW GCC 16.2.0 using C++17, static linkage,
  `-Wall -Wextra -Werror`, and d3d12/dxgi/dxguid/user32/gdi32 libraries.
- Probe executable SHA-256:
  `a652ebb7f2c5c111556ba7d79fe3991cb7c53f4e743591d9ed9c26f4d3c5ee74`.
- **34,611 successful Present calls over 15,000 ms.** This is a submission count,
  not a measured display refresh rate or performance benchmark.
- GPU-readback samples matched RGBA **32,64,191,255**, within one integer step.
- The user confirmed a visibly solid blue window that closed automatically.
- Diagnostic exited 0, emitted its completion marker, and the crash-aware runner
  found no failure or unhandled-exception signature.
- The loaded-image trace identifies the exact engine-local
  `D3DMetal.framework/Versions/A/D3DMetal` from Apple 4.0b2.
- DXGI reports `AMD Compatibility Mode`; that is the translation layer's adapter
  identity, not the physical GPU. WARP/software adapters are rejected by the test.

The test verifies a simple clear/present/readback path. It does not exercise game
shaders or establish broad game compatibility. `D3DM_MTL4` remains unset, using
Apple's documented default on macOS 27; no independent Metal-backend profiling
claim is made.

Build and run it with the exact runtime environment from the linked revision:

```bash
x86_64-w64-mingw32-g++ -std=c++17 -O2 -Wall -Wextra -Werror -static \
  diagnostics/d3d12_render_probe.cpp -o "$ROOT/Diagnostics/d3d12-render-probe.exe" \
  -ld3d12 -ldxgi -ldxguid -luser32 -lgdi32

python3 scripts/run_runtime_probe.py --wine "$WINE" --prefix "$WINEPREFIX" \
  --exe "$ROOT/Diagnostics/d3d12-render-probe.exe" --frameworks "$FRAMEWORKS" \
  --log "$HOME/Library/Logs/Gamekit/E2/new-render-check.log" --trace-images \
  --require 'PASS D3D12 clear/present/readback probe' \
  --require '/Contents/SharedSupport/wine/lib/external/D3DMetal.framework/Versions/A/D3DMetal'
```

## Installer and bootstrap

Downloaded from Valve's official HTTPS URL:
`https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe`.

- Saved artifact: `Artifacts/SteamSetup-20260915.exe` under the Gamekit data root.
- SHA-256: `7d3654531c32d941b8cae81c4137fc542172bfa9635f169cb392f245a0a12bcb`.
- Format: PE32 Intel 80386 NSIS installer, identical to the artifact inspected in E1.
- User completed the normal installer, kept its default folder and unchecked
  Run Steam before Finish. The installer process exited.
- Installed executable was found at
  `drive_c/Program Files (x86)/Steam/Steam.exe` inside the new prefix.
- Steam was launched separately, without compatibility flags, using the same
  explicit runtime environment and its installation directory as the working
  directory. This makes installer completion distinct from client readiness.

Bootstrap log progression (local time, UTC−05:00):

| Time | Observation |
|---|---|
| 13:23:37 | Initial updater, built May 20 2024, starts |
| 13:24:23 | Valve's win32 manifest version 1769731672 received |
| 13:24:39 | Initial ~336 MB update download completes |
| 13:24:50 | Update completes and Steam restarts into the Jan 29 2026 updater |
| 13:24:50 | Updated bootstrapper requests the win64 client manifest |
| 13:25:36 | Win64 manifest **1788652215** received from Valve |
| 13:25:45 | Second download completes |
| 13:25:55 | Update completes; September 2, 2026 updater launches the current client |

This is observed automatic progression, not a manually pinned or downgraded
Steam client. The final `Steam.exe` and active
`bin/cef/cef.win64/steamwebhelper.exe` are both **PE32+ x86-64**. The directory
name remains `Program Files (x86)` despite the client becoming 64-bit. The populated
prefix measured approximately **2.7 GiB** after login and lifecycle checks.

## Steam acceptance results — passed

The user completed sign-in/Steam Guard themselves and confirmed responsive Library
navigation over five minutes. No credentials or authentication codes were
collected. All launches used the same environment and no Steam compatibility
flags, updater pinning, DLL overrides, or graphics-setting workarounds.

| Cycle | Shutdown in bootstrap log | Relaunch in bootstrap log | User observation |
|---|---|---|---|
| 1 | 13:31:32 | 13:32:45 | Library responsive, no new login |
| 2 | 13:34:05 | 13:34:30 | Library responsive, no new login |
| 3 | 13:38:42 | 13:38:59 | Library responsive, no new login |

Before each relaunch, `lsof` scoped to this prefix's Steam directory confirmed
there were no remaining processes holding its files. No global process-name kill
or forced termination was used. This observes Steam process/file ownership; it
is not a claim that every Wine service must exit when the Steam window closes.

The third initial exit confirmation did **not** correspond to a shutdown entry:
Steam/helper processes and file handles remained after a 30-second observation.
After the user explicitly selected Exit again, the shutdown entry appeared and
all scoped handles were released before relaunch. The cause of that initial
non-exit was not established. A closed/hidden window alone is not adequate exit
evidence; this is why the process check is part of the acceptance procedure.

The first-launch and relaunch logs contain no matched unhandled-page-fault,
unhandled-exception, assertion-failure or fatal signature. This is a diagnostic
screen, not a guarantee of absence of all errors. The user also reported no
unexpected changes to the separate macOS Steam installation.

Raw evidence remains in `installer.log`, `steam-first-launch.log`,
`relaunch-1.log` through `relaunch-3.log`, `render.log`, and this prefix's Steam
`logs/bootstrap_log.txt`. The final client was left open for the user.

## E2.3 — Second fresh environment

The first client was normally exited and its scoped file handles verified closed
before starting the reproduction. The path `Environments/steam-eval-b` was checked
to be absent before Wine created it. No prefix, registry, Steam installation or
authenticated session was copied from environment A. Only the identical runtime,
installer artifact and compiled rendering probe were reused.

- Both Windows command architectures run and report Windows 10.0.19043.
- Rendering repeated with **1,811 Present calls over 15,007 ms**, nine correct GPU
  readback samples, and the same exact 4.0b2 loaded-image path. The user confirmed
  the second visible blue window. The submission-count difference is not a
  benchmark or a claimed rendering regression; display refresh was not measured.
- The user completed the installer again, with default folder and Run Steam
  unchecked. One orchestration shell timed out after reporting the installer PID;
  subsequent checks found the installer complete and no installer process active.
  The user confirmed they performed the dialog clicks. This was not an unattended
  installer test or evidence that the installer itself timed out.
- The user signed in separately and confirmed responsive Library navigation.
- No new compatibility flags, renderer changes or update pinning were introduced.

Second bootstrap sequence (local time, UTC−05:00):

| Time | Observation |
|---|---|
| 14:15:32 | Original 2024 bootstrapper starts |
| 14:16:19 | Win32 manifest 1769731672 received |
| 14:16:49 | First update completes |
| 14:16:50 | January 2026 updater starts |
| 14:17:36 | Win64 manifest **1788652215** received |
| 14:17:54 | Second update completes |
| 14:17:55 | September 2, 2026 updater starts the final client |

The final Steam executable and active `cef.win64/steamwebhelper.exe` are again
PE32+ x64. Lifecycle observations:

| Cycle | Normal shutdown | Relaunch | Result |
|---|---|---|---|
| 1 | 14:20:04 | 14:21:49 | Library responsive, login retained |
| 2 | 14:25:48 | 14:26:27 | Library responsive, login retained |
| 3 | 14:27:42 | 14:27:57 | Library responsive, login retained |

Every exit was checked with prefix-scoped `lsof` before the next launch. The user
confirmed all final checks and no unexpected effect on native macOS Steam.
The second run's captured logs have no matched unhandled-exception/page-fault,
assertion-failure or fatal signature. At **19:33:25 UTC**, the final client process
had been continuously running for **5 minutes 30 seconds**. The user then
reconfirmed responsive Library navigation and explicitly accepted E2. This final
timed session supplies the uninterrupted five-minute stability evidence for B;
the earlier initial session was shorter despite the earlier user confirmation.

## Comparison and minimal recipe

| Property | Environment A | Environment B |
|---|---|---|
| Fresh Wine prefix | Yes | Yes |
| Wine / Windows | Sikarugir 10.0 rev6 / 10.0.19043 | Same |
| Apple graphics | D3DMetal 4.0b2 | Same |
| Installer and rendering-probe hashes | Recorded above | Identical artifacts |
| Final Steam manifest | 1788652215 (win64) | Same |
| Final Steam / active CEF architecture | x64 / x64 | Same |
| Blue presentation + fenced GPU readback | Pass | Pass |
| User login and Library | Pass | Pass |
| Normal exit/relaunch cycles | 3 | 3 |
| Login retained across relaunches | Yes | Yes |
| Uninterrupted five-minute Library stability | Pass, initial session | Pass, final relaunch session |
| Prefix size after checks | About 2.8 GiB | About 2.6 GiB |
| Compatibility flags/registry workarounds | None | None |

The reproducible recipe for automation is:

1. Validate the pinned runtime and artifacts in `runtime-revision.md`.
2. Create a previously absent win64 prefix with the exact dependency environment;
   confirm Windows 10 and both PE architectures.
3. Execute the rendering probe through the crash-aware runner and confirm visible
   output and correct readback/loaded-image evidence.
4. Run the official Windows installer in that prefix, keeping the default folder.
   This feasibility run uses user clicks; automation is an E4 deliverable.
5. Launch the installed `Steam.exe` with an explicit argument array, the same
   environment, and **its installation directory as working directory**. Allow
   both automatic update stages and identify the final client/helpers afterward.
6. Have the user perform sign-in/Steam Guard in Steam. Check Library and session
   persistence, then verify real process shutdown before each relaunch.
7. Retain raw logs locally and publish only the normalized evidence. Preserve
   updater behavior; the observed manifest identifies the tested version and is
   not an instruction to freeze future Steam updates.

The complete command-level procedure is in `steam-feasibility-test.md`. Both
prefixes are retained; A is closed and the final B client is left open for the
user. Game installation and game-specific compatibility remain outside E2.
