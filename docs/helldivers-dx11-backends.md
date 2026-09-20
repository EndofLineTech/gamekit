# Helldivers 2: `--use-d3d11` with DXMT and DXVK

Issue: `gamekit-mkr`. Investigation on 2026-09-19, Helldivers build **24826606**,
M4 Pro/24 GB, macOS 27 build 26A428, Wine 10/Sikarugir rev6 with the accepted
`driver-version-1` runtime and Apple D3DMetal 4.0b2.

## Result

**Keep Metal 3 compatibility for this game.** Neither installed alternative
reached the ship with `--use-d3d11`. This corrects the earlier blanket assertion
that Helldivers cannot have a DX11 path because it is a DX12 game.

| Backend | Bounded observation | Renderer evidence |
| --- | --- | --- |
| DXMT `dxmt-0.80-compat2` | Startup crash reporter; same outcome with an isolated fresh shader cache | Maximum feature level `11_1`; minimum required `12_0` rejected |
| DXVK `dxvk-macos-1.10.3-compat2` | Startup crash reporter; same outcome with an isolated fresh shader cache | D3D11 probes feature level `12_0`, then reports unsupported |
| Apple Metal 3, same flag | Reached rendered ship | Both D3D11 and D3D12 device creation observed; gameplay rendering API unresolved |

Steam's game-process log confirms forwarding of the actual argument:

```text
"helldivers2.exe" --bundle-dir data --release --use-d3d11
```

The diagnostic renderer logs contain these sanitized excerpts:

```text
DXMT:
info:  Maximum supported feature level: D3D_FEATURE_LEVEL_11_1
err:   Minimum required feature level D3D_FEATURE_LEVEL_12_0 not supported

DXVK:
info:  D3D11CoreCreateDevice: Probing D3D_FEATURE_LEVEL_12_0
err:   D3D11CoreCreateDevice: Requested feature level not supported
```

**API version and feature level are different.** Calling D3D11 does not imply
that a feature-level-11 implementation satisfies every request. This establishes
a concrete rejected startup request on both installed backends. It does not
prove that this request is the sole cause of the subsequent crash, that every
request is for gameplay rendering rather than hardware probing, or that the
gameplay DX11 path is absent in this build.

Both initial alternative-backend dumps record access violation `0xc0000005` at
`helldivers2.exe` address `0x14007f13b`. The available dump evidence does not
establish a causal stack from the feature-level rejection to that instruction.
DXVK also logs `Adapter is not a DXVK adapter` before its feature-level probe;
adapter interoperability remains another possible contributor.

## Flag research and interpretation

