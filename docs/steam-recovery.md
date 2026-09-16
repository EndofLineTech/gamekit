# Interrupted setup and download-preserving reset

E4.4 (`gamekit-ftm.4`) adds explicit recovery controls. It implements the selected
policy: **preserve downloaded games**, including when resetting the Windows
environment. Recovery never resets an unregistered prefix automatically.

## Which action to use

| Situation | Action |
|---|---|
| Download failed before a prefix was created | **Retry interrupted install** starts a fresh bounded download |
| Prefix initialization or the installer was interrupted, with no Steam executable | Retry reuses the prefix, reruns baseline initialization, downloads a validated installer and opens its wizard |
| Steam files exist but bootstrap/UI verification was interrupted | Retry relaunches Steam for explicit UI verification |
| A reset was interrupted | Retry completes its journal before starting the appropriate install step |
| An interrupted setup left Wine processes running after Gamekit exited | **Force-stop interrupted setup…**, confirm, then Retry |
| The existing prefix needs replacement | **Reset, preserve downloads…**, confirm, then Retry |
| Steam is already installed and running | Use the ordinary **Stop Windows Steam** lifecycle control first |

Keep Steam open when confirming usable UI. Normal setup still uses the interactive
installer wizard; recovery does not silently accept dialogs or authenticate Steam.

## Reset semantics

Reset requires an explicit confirmation naming the managed `steam` environment.
It does not delete the old prefix. Instead it:

1. Acquires whole-install and prefix execution leases and requires complete,
   repeatedly idle process observations.
2. Saves a reset journal and the original environment record.
3. Atomically moves the old prefix into a private recovery archive on the same
   filesystem, then marks the registered environment ready for fresh setup.
4. During the next setup, initializes a fresh Wine prefix and restores the old
   `steamapps` and `depotcache` directories **before running the installer**.

This preserves downloaded game payloads, app manifests, workshop/download data
inside `steamapps`, and depot download caches. It does not copy game content: the
directories move, preserving their filesystem identity and bytes. External game
libraries are not traversed or removed; Steam's restored library metadata can
reference them, subject to the new environment's drive mappings.

The old registry, client files, settings, sign-in data and saves outside these two
library directories remain in the private archive and are not reused by fresh
setup. Reset therefore **does not erase archived credentials**. Diagnostics stay
in their separate log directory. Steam may verify rediscovered game files or need
normal updates after restoration; byte preservation is not a promise that Valve
will never request additional downloads.

Archives are retained rather than automatically deleted. They consume storage for
the old Windows/client files, but restored game directories are moved out of them.
The ordinary prerequisite disk check applies before reinstalling. Archive cleanup
is a separate explicit storage-management concern; do not remove an archive while
its recovery journal is pending.

## Journal and restart safety

```text
Metadata/Recovery/<environment-id>.json
Recovery/<environment-id>/<reset-uuid>/original-record.json
Recovery/<environment-id>/<reset-uuid>/prefix/
```

The schema-1 journal records the original metadata, reset timestamp, old prefix
identity, preserved library identities, replacement prefix identity and phase:
`prepared`, `ready`, `restoring`, or `restored`.

All traversed components reject symlink redirection. Directory moves are
descriptor-relative and no-clobber. A colliding destination, changed identity,
corrupt journal or unexpected metadata revision causes refusal while preserving
both sides. A symlinked `steamapps`/`depotcache` root is refused rather than treated
as app-owned data; links inside a preserved library move with the directory.

Replay checks whether each move already happened by its saved directory identity.
A crash after archiving the prefix, after saving reset metadata, or after moving
one library can resume without duplicating or overwriting game data. Ordinary
Install is blocked while a reset still needs journal completion: use Retry first.
Reset critical steps are journaled forward recovery, not an implicit rollback.
The filesystem and same-user cooperative ownership limitations of the metadata
store still apply; this is not a sandbox or a full power-loss durability claim.

## Stopping an interrupted setup

This is a separate, explicitly confirmed force-stop for unfinished installation,
not the normal installed-Steam Stop policy. It requires registered recipe-1
metadata, the selected validated runtime, a pinned prefix, a complete inventory
and one consistent UUID session tag. Untagged, mixed or unreadable activity is
refused. Cleanup uses that prefix's Wine server protocol and then verifies
quiescence; no global process-name or PID sweep is performed.

The action can restore cancellation control after the original Gamekit process
has exited. It cannot break an execution/installation lease held by another live
controller. An installed environment uses E4.3's normal graceful/30-second-fallback
Stop instead. Recovery refuses uncertainty rather than deleting data to clear an
error.

## API

```swift
let store = try EnvironmentStore()
let recovery = SteamRecovery(store: store, layout: RuntimeLayout(dataRoot: store.root))
let action = try await recovery.prepareRetry()
// Dispatch install / resumeInstaller / verifyExistingInstallation on the setup
// coordinator, or report alreadyInstalled. Each reacquires ownership and checks state.

// Only after the corresponding UI confirmation:
let reset = try await recovery.resetPreservingDownloads(confirmed: true)
try await recovery.stopInterruptedSetup(confirmed: true)
```

These are alternative operations, not a required sequence. `resumeInstaller` never
creates or resets an existing prefix. The setup coordinator restores preserved
libraries before installer execution and records its normal durable stages.

## Verification

Automated fixtures cover every interrupted installation stage, explicit
confirmation, active/uncertain-process refusal, concurrent ownership, corrupt
journals, symlink roots, destination collisions, reset/reinstall integration and
replay after journal, archive, metadata and library-move checkpoints. Tests assert
game bytes and unrelated environments remain unchanged.

The opt-in real-runtime test initializes a disposable Wine prefix with synthetic
game/depot files, stops it, archives it, initializes a new prefix, and restores the
downloads. It passed on the validated macOS 27 host: the new prefix identity differs
and both game/depot byte sequences are unchanged. It does not reset the user's
installed Steam environment or download games.

```bash
GAMEKIT_RECOVERY_SMOKE=1 swift test --filter liveRecovery
```

Local UI testing became unavailable after the desktop locked: XCTest reported
“System authentication is running.” The native reset-confirmation and Cancel test
is included in hosted CI. A user walkthrough of the new recovery controls remains useful
for E5 acceptance, especially rediscovery of a real game library after reset.
