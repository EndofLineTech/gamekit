# Notch-safe 16:9 display investigation

Work `gamekit-6q8`. This is an investigation checkpoint, not a verified new
display configuration. Preserve the accepted Metal 3/fullscreen/display-capture
settings and mouse-coordinate behavior while testing.

## Observed host and guest modes

On the built-in display, the read-only macOS inventory reports:

- Current desktop: **1800×1169 logical points**, backing scale 2.
- Current mode framebuffer: **3600×2338 pixels**, 120 Hz.
- Top safe-area inset: **38 logical points**.
- Mode lists include notch-height and shorter variants, such as 1800×1169 and
  1800×1125. The latter is 16:10, not 16:9.
- No exact 16:9 mode appears in the inspected macOS mode list.

The actual Windows/DXGI probe on the selected runtime agrees with the current
1800×1169 mode. Windows enumerates the low-resolution and HiDPI-related size
variants; DXGI advertises the smaller logical-resolution set. Neither reported
an exact 16:9 mode, including 1920×1080. Device/queue creation still passes.

This is why writing a desired resolution is not sufficient evidence of a true
16:9, correctly scaled output. The active viewport, HUD, letterboxing and mouse
coordinates need to be observed. Backing-pixel dimensions must not be confused
with physical panel dimensions or the game render target.

```bash
swift diagnostics/display_modes.swift
x86_64-w64-mingw32-g++ -O0 -Wall -Wextra -Werror -static \
  diagnostics/d3d12_device_probe.cpp -o .build/notch-display-probe.exe \
  -ld3d12 -ldxgi -ldxguid -luser32
GAMEKIT_DXGI_PROBE=1 GAMEKIT_DXGI_PROBE_PATH="$PWD/.build/notch-display-probe.exe" \
  swift test --filter AVXCapabilityTests.inspectAdapter
```

The Windows probe enumerates modes without requesting a mode switch, then uses
the existing bounded device/queue/lifetime check and scoped cleanup.

## Candidate routes

The game generates an `aspect_ratio=-1` setting. A reversible trial staged
`1.7777778` to investigate whether the renderer letterboxes 16:9, rather than
only changing projection or stretching the image. **This trial did not reach
the game**, so neither its value semantics nor its visual effect is established.
It was reverted to `-1`.

Apple documents
[`NSPrefersDisplaySafeAreaCompatibilityMode`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsprefersdisplaysafeareacompatibilitymode):
when enabled for an application on a notched Mac, the system changes the active
display area to keep app content out of the camera housing. This is a promising
notch-safety route for the generated Wine application bundle, but does not by
itself promise a 16:9 aspect ratio. It also needs verification with Wine's
fullscreen display-capture behavior, app activation and restoration. No bundle
or desktop-mode change has been applied at this checkpoint.

## Current blocker and preserved state

Steam reported another computer playing **Stardew Valley** and warned that
continuing Helldivers would disconnect that session. The operator did not
continue. The local test session closed gracefully; the other computer was not
disconnected. This is an account-use gate, not a display-setting failure.

The original configuration backup is private:
`.build/helldivers-before-16x9-20260918.config`, SHA-256
`b61ac031d4c1a71b12b0db4f8f3a093a4e2a7ac744cd76dc317b71134cc8ed85`.
The original aspect-ratio value was restored after the blocked launch.
Raw account-dialog captures stay under `.build/notch-aspect-trial-1/` and are
not committed.

Resume the controlled game trial when the account is free. Acceptance requires
visible top HUD clear of the notch, undistorted 16:9 content, correct pointer
alignment, preserved Dock-edge capture, Command-Tab recovery and restoration
after exit. A probe completing successfully is not a display-mode acceptance.
