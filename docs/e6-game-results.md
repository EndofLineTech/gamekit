# E6 game evaluation — current evidence

Recorded 2026-09-17 UTC. E6.2 (`gamekit-ec8.2`) remains **in progress**.
The [approved matrix](https://github.com/EndofLineTech/gamekit/pull/17) selects
Helldivers 2, Satisfactory and Stardew Valley, with separate 75 GiB download and
installed-data caps and a 15 GiB free-space reserve. The user started with
Satisfactory because Stardew was in use on another computer.

## Accepted launcher-feature package

The installed-game tiles, VC++ prerequisite correction and game Dock identity were
verified together using:

| Item | Identity |
| --- | --- |
| Package | `.build/packages/Gamekit-20260917T043130Z/Gamekit.app` |
| Source | `8e68abc91872befe151a841e8412277154930fc1`, clean tree |
| Version/build | 0.1.0 / 1, arm64 app with x86_64 Wine identity helper |
| App executable SHA-256 | `06e47532ec42dcb42ca79d707c275634431d593afc59271173cf8670da831318` |
| Helper SHA-256 | `5a4c55c7151bd97345289d0388b998286c182d072a9b9407a9d627bea082a797` |
| Host | M4 Pro, 24 GB RAM, macOS 27.0 (26A428) |
| Runtime | Sikarugir Wine 10.0 revision 6, unchanged Apple D3DMetal 4.0b2 |
| Steam client manifest | win64 `1788652215`, rechecked locally |
| VC++ runtime | 14.51.36247 x64 installed by Steam; native DLL preference |

The original package manifest remains build provenance. This record supplies the
subsequent acceptance evidence; it does not change the tested binaries.

### Checks completed

- Gamekit detected Satisfactory's transition from incomplete download to installed.
- Its native game tile launched through managed Windows Steam.
- The actual shipping game process appeared with **one Satisfactory Dock entry**,
  while Show Steam produced **one separate Windows Steam entry**.
- The user confirmed the game icon was correct. The repeated VC++ prompt was
  removed and remained absent on subsequent launches.
- A packaged-app Accessibility sequence passed game-tile launch, the visible game
  Dock title, normal Gamekit Quit, game survival, ordinary Gamekit reopen, Show
  Windows Steam and Stop.
- Scoped cleanup subsequently reported `alreadyStopped`; final inspection found
  zero running Satisfactory applications and zero Windows Steam applications.
  Satisfactory was not left running after the unattended tests.
- `make check` passed: 172 reported Swift tests, 19 Python tests (one opt-in skip),
  and native build. Hosted CI runs `35182186727` and `35182189520` passed; the UI
  suite reported 10 passes and three opt-in skips.
- Local XCTest still failed to initialize automation mode before executing tests.
  Direct Accessibility-based checks worked after the user granted permission and
  supplied the actual packaged-app/Dock evidence above.

## Satisfactory

| Measurement | Result |
| --- | --- |
| AppID / installed BuildID | 526870 / 24656030 |
| Game build tag | `++FactoryGame+rel-main-anniversary-2026-CL-502094` |
| Engine | Unreal 5.6.1, CL 502094 |
| Renderer | D3D12 / SM6 confirmed in local game log |
| Manifest download bytes | 13,043,930,640 (12.148 GiB) |
| Manifest staged bytes | 30,223,576,850 (28.148 GiB) |
| Installed game bytes | 30,197,902,335 (28.124 GiB) |
| Quality | Medium, user selected; saved quality values corroborate it |
| Resolution | Saved 1800×1169; user reported menu maximum 1800×1168 |
| Desktop | macOS logical 1800×1169 at 2× backing scale |
| Install | Passed |
| Launch / game identity | Passed with the accepted package above |
| Gameplay | User entered gameplay; complete 15-minute assessment pending |
| Audio/input/save reload | Full matrix confirmation pending |
| Performance | Unmeasured; no FPS pass claimed |

This is **not a 1920×1080 result**. The available-resolution deviation is recorded
rather than silently treated as the planned condition. Complete checks for render
scale, upscaling, frame generation and global illumination remain part of the
gameplay run. These byte counts come from the game's manifest; separately delivered
shared prerequisites are not being represented as fully accounted network totals.
The data volume had about 87 GiB available after the work, above the reserve.

### Findings resolved during launcher acceptance

1. **Repeated VC++ installation prompt (`gamekit-5se`).** The installed runtime
   was newer than the bundled installer, but Wine's builtin DLL version resources
   failed the bootstrapper's check. The verified native-DLL preference resolves
   this without falsifying registry state. See [prerequisite evidence](visual-cpp-prerequisites.md).
2. **Duplicate/misnamed Dock entries (`gamekit-6h9`).** Removing the prerequisite
   prompt removed the extra foreground bootstrapper. Runtime registry renaming
   still failed the visible Dock. Named loader bundles with shared PE image
   identity passed the actual game/Dock test. See [identity evidence](game-dock-identity.md).

These were explicitly user-requested launcher/runtime integration changes during
E6.2. No game binary was patched. Obsolete generated-cache inspection/cleanup is
tracked separately as `gamekit-m3k`.

## Other selected titles

Helldivers 2 and Stardew Valley have not yet completed E6.2 installation/gameplay
evaluation. Their planning estimates and dependency risks remain in the approved
matrix. Launcher acceptance for Satisfactory establishes neither their
compatibility nor a full Satisfactory gameplay/performance pass.
