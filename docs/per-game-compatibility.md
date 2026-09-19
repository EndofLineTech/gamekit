# Validated per-game compatibility controls

Issue: `gamekit-tmx`. The first supported override is Helldivers 2 (Steam AppID
553850), `CaptureDisplaysForFullscreen` in the Wine `helldivers2.exe` AppDefaults
Mac Driver key. The accepted cursor configuration is documented in
[Helldivers stalls and cursor](helldivers-stalls-and-cursor.md).

## Scope

The game panel exposes enabled, disabled and inheritance. Effective state combines
the explicit app override with `HKCU\Software\Wine\Mac Driver`; Wine 10 defaults
capture to false. `winemac.drv/macdrv_main.c` initializes
`capture_displays_for_fullscreen` to zero and reads application-specific config
before the global fallback. The control applies to the next game process.

The shared graphics backend in Setup is the default for Steam and its games.
`gamekit-aty` adds [per-game backend overrides](per-game-graphics-backends.md)
to each ready installed game's gear panel, accounting for Steam's inherited
environment. The original capture feature does not change aspect ratio or
implement automatic warning handling.
The later `gamekit-deg` feature adds an independent opt-in Helldivers fullscreen
Space; see [native fullscreen Spaces](native-fullscreen-spaces.md). No unsupported
cursor-handler preference is exposed.

## Persistence and mutation boundary

The existing Wine registry is authoritative; opening the panel never imports a
default over the accepted live configuration. A missing app-specific value means
inheritance. The narrow registry reader supports canonical `REG_SZ` y/n values;
unknown types/values, duplicate relevant sections/values, invalid encoding and
unsupported headers fail closed.

Saving takes installation and execution leases, refuses persistent session
receipts, and checks the selected and both known runtime layouts for live or
unobservable processes. It reads `user.reg` through the pinned managed directory,
edits only the app's capture value, atomically publishes after revalidating prefix
identity and original bytes, then reads back the result. Symbolic-link destinations
are refused. Unrelated lines are preserved. The game configuration, source runtime
and generated PE-sharing launcher caches are unaffected by this registry option.

Inherit removes only the supported value; it does not reset the shared graphics
backend, delete the key's sibling preferences or reset any saves. The UI shows
saved effective configuration, not a claim that an already-running game has
adopted it. Stop and relaunch are required for changes.

## Verification

- Core tests: persistence/reopen, inherited global setting and Wine default,
  enable/disable/reset, sibling preservation, new sections, malformed/ambiguous
  values, unsupported AppIDs, active/uncertain processes, receipts, execution
  leases and registry symlinks.
- Native UI: enable, disable, restore defaults, enable again, quit/reopen and
  verify persistence on a disposable installed-game fixture.
- Real Wine: initialize a disposable prefix with the selected text-input runtime,
  save each setting, launch an independent Windows `RegGetValueW` probe in a fresh
  session, then stop it and verify persisted state. Enabled, disabled and absent
  (inheritance) all passed. The primary game configuration was not changed.

The Windows probe is diagnostic-only, compiled from
`diagnostics/helldivers_cursor_override.c`; it is not shipped or invoked by the
product UI. The app's settings mutation does not launch Wine.

```sh
swift test --filter GameCompatibilityTests
GAMEKIT_COMPATIBILITY_WINE_SMOKE=1 \
  GAMEKIT_CURSOR_PROBE_PATH=/absolute/path/to/helldivers-cursor-override.exe \
  swift test --filter GameCompatibilityTests.wineReadback
```
