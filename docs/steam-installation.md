# Managed Steam installation

E4.2 (`gamekit-ftm.2`) implements a fresh-install coordinator and a native setup
control. Recipe **1** reproduces the E2 baseline using the existing pinned
Sikarugir 10.0 revision 6 / Template 1.0.11 / D3DMetal 4.0b2 runtime.

## Setup flow

1. Open Gamekit and click **Install Steam**. Prerequisites must pass before setup
   registers a new environment or downloads an installer.
2. Gamekit downloads and validates the official installer, creates a fresh prefix,
   and runs `cmd /c ver` through the selected Wine runtime to initialize it.
3. Complete the normal Steam installer wizard. Keep its default destination and
   **uncheck Run Steam before Finish**, as in the accepted E2 recipe.
4. Gamekit closes the installer's owned Wine session and launches the installed
   Steam executable separately. Allow Steam to download updates and restart itself.
5. **Keep Steam open.** When Steam shows a usable sign-in or Library window, click
   **Steam UI is usable — finish setup** in Gamekit. A process appearing in an inventory is not enough
   to prove this visual acceptance criterion.
6. Gamekit rechecks the managed processes and executable, closes this setup's Steam
   session, then marks the environment installed. Ongoing launch/stop controls are
   the next lifecycle task, E4.3.

The native control uses environment ID `steam`, at
`~/Library/Application Support/Gamekit/Environments/steam`. Existing manual
`steam-eval-a` and `steam-eval-b` prefixes are not adopted. Repeating setup for a
successfully installed recipe-1 record verifies its file facts and returns that
record without downloading, launching an installer, or creating another prefix.

**Cancel installation** waits for scoped cleanup, then records the interrupted
stage. A failed or interrupted prefix is preserved. Setup refuses to recreate or
silently resume it. **Retry Steam verification** explicitly relaunches only the
bootstrap/UI check for a recipe-1 environment with intact Steam files and a saved
bootstrap failure or interrupted bootstrap/validation stage. It never reruns the
installer or creates a prefix. [Recovery](steam-recovery.md) adds stage-aware retry
and separate confirmed preserving/clean resets. Preserved libraries return only
after installer success, so Valve sees an empty installation destination.

## Core API

```swift
let store = try EnvironmentStore()
let coordinator = SteamInstallationCoordinator(
    store: store,
    layout: RuntimeLayout(dataRoot: store.root),
    acquisition: try SteamInstallerAcquisition(root: store.root),
    diagnostics: try DiagnosticStore()
)
let installed = try await coordinator.install(
    onStage: { stage in /* update progress UI */ },
    confirmUsableUI: { /* await the user's visual confirmation */ false }
)
```

The confirmation callback must cooperate with task cancellation. Setup bounds
prefix initialization to three minutes, the interactive installer to twenty
minutes, and bootstrap plus visual confirmation to twenty minutes. Expiration or
cancellation triggers cleanup restricted to the current session's prefix/tag.
Keep the coordinator alive while setup is running, including after any cleanup
refusal that retains ownership.

`verifyExistingInstallation(onStage:confirmUsableUI:)` exposes the narrowly scoped
verification retry. It uses the same prerequisites, ownership, process checks and
confirmation contract; unsupported states return `recoveryRequired`.

`resumeInstaller` is the recovery path for a saved partial prefix without a Steam
executable. It reruns initialization and the installer in that same prefix, with
no reset. A record explicitly prepared as `notStarted` with no prefix can use
`install` again; pending reset journals must first be completed through recovery.

Recipe 1 uses the runtime layout's explicit `WINEPREFIX`, `WINEARCH=win64`,
`WINEDEBUG=-all`, and validated packaged library/framework paths. It adds no DLL,
registry, MetalFX, MSync/ESync or AVX overrides. Wine is invoked with literal argv;
the installer is interactive, not an unverified silent-install variant.

## Persistence and ownership

