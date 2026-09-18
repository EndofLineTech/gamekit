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

## First Metal 3 comparison

The opt-in launcher verified `D3DM_MTL4=0` in both managed Steam and the
Helldivers process before handing control to the user. Focus/resource capture
was armed before launch; a targeted graphics log stream was also collected.
The user reported that this comparison was **"definitely better."** This is
qualitative improvement, not a measured FPS result or a completed mission test.
The user subsequently confirmed less-frequent pauses and much faster loading
onto the Super Destroyer. Pauses were not eliminated. The cursor initially
behaved without the workaround but later reappeared during active play, so
the cursor defect remains unresolved.

At inspection, `.build/helldivers-metal3-graphics-1.txt` still contained 80
pipeline/no-op failure records and 80 stage-compilation failures—the same
counts observed in the automatic-backend run. Therefore the improvement cannot
be described as removal of those logged failures, nor does their presence alone
explain the difference in perceived smoothness. Capture methods differ (live
stream versus historical query); matching counts are not a complete pipeline
identity or timing comparison. The automatic default remains unchanged.

## Driver-warning suppression attempt and research

The user requested removal of the recurring virtual-GPU warning. With the game
closed, its configuration was backed up and only
`IGNORE_APPROVED_DRIVER_WARNING` was changed from `false` to `true`. A bounded
launch using the existing comparison Steam session still showed the warning;
both the user's observation and the private screenshot confirmed failure.
The setting remained `true` afterward, so it was not simply reset in the saved
file. The test stopped the managed session, ending that temporary Metal 3
session. The ineffective preference change was then reverted to `false`.

Research found:

