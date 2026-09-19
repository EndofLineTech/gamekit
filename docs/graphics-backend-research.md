# DXMT and DXVK integration research

Research history, 2026-09-19. The initial failures below were followed by the
source-backed fixes in the final section. Current installation, launch behavior
and qualification limits are documented in [graphics-backends.md](graphics-backends.md).
Research findings determined the subsequent targeted trials.

## DXVK: correct the library pairing before diagnosing a renderer defect

The initial candidate combines Gcenx DXVK-macOS
`v1.10.3-20230507-repack`, Sikarugir 10.0 revision 6's original Wine DXGI,
and the wrapper's generic `Frameworks/libMoltenVK.dylib` (observed 1.4.1).
Simple x64/x86 shader draw/readback/presentation passes, but Satisfactory's
D3D11 menu background is black.

[OneLauncher's integration](https://github.com/JuneStepp/OneLauncher/blob/main/src/onelauncher/wine_environment.py)
uses the same Sikarugir engine, Template-1.0.11 and DXVK release, and explicitly
puts **`Frameworks/moltenvkcx` first** in `DYLD_FALLBACK_LIBRARY_PATH`.
For Sikarugir it selects the bundled DXVK through `WINEDLLPATH_PREPEND`.
The initial Gamekit candidate did not reproduce that library preference.
The corrected candidate now selects it only for DXVK game images, through the
prefix/session-bound mapping. Steam, DXMT and Apple-backend children reset to
the original library search path. dyld captures search paths at startup, so a
path change forces a bounded loader re-exec even if the correct game's loader
was already selected. Native tests verify actual `dlopen` results in both
directions, including the same-loader case.

The paired library is pinned to SHA-256
`e9de8aa6053e1347c82aff01c6d7964556f306b2f7c63db88eb54a05e4f8b980`.
One 180-second Satisfactory comparison verified the DXVK derived loader and
`Frameworks/moltenvkcx/libMoltenVK.dylib` in the owned game process's module map.
The game reached its menu, but the 3D background remained black. This corrects
the library pairing; it does **not** fix or qualify Satisfactory's rendering.
Cleanup was graceful and the original backend preference was restored/read back.
Local evidence: `.build/graphics-satisfactory-cx*`, `.build/graphics-cx-restore.log`.

[MoltenVK issue 1665](https://github.com/KhronosGroup/MoltenVK/issues/1665)
records the closely matching Unreal symptom: visible menus, black scene and
colored outlines. A commenter links the historical `ue4-workaround-3` build.
Inspection of the
[preserved patch](https://github.com/rinsuki-lab/nastys-MoltenVK/commit/d732aaf7e03f371b9ad8acd56416edb237140d51)
shows that it does considerably more than change a runtime option:

- Advertises geometry-shader and cull-distance features.
- Enables image-view swizzles, disables fast math, changes semaphore behavior.
- Replaces two specific generated shader expressions.

That 2023 patch is not a verified solution for current Satisfactory/UE 5.6.
Do not blindly install it or treat its feature advertisement as implementation.
[Whisky issue 1310](https://github.com/Whisky-App/Whisky/issues/1310) also reports
Satisfactory launching with `-dx11` but rendering black with lines/dots; its
report does not establish the cause of this candidate's failure.

## DXMT: timestamp completion deserves source analysis

[DXMT PR 138](https://github.com/3Shain/dxmt/pull/138) explains the v0.80
timestamp implementation. Earlier versions returned zero; v0.80 adds command
buffer end-time and counter-sample-buffer implementations. In
[the release source](https://github.com/3Shain/dxmt/blob/v0.80/src/dxmt/dxmt_occlusion_query.hpp),
`TimestampReadback` aliases `TimestampReadbackCBuf` at **compile time**.
Switching implementations is not an established environment-variable fix.

The
[queue implementation](https://github.com/3Shain/dxmt/blob/v0.80/src/dxmt/dxmt_command_queue.cpp)
waits for command-buffer completion on its finishing thread, then resets the
chunk (publishing timestamp readback) before signaling CPU coherence. GPU event
completion and that CPU-side publication are distinct stages.

Local evidence, obtained before this research checkpoint:

- Shader draw/readback/presentation passed in both x64 and x86 derived loaders.
- Satisfactory's crash symbols identify
  `TOptional<FD3D11DynamicRHI::FTimestampCalibration>::GetValue`,
  `FD3D11DynamicRHI::GetQueryData`/`PollQueryResults` and
  `RHISubmitCommandLists`.
- A tight-poll standalone probe observed event completion followed by timestamp
  `S_FALSE` on all three DXMT attempts. With a 1 ms polling sleep, all three
  yielded nonzero timestamps. DXVK also had pending results on two tight-poll
  attempts, so the observation alone is not a complete causal proof.

No public Satisfactory-specific
DXMT fix was found in the searched upstream issues or indexed web results.
`dxmt.report` redirects to the project's Discord; no private Discord content was
accessed. The reviewed post-v0.80 mainline history does not identify a timestamp
ordering fix that can simply be assumed to resolve this failure.

### Source analysis of the readiness gap

The release's
[`MTLD3D11ImmediateContext::GetData`](https://github.com/3Shain/dxmt/blob/v0.80/src/d3d11/d3d11_context_imm.cpp)
passes `cmd_queue.SignaledEventSeqId()` to event/disjoint queries. That method
reads the GPU `MTLSharedEvent` value. It does not wait for the finishing thread's
`cpu_coherent` fence.

Timestamp queries instead call `TimestampQuery::getValue()`. Their value is
published by `TimestampReadbackCBuf` destruction when the finishing thread resets
the completed chunk. Only **after** that reset does it signal `cpu_coherent`.
There is therefore a real interval in this implementation during which an event
can be signaled but its preceding timestamp remains unavailable. The timestamp's
`cached_value_` is also an ordinary `uint64_t`, read and written on different
threads without an evident release/acquire publication operation in those methods.

[Microsoft's query documentation](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/ne-d3d11-d3d11_query)
describes an event as GPU command completion. It does not explicitly promise in
that reference that another query's CPU readback must immediately return `S_OK`.
Consequently the local observation is not by itself proof of an API violation.
The game's finite calibration retries and the backend's later CPU publication
form a plausible compatibility failure, consistent with the symbolized assertion.
Its causal role still requires a corrected-backend comparison.

A source-fix candidate should associate event/disjoint query readiness with both
its GPU event and the CPU readback generation for preceding queries. Initial
empty events and reused events must remain nonblocking; do not wait on an
uncommitted chunk. Timestamp publication independently needs a valid C++
release/acquire relationship. `GetData` should remain a nonblocking readiness
check, preserving `DONOTFLUSH`, rather than adding sleeps, returning fabricated
timestamps, or disabling the game's assertions.

This is an upstream renderer change, not a Gamekit launch flag. No such patch
has been built or claimed fixed here, and no further DXMT game launch was run
for this source-analysis step.

## Streamline is a separate startup hurdle

Both initial Satisfactory D3D11 trials stopped during Streamline initialization.
The shipped plugin exposes `r.Streamline.InitializePlugin`. A test-only command
line override,
`-ini:Engine:[SystemSettings]:r.Streamline.InitializePlugin=0`, moved execution
past that point; the game's log confirmed initialization was disabled.
It did not cure DXMT's later assertion or DXVK's black 3D scene.
This was not persisted in game settings or added to ordinary Gamekit Play.

## Acceptance boundary

The published Satisfactory entries in
[AppleGamingWiki](https://www.applegamingwiki.com/wiki/Satisfactory) and
[Whisky's guide](https://docs.getwhisky.app/game-support/satisfactory.html)
are older; the explicit successful CrossOver report uses **D3DMetal**. They do
not qualify current DXMT or DXVK for the installed game build.

All game observation sessions were closed. Satisfactory's saved override was
restored to `inherit`, with shared `metal3` and effective `metal3` read back.
Raw game logs, crash data, module maps and screenshots remain local. The
initial integration checkpoint passed
`make check`: 254 Swift tests, 42 Python tests (one opt-in skip), and the native
app build. The Release candidate also built successfully. These checks and the
scoped library-load test were not sufficient game qualification. The alternatives
remained disabled at that checkpoint.

## Resolved paths and rejected follow-ups

### DXMT: real timestamps and legacy same-process sharing

The v0.80 source was rebuilt with event readiness gated on finishing-thread
publication, and release/acquire timestamp storage. The same tight-poll test
changed from **100/100 pending results** in the unmodified control to **0/100**
in the patched build; shader rendering still passed.

The next Satisfactory failure was a 1024x1024 shared R16_FLOAT texture, not a
continuation of the timestamp fault. Upstream
[v0.72 release notes](https://github.com/3Shain/dxmt/releases/tag/v0.72) and
[PR 105](https://github.com/3Shain/dxmt/pull/105) explicitly require Wine 10.18+
for D3DKMT sharing and discuss restoring the older same-process functionality.

Wine 11 candidates were isolated and rejected: the generic 11.17 build lacks
the DXMT macOS-driver exports; Sikarugir 11.0 has a `no_d3dmetal` marker and the
tested candidate did not bootstrap. An attributed DXMT driver adapter was built
for a disposable 11.0 candidate, not installed in the accepted runtime. Existing
repository warnings about unsupported generic Wine/D3DMetal combinations should
have ruled out that path sooner. None of these experiments migrated the primary
Steam prefix or became a product dependency.

The qualified DXMT revision instead restores a bounded same-process shared-2D
texture path on Wine 10, using a weak resource-state registry and prefix-global
atom tokens rather than the old raw-COM-pointer approach. x64/x86 tests verify
cross-device pixel readback, owner-release lifetime, foreign-process rejection,
stale/bogus handles and explicit rejection of NT/keyed-mutex sharing. The normal
D3DKMT path is retained. The resulting `dxmt-0.80-compat2` reached Satisfactory's
rendered 3D menu and stopped gracefully.

### DXVK: compute post-processing and query completion

The config-only fast-math/swizzle subset of the historical workaround did not
establish a rendering fix. The newer
[MetalSharp DXVK 3.1 package](https://github.com/metalsharp/DXVK-MacOS/releases/tag/v3.1-macos1.0)
created a device but failed on shared-resource creation on this runtime. Its
newer MoltenVK paired with the older DLLs passed the small render probe but still
produced Satisfactory's black scene. These combinations were not promoted.

Inspection of the historical shader substitutions pointed to post-processing
lookup-table sampling. Unreal's documented
[`r.PostProcessing.PreferCompute`](https://indxzero.github.io/ue544cvarwiki/articles/r.postprocessing.prefercompute/)
selects compute implementations where available. The installed game contains
this setting. A single-option comparison with
`-ini:Engine:[SystemSettings]:r.PostProcessing.PreferCompute=1` restored the
visible 3D scene using the original DXVK/MoltenVK pairing. This avoids replacing
shader expressions or removing color grading. It does not prove every effect
or gameplay path is correct.

DXVK event polling also needed to observe submission completion rather than
only the Vulkan event. Tracking that event as a resource write resolved the
100-attempt tight-poll calibration probe without blocking or fabricated values.
The rebuilt 32-bit DLL exposed an existing logger ABI mismatch: DXVK declared
Wine's `__wine_dbg_output` callback as stdcall, whereas Wine's source and spec
declare cdecl. A probe exception handler located the fault in Logger::emitMsg;
correcting the calling convention made the x86 calibration/render test pass.
Stack realignment alone did not fix it and was not retained.

### Normal launch integration

Gamekit Play now adds only the validated Satisfactory options when its effective
backend is DXMT/DXVK. Apple-backend launches and other games receive no added
options. The options are transient; Steam's saved Launch Options and game
preferences are not edited. Source patches, compiler dependencies, licenses,
module pins and rollback remain explicit in the source-notice directories.

Final local acceptance used the packaged app's dropdowns and actual Play button
for both backends. Both reached Satisfactory's rendered 3D menu; the DXVK run
subsequently logged a normal `UGameEngine::HandleExitCommand`, not a crash.
Transient launch options were read back from the game log. Both sessions closed
gracefully. The Apple/Helldivers regression reached the ship without an observed
driver alert and also stopped gracefully. Shared Metal 3 and Satisfactory's
original inheritance were restored.

Both source rebuilds reproduced all pinned x64/x86 PE hashes. The completed
derived-loader checks include DXVK's 100-attempt timestamp test on both
architectures and DXMT's cross-device/shared-handle/lifetime checks, including a
separate process attempting to import the live token. Native UI acceptance passed
after the local automation session became available. Missing-payload controls,
restart/revert, active-session locking, and installed-payload independence were
checked separately.
