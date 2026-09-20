# 7 Wonders II: legacy display-requirements failure

Issue: `gamekit-0wm`. Investigation on **2026-09-20**.

**Result: Unplayable on the tested setup; no validated workaround.** Further
retries are deferred under the user's bounded-investigation preference.

## Evidence

- Managed Steam AppID **15900**, build **210749**; executable
  `WondersII_1_13.exe`.
- M4 Pro/24 GB, macOS 27 build 26A428; accepted Sikarugir Wine 10 rev6
  `driver-version-1` runtime, shared Metal 3, no per-game graphics override.
- The user reported a startup error requiring at least **16-bit color and
  800×600**. A subsequent normal Steam launch reproduced the exact dialog.
- Read-only executable import inspection found `DirectDrawCreate` from
  `ddraw.dll` and `Direct3DCreate8` from `d3d8.dll`. This does not identify a
  successfully rendered gameplay API.

A 32-bit read-only probe in a fresh disposable prefix using the selected runtime
reported:

| Probe | Normal desktop | Explicit 800×600 virtual desktop |
| --- | --- | --- |
| GDI / current Win32 display | 1800×1169, 32-bit color | 800×600, 32-bit color |
| Win32 enumerated 800×600 modes | 0 | 8-, 16-, and 32-bit |
| DirectDraw enumerated 800×600 modes | 0 | 8-, 16-, and 32-bit |
| D3D8 enumerated 800×600 modes | 0 | X8R8G8B8 and R5G6B5 |

DirectDraw and Direct3D 8 creation succeeded in the probe. Thus the warning is
not evidence that the runtime universally reports less than 800×600 or 16-bit
color. The missing enumerated legacy mode is a concrete compatibility lead,
but not a proven sole cause of the game's failure. The fresh probe is not an
in-process trace of the game's own checks.

## Bounded comparisons

1. **Explicit virtual-desktop probe:** `explorer.exe /desktop=GamekitLegacyProbe,800x600`
   exposed the missing modes. The initial observation lost the child output;
   it was corrected to require a completed on-disk child report rather than
   treating Explorer's exit as probe success.
2. **Per-executable desktop probe:** Wine 10's `win32u/winstation.c` reads
   `HKCU\Software\Wine\AppDefaults\<exe>\Explorer\Desktop`, while the named
   size is in `HKCU\Software\Wine\Explorer\Desktops`. The probe confirmed
   that this configuration exposes 800×600 when applied to the probe executable.
3. **Normal Steam game trial:** both game-specific values were initially absent.
   The helper set `WondersII_1_13.exe\Explorer\Desktop` to `Gamekit15900` and the
   named size to `800x600`, then verified readback. The real game still displayed
   the same requirements error. The game was closed, the managed session stopped,
   and both values restored to absent. No default desktop or host display setting
   was changed. Whether Steam's process desktop selection bypasses this override
   remains unconfirmed.
4. **Explicit isolated game trial:** only the approximately 21 MB game directory
   was copied, with a fresh prefix and the accepted external runtime. The bounded
   capture showed Wine initialization but did not establish a game menu or a
   working launch. This does not prove that the display workaround itself failed;
   launch context, working directory or other startup requirements remain possible
   contributors. No further launch attempts were made.

All disposable probe prefixes and the small game copy were removed after verified
scoped shutdown. The primary registry trial was reverted. The installed game,
accepted runtime and saves were preserved. Screenshots and raw output remain
private under `.build/0wm-*`; no full Steam environment was cloned.

## Reproducible diagnostics

- `diagnostics/legacy_display_probe.cpp`: Win32, DirectDraw and D3D8 enumeration;
  accepts an optional report-file path and emits an explicit completion marker.
- `LegacyDisplayProbeTests`: opt in with `GAMEKIT_LEGACY_DISPLAY_PROBE` pointing
  to the x86 probe. Optional `GAMEKIT_LEGACY_DESKTOP=800x600` or
  `GAMEKIT_LEGACY_APP_DESKTOP=1` exercises the two isolated desktop configurations.
- `diagnostics/seven_wonders_desktop.c`: explicit `query`, `apply`, or `restore`
  for only the two named game settings. Unknown existing values are refused;
  application requires both values initially absent.
- `SevenWondersDesktopTests.configure`: opt in with
  `GAMEKIT_SEVEN_WONDERS_DESKTOP` and `GAMEKIT_SEVEN_WONDERS_DESKTOP_TOOL`.
  It requires games closed and uses scoped Wine registry calls and shutdown.
- `SevenWondersDesktopTests.observe`: opt-in disposable-copy observation via
  `GAMEKIT_SEVEN_WONDERS_TRIAL=1` and a fresh
  `GAMEKIT_SEVEN_WONDERS_EVIDENCE` directory. A completed observation is not a
  game-success assertion.

The [PCGamingWiki entry](https://www.pcgamingwiki.com/wiki/7_Wonders_II) lists
DirectX 8.1-era requirements but supplies no verified fix for this setup. The
next useful investigation, if reprioritized, is the actual game's desktop/API
selection under Steam, rather than further global resolution changes or assuming
the installed DX11 backends provide a D3D8 solution.
