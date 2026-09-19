# Helldivers loading and first-boarding hitches

## Disposition: investigation stopped

The user reports a similar hitch on their native Windows gaming PC with an
RTX 5070 Ti. That comparison supports treating the startup-transition hitch
as game-side behavior rather than an established Gamekit-specific defect.
`gamekit-w58` is closed: **no Gamekit fix warranted at present**, not "fixed."
This is a user-observed comparison, not a controlled timing benchmark or
proof that the underlying causes are identical. No further tracing or
workaround is planned unless materially different symptoms or new evidence
justify reopening. The diagnostic findings below are retained as history;
their proposed next experiments are superseded by this disposition.

Investigation: `gamekit-w58`, 2026-09-18. This is a diagnostic assessment,
not a stutter fix. The user localized the remaining hitches to loading and
first boarding; sustained gameplay is not the target of this assessment.
The user subsequently specified the sequence: introduction video, Escape or
Enter to skip, Super Destroyer appears, then a flash at its front coincides
with the freeze. Once that flash finishes, the user reports no further hiccups.
Here, "first boarding" refers specifically to that startup transition.

## Findings

The repeatable approximately 0.9-second presentation gap coincides with a
large loading/CPU-work burst. The latest capture does **not** support a single
slow intercepted file read as its explanation. CPU-side asset processing,
synchronization and successful pipeline work remain candidates; none has been
isolated to a causal call site.

Accepted configuration remained Metal3, per-game display capture enabled,
and fullscreen Space enabled. Host: M4 Pro, 24 GB, macOS 27 build 26A428;
Helldivers build 24826606; text-input-1 runtime with D3DMetal 4.0b2.
See [the shader assessment](helldivers-shader-assessment.md) for prior
stage-in timing and Space-on/off comparisons.

### Lower-interference CPU/IO capture

The process-counter helper pins PID, start time and UID before and after each
observation. CPU values from `proc_pid_rusage` are Mach ticks, converted with
the host timebase (125/3 here), not nanoseconds. Its self-test compared a
250 ms CPU workload against the process CPU clock and measured a 1.0000 ratio.

Run 3 captured an 887.5 ms presentation interval. A coarse counter window
around its HUD batch contained 264,736,768 disk-read bytes and 5.338 CPU-seconds
over 2.162 seconds, approximately 2.47 occupied cores on average.

Run 5 added pass-through read timing and reproduced the gap:

| HUD batch emission (UTC) | Largest interval | Paired GPU time | Disk-read bytes in context window | CPU-seconds / elapsed seconds |
| --- | ---: | ---: | ---: | ---: |
| 20:12:11.686 | 308.33 ms | 20.46 ms | 115,830,784 | 4.919 / 2.165 |
| 20:12:15.159 | 883.33 ms | 15.01 ms | 267,223,040 | 5.149 / 2.159 |
| 20:12:16.973 | 195.83 ms | 17.96 ms | 102,060,032 | 4.886 / 2.148 |

Run 5 contained 7,699 HUD timing pairs: five intervals at least 50 ms, three
at least 100 ms, median/p95 8.33 ms. These are captured pairs, not an assertion
of unique frames or a sustained-gameplay benchmark.

Counter windows run from two seconds before to 0.25 seconds after **batch
emission**, with approximately 95–96% sampled coverage in the table. They are
not exact frame timestamps. The paired GPU duration does not account for
every queue/presentation wait. Large IO and CPU deltas establish context,
not which thread blocked the next frame.

### Direct read timing

`diagnostics/FileReadTiming.m` interposes `read` and `pread` only for the
managed Helldivers main image. It preserves return values, data and errno;
records no file contents or paths; and exports bounded coarse categories,
durations, counts and byte totals. Completed calls contribute to counters.
Per-second maxima cover completed `pread` calls; cumulative elapsed time is
summed across threads and is not CPU time or exclusive wall time.

The initial run 4 exhausted its shared 128-record budget on routine non-file
reads, preventing later file-read conclusions. Run 5 uses separate limits:
128 path-resolved reads of at least 20 ms, and 16 non-file/unavailable reads
of at least 500 ms, plus up to 120 one-second total records.

