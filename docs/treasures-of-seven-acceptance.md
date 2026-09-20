# 7 Wonders: The Treasures of Seven — windowed acceptance

Issue: `gamekit-dmi`. Recorded **2026-09-20**.

**Playable with caveats: use windowed mode.** After reporting `D3DERR_INVALIDCALL`, the user
reported “Working great now” and explicitly confirmed audio, controls, and
saving/resuming all work.

## Working configuration

- Steam AppID **16030**, installed build **286184**; bundled `versioninfo.xml`
  identifies product version **1.0**.
- Executable: `7 Wonders - Treasures of Seven.exe`.
- M4 Pro/24 GB, macOS 27 build 26A428; Sikarugir Wine 10 rev6,
  accepted `driver-version-1` runtime.
- Normal managed Steam launch, shared Metal 3 setting, no per-game backend
  override. The actual legacy path is **Direct3D 8 / WineD3D OpenGL**, corroborated
  by executable imports and the live D3D8/WineD3D/OpenGL diagnostics.
- Saved game settings: **ScreenWidth=1024**, **ScreenHeight=768**,
  **FullScreen=False**. No additional launch options are required for this result.

Use the game's **Options → Fullscreen** checkbox to select windowed mode. The
bundled readme documents this option. In the observed run, the startup error was
followed by the name-entry menu, allowing the game to continue. If that menu is
reachable after dismissing the initial error, configure windowed mode there.

The profile is stored at
`C:\ProgramData\MumboJumbo\7 Wonders - Treasures of Seven\1.00\Data\UserProfile.xml`.
It also contains progress; use the game's UI rather than replacing the whole file.
The agent inspected these settings but did not edit the profile or saves.

## Investigation and evidence

One bounded diagnostic launch captured the exact error dialog and subsequently
the rendered name-entry menu. Wine reported:

```text
NtUserChangeDisplaySettings ... returned -2
wined3d_swapchain_state_set_display_mode Failed to set display mode, hr 0x8876086a
```

These are concrete display-mode-change failures, although the capture does not
prove the exact mapping from that HRESULT to the game's displayed
`D3DERR_INVALIDCALL`. The next launch, with the saved windowed configuration,
showed the rendered game menu without an observed error dialog and without those
display-mode-change errors. Both bounded sessions ended with graceful scoped
cleanup. The user supplied the functional acceptance beyond menu observation.

The first diagnostic also emitted many buffer-map warnings. They were **not**
treated as a demonstrated cause: Wine's implementation permits those malformed
boxes for buffers, and upstream commit
[`da9f8090`](https://github.com/wine-mirror/wine/commit/da9f8090bfcdd6cdf607d6c984688a1d8709af85)
explicitly describes the warning as relatively harmless and misleading.
OpenGL context fallback and two `GL_INVALID_FRAMEBUFFER_OPERATION` diagnostics
were also observed; the latter remained in the successful windowed observation.
Their presence alone is not evidence of an unusable game.

No runtime/DLL patch, global display change, or registry workaround was needed.
This result does not qualify fullscreen mode, measured FPS, an exact session
duration, DXMT, or DXVK. It is separate from the unresolved **7 Wonders II**
display-requirements failure (`gamekit-0wm`).

## Diagnostic reproduction

`diagnostics/LegacyD3DTrace.m` is linked only into an explicitly built diagnostic
identity helper, with `GAMEKIT_LEGACY_D3D_LOG` naming a fresh private output file.
It matches this title's executable in a managed Wine session and redirects its
stderr for a bounded observation. The retained version enables only D3D/display
error channels to avoid the initial warning flood; it is not part of the normal
app. `GameEvaluationLaunchTests` now allows AppID 16030 for the same bounded
observation/cleanup flow used by the other approved titles.

Raw captures remain private under `.build/dmi-*`. No game/environment copies were
created. A passing observation test establishes capture/cleanup completion, not
gameplay acceptance; the latter comes from the user's confirmation above.
