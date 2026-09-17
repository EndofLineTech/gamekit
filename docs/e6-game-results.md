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
| Gameplay | User confirmed the full 15-minute checklist was completed successfully |
| Audio/input/save reload | User confirmed rendering, audio, keyboard/mouse and save/reload all worked; no issues reported |
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

## Helldivers 2 — reproducible launch failure

**Later experimental result:** the [Wine 10 text-input backport](helldivers-text-input-backport.md)
resolves the post-AVX startup crash and reaches the ship scene in an isolated
runtime/prefix. The user confirmed controlling the game. This is changed-recipe
evidence, not a rewrite of the original baseline or a complete mission/FPS pass.

The following is the original baseline with AVX advertisement unset. A subsequent
user-requested [AVX experiment](avx-capability.md) clears that CPU gate with
`ROSETTA_ADVERTISE_AVX=1`, but exposes a driver-version warning and a crash after
Continue. It does not turn this baseline into a gameplay pass.

The user authorized accepting the displayed PlayStation software EULA. Windows
Steam's install dialog showed 22.25 GB. Installation completed with StateFlags=4:

| Measurement | Result |
| --- | --- |
| AppID / installed BuildID | 553850 / 24826606 |
| Download bytes | 22,685,221,824 (21.127 GiB) |
| Staged bytes | 24,046,538,179 (22.395 GiB) |
| Installed bytes | 23,886,952,713 (22.246 GiB) |
| Install | Passed |
| Launch | Failed twice under the same recorded runtime configuration |
| Gameplay / graphics / audio / input / saves / FPS | Not tested: interactive game menu was not reached |

Both bounded 60-second observations produced the same **Fatal Error!** dialog:

> Incompatible CPU detected! Your CPU must support AVX instructions to run this game.

Private captures are retained locally in `.build/e6-helldivers-launch-1/` and
`.build/e6-helldivers-launch-2/`. Each observation ended with graceful managed-session
cleanup. The successful operator-test result means the observation/cleanup ran;
it does **not** mean the game passed.

This is a CPU-capability startup gate on the current recipe, not proof that Apple
silicon has no possible translation path. `gamekit-5ta` tracks investigation of
guest CPU feature exposure and documented runtime/Rosetta capabilities. The
previously documented anti-cheat risk has not been established as the cause of
this result. No CPU flags or game-specific workarounds were applied.

## Stardew Valley — installed and menu reached; gameplay deferred

The user confirmed it was available for evaluation here. Windows Steam's install
dialog showed 659.8 MB. The Windows build installed successfully:

| Measurement | Result |
| --- | --- |
| AppID / installed BuildID | 413150 / 16826371 |
| Package version | 1.6.15.24356, from installed dependency metadata |
| Frameworks | .NET 6.0.32 win-x64; MonoGame.Framework.DesktopGL 3.8.0.1641 |
| Download bytes | 510,452,384 (0.475 GiB) |
| Staged bytes | 749,358,116 |
| Installed bytes | 691,846,347 (0.644 GiB) |
| Install | Passed |
| First launch observation | Blocked by Steam concurrent-account-use dialog |
| Launch/rendering after that gate cleared | New / Load / Co-op / Exit menu captured |
| Gameplay, audio/input, save/reload, measured FPS | Deferred by user; not passed by inference from the menu |

The first observation showed that another computer was playing a game and that
continuing would disconnect it. The assistant did not continue through that gate;
the local session was closed gracefully. The user chose to close the other game
first. This is not a Stardew compatibility failure.

After the account gate cleared, the Windows game rendered its startup scene and,
when foregrounded, the New / Load / Co-op / Exit menu. The installed metadata
identifies the DesktopGL framework; no live OpenGL driver-version measurement is
claimed. The initial capture filters and foreground handling missed the game
window, and an intermediate attempt to capture hidden windows produced
capture errors. These were observation-harness gaps, not game failures. The
operator now foregrounds the selected owned game and captures visible owned
windows without restricting them to layer zero.

Private captures are under `.build/e6-stardew-launch-1/` through
`.build/e6-stardew-launch-4/`. The last captured menu is `sample-5-0.png` in run 4.
Some earlier bounded observations required the scoped forced-stop fallback; the
final foreground observation ended with graceful cleanup. No existing save was
opened or overwritten. The user chose to perform the 15-minute gameplay and
save/reload check later, so Stardew remains installed and closed.

## Budget accounting

The three game manifests record approximately **33.751 GiB downloaded** and
**51.015 GiB installed**, within the separate 75 GiB caps. These totals do not
claim complete accounting of separately delivered shared prerequisites, external
updaters or all network retries. The host still reported about **63 GiB available**
after installation, above the 15 GiB reserve.

### Continuation checkpoint

PRs #17–#20 were merged into `dev` on 2026-09-17, ending at
`c4905fdd438abe7dd779c6e666062f60c51bd1fd`. The accepted package's application,
core, tooling and build sources match the merged branch.

Before the permission restart, a scoped operator test sent
`steam://install/553850` to the owned Windows Steam client. Command delivery passed;
the dialog contents and sizes had not yet been visually verified, and its download
had not been confirmed at that point. Available disk space was still
about 87 GiB.

Steam's Windows window exposes no usable child controls through macOS Accessibility.
Window capture was denied. The user granted capture permission and requested a pause
to restart iTerm. After resume, Steam-window capture and measured pointer events
worked; installation and observation results above supersede that pause. Captures
remain local. The user subsequently authorized Stardew testing here.

### Reproducing a bounded launch observation

With the approved Windows game installed, window-capture/Accessibility permissions
enabled, and other managed games closed, use a fresh private evidence directory:

```bash
GAMEKIT_E6_OBSERVE_LAUNCH=1 GAMEKIT_E6_APPID=553850 \
GAMEKIT_E6_OBSERVE_SECONDS=60 \
GAMEKIT_E6_PACKAGE="$PWD/.build/packages/Gamekit-20260917T043130Z/Gamekit.app" \
GAMEKIT_E6_EVIDENCE="$PWD/.build/e6-observation-new" \
  swift test --filter GameEvaluationLaunchTests
```

The operator allows only the approved Helldivers/Stardew AppIDs and a 15–90 second
observation. It foregrounds the owned game, captures bounded samples of visible
owned windows, and closes the managed session afterward. Inspect the captures to
classify launch outcomes; the operator's pass/fail concerns its execution and
cleanup, not game compatibility. Transient window disappearance is recorded as a
capture gap. Authentication, cloud conflicts and license decisions remain explicit
user interactions. This does not replace the human gameplay/audio/save assessment.