- [Valve Proton maintainer comment, 2024-12-30](https://github.com/ValveSoftware/Proton/issues/7486#issuecomment-2565570142):
  D3D12 initialization can occur for hardware probing despite `--use-d3d11` in
  the arguments. DLL loads and device creation alone cannot identify the
  rendering API.
- [DXVK issue 3905](https://github.com/doitsujin/dxvk/issues/3905) documents
  historical use of the DX11 flag, including HDR limitations also reported on
  Windows. This is evidence against the blanket DX12-only claim, not a guarantee
  for today's game/runtime combination.
- [2026 Steam community report](https://steamcommunity.com/app/553850/discussions/0/803468669855253390/)
  describes DX11 crashes and DXVK use on another setup. It is a community report,
  not qualification of these macOS payloads.

No official current-build guarantee was established. The exact forwarded flag,
renderer logs and controlled observations are stronger evidence here than
community launch-option recipes. Cache isolation did not change the result.

## Reproduction and restoration

`HelldiversDX11AcceptanceTests` is an opt-in **observation and restoration**
harness. A passing Swift test means the bounded observation and cleanup
completed; it does not mean that the game rendered successfully. Inspect the
screenshots and renderer logs independently.

With games closed, set these environment variables and run
`swift test --filter HelldiversDX11AcceptanceTests`:

| Variable | Value |
| --- | --- |
| `GAMEKIT_HELLDIVERS_DX11_BACKEND` | `dxmt`, `dxvk`, or `metal3` |
| `GAMEKIT_E6_HELLDIVERS_D3D11` | `1` |
| `GAMEKIT_E6_APPID` | `553850` |
| `GAMEKIT_E6_OBSERVE_SECONDS` | `90` |
| `GAMEKIT_E6_WARNING_SETTINGS` | Absolute path to this managed prefix's Helldivers `user_settings.config` |
| `GAMEKIT_E6_EVIDENCE` | Absolute private screenshot/evidence directory |
| `GAMEKIT_E6_PACKAGE` | Optional diagnostic package containing `Contents/Frameworks/WineGameIdentity.dylib` |
| `GAMEKIT_HD_DX11_FRESH_CACHE` | Optional `1` to isolate the shader cache |

Do not also enable the standalone `GAMEKIT_E6_OBSERVE_LAUNCH` test or supply a
UI launch script. The wrapper invokes the launch observer itself and passes
the flag through Steam's `-applaunch` arguments. Cold Steam startup consumed
roughly 40 seconds in some runs; 45-second observations provided insufficient
game time and are not meaningful negative API-trace evidence.

The wrapper snapshots backend preference and settings bytes, stops the managed
session, and restores both after observation. Optional fresh-cache runs move
the original directory aside, pin directory identities, retain the trial cache
under `.gamekit-dx11-trial-<UUID>`, and restore the original directory under
installation/execution leases after verifying that managed processes stopped.
Both fresh-cache runs and final renderer-log runs completed graceful cleanup
and restoration. Saves and the accepted runtime were preserved.

## Diagnostic scope

`diagnostics/DeviceAPICapture.c` is an optional x86_64 diagnostic interposer,
not part of the normal app build. Compile with
`GAMEKIT_DEVICE_API_LOG_DIRECTORY` pointing at a private existing directory,
then link it into a diagnostic identity helper compiled with
`GAMEKIT_DEVICE_API_CAPTURE`. The helper arms capture only for the mapped
Helldivers image or the mapped AppID 900001 probe image. Inspected native
D3DMetal exports use the Windows x64 ABI (`ms_abi`).

The interposer passes device-creation calls through and records at most 32
JSON events per process in owned, single-link, mode-0600 files with no-follow
opens. A standalone Apple D3D11 probe served as the positive control. With the
flag, the Apple game run recorded five D3D11CreateDevice calls (one returning a
device), followed by a successful D3D12CreateDevice returning a device. It does
not trace draw calls or presentation and therefore cannot resolve gameplay API
selection. It does not capture alternative implementations' device entry points.

For alternative-backend logs, a separate diagnostic identity helper used
`diagnostics/GraphicsBackendExperiment.h`, `GAMEKIT_RENDERER_EXPERIMENT`, and a
private `GAMEKIT_RENDERER_LOG_PATH`. This produced the decisive excerpts above.
Raw logs, screenshots and dumps remain private in `.build/mkr-*`.

## Boundary of this investigation

These installed alternatives are **not validated for Helldivers DX11**. There
is no automatic Helldivers flag or feature-level workaround to ship. A useful
next experiment requires a backend/runtime that genuinely satisfies the
observed request, or evidence of a supported game option that avoids it; merely
repeating launches or advertising unsupported features would not validate it.
The successful Apple control is startup evidence, not mission-level graphics,
performance, audio or save/reload acceptance.

Follow-up research is tracked as `gamekit-zl5`. Local delivery checks passed:
`make check DERIVED_DATA=.build/graphics-xcode` (256 Swift tests, 42 Python tests
with one skip, Debug app build), diagnostic C compilation with
`-Wall -Wextra -Werror`, and the final real Apple probe with capture enabled
(shader draw/readback/presentation passed and device-creation events recorded).
