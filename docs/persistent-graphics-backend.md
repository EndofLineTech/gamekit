# Persistent graphics backend

`gamekit-s8v` makes the accepted Helldivers Metal 3 choice available through
normal Gamekit launches. It uses the existing Wine 10/text-input-1 runtime and
unchanged D3DMetal 4.0b2 payload.

## User controls and scope

In **Setup and prerequisites**, Gamekit displays **Saved graphics backend** and
offers a dropdown with **Automatic (Apple default)** and **Metal 3 compatibility**.
Each game's gear panel offers a separate override with **Use shared default**.
**DXVK (In Dev)** and **DXMT (In Dev)** are listed but disabled until implemented.

- **Automatic (Apple default):** Gamekit leaves `D3DM_MTL4` unset. On the
  validated macOS 27 host, Apple's documented D3D12 default is Metal 4.
- **Metal 3 compatibility:** Gamekit explicitly supplies `D3DM_MTL4=0`.

This is the **managed Steam-environment default**, affecting Steam and games
that inherit it. [Per-game overrides](per-game-graphics-backends.md), delivered
in `gamekit-aty`, explicitly replace or clear that inherited choice in the
matching game process before graphics initialization.

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

Rollback uses the same stopped-session flow: choose **Automatic (Apple default)**.
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

The launch environment allowlist discards inherited `D3DM_MTL4` values. The
selected shared backend supplies Steam's flag; the owned-process helper applies
the corresponding per-game override. Both modes retain AVX advertisement and
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

## Packaged-app acceptance, September 18, 2026

Accepted local candidate:
`.build/packages/Gamekit-20260918T014731Z/Gamekit.app`, built from clean source
`d99c4e5bb75916b13fe6b9f2191ab080ef3d8bb4`.

- App executable SHA-256:
  `cea0cd24eceaee52a2b70b71684d234b43e37ed9d8bef140d88dd76c2c420672`.
- Source-tree fingerprint:
  `ca92e73330e7f7826970e3aa703c2efaaafc6870f15a9ce2a1d34d8e6735755d`.
- Embedded Intel identity helper:
  `5a4c55c7151bd97345289d0388b998286c182d072a9b9407a9d627bea082a797`.

Actual native accessibility controls selected Metal 3, quit/reopened the app,
and launched Helldivers from its game tile. The saved-backend UI restored Metal
3. Read-only process inspection verified `D3DM_MTL4=0` in both the new Steam
client and Helldivers. Backend controls were confirmed disabled while the
session was running. The user then reported: **"Works great - just tested.
Whatever changes you made still persist."**

After stopping that session, a fresh Steam-only launch again inherited the saved
Metal 3 flag with a new PID. Through the UI, stopping Steam and selecting
Automatic then produced another new Steam process with the override absent.
Metal 3 was reselected afterward. This also exercises same-bundle controller
refresh rather than only a runtime-path change.

Regression checks with the saved Metal 3 selection:

- Satisfactory tile, visible Dock identity, normal Gamekit Quit/game survival,
  ordinary reopen, Show Steam and Stop passed.
- The separate Satisfactory shipping-process/Dock check passed on a fresh repeat.
  Its first run reached the game/Dock checks but cleanup reported
  `observationUnavailable`; an immediate scoped stop-only check reported
  `alreadyStopped`. Follow-up `gamekit-idr` tracks that transient observation
  failure without weakening ownership checks.
- Stardew launched through the actual app tile and rendered New/Load/Co-op/Exit,
  then stopped gracefully. No save was opened.
- Registry readback still reports Helldivers fullscreen display capture enabled
  and the experimental cursor-confinement override absent.

Final local selection is schema 3, `text-input-1`, `metal3`. All test sessions
are stopped. Private captures are under `.build/persistent-metal-helldivers-1/`
and `.build/persistent-metal-stardew-1/`.

Local `make check` passed 192 reported Swift tests in 32 suites, 23 Python tests
(one opt-in skip), and the native build. The first hosted UI run exposed a test
assertion using macOS static-text `label` instead of `value`; its underlying
saved-setting assertion passed. The UI assertions were corrected to use the
actual accessibility value, matching the successful local AX checks.

This delivery does not add a measured FPS or full mission-performance claim to
the existing user acceptance.
