# AVX advertisement and Helldivers 2

Investigation `gamekit-5ta`, 2026-09-17, on the recorded M4 Pro/macOS 27.0 (26A428)
and Sikarugir 10.0 revision 6 / D3DMetal 4.0b2 combination.

## Documented setting

Apple's GPTK 4.0 beta 2 evaluation-image `Read Me.rtf`, Environment Variables
section, documents **`ROSETTA_ADVERTISE_AVX=1`** on macOS 15 and later. It defaults
to zero. It changes CPUID advertisement of supported translation extensions,
not their instruction implementation. The Troubleshooting section specifically
recommends considering it for games reporting missing instruction extensions.
The package was mounted read-only and the original instructions rechecked;
[artifact identity](gptk-package-inspection.md) records its provenance.

Apple also confirms AVX evaluation in
[WWDC24: Port advanced games to Apple platforms](https://developer.apple.com/videos/play/wwdc2024/10089/).
The current [Rosetta documentation](https://developer.apple.com/documentation/apple-silicon/about-the-rosetta-translation-environment)
states that AVX and AVX2 are translated, while AVX-512 is not supported.

Gamekit's original baseline deliberately left this setting unset. Its environment
allowlist also discarded an inherited value, so exporting the variable in iTerm
would not enable it in managed Steam. Gamekit now sets it explicitly to `1` in
the controlled Wine environment. This is scoped to the currently supported recipe;
it is not a capability promise for arbitrary runtimes or operating systems.

## Actual capability comparison

`tools/avx_capability_probe.c` is compiled separately as native x86_64 Mach-O and
Windows x64. It reports CPUID feature bits, checks XCR0 only when OSXSAVE is
advertised, and executes basic AVX and AVX2 arithmetic with validation of all eight
result lanes. The Windows build also queries `IsProcessorFeaturePresent`.

| Measurement | Advertisement off | Advertisement on |
| --- | --- | --- |
| CPUID XSAVE / OSXSAVE / AVX | 0 / 0 / 0 | 1 / 1 / 1 |
| CPUID AVX2 | 0 | 1 |
| CPUID FMA / F16C | 0 / 0 | 1 / 1 |
| CPUID AVX512F | 0 | 0 |
| XCR0 | Not queried | `0x7`, XMM/YMM state enabled |
| Windows PF XSAVE / AVX / AVX2 | 0 / 0 / 0 | 1 / 1 / 1 |
| Windows PF AVX512F | 0 | 0 |
| Basic AVX / AVX2 execution | Both pass | Both pass |

The native and Windows results agree. The Windows comparison used two fresh
disposable prefixes, each with its own scoped session and verified cleanup; it
did not reset the user's environment. A native `machdep.cpu.features` sysctl
query did not reflect the per-process advertisement change, so the conclusion is
based on actual CPUID and Windows API probes instead. These small instruction
checks do not claim exhaustive ISA or whole-game compatibility.

```bash
xcrun clang -arch x86_64 -O0 -Wall -Wextra -Werror \
  tools/avx_capability_probe.c -o .build/avx-capability-probe
x86_64-w64-mingw32-gcc -O0 -Wall -Wextra -Werror -static \
  tools/avx_capability_probe.c -o .build/avx-capability-probe.exe
.build/avx-capability-probe --execute
ROSETTA_ADVERTISE_AVX=1 .build/avx-capability-probe --execute
GAMEKIT_AVX_PROBE=1 GAMEKIT_AVX_PROBE_PATH="$PWD/.build/avx-capability-probe.exe" \
  swift test --filter AVXCapabilityTests.compare
```

## Fresh Steam session required

Save and exit games, Stop managed Windows Steam, then launch from an updated
Gamekit build. Games inherit the persistent Steam client's environment. Merely
reopening Gamekit or sending a game command to an old client retains the old
advertisement. The environment isolation regression verifies that an inherited
`ROSETTA_ADVERTISE_AVX=0` cannot override the managed policy.

## Helldivers result and next blocker

The original [E6 baseline](e6-game-results.md) remains valid historical evidence:
with advertisement unset, build 24826606 displayed the fatal AVX requirement.
With advertisement enabled in a fresh session, that CPU gate disappeared. The
game proceeded through its GameGuard startup display to a GPU-driver warning:

- Reported installed AMD version: **65535.65535.65535.65535**.
- Minimum recommended AMD version: **32.0.21043.5001**.
- The game offered Cancel, Try Again and Continue.

The existing D3D12 device probe was extended with a read-only DXGI driver query.
`IDXGIAdapter::CheckInterfaceSupport(IID_IDXGIDevice)` returned `S_OK` and
`0xffffffffffffffff`, explaining the four 65535 components. The virtual adapter
reported vendor `0x1002`, device `0x66af`; D3D12 device and queue creation passed.
This is compatibility-layer reporting, not evidence of an obsolete AMD driver
installed on the M4 Mac. A [CrossOver user report](https://steamcommunity.com/app/553850/discussions/1/833871839865437475/)
describes the same all-65535 value; it is corroborating context, not validation of
this runtime or a proposed fix.

Two bounded runs selected **Continue** on that exact warning. Both opened a black
game window and then the game's crash-report dialog, without reaching a playable
menu. Local dump inspection found `0xc0000005` at `helldivers2.exe+0x670c27` in one
run. This does not establish whether graphics, another runtime component or the
game itself caused the fault. `gamekit-1ae` tracks the remaining startup failure.
No driver-version registry changes, Windows GPU driver installation, game patch,
anti-cheat bypass or crash-report submission was performed.

Private evidence is in `.build/avx-helldivers-enabled-1/` and
`.build/avx-helldivers-driver-continue-{1,2}/`; raw dumps remain local. The optional
operator switch `GAMEKIT_E6_CONTINUE_GPU_WARNING=1` is restricted to AppID 553850
and the exact owned warning window; it clicks Continue once and is off by default.
All three sessions ended with graceful cleanup. Satisfactory's shipping-process,
Dock-identity and shutdown regression also passed with AVX advertisement enabled.

**Conclusion:** AVX availability is now correctly advertised and the Helldivers
CPU gate is resolved. Helldivers 2 is still not verified playable because startup
fails after the subsequent warning.
