# Helldivers Wine 10 text-input backport experiment

**Delivery update:** [normal Gamekit runtime selection](runtime-text-input-delivery.md)
now supports this component revision, with packaged-app startup/regression checks
and a rollback button. The experiments below retain their original scope.

Investigation `gamekit-1ae`, September 17, 2026. This continues the
[initial text-input diagnosis](helldivers-text-input.md).

**Result:** the experimental backport resolves the reproduced post-warning
startup crash and reaches the actual ship scene. The user confirmed controlling
the game; private captures show character movement, the bridge/NPC and menu
navigation. Mission gameplay, sustained performance, audio quality and a full
save/reload acceptance test remain unverified.

## Controlled comparison

Both variants use the existing Sikarugir Wine 10 engine and unchanged Apple
D3DMetal 4.0b2 payload. Both advertise AVX. Each uses its own APFS-cloned runtime
and local Steam prefix with fresh Gamekit metadata and launcher caches.

| Variant | System function provider | Reconversion interface | Helldivers result |
| --- | --- | --- | --- |
| Accepted runtime | `E_NOTIMPL`, null | Unavailable | Original post-warning crash |
| Locally built unmodified Wine 10 `msctf.dll` | `E_NOTIMPL`, null | Unavailable | Control reproduces crash-report dialog |
| Same Wine 10 source plus text-input backport | `S_OK`, non-null | `S_OK`, non-null | Language/setup/title screens, intro video, then ship scene |

The changed module is **msctf.dll**, which implements Windows text-input
services. There is no graphics-driver version spoof. The all-65535 GPU warning
still appears; Continue permits startup with the backport. This comparison
supports the text-input change as the fix for this reproduced startup failure.

The experiment rebuilds one PE DLL, not the entire engine. The remainder of the
validated engine and graphics payload is retained. The patch implements the
upstream compatibility stubs; it is not a full text-reconversion implementation
or a claim that every application using text services has been validated.

## Source and artifact identities

- Wine 10.0 source commit: `b073859675060c9211fcbccfd90e4e87520dc2c2`.
- Source archive: `https://github.com/wine-mirror/wine/archive/refs/tags/wine-10.0.tar.gz`.
- Downloaded archive SHA-256:
  `b3edf134a5698d55bd210f11c3ae833c943abcece75810f6aa8cbd7a9f293ff7`.
- Backport: [`diagnostics/wine10-msctf-backport.patch`](../diagnostics/wine10-msctf-backport.patch),
  adapted from Valve Wine commits `1527888` and `f8442ce`. It excludes the
  incomplete unrelated ntdll exception-code fragment in the latter commit.
- Additional `include/ctffunc.idl`: pinned to Valve Wine commit
  `f8442ce00f4eeb010c0e428dfa1b91c00b313018`; SHA-256
  `b93d84a52481c5252652212bc5490ca3a50d27c675716e4621a368a519c05e30`.
- Unmodified locally built DLL SHA-256:
  `879f013ac17231de312e04c0db6b4f6dcbc4ee77d0bc439099b6dbe92286f9ae`.
- Backported DLL SHA-256:
  `bb8db266526cff89c2bc6a436482b24c632c13596c1864adb4cb2e42e58fca8b`.

Wine and the adapted changes are LGPL-2.1-or-later. The original source archive
includes `COPYING.LIB`; the additional IDL retains its upstream copyright and
license notice. The repository stores the patch and reproduction instructions;
compiled DLLs and the runtime copies remain local. These hashes identify this
specific local build, including its toolchain/debug-path effects.

## Build reproduction

The host has Xcode 27, MinGW-w64 14.0.0_3 and Homebrew Bison 3.8.2. macOS's
bundled Bison was too old, so the build explicitly selects the newer executable.
From a fresh extracted Wine 10 source directory, first build the control:

```bash
./configure --build=x86_64-apple-darwin --enable-win64 --disable-tests \
  --without-x --without-freetype CC='clang -arch x86_64' \
  CXX='clang++ -arch x86_64' BISON=/opt/homebrew/opt/bison/bin/bison
make -j4 dlls/msctf/x86_64-windows/msctf.dll
cp dlls/msctf/x86_64-windows/msctf.dll ../baseline-msctf.dll
```

Apply the tracked patch to that source tree and fetch the pinned additional IDL:

```bash
git apply /absolute/path/to/gamekit/diagnostics/wine10-msctf-backport.patch
curl -fL \
  https://raw.githubusercontent.com/ValveSoftware/wine/f8442ce00f4eeb010c0e428dfa1b91c00b313018/include/ctffunc.idl \
  -o include/ctffunc.idl
make -j4 dlls/msctf/x86_64-windows/msctf.dll
cp dlls/msctf/x86_64-windows/msctf.dll ../backport-msctf.dll
```

The patch was checked against clean Wine 10 source and reverse-checked against
the exact modified source used to build the tested artifact. The unused X/font
build components do not affect this PE-only DLL target.

## Probe and local isolation

`text_input_probe.cpp` can load an explicitly supplied DLL through its class
factory, avoiding COM registration changes. Give standalone candidates distinct
filenames: the literal name `msctf.dll` initially resolved to the installed
module and correctly failed the expected-capability assertion. Renamed control
and backport candidates then produced the expected 0/1 comparison. The cloned
runtime/prefix subsequently passed the ordinary registered COM probe as well.

