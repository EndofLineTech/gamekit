# Helldivers shader failures and startup hitches

Assessment `gamekit-2lg`, 2026-09-18. **The errors are still present; this work does
not claim a shader fix or a stutter fix.** It identifies the failing boundary and
measures its direct latency separately from presentation gaps.

## Findings

1. Broadening the old D3DMetal-only log filter exposed
   `MetalIRConverter: FailedToSynthesizeStageInFunction` immediately before some
   D3DMetal stage/pipeline failures. These are vertex input-function synthesis
   failures, not evidence of a generic GPU crash.
2. The game uses the D3DMetal-specific `IRCreateStageInFunction` entry, not the
   public `IRMetalLibSynthesizeStageInFunction` entry. A first public-API tap loaded
   successfully but observed no calls; that was a coverage gap, not zero failures.
3. A bounded pass-through trace of the actual entry observed **17 false returns
   across 10 distinct reflection ShaderID values**. The records identify vertex
   shaders with Float, Half and Uint32 inputs. These are within-run identities,
   not stable names for game effects. The private input-layout descriptor was
   deliberately left opaque, so the exact rejecting layout/format/compiler option
   remains unknown. Reflection alone is not a complete reproducer.
4. In the timed run, failed calls took **0.213 ms median, 3.548 ms maximum**.
   Their summed elapsed time was **11.023 ms** across parallel worker calls; this
   is not wall-clock or total CPU time. Those direct durations alone do not explain
   the observed 100–900 ms presentation gaps. Work outside this entry, including
   retries, successful shader compilation and synchronization, remains unmeasured.
5. The user reports **stutters, but normal-looking visuals**. The ship rendered in
   captured frames. We have not shown whether any failed PSO is actually drawn,
   what its intended effect is, or whether a reference renderer differs. Do not
   label the failures harmless, all shaders broken, or a confirmed Apple bug.

Baseline: M4 Pro/24 GB, macOS 27.0 build 26A428, Helldivers build 24826606,
text-input-1 Wine runtime, unchanged D3DMetal 4.0b2, saved Metal 3 request,
fullscreen/display capture enabled, 1800×1169 game output. No graphics preferences
were intentionally changed. The Space preference alone was toggled for one
comparison and restored to enabled afterward.

## Measured runs

The HUD data below is from Apple's documented per-frame statistics format. Counts
refer to captured timing pairs, not a claim of deduplicated presentation IDs or a
whole-game benchmark. HUD batch timestamps are emission times, not exact times
for each interval in the batch. Trace timestamps use Unix time; local text logs
in these runs used UTC−05:00.

| Capture | Timing pairs | Intervals ≥50 ms | Intervals ≥100 ms | Largest interval | GPU time in that pair |
|---|---:|---:|---:|---:|---:|
| Stage-in trace + HUD + periodic screenshots | 4,572 | 11 | 5 | 883.33 ms | 16.05 ms |
| HUD only; no periodic capture/focus actions after warning | 4,409 | 12 | 7 | 887.50 ms | 22.70 ms |
| HUD only + read-only focus observer; Space enabled | 5,009 | 11 | 6 | 883.33 ms | 16.21 ms |
| Same observation mode; desktop fullscreen | 4,494 | 9 | 5 | 899.99 ms | 8.55 ms |

The last two runs both logged **80 no-op pipeline failures**. Their different
sample counts/durations and unconstrained gameplay mean the small count differences
are not a performance ranking. They do show that the approximately 0.9-second
startup gap persists without the Space feature. **Disabling Spaces is not a
supported stutter workaround from this evidence.**

The first timed trace's failure records span 18:24:31.176 through 18:24:41.889 UTC.
It logged 80 D3DMetal stage failures, 80 no-op pipeline failures and 17 converter
synthesis failures. The trace recorded no successful calls at that entry; cached
or other compilation paths are outside its coverage. Its failure cap of 64 records
was not reached.

The HUD-only runs remove the extra converter serialization/interposition and the
observer's repeated screenshots, OCR and activation calls. Long gaps persisted.
Read-only focus traces for the Space comparison show the game activation at
startup and return to another app at cleanup, without intervening app activation
changes in the play interval. This does not inspect Windows-internal focus.

In these short passes, ≥50 ms intervals were concentrated near startup/ship
arrival; later captured batches did not reproduce ≥50 ms intervals. This does not
disprove the user's longer-session reports. GPU work time being much shorter than
a long presentation interval motivates CPU/IO/synchronization investigation but
does not, by itself, identify a bottleneck. HUD overhead, startup behavior and
unobserved scheduling remain limitations. No cache was deleted or reset, and no
FPS-cap or graphics-quality workaround was inferred from these runs.

A screenshot's HUD displayed about 53 FPS in one ship scene. That is a scoped
observation under diagnostic instrumentation, not a mission benchmark or evidence
about the earlier 30-FPS limiter experiment, whose settings were different.

## What the error means—and does not mean

Apple's shader-converter documentation describes a separate stage-in function as
vertex attribute fetching/type conversion, linked into the vertex pipeline.
D3DMetal marks the failed pipeline as no-op, so its draw behavior may be disabled.
The exact effect still depends on whether the game uses that pipeline and on the
game's own fallback/selection behavior. The 80 PSO messages are not 80 independently
identified source shaders; several pipelines can share a vertex shader or stage-in
result. Pipeline numbers also vary between processes.

Other messages include unsupported `EndQuery`/`ResolveQueryData` type 2. Microsoft's
enum identifies type 2 as a **timestamp query**. That is a distinct API limitation,
not the stage-in error. No result/timeout probe was performed here, so it is a
candidate for follow-up rather than a claimed cause of the hitches.

## Diagnostic artifacts and boundaries

