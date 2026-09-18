# Transient process observations during Stop

Issue: `gamekit-idr`.

## Evidence and scope

During earlier Satisfactory validation, scoped cleanup reported
`SteamLifecycleError.observationUnavailable`. An immediate Stop retry returned
`alreadyStopped`; a subsequent game run cleaned up gracefully. The original
inventory did not record which kernel check failed, so its exact cause is unknown.

The observer reads a process identity, reads its scoped arguments, then checks its
identity again. An exit or identity change during the second check can make that
inventory incomplete. Permissions or other inspection failures can also do so.
Previously every incomplete inventory made Stop fail immediately, even after a
successful graceful shutdown request. Deterministic driver tests reproduce that
control-flow failure before shutdown and after the process exits.

## Behavior

Stop now has a shared budget of **three additional observations**, waiting 100 ms
before each retry. The budget covers the whole operation, including preflight,
graceful exit, server shutdown and final identity-checked signalling. It does not
restart the entire shutdown or reset the budget at each stage.

- Only an incomplete inventory consumes the retry budget.
- Every attempt checks cancellation and revalidates the pinned prefix before and
  after observation.
- A foreign or untagged process in even a partial inventory fails immediately.
- Shutdown commands and signals still require a fresh, complete, owned inventory.
- Observation gaps restart quiet-period tracking rather than counting unknown
  time as evidence of inactivity.
- Exhaustion preserves the launch receipt and reports `observationUnavailable`;
  it does not authorize escalation or pretend Steam has stopped.
- Receiptless Stop can retry inspection but cannot adopt or terminate processes.

The low-level observer and launch/show behavior retain their existing semantics.
Retries tolerate short-lived uncertainty; they do not diagnose its cause or treat
an unreadable process as absent.

## Verification

Deterministic tests cover transient and persistent gaps before/after graceful
shutdown, the operation-wide budget, foreign processes in partial inventories,
idle-confirmation gaps, receiptless Stop, cancellation, and prefix replacement
during observation. Existing graceful, forced and orphan-signalling tests remain
in the lifecycle suite.

On the development Mac, three real Steam launch/controller-reopen/Stop cycles
passed using the saved text-input runtime and Metal 3 selection: two graceful,
one forced, all finally stopped. The bounded Satisfactory shipping-process/Dock
check also passed and cleaned up gracefully. These runs validate the real control
path; they do not prove the intermittent original race occurred during the runs.
No game save was opened for this validation.

Commands:

```sh
swift test --filter SteamLifecycleTests
GAMEKIT_LIFECYCLE_SMOKE=1 swift test --filter SteamLifecycleTests.liveSteamLifecycle
GAMEKIT_SATISFACTORY_DOCK_ACCEPTANCE=1 \
  GAMEKIT_IDENTITY_X86_HELPER=/path/to/Gamekit.app/Contents/Frameworks/WineGameIdentity.dylib \
  swift test --filter GameDockAcceptanceTests.satisfactory
```

The opt-in lifecycle smoke refuses an already-running managed session and closes
the sessions it starts. The Satisfactory acceptance requires an explicitly
authorized fresh managed session; it closes the game after the check.