Run 5's last total contained 34,014 `pread` calls, 1,884,365,185 returned bytes,
and 1.055 seconds of summed call duration. The largest recorded interval
maximum was **16.046 ms**; no path-resolved `read`/`pread` reached the 20 ms
logging threshold. Around the largest hitch, cumulative `pread` bytes rose
from 481,910,570 to 664,657,706 between the 20:12:14.113 and 20:12:15.114 totals;
summed `pread` duration rose by 82.617 ms, with a 0.956 ms interval maximum.

This weakens the single-slow-file-syscall hypothesis for this capture. It does
not rule out aggregate loading dependencies, page faults/mapped IO, other
uninterposed read entry points, decompression, CPU work between calls or
downstream synchronization. Returned bytes include cached reads and are not
equivalent to physical disk counters. Long 16-byte non-file/unavailable reads
are not evidence of slow asset storage or a blocked rendering thread.

### Unsupported GPU timestamp queries

The independent D3D12 probe ran three rounds each with Metal3 and automatic
graphics in disposable prefixes. `GetTimestampFrequency` returned S_OK/60,
but timestamp EndQuery/ResolveQueryData were unsupported. Result slots stayed
at `0xfedcba9876543210`; copy controls were correct and fences completed.

Fence waits were 3.874/1.268/1.213 ms for Metal3 and 2.633/1.045/1.262 ms for
automatic. Exit 2 means observed unavailable timestamp functionality, not
working timestamps. This confirms the API limitation independently; it does
not show how Helldivers handles it or that it causes loading pauses.

### Sampling limitations and remaining evidence gap

The first 8-second/1 ms stack sample timed out; its early counters also had
incorrect nanosecond labeling and are rejected by the current analyzer.
Two coarser 8-second/10 ms samples completed in run 2, but symbolication was
largely unresolved Windows/Rosetta stacks, and the run had 24 intervals above
100 ms. It is perturbed evidence, not the baseline. Subsequent runs omitted
stack sampling. Runs 4 and 5 completed bounded observation and graceful
managed-session cleanup.

The user's flash-at-the-front-of-the-Super-Destroyer clarification identifies
the visual event, but is not a timestamped marker in the existing captures.
Those passive captures did not explicitly mark the intro skip or flash; their
approximately 0.9-second gaps must not be asserted to be this exact event.
The remaining work is to obtain a minimally
perturbing, symbol-resolved CPU/wait trace aligned to a user-confirmed boarding
event, distinguishing asset processing, successful shader work and waits.
Mark the intro skip and flash, retain a post-flash observation interval as a
control, and compare repeated launches with existing caches and settings.
The current evidence does not justify a production graphics setting change,
cache deletion or binary patch. This was the evidence gap before closure.

## Reproduction tools

### Visually aligned follow-up (run 8)

After the user's clarification, an app-filtered ScreenCaptureKit run captured
432 complete frames at a requested 10 Hz, spanning the intro, Super Destroyer
exterior, and ship interior. The earlier run 6 recorder started too late;
run 7's window recorder failed when its selected startup window disappeared.
Run 8's application filter survives window replacement and excludes other apps.
The bounded run and managed-session cleanup passed.

When asked whether this recorded launch reproduced the symptom or felt milder,
the user answered **"Same freeze."** This confirms symptom reproduction in
run 8; it does not assign an exact onset timestamp or prove that earlier
900 ms startup gaps represent the same event.

The largest HUD interval in run 8 was **200 ms**, paired with 29.61 ms GPU time,
in the batch emitted at 20:28:25.690 UTC. Visual frames 164–166 show the exterior
ship scene around this time; frame 164 to 165 presentation timestamps differ
by 199.998 ms. The coarse counter window contains 232,968,192 disk-read bytes
and 5.592 CPU-seconds across 2.163 seconds. This aligns a measured stall with
the exterior scene, but does not isolate the exact flash/effect call site.
The capture does not record who skipped the intro or a skip-key timestamp.

Crucially, the captured HUD says **Composited**, whereas the earlier run 6
still showed **Direct**. Median interval in run 8 was 16.67 ms rather than
run 5's 8.33 ms. Recording therefore perturbs the presentation path; the
smaller maximum is not evidence of a fix. The 10 Hz visual sampling can also
miss a brief flash. A marker-only direct-presentation run is needed to test
whether the user's exact freeze matches the earlier approximately 900 ms gap.

