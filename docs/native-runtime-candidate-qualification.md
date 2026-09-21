# Native ARM64 runtime candidate qualification

Date: **2026-09-21**. Issue: `gamekit-5wd`. Host: Apple M4 Pro, 24 GB,
macOS 27.0 **26A428**. This is a qualification checkpoint, not runtime promotion
or macOS 28 acceptance.

## Result

**A public native-host Wine/FEX artifact is available and executes x64 Windows
code without Rosetta on this host. It has not passed Gamekit's replacement gates.**
The tested VKMT release failed the graphics qualification and an ARM64 Windows
CRT startup test. The existing runtime/prefix/settings remain the accepted setup.

The broader search also found a concrete native ARM64 VM option, Varmint. Its
native DXMT/Venus paths merit a separate VM evaluation; they are not a drop-in
Darwin Wine adapter. No VM boot, Steam login or game acceptance is claimed here.

## Exact VKMT artifact, not the changing README

- Release: [VKMT-1.0](https://github.com/metalsharp/VKMT-Wine/releases/tag/VKMT-1.0).
- Retrieved documentation commit: `184ceba465a5a0add6e4eb245360da67f2401655`.
- Actual four-part archive SHA-256:
  `5d0652cd89d9d9bf2d6f1d44e57cae9037ff5b16f4f29209fc40a15aa7905848`.
- All four part hashes and **14,910** internal payload receipts passed.
- Extracted regular payload: **5,666,925,687 bytes**, 14,911 regular files and
  475 links. Finder metadata was excluded; links were checked and installed only
  after regular files. No publisher installer or GOG executable was run.
- Archived provenance identifies VKMT `a89dcc9845c8dea89d224187ae60253ed5f8d627`,
  Wine `03cd2bd8f1435a174c295596e4f97d84fb0c8d78`, and FEX
  `18a20dc8d972c2bc47c15e92ccc4e83d6b6aacdd`. The executable prints
  `wine-11.12-29-gc13760f`. These different identifiers are recorded as supplied,
  not treated as proof of a reproducible source-to-binary mapping.
- Current publisher documentation describes a different archive digest/source
  snapshot. This assessment therefore uses the downloaded receipts and bytes.
- The archive's identified integration material carries PolyForm Noncommercial
  terms permitting personal research/testing. It is retained privately for this
  personal prototype; it is not bundled or relicensed by Gamekit.

Candidate inputs, paths and environment are recorded in
`diagnostics/profiles/runtime-candidates/vkmt-1.0.json`.

## Architecture and execution observations

| Gate | Observation | Assessment |
| --- | --- | --- |
| Wine host / wineserver / ntdll / DXMT Unix bridge | Actual Mach-O ARM64 binaries; loader and ntdll have ad-hoc linker signatures and no displayed entitlement dictionary | Native host exists; no signing or system-security changes made |
| Whole archive header inventory | 867 thin ARM64 Mach-O members, two universal ARM64+x86_64 MoltenVK files, no thin Intel Mach-O members observed | Universal files require actual loaded-slice evidence; package-wide “ARM64-only” wording is too broad |
| Host `--version` | Exit 0 | Startup only |
| Fresh prefix `cmd.exe /c ver` | Exit 0; Windows 10.0.19045 reported | Prefix/native runtime bootstrap works; command alone does not establish guest architecture |
| External x64 PE | Threads, TLS, 40,000 atomic operations, vectored exception callback/return passed | Positive bounded CPU/ABI evidence |
| x64 AVX / AVX2 | CPUID/OSXSAVE/XCR0 checks and actual vector instruction checks passed | Positive instruction execution evidence |
| Native execution receipt | Final x64 run recorded 20 host receipts, all `proc_translated=0`; all 12,054 loaded-image records were ARM64 | Observed run did not use an Intel/Rosetta host image |
| External i386 PE | Uninstrumented run passed threads/TLS/atomics and exception callback; XSAVE/OSXSAVE/AVX all reported 0 | Basic 32-bit execution works; AVX qualification does not pass |
| Instrumented i386 run | Timed out during thread stage; uninstrumented control completed | Do not attribute a deterministic application defect from the instrumented run alone |
| External ARM64 PE | Crashed in MinGW CRT startup; unobserved control showed null x18/TEB and read at address 8 | Native Windows ARM64 ABI lane not qualified |

The final SIMD probe uses volatile assembly. Inspection of an initial build found
that the optimizer had reduced its AVX2 comparison to `return 1`; that initial
marker is **not** AVX2 evidence. The corrected executable was disassembled to
confirm YMM `vpaddd`/`vpbroadcastd`, then executed successfully. Its receipt is the
one reported above.

The candidate's documented environment disables all three FEX TSO switches.
The tested atomic/thread cases do not establish correctness of every x86 memory
ordering pattern. Neither advertised CPU bits nor isolated arithmetic benchmarks
are sufficient to qualify a game runtime.

## Graphics gates

All DLL staging occurred in fresh private prefixes, using files checked against
the downloaded archive's receipt. Replacements used new files/atomic rename;
runtime inodes and the accepted Gamekit prefix were not overwritten.

### DXMT

The shipped ARM64EC DXGI/D3D11 pair plus native Unix bridge created an FL11_0
device/swapchain. All three calibration timestamps remained pending with zero
values; shared R16_FLOAT creation returned success. The probe then stalled before
the shader/draw/readback acceptance marker. A 60-second instrumented run and a
45-second uninstrumented control both required scoped shutdown.

**No render/present/readback pass is claimed.** The last printed marker does not
identify whether release, shader compilation or subsequent work caused the stall.

### D3D12 / VKD3D

Two distinct supplied layouts were assessed:

1. The architecture-lane DXVK/VKD3D files failed DXGI factory creation because
   DXVK rejected missing `geometryShader` support.
2. The separate matched `vkd3d-proton-macos-v1.0` bundle initialized its DXGI path
   but rejected D3D12 device creation for missing **single-texel alignment**.
   Missing dynamic-rendering-unused-attachments support and disabled stream output
   were also reported.

The matched bundle's archive receipt
`f1eabd729a65f0a62bcba9a3a8054bdef9895981351dc8896993a8cffa12299c`
matches the current public graphics release. The publisher documents
`VKMT_ALLOW_NON_SINGLE_TEXEL_ALIGNMENT=1` as an escape hatch. That bypass was not
enabled or promoted as evidence of genuine capability. There is no passed D3D12
queue/render/present/readback gate in this assessment.

Steam/account/game acceptance was not advanced after these failed replacement
gates. Publisher Steam scripts also include helper replacement and reduced CEF
isolation options; those were inspected, not adopted.

## Broader ARM64-native search

| Option | Current evidence | Fit / next gate |
| --- | --- | --- |
| [VKMT-Wine](https://github.com/metalsharp/VKMT-Wine) | Public complete artifact; actual ARM64 host and x64 CPU execution above | Partial candidate; graphics and native ARM64 guest gates failed |
| [CrossOver native Preview](https://www.codeweavers.com/preview) | Publisher offers it to current license holders; no trial mode. No installed CrossOver app found in the standard application locations | Obtain an authorized current **ARM64 Preview** artifact plus release notes; do not infer current limits from July's initial preview |
| [CodeWeavers public source](https://www.codeweavers.com/crossover/source) | Public page currently links stable 26.3.0 sources | This is not a published, independently qualified native Preview/FEX artifact |
| [gzimbric native Wine](https://github.com/gzimbric/wine-arm64-macos) | Still at `e588cf66f022aeb7a4a0f5d95d8803ce7fb7fb98`, no release assets; BUILD.md explicitly omits external Darwin FEX/DXMT integration patches | Incomplete reproducible runtime; developer provisioning also required by its documented path |
| [DiagBridge / citi94 Wine](https://github.com/citi94/diagbridge) | Native ARM64 Windows VCDS support, but its own docs retain Rosetta for Intel helper programs | Not a Rosetta-free x86/x64 gaming replacement |
| [Ferrum](https://github.com/PyroSoftPro/Ferrum) | Public repository has documentation and proprietary license, no downloadable release found; author says no end-to-end game session yet | Artifact/licensing gate; benchmark percentages are not Gamekit acceptance |
| [AehoraDeSum Wine build](https://github.com/AehoraDeSum/wine-arm64-macos-build) | Script targets ARM64 but builds Wine 9.12 with no demonstrated complete Darwin FEX guest path | Architecture/build intent, not a qualified replacement |
| [wine-x18](https://github.com/theoparis/wine-x18) | Inspected repository contains a license file, no complete runtime | No runnable candidate |
| [Varmint](https://github.com/kisasexypantera94/varmint) | Current public alpha, Debian ARM64 guest/FEX, DXMT/Neptune and MoltenVK/Venus paths | Concrete VM alternative; separate architecture decision and live qualification required |
| [Impulse](https://github.com/Zonharo/impulse) | Public ARM64 Linux VM/FEX gaming product, not Darwin Wine | Same architectural distinction; newer Varmint has a documented native DXMT/Neptune path |

### Varmint artifact inspection

Inspected `v0.2.0-alpha.3`, published September 20. The GitHub asset SHA-256 is
`9497af4cc1c17892805ebec9e32f980fa2f750b6dba04b0dcec42b110ecadf28` and was verified.
The ZIP contains a nested `Varmint.zip`; both layers were read without installing
or executing the application.

Actual headers identify the main executable, DXMT-native, MoltenVK, ANGLE, epoxy,
virglrenderer and vmnet helper as ARM64. `libd3dmetal-native.dylib` is Intel-only,
and `virgl_render_server` is universal. Source configuration defaults Neptune to
DXMT; choosing the optional D3DMetal path reintroduces a Rosetta renderer boundary.
The bundle reports version 0.1.0 despite the release tag; the asset digest is the
unambiguous identity. The ARM64 PE-looking `Resources/kernel/Image` is the Linux
kernel's EFI image, not proof of a Windows ARM64 guest library.

This establishes a concrete native graphics/VM artifact to evaluate, **not** a
local game, D3D12 or macOS 28 pass. VM provisioning/login and lifecycle integration
are separate from Gamekit's current managed-Wine environment.

## Apple's Game Porting Toolkit

The installed GPTK-derived Wine loader and D3DMetal 4.0 beta 2 binary were checked
again with `lipo`: both are **x86_64**. Apple's current
[GPTK 4 page](https://developer.apple.com/games/game-porting-toolkit/) advertises
Metal 4 evaluation and native game-porting tools, not a native ARM64 Wine runtime.
[UTM's D3DMetal-native adapter](https://github.com/utmapp/d3dmetal-native) likewise
explicitly requires an Intel process under Rosetta. “Native” there means a
non-Wine host interface, not an ARM64 D3DMetal binary.

FEX translating Windows PE code does not make the Intel Mach-O D3DMetal framework
loadable into ARM64 Wine. A separate native provider or a different graphics path
is still necessary for the no-Rosetta goal.

## Reproduction and scope

- `tools/audit_runtime_candidate.py`: verifies ordered parts/whole digest, reads
  binary headers, extracts only selected inspection files, and records links
  without following/materializing them.
- `tools/stage_runtime_candidate.py`: fresh-directory, bounded extraction with
  deferred contained links and complete payload-receipt verification.
- `tools/probe_runtime_candidate.py`: fresh private home/prefix, bounded command,
  optional first-party host observer, hash-checked provider staging and
  prefix-specific server stop/wait.
- `diagnostics/native_runtime_cpu_probe.c`: independent per-guest CPU/ABI probe;
  compile with LLVM-MinGW 20260908 and verify SIMD disassembly.
- `diagnostics/native_runtime_observer.c`: ARM64-only, read-only process/image
  receipt; instrumentation is not assumed behavior-neutral.
- `tools/cleanup_runtime_probes.py` plus `native_candidate_processes.c`: require
  successful scoped server-wait receipts and zero candidate processes before
  removing disposable homes/prefixes; logs stay private under `.build`.
- `tools/audit_native_app_archive.py`: pinned nested-ZIP architecture inspection.

The accepted runtime, Steam authentication, saves, per-game profiles, host support
policy and security settings were not changed. No new runtime is offered in the
app. `gamekit-5wd` remains incomplete until a candidate passes the required gates;
`gamekit-m47` remains dependent on it and on actual macOS 28 testing.
