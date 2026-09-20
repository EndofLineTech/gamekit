# Satisfactory optional-backend performance investigation

Issue: `gamekit-7j9`. Observed 2026-09-19–20 UTC on M4 Pro/24 GB,
macOS 27 build 26A428, Satisfactory build 24656030, and the accepted
Sikarugir Wine 10 rev6 `driver-version-1` runtime.

## Disposition

**Unresolved; further trials deferred at the user's request.** The user asked
to record defects and move on after multiple unsuccessful attempts rather than
continue spending time/tokens. No experimental backend or setting was promoted.

- **DXVK `dxvk-macos-1.10.3-compat2`: not recommended for this game.** The user
  reported very slow loading, severe choppiness and poor responsiveness, and
  again reported choppiness during the diagnostic observations.
- **DXMT `dxmt-0.80-compat2`: functional acceptance passed**, including gameplay,
  audio, controls and save/reload. Temporary movement stutter that settles also
  occurs in the user's default graphics mode. That separate symptom is tracked
  as `gamekit-gi0`; a DXMT-specific cause has not been established.
- Satisfactory's original **Use shared default → Metal 3** selection was restored.
  The final observation stopped gracefully and original saves/configuration
  passed byte-content comparisons. One earlier protected run required the
  scoped forced-stop fallback; this was not represented as graceful cleanup.

## What the original gameplay logs establish

The DXVK run used D3D11/SM5 and the expected transient Streamline-disable and
compute-post-processing arguments. The DXMT run used D3D11/SM5 with its expected
Streamline-disable argument. This rules out an accidentally selected D3D12 path
for these two recorded gameplay runs.

| Observation | DXMT | DXVK |
| --- | --- | --- |
| Engine-reported world `LoadMap` duration | 5.345026 s | 5.335939 s |
| Five-second GPU-query timeouts in these logs | None | Seven consecutive timeouts on frame marker 988 |

DXVK's timeouts occur immediately after world loading, at 22:01:01 through
22:01:31 UTC on September 19. They account for a **35-second sequence of query
waits**, not an equivalent difference in the engine's map-loading duration.
They do not identify the query type or establish the underlying cause. Later
warm observations remained variable/choppy without repeating those timeouts,
so the timeout sequence does not explain the entire performance complaint.

The inspected saved configuration was 1800×1169, quality-group values mostly 1,
VSync and dynamic resolution off. Some groups differed (for example reflection
and shading were 3). Settings were preserved rather than silently normalized.

## Bounded experiments

1. **Expanded standalone queries:** both x64 and x86 DXVK/DXMT completed 1,100
   occlusion queries and 1,100 timestamp queries over three reuse rounds,
   including implicit/explicit flushing and submission boundaries. Pixel counts
   and timestamp ordering passed. The small workload did not reproduce the
   multi-second gameplay stall; this does not qualify arbitrary game workloads.
2. **Thread sampling:** a protected world observation captured rendering-query
   polling, Vulkan fence waits and some graphics-pipeline creation. Wine/Rosetta
   unwinding produced extensive repeated/unknown frames. Sampling itself perturbs
   timing; stack counts are not CPU-use percentages or proof of a bottleneck.
3. **Newer MoltenVK:** retained MetalSharp candidate reporting 1.4.3, SHA-256
   `8249d81ebf2d46f82b16ca166c2e5cca5d76d91d0a412cd6d3db1aaa6e8430bf`,
   was mapped with the original qualified DXVK DLLs. The first run reproduced
   repeated five-second waits; a subsequent warm run reached the world without
   them. The first harness path assertion failed because `Code` versus `code`
   differed in the supplied path; the module map did contain the candidate.
   The corrected warm-run assertion passed. No upgrade was accepted.
4. **Occlusion-culling diagnostic:** a run forwarded
   `-ini:Engine:[SystemSettings]:r.AllowOcclusionQueries=0`. It did not establish
   a performance fix. The launch argument is confirmed, not an independent
   runtime readback of the cvar. No permanent preference was changed.

DXVK HUD screenshots included 21.1 FPS with newer MoltenVK, 44.5 FPS with the
original paired library, and 35.5 FPS in the requested no-occlusion trial.
**These are point readings from different viewpoints and cache histories, not
a benchmark ranking.** Some sessions included user movement; a completed
repeatable scripted movement comparison was not obtained. Neither best sustained
performance nor an improvement over the user's original acceptance result is
claimed.

## Save protection and diagnostic tooling

