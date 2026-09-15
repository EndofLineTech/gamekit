# E2.2 — First Windows Steam evaluation

Date: 2026-09-15. Bead: `gamekit-9jv.2`.

## Status

**E2.2 passed in the first fresh environment.** Independent rendering, interactive
installation, automatic updates, user login/Library and three normal exit/relaunch
cycles completed. E2.3 still requires a second complete fresh installation.

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

## Next gate

E2.3 must repeat the complete installation, rendering and Steam acceptance in a
second fresh prefix. These successful first-environment results do not yet close
the E2 epic or establish game compatibility.