`EnvironmentRecord` keeps schema version 1 and adds an optional
`installationRecipeVersion`. Older records without this field still decode; the
new coordinator does not silently adopt them as completed recipe-1 installations.
Installer provenance comes from the acquisition API and is saved before prefix
creation.

Durable stages are saved before their corresponding work:

```text
downloadingInstaller → creatingPrefix → runningInstaller
    → bootstrappingSteam → validatingInstallation → installed
```

A global installation lease in the metadata directory prevents competing
coordinators, including different store instances, from installing concurrently.
It also prevents an idle scan from persisting a false interruption between command
sessions and prevents runtime/recipe/executable selection changes during setup.
Per-prefix execution leases continue to protect each runtime session.

Prefix creation uses exclusive descriptor-relative `mkdirat`, after checking the
registered record and revision under the metadata writer lock. Existing directories
are refused rather than reused. No failure path deletes or resets a prefix.

For initialization and installer commands, the coordinator observes leader exit
independently of inherited output pipes, then stops the owned session. For Steam
bootstrap, it follows fresh scoped inventories through empty/incomplete updater
handoff gaps; the original launcher exiting is not installation success. The final
installed state requires user confirmation, fresh Steam/process and executable
facts, successful scoped cleanup, and a successful metadata write.

Cleanup uses the validated per-prefix Wine server protocol and ownership checks.
It never kills processes globally by name. If cleanup is refused, setup preserves
its in-progress metadata and keeps its process handle and installation lease.
It does not manufacture an idle or successfully installed state to hide the error.

## Diagnostics

The coordinator records download, installation, bootstrap and rendering-validation
stages through `DiagnosticStore`, with bounded runtime output. Logging failures are
reported separately from installation results. Raw local output remains excluded
from exports; environment metadata stores progress and provenance, not log text.

## Verification

Isolated core tests exercise successful stage progression, repeat-install behavior,
preexisting-prefix preservation, installer failure, declined confirmation,
same-instance/cross-instance ownership, cancellation, blocked idle reconciliation,
selection-change rejection, updater handoff gaps, cleanup refusal and diagnostic
stage records. OS process ownership and literal-argv behavior remain covered by
the existing runtime-session and process-executor suites.

For an explicitly requested real setup, a Debug build accepts `--install-steam`
to start the same native flow automatically, or `--verify-steam` to retry eligible
verification. The normal UI tests never pass those
flag, download Steam, or write to real environments. A real setup still requires
the installer wizard and visual confirmation; automated process observations do
not replace that evidence.

### Recorded live verification

On the target M4 Pro, macOS 27.0 (26A428), Xcode 27.0 (27A266a), recipe 1 created
the fresh `steam` environment, ran the normal installer and reached the current
Windows Steam UI. The installed win64 manifest is **1788652215**. Installer
SHA-256 is `7d3654531c32d941b8cae81c4137fc542172bfa9635f169cb392f245a0a12bcb`.

Initial confirmation attempts exposed an observer defect: Wine rewrites its argv
area and leaves NUL padding before intact environment strings. The old parser
stopped at the first empty slot and lost `WINEPREFIX` and the session tag. A
live scoped inspection confirmed both keys remained in the kernel buffer. A new
padding regression failed before the parser fix and passed afterward; the fixed
observer saw the Steam client, helpers and services with their correct tags.
The ownership policy was not relaxed.

The same prefix was preserved throughout. Explicit verification retry with the
fixed build succeeded; the user confirmed a usable Steam UI, Gamekit closed its
session, and metadata reached `installed` at revision 17. The live verification
test then confirmed complete/empty process observations and an unchanged record
on repeat installation:

```bash
GAMEKIT_INSTALLATION_VERIFY=1 swift test --filter verifyManagedInstallation
```

This opt-in test requires an already completed `steam` installation; it does not
create one or auto-confirm a UI. A separate read-only inspection is available with
`GAMEKIT_INSTALLATION_INSPECT=1 swift test --filter inspectManagedInstallation`.
It reports typed state/process facts without dumping arguments or environment
values. Normal CI skips these host-specific tests.