`HelldiversTextInputExperimentTests.prepare` requires a fresh destination,
acquires the source installation/execution leases and verifies its processes
are stopped. It uses `cp -cR` APFS clones with no ordinary-copy fallback,
creates a fresh experimental record, then replaces only the cloned runtime and
prefix `msctf.dll` entries. It verifies the candidate hash and that the original
runtime DLL hash is unchanged. Separate profile identities distinguish the
control from the backport. No production runtime selection is changed.

From the Gamekit checkout, using the recorded local artifact:

```bash
GAMEKIT_PREPARE_TEXT_INPUT_EXPERIMENT=1 \
GAMEKIT_TEXT_INPUT_EXPERIMENT="$PWD/.build/fresh-text-input-experiment" \
GAMEKIT_TEXT_INPUT_DLL="$PWD/.build/text-input-candidate/backport-msctf.dll" \
  swift test --filter HelldiversTextInputExperimentTests.prepare

GAMEKIT_TEXT_INPUT_PROBE=1 \
GAMEKIT_TEXT_INPUT_PROBE_PATH="$PWD/.build/text-input-probe.exe" \
GAMEKIT_TEXT_INPUT_EXPERIMENT="$PWD/.build/fresh-text-input-experiment" \
GAMEKIT_TEXT_INPUT_EXPECT_AVAILABLE=1 \
  swift test --filter TextInputCapabilityTests
```

Use `GAMEKIT_TEXT_INPUT_CONTROL=1` with `baseline-msctf.dll`, a separate fresh
destination and expected availability 0 for the control. Artifact hashes in the
test helper are deliberately pinned to these local builds; a rebuilt artifact
needs an explicit identity review before using the experiment helper.

Current successful experiment: `.build/helldivers-text-input-experiment-3/`.
Control: `.build/helldivers-text-input-control/`. Earlier preparation attempts
left small incomplete staging trees after metadata-revision and missing-parent
errors; they were not executed as game environments.

## Bounded startup observations

The existing E6 operator supports an explicitly selected experimental root and
an experiment-only maximum of 180 seconds. Its normal baseline maximum remains
90 seconds. Compile the opt-in OCR helper first:

```bash
xcrun swiftc -swift-version 6 tools/recognize_game_screen.swift \
  -o .build/recognize-game-screen
```

The screenshot operator still verifies the owned session and window PIDs before
acting. Optional recognized-screen actions are individually enabled:

- `GAMEKIT_E6_CONFIRM_ENGLISH=1`: text and speech language confirmation.
- `GAMEKIT_E6_ADVANCE_TITLE=1`: the identified title screen's Press Any Button.
- `GAMEKIT_E6_DECLINE_OPTIONAL_DATA=1`: Decline on About Game Data. The user
  explicitly chose this option; the saved experimental setting is `data_privacy=0`.
- `GAMEKIT_E6_ADVANCE_SETUP_DEFAULTS=1`: observed subtitles/audio/crossplay
  defaults, account-status Next, and brightness Next. It never operates account
  sign-in or Link controls. Audio advancement requires recognizing Disabled
  alongside the voice-chat controls.
- `GAMEKIT_E6_OCR_TOOL`: absolute path to the compiled helper.

Recognition runs in a separate process with a five-second timeout. A failed
recognition is an observation gap, not permission to click. Small known button
regions improve recognition of striped controls; returned coordinates are
mapped back to the full window. Each recognized action occurs at most once per
run. Gameplay controls are not automated by these flags.

One earlier run using synchronous in-process Vision exceeded the outer timeout
at the subtitles screen; explicit scoped cleanup then succeeded. Another run
was interrupted by the user's restart. After restart, cleanup confirmed the
session was already stopped. The final separately timed operator completed.

Raw captures remain private under `.build/helldivers-text-input-launch-*` and
`.build/helldivers-text-input-control-launch/`. Important checkpoints:

- Control: reproduced crash-report dialog; bounded forced cleanup completed.
- Patched run 2: language screen, graceful cleanup.
- Patched runs 8/10/12/14: progressively verified onboarding, including the
  explicitly declined data-collection prompt and account-status continuation.
- Patched run 15: saved setup completion and rendered intro video; graceful stop.
- Patched run 16: intro/title relaunch with a 30 FPS **configuration cap**.
- Patched run 17: actual ship scene and graphics menu; the user confirmed they
  were controlling it. The capture shows Medium selected in the graphics menu,
  but this is not a complete settings or frame-rate measurement. Scoped forced
  cleanup completed at the end of the observation.

The FPS cap was changed only in the experimental configuration after the
startup comparison. It is not evidence of achieved 30 FPS. Current gameplay
performance and mission stability still need a dedicated hands-on assessment.

Explicit experiment cleanup:

```bash
GAMEKIT_STOP_TEXT_INPUT_EXPERIMENT=1 \
GAMEKIT_TEXT_INPUT_EXPERIMENT="$PWD/.build/helldivers-text-input-experiment-3" \
  swift test --filter HelldiversTextInputExperimentTests.stop
```

Final checks confirmed the experimental session stopped and the original
runtime still returns the original missing-capability result. About 64 GiB disk
space remains free. The ordinary packaged Gamekit app still uses the accepted
runtime; integrating and distributing the experimental runtime revision is a
separate delivery step.
