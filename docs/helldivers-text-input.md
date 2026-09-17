# Helldivers post-AVX text-input investigation

**Update:** the [controlled Wine 10 backport](helldivers-text-input-backport.md)
now resolves the reproduced startup crash and reaches the ship scene. The
initial diagnostic findings and candidate constraint below are retained as
the investigation history.

Investigation `gamekit-1ae`, 2026-09-17. The [AVX fix](avx-capability.md)
is delivered in [PR22](https://github.com/EndofLineTech/gamekit/pull/22).
Helldivers build 24826606 still crashes after Continue on the virtual GPU-driver
warning. This investigation identifies a missing runtime interface; it does not
yet establish that repairing it makes the game playable.

## Local crash evidence

Read-only LLDB inspection of the existing private minidump found:

- Exception `0xc0000005` at `helldivers2.exe+0x670c27`.
- `RAX=0x80004001` (`E_NOTIMPL`), `RCX=0`, and a null output-sized stack slot.
- A raw stack address resolves to `msctf.dll+0xefac`. Other raw stack values
  resolve to the Steam overlay and Wintab. These are **not** a reliably unwound
  call chain and do not prove which API immediately preceded the exception.
- The dump lacks the faulting instruction bytes; LLDB could not disassemble
  that address. The corresponding game-image range has no on-disk raw code in
  the inspected PE sections. No game or runtime binary was modified.

## Upstream lead

The [Proton Helldivers issue](https://github.com/ValveSoftware/Proton/issues/7486#issuecomment-4337159849)
records an April 28, 2026 startup fix in bleeding-edge build
`experimental-bleeding-edge-11.0-351515-20260428-pee99a7-w9012f3-dbcbc56-v228cc3_`.
Its Wine revision includes:

- [`1527888`](https://github.com/ValveSoftware/wine/commit/1527888ecafb61f8fe80a1441bb40af009065d6b):
  return a function-provider interface from `ITfThreadMgr::GetFunctionProvider`.
- [`f8442ce`](https://github.com/ValveSoftware/wine/commit/f8442ce00f4eeb010c0e428dfa1b91c00b313018):
  provide a stub `ITfFnReconversion` interface.
- [`9012f3`](https://github.com/ValveSoftware/wine/commit/9012f3829ecb328b5bd60082ec36ffbb34b81406):
  remove an incomplete unrelated exception-code fragment introduced in the
  previous commit. Do not blindly cherry-pick the intermediate revision.

These are Windows text-input interfaces, not graphics-driver version APIs.
The upstream result is Linux/Proton evidence, not a validation of our macOS
runtime or current game build.

## Reproduced missing capability

The standalone Windows x64 probe creates and activates a text-input thread
manager, queries the system function provider, and queries reconversion only
if the provider succeeded and is non-null. It guards failed COM outputs and
releases acquired interfaces. No game needs to run.

On the selected Sikarugir 10.0 revision 6 runtime, using the managed prefix:

```text
Create thread manager: 0x00000000
Activate: 0x00000000
GetFunctionProvider: 0x80004001; nonnull=0
Text-input reconversion available=0
Text-input observation complete
```

The scoped probe session stopped and its final process snapshot was empty.
The test passing means the **observation completed**, not that the capability
exists. No games were launched during this follow-up.

```bash
x86_64-w64-mingw32-g++ -O0 -Wall -Wextra -Werror -static \
  diagnostics/text_input_probe.cpp -o .build/text-input-probe.exe -lole32 -luuid
GAMEKIT_TEXT_INPUT_PROBE=1 \
  GAMEKIT_TEXT_INPUT_PROBE_PATH="$PWD/.build/text-input-probe.exe" \
  swift test --filter TextInputCapabilityTests
```

Stop managed Steam and games before running the opt-in probe. It uses the
existing exclusive runtime-session lease and scoped shutdown machinery.

## Remaining decision and verification

The missing provider is now reproduced independently of the game and aligns
with an upstream fix for similar startup symptoms. Causality still needs a
controlled runtime comparison. Evaluate a separate runtime candidate containing
the text-input fixes, first with this probe, then a bounded Helldivers launch.
Preserve the accepted runtime and environment before any version migration.
Retain the same AVX policy, graphics payload and game build for the comparison
where possible; document any unavoidable differences.

Suppressing the GPU warning or advertising a fabricated driver version would
not implement these missing interfaces. No such change has been made.

## Newer engine candidate constraint

The official Sikarugir engine release lists `WS11WineSikarugir11.0_1.tar.xz`,
updated September 17, 2026. Its 167,218,856-byte archive was downloaded locally;
SHA-256 matches the GitHub asset digest:
`266e852bdb98e80da09f09d4ee10fd9fd3dbb6b18b0801c0836f1430c4979fb6`.
Archive inspection identifies `wine sikarugir 11.0 (revision 1)` and includes
the explicit **`wswine.bundle/no_d3dmetal`** marker. It has not been installed
or executed, and cannot be treated as a drop-in update to our D3DMetal recipe.

The Sikarugir Wine source at
[`36b6a2c`](https://github.com/Sikarugir-App/wine/blob/36b6a2cf679fb395f668a917b76537190e212d9c/dlls/msctf/threadmgr.c)
contains provider and reconversion implementations. This source observation
does not prove which source revision produced the archive.

Consequently, the next runtime experiment needs either a verified
D3DMetal-compatible engine containing these interfaces or an isolated backport
to the existing Wine 10 recipe. Replacing the accepted engine with the downloaded
Wine 11 archive would combine text-input and graphics changes and would not be
a controlled fix for this issue.
