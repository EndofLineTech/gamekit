# Persistent graphics backend

`gamekit-s8v` makes the accepted Helldivers Metal 3 choice available through
normal Gamekit launches. It uses the existing Wine 10/text-input-1 runtime and
unchanged D3DMetal 4.0b2 payload.

## User controls and scope

In **Setup and prerequisites**, Gamekit displays **Saved graphics backend** and
offers **Automatic graphics** and **Use Metal 3**.

- **Automatic (Apple default):** Gamekit leaves `D3DM_MTL4` unset. On the
  validated macOS 27 host, Apple's documented D3D12 default is Metal 4.
- **Metal 3 compatibility:** Gamekit explicitly supplies `D3DM_MTL4=0`.

This is a **managed Steam-environment setting**, affecting Steam and every game
started by that Steam client. It is not a per-game override. Per-game controls
are backlog `gamekit-tmx`; they must account for Steam's inherited environment.

Save/exit games, **Stop Windows Steam**, select the backend, then launch Steam
or a game tile. Backend controls are disabled during a recorded session or a
busy app operation. Backend APIs independently enforce installation/execution
leases and complete idle process observations. There is no automatic shutdown
or live reconfiguration of a running game.

The saved choice survives Gamekit Quit/reopen and is reapplied to new Steam
sessions. Existing Steam keeps the environment it started with, so merely
reopening Gamekit is not a backend change. The UI deliberately labels the
preference **saved**, rather than claiming it is the mode of a pre-existing
diagnostic or legacy session.

Rollback uses the same stopped-session flow: choose **Automatic graphics**.
Selecting another runtime revision or custom runtime path preserves the saved
backend unless the caller explicitly supplies a different one.

## Persistence and compatibility

`Metadata/RuntimeSelection.json` schema 3 records `graphicsBackend` as either
`automatic` or `metal3`, alongside the existing optional bundle and runtime
revision. Schemas 1 and 2 retain their previous runtime selection and default
to automatic graphics. Missing settings also retain the original automatic
behavior. Unknown backends, incomplete schema-3 records, and backend fields in
older schemas are rejected rather than silently downgraded.
Older Gamekit builds cannot read schema 3; use the current app for both backend
choices, including rollback to automatic graphics.

Backend-only updates acquire the installation lease before reading the current
selection, then reuse the runtime-selection process/execution gates and atomic
metadata write. They preserve the custom bundle/default-path choice, component
revision, environment records and prefix contents. The per-game
`CaptureDisplaysForFullscreen=y` cursor fix is not rewritten by this operation.

The environment allowlist discards inherited `D3DM_MTL4` values. Only the explicit
selected backend supplies the flag. Both modes retain AVX advertisement and
the native Visual C++ DLL preference.

Backend changes do not change Wine/PE binary identity, so existing
revision-specific launcher caches and their shared PE mappings remain valid.
The app's cached lifecycle controller is refreshed when backend, bundle or
component revision changes; otherwise a same-path backend change could launch
using a stale controller. Game-launch/acceptance helpers also preserve the
selected backend when adding an identity helper or relocating their data root.

## Verification

Unit coverage includes persisted selection and rollback, preserving prefix
data and records, legacy schema behavior, invalid settings, and rejection
during installation/execution leases or recorded sessions. UI coverage exercises
selection, app restart, reverting to automatic and disabled controls for a
recorded session.

The opt-in verification helper only **inspects** an already app-launched
session; it does not inject the flag or start Steam. After launching from the
packaged app:

```bash
GAMEKIT_VERIFY_SAVED_BACKEND=1 GAMEKIT_EXPECT_BACKEND=metal3 \
  swift test --filter HelldiversGraphicsBackendTests.inspectSavedBackend
```

It verifies the saved setting and the actual native Steam and Helldivers process
environments. `GAMEKIT_VERIFY_STEAM_ONLY=1` permits checking a Steam-only launch;
`GAMEKIT_EXPECT_BACKEND=automatic` checks that the override is absent.

Packaged-app restart, rollback and game regression results are recorded after
candidate verification. This delivery does not add a measured FPS or full
mission-performance claim to the existing user acceptance.
