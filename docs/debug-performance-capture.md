# Debug performance capture

## In the app

Under **Local diagnostics**, enable **Debug mode — capture game startup
performance**, then launch a game from Gamekit's Play control. The option is
off by default on each fresh Gamekit app launch; it does not persist in Wine or alter
game/runtime settings.

Gamekit waits up to 60 seconds for exactly one owned, visible application
process with that AppID's bundle identifier or derived-loader path. Display
names are used only for UI labels, not process selection. It then records up to 60 seconds of
CPU ticks, memory footprint, disk read/write counters and page-ins at 100 ms
intervals. This measures one identified process, not all of a game's helper
processes or every startup instruction. Direct launches from Steam are not
automatically captured by this app-side option.

**Stop debug capture** stops the sampler, not the game. Turning debug mode off
also cancels sampling. Normal game launches bypass the capture path when debug
mode is off. Failed, ambiguous or changing ownership ends/refuses capture
without controlling the game. The helper pins UID/PID/start time before and
after each counter read; Gamekit additionally rechecks session ownership.

Results appear as **performanceCapture** records in Local diagnostics. Choose
**View local output** to read/copy the JSONL counters or **Open local logs** to
inspect the private records. Normal **Export summary** continues to exclude
raw counters and identifiers. Nothing is uploaded automatically.

The existing diagnostic policy bounds each stream to 256 KiB and retains up
to 20 operations for seven days, with active records protected and one-second
checkpoints. Quitting/crashing Gamekit can leave an incomplete checkpointed
record. The standalone sampler has its own duration bound and never stops the
game. A counter or storage failure is a diagnostic failure, not evidence that
the game failed.

Counters add some overhead and do not establish frame timing or the cause of
a hitch. CPU fields are **Mach ticks**, converted using the recorded timebase;
they are not nanoseconds. Cumulative CPU seconds across threads can exceed
elapsed wall time. Disk counters are not equivalent to all asset reads.

## Analyze a saved app record

From the source checkout:

```sh
python3 tools/analyze_process_counters.py \
  --diagnostic-record "<local logs>/Operations/<capture-id>.json"
```

This reads the private record's base64-encoded stdout, identifies the single
counter PID, and reports CPU/IO deltas and peak observed footprint. Summary
exports do not contain the counters and cannot be used here. Standalone helper
JSONL can instead be supplied with `--counters`. Optional `--hud`, `--pid` and
`--utc-offset=-05:00` retain the earlier coarse HUD-batch correlation workflow;
batch emission time is not an exact frame timestamp.

## Retained developer tools

The earlier startup investigation is retained, including its tests and
[findings](helldivers-startup-hitches.md). Its closure remains unchanged: the
user observed similar transition behavior on native Windows.

| Tool | Delivery |
| --- | --- |
| `process_counters.c` | Bundled as the signed native `GamekitProcessCounters` helper; also usable standalone |
| `analyze_process_counters.py` / `analyze_metal_capture.py` | Source-checkout analysis tools |
| `d3d12_timestamp_probe.cpp` / `TimestampQueryTests` | Opt-in, disposable-prefix API observation; not an app debug action |
| `MetalHUDCapture.m` | Explicit developer capture build; not injected by app debug mode |
| `MetalStageInTrace.mm` compile/link extension | Version-specific private-ABI investigation; not in release app instrumentation |
| `FileReadTiming.m` | Developer-only syscall interposition; not in release app instrumentation |
| `StartupVisualCapture.swift` | Developer-only app-filtered visual evidence; it changes compositing/presentation |
| `sample` integration in the opt-in launch harness | Developer-only; previous runs measurably perturbed timing |

The advanced harness flags remain opt-in and preserve its ownership/cleanup
checks. Its historical passive-after-warning profiling mode requires that
warning to actually appear; the app's new counter capture has no such
dependency. Raw screenshots, reflection and process captures remain local
under `.build` and are not committed with these tools.

## Local verification

- The packaged helper's self-test agreed with the process CPU clock after Mach
  timebase conversion (125/3 on the evaluated host).
- A real app-launched Helldivers capture completed its 60-second window and
  stored 583 samples; the rebuilt sampler produced no stderr. An initial
  coverage-runtime profiling-file warning was fixed by disabling coverage
  instrumentation for the helper target.
- Live cancellation followed the PID/start identity in the capture record,
  rather than a hardcoded game name. The same owned game process remained
  alive after the UI's Stop debug capture action and the record was cancelled.
  Subsequent test-session cleanup used the normal scoped Stop path, including
  its forced fallback; that was separate from stopping the sampler.
- Tests cover private-output/summary separation, refused/replaced ownership,
  cancellation without terminating a target process, process loss during
  sampling, the default-off/reopen UI behavior, and packaged helper presence.
- The counter analyzer reads the app's private record directly, with CPU/IO
  and observed footprint summaries. These are not FPS measurements or causal
  conclusions about stutters.
