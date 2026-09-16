# Managed Steam lifecycle

E4.3 (`gamekit-ftm.3`) adds Launch/Stop controls for the installed recipe-1 Steam
environment. The lifecycle card refreshes live status every second. Quitting
Gamekit leaves Windows Steam running; reopening Gamekit restores observation and
control without launching another Steam instance.

A persistent launch receipt also pins runtime/recipe/executable selection after
the launching controller releases its operation lease. Complete scoped Stop to
clear the receipt before changing that selection, even if Steam exited manually.

## Ownership and restart

`SteamLifecycle` persists a private schema-1 launch receipt under
`Metadata/Lifecycle/<environment-id>.json`. It records a random session UUID, the
prefix's device/inode identity and the selected runtime, not a PID. The receipt is
published before launch, and the UUID becomes `GAMEKIT_SESSION_ID` in the validated
Wine environment.

On every control operation the controller acquires the whole-install and prefix
execution leases. It checks installed metadata, runtime readiness, prefix identity
and complete scoped process observations. Only processes carrying the receipt's
exact tag may be controlled. Foreign tags, unreadable inventories, corrupt receipts
or replaced prefixes cause refusal. No process-name kill or PID restoration is used.
This remains cooperative same-user ownership, not a security sandbox.

Repeated Launch requests return the current running/starting state. Short empty
updater handoff gaps retain ownership and suppress a duplicate launch; five seconds
of observed emptiness are required before a prior receipt is treated as stopped.
Unknown inventory results remain `unverified`, never inferred idle.

Persistent launches have no setup deadline. Their stdin/stdout/stderr go to
`/dev/null` so closing Gamekit does not close an output pipe needed by Steam.
`ProcessExecutor` still observes/reaps its initial child while Gamekit is alive.
Lifecycle operation summaries are recorded by the UI; continuous Wine stdout is
not captured for these detached-lifetime launches. Steam's own logs remain private
inside the prefix. One-shot commands and installation sessions retain bounded
capture as before.

## Stop policy

The user selected automatic bounded fallback:

1. Revalidate the runtime, pinned prefix and ownership.
2. Run the installed Steam executable with `-shutdown` in the same tagged prefix.
3. Allow up to **30 seconds** for graceful shutdown; continue scoped observation.
4. If owned processes remain, use that runtime's `wineserver -k` with the exact
   prefix and packaged dependency environment.
5. Verify quiescence before removing the launch receipt and reporting stopped.

The UI explains the forced fallback before use. Stop affects the entire managed
Wine environment, including games running in it. Unrelated macOS Steam and other
prefixes are not selected. A successful graceful client exit can still require
the timed fallback to stop lingering Wine services.

```swift
let store = try EnvironmentStore()
let steam = SteamLifecycle(store: store, layout: RuntimeLayout(dataRoot: store.root))
let state = try await steam.launch()
let current = try await steam.status()
let result = try await steam.stop() // alreadyStopped, graceful, or forced
```

## Verification

Core tests cover duplicate requests, controller replacement, graceful and forced
stop, foreign activity refusal, receipt/prefix identity mismatch, handoff gaps and
discarded-output semantics. Normal CI uses isolated fixtures and skips live tests.

On the validated M4 Pro/macOS 27/Xcode 27 host:

- Three real launch/stop/relaunch cycles passed. Each used a new controller before
  Stop to verify persistent ownership; each ended completely stopped. Wine cleanup
  used the configured timed fallback.
- A native UI test launched Steam, terminated Gamekit, reopened Gamekit without a
  launch flag, observed Steam running with an unchanged receipt, and stopped Steam
  through the UI. All five UI tests passed with the live opt-in enabled.
- The XCTest UI runner cannot reliably inspect other processes' kernel arguments
  in its own execution context. The restart test verifies observations in the
  reopened Gamekit app, not by weakening unknown-state handling in the core.

```bash
GAMEKIT_LIFECYCLE_SMOKE=1 swift test --filter liveSteamLifecycle
TEST_RUNNER_GAMEKIT_LIFECYCLE_UI_SMOKE=1 \
TEST_RUNNER_GAMEKIT_LIFECYCLE_ROOT="$HOME/Library/Application Support/Gamekit" \
make ui-test
```

Both commands require an already installed managed `steam` environment and perform
real launches/stops. The UI test uses temporary diagnostic storage. Login, Steam
Guard, game behavior and host-reboot acceptance are separate from these unattended
lifecycle checks. A Debug build's `--launch-steam` flag starts the same normal
lifecycle action; ordinary UI tests do not enable it.