`diagnostics/StartupVisualCapture.swift` is compiled separately with `swiftc`
and supplied as the absolute executable `GAMEKIT_E6_VISUAL_TOOL` path. It
records only the selected app for 45 seconds at 900×584, with presentation,
display and callback timestamps. The harness awaits/cancels this task before
cleanup. Treat images as private visual evidence, not timing ground truth;
callback receipt times include capture latency.

### Compile/link follow-up (run 9)

Inspection of the confirmed run 8 read trace found one 41.080 ms, 4 KB
game-installation `pread`, completing at 20:28:24.420 UTC. Between the totals
at 20:28:25.068 and 20:28:26.068, another 124,141,568 bytes were returned by
`pread` with 55.121 ms summed elapsed time and a 2.519 ms maximum. This is
additional loading context, not a complete explanation of the freeze.

An optional `GAMEKIT_COMPILE_TIMING` build of `MetalStageInTrace.mm` now times
the actual vector-reference C++ `IRCompilerAllocCompileAndLink` import used
by this D3DMetal version. It forwards arguments and outputs unchanged, logs
at most 8,192 calls, and exports no entry-point names or shader contents in
the new records. A synthetic shared-library test verifies success/failure,
pointer and error-output preservation, errno and name exclusion. This is
version-specific instrumentation, not a supported cross-version API.

The bounded run 9 used this probe without visual recording and stopped
gracefully. It captured an 883.33 ms maximum (paired GPU 16.27 ms), and a later
179.17/112.5 ms pair. Seventeen failed stage-in calls totaled 25.462 ms, with
a 10.209 ms maximum. **No compile/link calls were observed at the interposed
entry.** Existing caches were retained. This does not rule out native Metal
pipeline creation, other compiler paths or waits for prior work; the absence
of observed calls must not be reported as absence of all shader work.

The user-confirmed symptom's precise mechanism remains unresolved. The proposed
next instrumentation target was native Metal pipeline creation and its waits around the exterior
transition, rather than assuming failed stage-in calls or disk latency are
the cause. That experiment is now cancelled following the native Windows
comparison. No graphics/cache configuration change is warranted.

Raw captures remain private under `.build/w58-*`; they are not repository
fixtures. Diagnostic helpers are not linked into release Gamekit.

```sh
xcrun clang -mmacosx-version-min=15.0 -Wall -Wextra -Werror \
  -I Sources/CProcessSupport/include diagnostics/process_counters.c \
  Sources/CProcessSupport/ProcessSupport.c -o .build/process-counters
.build/process-counters --self-test

x86_64-w64-mingw32-g++ -O0 -Wall -Wextra -Werror -static \
  diagnostics/d3d12_timestamp_probe.cpp -o .build/d3d12-timestamp-probe.exe \
  -ld3d12 -ldxgi -ldxguid
GAMEKIT_TIMESTAMP_PROBE=1 \
  GAMEKIT_TIMESTAMP_PROBE_PATH="$PWD/.build/d3d12-timestamp-probe.exe" \
  swift test --filter TimestampQueryTests
```

The existing opt-in `GameEvaluationLaunchTests` harness adds
`GAMEKIT_E6_PROFILE_STARTUP=1`, requiring passive-after-warning mode, at least
90 seconds and an executable absolute `GAMEKIT_E6_COUNTER_TOOL` path.
Use `GAMEKIT_E6_COUNTERS_ONLY=1` to omit intrusive stack sampling. Task cleanup
is awaited before scoped game shutdown. Read timing is separately compiled
into a diagnostic identity helper alongside GameIdentity, FullscreenSpace and
MetalHUDCapture, with fresh private output-directory macros. Never replace
the production helper to collect this evidence.

`tools/analyze_process_counters.py` combines PID-filtered counters and HUD
logs with an explicit `--utc-offset=-05:00`. It rejects schema-less legacy
captures, invalid timebases, counter reversals and insufficient observations.
Tests cover conversion/deltas and invalid evidence; the native interposer
fixture covers data, return/errno preservation and content/path exclusion.
