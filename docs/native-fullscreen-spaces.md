# Native macOS fullscreen Spaces investigation

Issue: `gamekit-deg`. Helldivers now has an opt-in fullscreen Space setting,
validated on the built-in display of the development Mac. The final implementation
retains the full 1800×1169 game area, including the notch-height region.

## Using the feature

Stop Windows Steam, open Helldivers' **Compatibility settings…**, and choose
**Use fullscreen Space**. Keep **Fullscreen** selected inside the game. A fresh
launch creates the Space without changing the game resolution or capture override.
Choose **Use desktop fullscreen** while stopped to restore the original path.
The setting is off by default; it was explicitly enabled on the development Mac
after the user's hands-on acceptance. Other games and Steam retain their existing
presentation.

The product helper creates a small native fullscreen host, then places the original
Wine window using FullScreenAuxiliary and MoveToActiveSpace. It never reparents a
Wine window or resizes its game content. The host uses HideDock/HideMenuBar, and the
accepted Wine fullscreen capture preference remains intact. The native host itself
is notch-safe; the separate game window covers the entire display.

`Metadata/GamePresentation.json` stores the typed opt-in under AppID 553850. Changes
require stopped-session checks and installation/execution leases. Launch copies
the preference into the private prefix/session-bound Dock mapping. The helper
requires a genuine JSON boolean, matching session/prefix, approved AppID and the
main `helldivers2.exe` image. Steam, crash handlers and other games cannot inherit
the Space merely through SteamAppId. Discovery is bounded to 90 seconds; failure
leaves the normal game window available.

The host exits with game-window lifetime or sustained disappearance while the game
is active. Wine emits close/hide operations during focus suspension, so these are
not interpreted as game exit. Command-Tab inactivity/minimization resets the
disappearance timer. No synthetic keyboard or Accessibility control is used by
the product helper; those appear only in the opt-in verification harness.

## Mechanism

Wine 10's `dlls/winemac.drv/cocoa_window.m` distinguishes two presentation paths:

- `adjustFullScreenBehavior` makes eligible, resizable, non-maximized top-level
  windows native fullscreen primaries. A windowed game can use AppKit fullscreen.
- `updateFullscreen` explicitly excludes windows with `NSWindowStyleMaskFullScreen`
  from its screen-covering Wine fullscreen calculation. Therefore the accepted
  `CaptureDisplaysForFullscreen=y` exclusive-presentation cursor fix does not by
  itself establish cursor behavior in a native fullscreen Space.

The initial diagnostic started with a windowed game, entered native fullscreen,
and requested AppKit's HideDock/HideMenuBar presentation options. It did not change
aspect ratio or patch game rendering. Its notch-height strip led to the separate
host implementation described above, preserving the original Wine fullscreen
game window instead.

## Initial diagnostic candidate

`diagnostics/WineNativeSpaceTrial.m` is linked alongside the identity helper in a
separate, ignored test package. Only a managed `helldivers2.exe` process can install
its temporary delegate proxy. It preserves Wine's delegate callbacks and requests
native fullscreen once, only for a visible eligible resizable Wine window. Window
discovery expires after 90 seconds. This diagnostic is not linked into the product.

The bounded E6 observation test adds `GAMEKIT_E6_SPACE_ROUND_TRIP=1` for Helldivers
with at least 90 seconds of observation. It checks `AXFullScreen`, primes Finder as
the previous application, sends actual Command-Tab events away and back, verifies
the owned foreground PID and retained fullscreen state, exits native fullscreen,
and verifies the state cleared. Existing scoped cleanup closes the test session.
This is not proof of mouse-coordinate alignment, physical Dock-edge behavior or
multi-game compatibility; those require additional validation.

## Investigation history

The candidate compiled for x86_64 with ARC, AppKit/Foundation and warnings as
errors, and was locally signed. Two bounded launch attempts on September 18 did
not start Helldivers. Steam's private console log identifies
`LaunchApp waiting for user response to KickingOtherSession` with Stardew Valley
as the other game. No response authorizing disconnection was sent. The second
attempt's extra startup delay did not change that account gate, and the delay was
removed from the diagnostic.

Both local sessions stopped gracefully. The only manually changed game setting,
`fullscreen`, was restored to true. Borderless remains false, aspect selection is
automatic, saved screen resolution is 1800×1169, and Metal 3 plus the accepted
game-specific capture preference remain the baseline. No native-Space, input or
Command-Tab pass is claimed from these blocked attempts. Screenshots/raw logs stay
private under `.build`.

After the account became free, direct native fullscreen rendered the game and
passed Command-Tab/exit checks, but its 1800×1130 content started 39 points below the
display top. The user explicitly required the entire display. Finder's fit-to-screen
checkbox was verified off, generated app metadata had no safe-area override, the
old letterbox delegate was absent, and the then-shipped identity helper still
matched its pre-experiment hash. Standalone AppKit windows reproduced the strip
without Wine, including full-size-content, borderless and custom-animation trials.
Requesting the whole screen through the size delegate did not remove the strip.

A parent/child host attempt produced a user-confirmed blank window. Its native
exception was traced to WineWindow's setMacDrvParentWindow: calling the Wine-only
removeChildWineWindow: selector on an ordinary NSWindow parent. That approach was
rejected. The non-parenting auxiliary-window implementation restored rendering and
full-display geometry. Both host and game reported being on the active Space,
with the game key and 1800×1169. The user confirmed full-display rendering, a
dedicated Space, and correct Dock-edge and Command-Tab mouse behavior.

## Product verification

- Saved opt-in, reopen, disable/rollback, invalid schema/value rejection and stopped
  process guards are covered by core tests.
- Native reader tests reject wrong sessions, crash-handler images, other games,
  false, numeric and string lookalikes for the opt-in boolean.
- The native UI test enables the setting, reopens the app and restores desktop
  fullscreen, alongside the existing capture controls.
- Actual Helldivers with the product helper passed native-host fullscreen state,
  real Command-Tab away/back, explicit host exit and graceful cleanup.
- A cleanup regression exposed Wine's temporary close/hide behavior on focus loss.
  The final helper tracks lifetime and active visibility instead. The subsequent
  real test retained the Space through Command-Tab and then quit the game normally
  with graceful session cleanup.
- Disabling the preference restored the desktop path; a fresh Helldivers run
  verified no native host. Re-enabling preserved capture=y and saved Metal 3.
- With the Helldivers preference enabled, the real Satisfactory shipping-process,
  Dock and graceful-stop regression passed with no Space host for Satisfactory or
  Steam. Satisfactory is not exposed as a supported Space title yet.

External displays and other game titles are not included in this acceptance. Raw
captures and traces stay private; the tests do not establish FPS or mission results.
