# Native macOS fullscreen Spaces investigation

Issue: `gamekit-deg`. Status: diagnostic candidate; live acceptance blocked by an
active Steam game on another computer. This is not a delivered fullscreen option.

## Mechanism

Wine 10's `dlls/winemac.drv/cocoa_window.m` distinguishes two presentation paths:

- `adjustFullScreenBehavior` makes eligible, resizable, non-maximized top-level
  windows native fullscreen primaries. A windowed game can use AppKit fullscreen.
- `updateFullscreen` explicitly excludes windows with `NSWindowStyleMaskFullScreen`
  from its screen-covering Wine fullscreen calculation. Therefore the accepted
  `CaptureDisplaysForFullscreen=y` exclusive-presentation cursor fix does not by
  itself establish cursor behavior in a native fullscreen Space.

The optional path under investigation starts with a windowed game, enters native
fullscreen, and requests AppKit's HideDock/HideMenuBar presentation options. It
does not change aspect ratio or patch game rendering. The existing Wine fullscreen
configuration remains the fallback. Dedicated-Space behavior, Mission Control,
focus transitions and cursor confinement must be verified before delivery.

## Diagnostic candidate

`diagnostics/WineNativeSpaceTrial.m` is linked alongside the identity helper in a
separate, ignored test package. Only a managed `helldivers2.exe` process can install
its temporary delegate proxy. It preserves Wine's delegate callbacks and requests
native fullscreen once, only for a visible eligible resizable Wine window. Window
discovery expires after 90 seconds. The production helper is unchanged.

The bounded E6 observation test adds `GAMEKIT_E6_SPACE_ROUND_TRIP=1` for Helldivers
with at least 90 seconds of observation. It checks `AXFullScreen`, primes Finder as
the previous application, sends actual Command-Tab events away and back, verifies
the owned foreground PID and retained fullscreen state, exits native fullscreen,
and verifies the state cleared. Existing scoped cleanup closes the test session.
This is not proof of mouse-coordinate alignment, physical Dock-edge behavior or
multi-game compatibility; those require additional validation.

## Current evidence and rollback

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

Next: once the account is free, rerun the bounded candidate, then check physical
mouse behavior, Mission Control/Space navigation, clean exit/restoration and a
second game's behavior before designing the persisted user-facing option.