- `diagnostics/MetalStageInTrace.mm`: explicitly built, separate diagnostic helper;
  observes the original function result and elapsed duration, and copies reflection
  through the public reflection API. Arguments, output binary and return value
  pass through unchanged. It records at most 64 failures and four successes per
  process, with bounded JSON records and owner-only output files. Only the managed
  Helldivers main image enables recording. Raw reflection stays private.
- The intercepted C++ ABI was inspected in **this exact** converter:
  SHA-256 `75974d49ad4dd1bdf17ab3cd666ae7cac43e7f7a5760237699ab33ecd3d31daf`.
  Its mangled parameter types and bool return were checked; the private
  `D3DMInputLayoutDesc` is passed by reference without decoding it. This is not a
  supported general-purpose instrumentation API. Verify that artifact before
  rebuilding; do not carry the interposer to another runtime/version unchanged.
  The public-API tap that missed the actual entry was removed from the final source.
- `diagnostics/MetalHUDCapture.m`: separate HUD-only helper with no compiler
  interposition or converter preloading. It sets only process-local Apple HUD
  variables and captures this game's stderr to a private directory.
- `GAMEKIT_E6_PASSIVE_AFTER_WARNING=1`: existing bounded observation harness can
  acknowledge the exact owned GPU warning and then stop all periodic capture,
  OCR and focus actions. It continues ownership checks and closes the session.
  Other input/Space-round-trip automation flags are rejected in this mode.
- `tools/analyze_metal_capture.py`: validates finite nonnegative HUD pairs, filters
  by PID, keeps unknown timing values null, and outputs statistics without raw
  shader IDs/reflection. It rejects redacted/truncated HUD payloads instead of
  interpreting them as complete timing data. P95 is nearest-rank; medians use
  the usual midpoint convention. No automatic causal correlation is generated.

These diagnostics are not linked into the normal product helper. No Apple shader
library, game executable or anti-cheat binary was patched. All observation
sessions stopped gracefully. No persistent HUD user defaults were written.
The saved Space preference was restored through the product store, with readback
showing capture enabled and Metal 3 retained.

Private evidence includes `.build/2lg-stagein-evidence-{2,3}/`,
`.build/2lg-stagein-run-3-metal.log`, `.build/2lg-hud-only-evidence-1/`,
`.build/2lg-hud-space-on-2/`, `.build/2lg-hud-space-off-1/` and the corresponding
focus traces and analyzer summaries. Raw screenshots/logs are not committed or
automatically submitted to a vendor.

## Reproducing the analysis

For existing private captures:

```sh
python3 tools/analyze_metal_capture.py --trace /private/stage-in.jsonl \
  --hud /private/stderr.log --pid GAME_PID
# HUD-only runs intentionally report no stage-in capture:
python3 tools/analyze_metal_capture.py --hud /private/stderr.log --pid GAME_PID
python3 -m unittest discover -s tests -p test_metal_capture.py
```

For another HUD-only run, build an isolated helper package using the normal
`GameIdentity.m` and `FullscreenSpace.m` plus `diagnostics/MetalHUDCapture.m`,
link Foundation/AppKit for x86_64 with ARC and warnings as errors, and define
`GAMEKIT_METAL_HUD_LOG_DIRECTORY` as a **fresh, private directory**. Sign the
helper locally. Use `GAMEKIT_E6_PACKAGE` to select that package only for the test,
`GAMEKIT_E6_OBSERVE_LAUNCH=1`, AppID 553850, a bounded duration up to 90 seconds,
`GAMEKIT_E6_CONTINUE_GPU_WARNING=1`, and `GAMEKIT_E6_PASSIVE_AFTER_WARNING=1`.
Steam and other managed games must already be stopped. Do not authorize kicking
another Steam session. Use the PID printed at the start of the private stderr log.

The converter tracer additionally requires linking the exact inspected game-cache
`libmetalirconverter.dylib` and an rpath to its Resources directory. Define
`GAMEKIT_STAGEIN_LOG_DIRECTORY` and optionally `GAMEKIT_STAGEIN_HUD=1`.
The lower-intrusion HUD-only helper is preferred for subsequent performance work.

For unified logs, include both `D3DMetal` **and** `MetalIRConverter` and scope to the
observed game PID/time window. The default system log redacted HUD per-frame values
in this investigation; the private stderr capture retained them. Although shader
logging was requested, no usable `CompileShader` records were recovered. That is
not proof that no successful compilation occurred.

## Disposition

Keep the accepted configuration. There is no verified shader-error suppression or
graphics setting that fixes these failures, and changing rendering behavior to
silence a log would not establish correctness or smoother play.

- **`gamekit-w58`**: profile the actual startup hitches with aligned CPU/IO/Metal
  data and explicit hitch markers; separately test timestamp-query behavior.
- **`gamekit-eac`**: obtain the rejected input-layout/compiler configuration and a
  legal minimal reproducer, then establish draw/visual impact or an upstream fix.

This closes the bounded assessment, not those unresolved rendering/performance
questions. A replacement graphics library is not justified solely by log counts.

## References

- [Apple Metal shader converter overview](https://developer.apple.com/metal/shader-converter/)
- [Apple vertex/stage-in integration guidance](https://github.com/apple/game-porting-toolkit/blob/main/game-porting-skills/skills/integrating-metal-shaderconverter-shaders/references/vertex-pipelines.md)
- [Public converter header mirror](https://github.com/wmarti/metal-shader-converter/blob/main/include/metal_irconverter.h)
- [Apple Metal HUD metrics/logging format](https://developer.apple.com/documentation/xcode/monitoring-your-metal-apps-graphics-performance.md)
- [Microsoft D3D12 query-type enum](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ne-d3d12-d3d12_query_type)
- [Earlier stalls/cursor observations](helldivers-stalls-and-cursor.md)
