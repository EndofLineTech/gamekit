# E6 compatibility findings and next-scope recommendation

Updated **2026-09-20**. E6.2 baseline evaluation now has recorded outcomes for
all three approved games, including the previously deferred Stardew save/reload
check. This is the E6.3 findings report; functional acceptance, launch failures
and unmeasured performance remain distinct.

## Current outcomes

| Game / build | Accepted path and scope | Limitations |
| --- | --- | --- |
| Stardew Valley / 16826371 | **Playable** on the Windows MonoGame DesktopGL path. User reports gameplay works great and explicitly confirms saving/reloading. | Duplicate macOS/game cursors (`gamekit-vl6`); hardware-cursor preference trial did not resolve it. No FPS measurement or independently verified resolution/duration. |
| Satisfactory / 24656030 | **Playable** Apple/D3DMetal baseline and user-accepted DXMT functional checks, including save/reload. Retained shared default is Metal 3. | Temporary movement stutter on default/DXMT paths (`gamekit-gi0`). Tested DXVK payload is **Unplayable** (`gamekit-7j9`); later trials did not establish a fix. |
| Helldivers 2 / 24826606 | Apple Metal 3 path reaches the ship and has user-confirmed control/personal-prototype acceptance. | No full mission/save-reload/performance acceptance claimed. Tested DXMT/DXVK `--use-d3d11` startup paths fail; gameplay rendering API in the Apple same-flag control remains unresolved. |

The current accepted host is M4 Pro/24 GB, macOS 27 build 26A428, Sikarugir
Wine 10 rev6 with the `driver-version-1` runtime. The original Satisfactory
functional baseline predates the later runtime revisions; it is not a fresh
benchmark of every current combination. Exact recipes and dates are retained in
the evidence links and [public compatibility wiki](https://endoflinetech.github.io/gamekit/).

## Failure classification

| Finding | Classification supported by evidence | Disposition |
| --- | --- | --- |
| Repeated VC++ installation prompt; duplicate/misnamed Dock entries | Launcher/runtime integration defects | Resolved and verified; see the prerequisite and game-identity reports. |
| Helldivers AVX startup gate and post-warning text-input crash | Runtime capability advertisement and compatibility issues | Resolved by documented AVX advertisement and the text-input backport, not by modifying the game. |
| Helldivers Dock-edge cursor exposure | Game-specific fullscreen/capture interaction | Accepted scoped fullscreen display-capture configuration; this does not establish the same fix for Stardew. |
| Steam Cloud sync failure or concurrent-account prompt | Steam-owned launch gate | User resolves it. A queued request is neither a game crash nor proof of launch. |
| Stardew duplicate cursor | Game/runtime presentation-input interaction; exact cause unconfirmed | Open `gamekit-vl6`; original preferences restored after the failed comparison. |
| Satisfactory DXVK stalls | Observed backend/gameplay incompatibility; root cause unconfirmed | Open `gamekit-7j9`. GPU-query waits explain a recorded stall sequence but not every later choppy run. |
| Satisfactory temporary default/DXMT stutter | Shared observed symptom; cause unconfirmed | Open `gamekit-gi0`. Do not label it a DXMT-only regression. |
| Helldivers alternative-backend startup | Rejected D3D11 feature-level 12_0 request followed by crash | Open research `gamekit-zl5`. API version and feature level are different; causality is not fully established. |

## Recommended next scope

1. **Keep the working recipes and published caveats.** Stardew uses its normal
   Windows launch; Satisfactory retains Apple/Metal 3 with DXMT as an accepted
   alternative; Helldivers retains Metal 3 and its scoped compatibility settings.
2. **Address Stardew's cursor only with a specific, bounded hypothesis**
   (`gamekit-vl6`). Verify the effective window/cursor mode before further changes;
   record and defer unsuccessful attempts under the user's retry limit.
3. **Defer repeated Satisfactory performance trials** (`gamekit-7j9`,
   `gamekit-gi0`) until there is a controlled movement/frame-pacing experiment
   capable of distinguishing first-use compilation from sustained rendering work.
4. **Qualify a complete authorized ARM64 Wine/FEX candidate** (`gamekit-5wd`)
   when available. Only then proceed to actual macOS 28 acceptance (`gamekit-m47`).
5. Keep Helldivers feature-level research (`gamekit-zl5`) and the D3DMetal
   shader-rejection reproducer (`gamekit-eac`) lower priority than user-visible
   defects. No visible impact from the latter has been established.

The observations do not currently justify a per-game-prefix migration, broader
host-support claim, or a generic graphics-performance workaround. No additional
game downloads or operating-system migration are part of this report.

## Evidence

- [Baseline and Stardew acceptance](e6-game-results.md)
- [Satisfactory backend gameplay acceptance](satisfactory-backend-gameplay.md)
- [Satisfactory performance investigation](satisfactory-performance-investigation.md)
- [Helldivers DX11 backend investigation](helldivers-dx11-backends.md)
- [Helldivers cursor/capture findings](helldivers-stalls-and-cursor.md)
- [VC++ prerequisite correction](visual-cpp-prerequisites.md)
- [Game Dock identity](game-dock-identity.md)
- [AVX capability](avx-capability.md)
- [Text-input runtime delivery](runtime-text-input-delivery.md)

The original three-game manifest totals were 33.751 GiB downloaded and 51.015 GiB
installed, within the approved separate 75 GiB caps; shared prerequisites and
updater traffic were not fully included. Those historical totals are not a
fresh disk-space measurement. Raw logs, captures and user saves remain private.
