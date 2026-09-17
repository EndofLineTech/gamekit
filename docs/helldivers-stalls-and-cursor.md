# Helldivers recurring stalls and host cursor

Investigation `gamekit-5pq`, September 17, 2026, on the managed text-input-1
runtime and Helldivers build 24826606. Startup success is established; playable
performance remains unresolved.

## User observations and controlled settings

- The host cursor interfered during gameplay in borderless mode.
- Switching only to fullscreen improved initial capture. Command-Tab still
  brought the host cursor back; opening the pause menu and resuming hid it again.
- The user reports frequent recurring pauses, including first arrival aboard
  the Super Destroyer and walking around shortly afterward. They also observed
  cursor reappearance with pauses. In the latest run the cursor was visible
  until pause/resume restored it; these are related observations, not proof
  that every pause causes a new cursor transition.
- A second comparison enabled the game's 30 FPS limiter. Both the saved file
  and the user-confirmed in-game menu showed 30. Motion felt above 30 to the
  user; no FPS overlay was used. Actual presented FPS is unmeasured, and the
  pauses continued under the configured setting.

Each settings change had a private configuration backup. Current saved mode is
fullscreen, borderless disabled, limiter enabled at 30. Graphics/texture settings
were not changed during these comparisons. The observed window is 1800×1169
logical points; this is not a verified 1080p performance result.

## Startup-aligned capture

Read-only observers were started **before** the game launch. The ten-minute
window includes application activation/deactivation, Spaces notifications,
owned game-window geometry (one-second samples), and CPU/RSS/system VM/swap
samples (five-second intervals). No screenshots, cursor visibility API or frame
timing was collected by these observers.

For the user-reported startup/ship run:

- Helldivers became foreground at **22:47:35 UTC**.
- From **22:47:37 through 22:48:36 UTC**, the same game window remained at
  1800×1169 and layer 27. No intervening app activation/deactivation or Space
  change was recorded. The observer continued producing roughly one-second
  samples through this period.
- The game window disappeared at 22:48:37, another application became active
  at 22:48:38, and game processes disappeared by 22:48:40, consistent with the
  user's reported normal quit.
- Swap usage and swap-in/out counters remained zero. Compression, wired-memory
  and CPU usage changed substantially during loading. These system-wide
  counters do not identify which game/graphics operation stalled.

This capture does **not support another macOS application stealing focus during
the play interval**. It does not rule out Windows-side focus/capture transitions
inside Wine, game-internal cursor state, or rendering stalls. Cursor visibility
and exact freeze times come from the user's report, not the window-geometry log.

## Concrete graphics errors

The macOS unified log for the game process contains **80** records of:

```text
[D3DMGraphicsPipelineState:327][ERROR] Failed to compile a pipeline, marking PSO(...) as no-op
```

There are also 80 corresponding `CompileGraphicsPipelineStages` failure records.
They occur in bursts between **22:47:41.057 and 22:47:51.832 UTC**, shortly after
the full-size game window appears. These are actual compilation failures and
disabled graphics pipelines, not evidence of harmless first-run compilation.
The excerpt does not expose the underlying shader/compiler reason. It also
does not prove that these errors explain every later pause or the cursor issue.

Private evidence:

- `.build/helldivers-startup-focus-1.jsonl`
- `.build/helldivers-startup-resources-1.jsonl`
- `.build/helldivers-startup-metal-log-1.txt`

Earlier short captures either lacked useful gameplay focus coverage or had no
freeze timestamps. They are not used to conclude that focus was stable during
unobserved play. `memory_pressure -Q` in the VM sampler used no allocation or
simulation flags; Apple's published source returns after reporting when no
target level/percentage is specified. The percentage is not treated as a
game-specific memory-pressure measurement.

## Next comparison: Metal 3 backend within D3DMetal 4.0b2

Apple's [inspected GPTK instructions](gptk-package-inspection.md) document
`D3DM_MTL4=0` to select the Metal 3 backend. With the variable unset, Metal 4 is
the documented D3D12 default on this macOS 27 host. This comparison changes the
backend request, **not** the Wine engine, text-input fix, D3DMetal binaries,
game settings or prefix.

`RuntimeLayout` now has an explicit `graphicsBackend` diagnostic option.
Normal app/settings-store construction remains `.automatic` and discards
inherited backend flags. `.metal3` supplies `D3DM_MTL4=0` in the controlled
environment. The opt-in test starts a fresh owned Steam session, launches
Helldivers with the existing game identity helper, and checks that the native
Steam and game process environments actually contain the flag.

After exiting games, arm captures before invoking:

```bash
GAMEKIT_HELLDIVERS_METAL3=1 \
GAMEKIT_E6_PACKAGE="$PWD/.build/packages/Gamekit-20260917T191349Z/Gamekit.app" \
  swift test --filter HelldiversGraphicsBackendTests.launchMetal3
```

This explicitly opted-in helper leaves a successful session running for the
user's comparison. Failures trigger scoped cleanup. Stop Steam in Gamekit after
the trial; a fresh normal launch restores the automatic backend. The option is
not a persisted preference or a new default. Compare both the user's pauses and
the pipeline-failure log before deciding whether the fallback helps.

No Metal 3 gameplay result is claimed at this checkpoint.