- An [August 13 Steam community reply](https://steamcommunity.com/app/553850/discussions/0/803471938699811827/#c585057095914782729)
  recommends that exact setting and reports success. It is community evidence,
  not a guarantee for our game build and Wine/D3DMetal combination.
- A [CrossOver user report](https://steamcommunity.com/app/553850/discussions/1/833871839865437475/)
  describes the same all-65535 AMD driver version. Earlier local DXGI probing
  already established this as the compatibility layer's reported value.
- The [Helldivers community wiki](https://helldivers.wiki.gg/wiki/GPU_Driver_Recommendation)
  describes incorrect driver warnings, but provides no verified suppression
  alternative for this setup. Its native Windows driver-installation guidance
  is not applicable to installing a driver for the Mac GPU inside Wine.
- The community [launch-command reference](https://helldivers.wiki.gg/wiki/Steam_Launch_Commands)
  did not establish another driver-check suppression argument. Generic Unreal
  command-line suggestions are not evidence for this Stingray-based game.

No verified alternative native suppression was found. A possible launcher
workaround is narrowly scoped automatic Continue on this exact owned dialog;
that would acknowledge the warning, not prevent the game from creating it or
repair graphics compatibility. No such product behavior has been added.
No driver version, game executable or anti-cheat component was modified.

The user deferred warning automation to backlog `gamekit-p92`. Active work
continues on cursor behavior.

## Game-specific cursor-confinement comparison

[Wine 10's cursor-clipping source](https://github.com/wine-mirror/wine/blob/wine-10.0/dlls/winemac.drv/cocoa_cursorclipping.m)
documents two implementations: the default macOS window-confinement rectangle
and an older event-tap/mouse-disassociation implementation. Setting
`UseConfinementCursorClipping` to string `n` selects the latter. Its comments
explicitly note that the event-tap path requires macOS Accessibility permission.
Consequently, a failed capture without that permission would not establish
whether the alternate implementation fixes the cursor problem.

The [option loader](https://github.com/wine-mirror/wine/blob/wine-10.0/dlls/winemac.drv/macdrv_main.c)
checks app-specific settings before global Mac Driver settings. The experiment
uses only:

```text
HKCU\Software\Wine\AppDefaults\helldivers2.exe\Mac Driver
UseConfinementCursorClipping = REG_SZ "n"
```

The installed Unix driver contains both implementation class names and the
corresponding option-name fragments. This supports trying the documented
option; registry readback alone is not proof that event-tap capture succeeded.

`diagnostics/helldivers_cursor_override.c` is a narrow configuration helper,
not a general registry editor. It refuses to overwrite an existing value and
refuses rollback if the stored value has changed unexpectedly. Rollback deletes
only this value, preserving sibling preferences and keys. Its Swift operator
uses the standard exclusive, scoped runtime session and verifies cleanup.

```bash
x86_64-w64-mingw32-gcc -O0 -Wall -Wextra -Werror -static \
  diagnostics/helldivers_cursor_override.c \
  -o .build/helldivers-cursor-override.exe -ladvapi32

GAMEKIT_CURSOR_OVERRIDE=query \
GAMEKIT_CURSOR_PROBE_PATH="$PWD/.build/helldivers-cursor-override.exe" \
GAMEKIT_CURSOR_EXPECT=absent swift test --filter HelldiversCursorTests

GAMEKIT_CURSOR_OVERRIDE=event-tap \
GAMEKIT_CURSOR_PROBE_PATH="$PWD/.build/helldivers-cursor-override.exe" \
GAMEKIT_CURSOR_EXPECT=event-tap swift test --filter HelldiversCursorTests
```

Games and the managed Steam session must be stopped before using this helper.
Use `GAMEKIT_CURSOR_OVERRIDE=restore-default` and expected result `absent` to
remove the override after an unsuccessful comparison.

Actual registry checks passed: initially absent; apply; readback; rollback;
readback absent; reapply; duplicate application correctly refused; final
readback `event-tap`. Each probe session stopped. The game comparison retains
fullscreen and explicitly restarts the Metal 3 session to match the better
graphics baseline. Gameplay and Command-Tab recovery results are pending.

## Dock-edge reproduction and fullscreen display-capture comparison

The user found that sustained downward mouse movement revealed the host cursor,
and pause/resume hid it again. Effective Dock settings were bottom placement,
autohide disabled. With explicit user permission, the Dock was temporarily moved
to the left, leaving the other test settings intact. The user then reported
that down/up/right were fine and **leftward** movement revealed the cursor.
The trigger followed the Dock edge. The Dock was restored to bottom and verified
with autohide still disabled.

The previous native log shows an Accessibility authorization UI appearing;
the user was unsure whether access had been granted. Therefore event-tap
capture success is still unconfirmed, despite the registry setting being read
back correctly. The Dock comparison identifies the edge interaction without
establishing the exact capture/hide-state failure underneath it.

[Wine's fullscreen handler](https://github.com/wine-mirror/wine/blob/wine-10.0/dlls/winemac.drv/cocoa_app.m)
supports `CaptureDisplaysForFullscreen`: while active with a fullscreen window,
it requests `CGCaptureAllDisplays()`. The next comparison sets only the
following additional app-specific value, preserving the existing cursor option,
Metal 3 request and fullscreen mode:

```text
HKCU\Software\Wine\AppDefaults\helldivers2.exe\Mac Driver
CaptureDisplaysForFullscreen = REG_SZ "y"
```

The narrow registry helper now also supports `query-display`, `capture-display`
and `restore-display`. It retains the same no-overwrite and guarded rollback
rules. Actual checks passed: original display override absent; apply/readback;
duplicate application refused; restore to absent; sibling cursor override still
`event-tap`; reapply display capture. This establishes setting control, not the
result of the macOS display-capture request.

```bash
GAMEKIT_CURSOR_OVERRIDE=capture-display \
GAMEKIT_CURSOR_PROBE_PATH="$PWD/.build/helldivers-cursor-override.exe" \
GAMEKIT_CURSOR_EXPECT=enabled swift test --filter HelldiversCursorTests
```

Use `restore-display` with expected result `absent` to undo just this value while
the prefix is stopped. The private focus observer records the public display
shield-window ID alongside foreground-game pointer coordinates. The older
`CGDisplayIsCaptured` query is unsupported by this SDK and is not used.
The user reported **"Whatever you just changed, that fixed it"** after this
comparison. The Dock was at its original bottom position. The trace shows the
game's fullscreen window at layer `2147483630` (with an additional window at
`2147483628`), rather than the earlier layer 27. This is consistent with Wine's
display-capture presentation path placing the game above the Dock. The external
shield-window query stayed zero and is not used as an independent capture-success
assertion; the layer change and user-observed behavior are the relevant evidence.

After confirming the game had exited, the earlier event-tap override was removed
and the display-capture value was read back as enabled. A fresh Metal 3 session
was launched for a final comparison using **only** the display-capture override
and the default cursor-confinement implementation. This avoids retaining an
unproven extra setting whose Accessibility permission was never confirmed.
The user subsequently confirmed **"Working great the way it is now"** following
the requested edge/Command-Tab recheck. The minimal cursor configuration is
accepted for this Mac: fullscreen plus the game-specific display-capture value,
with the default cursor handler and the Dock restored to bottom. Metal 3 remains
the better-performing tested session backend; pipeline errors and full mission
performance are separate unresolved findings.

Private evidence is in `.build/helldivers-display-capture-focus-1.jsonl` and
`.build/helldivers-display-capture-only-focus-1.jsonl`.

The user also requested notch-safe **16:9** presentation because the camera notch
covers part of the current fullscreen image. Backlog `gamekit-6q8` tracks true
aspect ratio, letterboxing/scaling, Retina versus logical dimensions and mouse
alignment while preserving the successful cursor behavior. No display-mode
change was made as part of filing that backlog item.