`-UserDir` redirects the game's logs and configuration, **but does not isolate
Satisfactory's save browser**. A copy-only user-directory experiment still
listed the original saves. It was stopped before an automated world load.

Applying a sandbox to all of Steam disrupted startup and was rejected. The
retained `diagnostics/SatisfactorySaveGuard.m` instead applies a diagnostic-only
write-denial policy in the mapped Satisfactory shipping process (or mapped
qualification probe). It permits reading saves while refusing writes; diagnostic
gameplay progress is not saved. It is never linked into the normal application.

The guard was verified with real x64/x86 Wine probes: Win32 `CreateFile` with
exclusive creation returned **ERROR_ACCESS_DENIED**, while rendering and query
checks still passed. The probe only targets a unique temporary marker, never an
existing save. The helper checks native denial before letting Wine proceed,
fails closed on unexpected results, and can record a bounded session/PID receipt.
The observation harness now gates automated load actions on that receipt.

Retained opt-in tools:

- `SatisfactoryPerformanceTests`: snapshots original save/config content hashes,
  uses a fresh alternative configuration directory, selects a backend, invokes
  the bounded observer and restores the preference after scoped shutdown.
- `GameEvaluationLaunchTests`: optional protected loading of the `Test` /
  `Test_autosave_0` fixture through recognized menu controls, module verification,
  optional CPU samples and transient occlusion diagnostic. It requires actual
  world-load completion for a requested world observation. Passing observation
  checks does not mean acceptable gameplay performance.
- `GraphicsPayloadQualificationTests`: `GAMEKIT_QUERY_WORKLOAD=1` and an optional
  `GAMEKIT_PROBE_BACKEND` select the expanded isolated query workload.
- `d3d11_render_probe.cpp`: optional `GAMEKIT_SAVE_GUARD_PROBE_DIRECTORY` build
  definition adds the Win32 write-denial check before rendering.
- `GraphicsBackendExperiment.h`: optional compile-time `GAMEKIT_DXVK_HUD` enables
  the DXVK HUD for developer observations.

For a protected world observation, compile the experimental identity helper with
`GAMEKIT_SAVE_WRITE_GUARD` and link `SatisfactorySaveGuard.m`. Define
`GAMEKIT_SAVE_GUARD_DIRECTORY` as the exact original `SaveGames` directory and
`GAMEKIT_SAVE_GUARD_LOG` as a private log path. Supply the matching
`GAMEKIT_SAVE_GUARD_LOG_FILE`, `GAMEKIT_SAVE_GUARD_HELPER=1`,
`GAMEKIT_SATISFACTORY_PERFORMANCE=1`, `GAMEKIT_SATISFACTORY_SAVED`,
`GAMEKIT_E6_SATISFACTORY_USER_DIR`, and the existing E6 package/evidence/backend
options. `GAMEKIT_E6_SANDBOX_CONTINUE=1` requests the protected fixture load.
The OCR helper supports the `satisfactory` fast-recognition mode. The fixture
loader is host-specific diagnostic tooling, not a user-facing auto-play feature.

Raw logs, screenshots, native samples and the alternative configuration trees
remain private under `.build/7j9-*`. No game, anti-cheat, accepted runtime or
installed renderer payload was patched by this investigation.

## Research references and remaining evidence gap

- [MoltenVK release notes](https://github.com/KhronosGroup/MoltenVK/blob/main/Docs/Whats_New.md)
  describe newer occlusion-query improvements. They motivated a comparison, not
  an assumption that upgrading would fix this title.
- [Unreal `r.AllowOcclusionQueries`](https://indxzero.github.io/ue544cvarwiki/articles/r.allowocclusionqueries/)
  controls hardware occlusion culling; disabling it can increase rendering work.
- [Satisfactory launch arguments](https://satisfactory.wiki.gg/wiki/Launch_arguments)
  documents the DX11 option and notes its deprecated status since Update 8.

If reprioritized, the next useful evidence is a controlled movement trace with
frame pacing and pipeline/submission timing, separating first-use compilation
from steady-state CPU/GPU work. The existing logs and screenshots do not justify
another backend recommendation or a claimed root-cause fix.

## Delivery checks

`make check DERIVED_DATA=.build/graphics-xcode` passed (256 reported Swift tests,
42 Python tests with one opt-in skip, and the Debug app build). The experimental
native helper compiled with `-Wall -Wextra -Werror`. A final isolated x64/x86
probe verified the updated session/PID guard receipts, Win32 access denial,
pooled query results and rendering. No additional gameplay retries were made
after the user's stop-and-record instruction.
