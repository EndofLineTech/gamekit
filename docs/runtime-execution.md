# Runtime detection and process execution

E3.3 (`gamekit-m19.3`) connects the E3.2 state contract to real host/runtime
checks and scoped macOS process observations. It also supplies asynchronous
command execution and exclusive Wine-operation sessions for the installer and
launcher work that follows.

## Runtime checks

`RuntimeLayout` resolves the approved Sikarugir 10.0 revision 6 / Template 1.0.11
layout beneath the configured Gamekit data root. `RuntimeProfile.sikarugir` is
the supported catalog entry, with the identity and critical-file hashes from the
[validated runtime recipe](runtime-revision.md).

`RuntimeDetector.detect` checks:

- Apple-silicon host identity and macOS major version 27 using the existing policy;
- actual Intel execution via `/usr/bin/arch -x86_64 /usr/bin/uname -m`;
- available volume capacity against the **15 GiB working allowance**;
- selected runtime identity, contained paths, critical hashes and executable access;
- required packaged dependency files, including GStreamer, FreeType, GnuTLS, SDL
  and libinotify;
- the runtime's actual `wine --version` output;
- Apple 4.0b2 framework/source-version metadata, graphics bridge/DLL hashes, and
  `codesign --verify --deep --strict` for the framework.

The app root and path to the runtime bundle reject symlink redirection. Legitimate
framework-internal symlinks are allowed only when they resolve within the bundle.
These are critical-file/dependency checks, not a fresh audit of every byte of the
distribution. The engine archive's published digest and extracted wine/wineserver
hashes were cross-checked when establishing the profile.

Checks distinguish passed, failed and unknown. Missing capacity/unsupported
execution conditions do not silently become ready. Wine execution is skipped on
an unsupported host or when Intel execution is unavailable; matched files alone
then do not count as a successful execution probe. Failed/cancelled checks never
install Rosetta, runtimes or dependencies.

## Command execution

`ProcessExecutor` uses a small native C bridge for `posix_spawn`, process groups,
exit observation and macOS process inventory. It does not build shell command
strings. Executable, argument vector, environment and working directory are
separate inputs; embedded NULs and invalid requests are rejected.

```swift
let result = try await ProcessExecutor().run(CommandRequest(
    executable: URL(fileURLWithPath: "/usr/bin/arch"),
    arguments: ["-x86_64", "/usr/bin/uname", "-m"],
    timeout: 10,
    outputLimit: 4096
))
// Check result.termination, not stdout text alone.
```

- Each launched command gets its own POSIX process group before exec.
- Stdout/stderr are drained concurrently using dispatch read sources.
- Retained result buffers are bounded independently; total byte counts and
  truncation/incomplete-output flags remain available.
- An optional callback receives each data chunk as it is read. It runs on the
  command's private serial queue and must return promptly. E3.4's
  [diagnostic recorder](local-diagnostics.md) captures bounded data there and writes
  checkpoints separately; export uses a distinct allowlisted summary.
- Nonzero exit and signal termination are results, while invalid/spawn failures
  throw typed errors.
- One-shot `run` handles task cancellation. An already-cancelled task can throw
  before launch; cancellation after launch returns a cancelled result after cleanup.
- Timeout/cancellation sends TERM to the owned group, then KILL after the bounded
  grace period. It never performs a global kill by process name.
- The leader remains unreaped until signalling and output cleanup finish, so a
  recycled PID/group ID cannot be signalled by a late timer.

Three completion boundaries are explicit:

1. `RunningCommand.leaderExit()` reports the original process's OS exit, without
   waiting for inherited pipe writers or treating an updater handoff as completion.
2. `RunningCommand.result()` includes pipe draining and bounded output. For a
   one-shot command, a child retaining inherited pipes remains covered by timeout.
3. `RuntimeSession.waitUntilStopped()` follows the complete scoped environment,
   including tagged detached children, rather than ending with the launcher.

`ProcessExecutor.start` transfers lifetime responsibility to the returned handle;
use `run` for bounded one-shot checks. Managed Wine launches use `RuntimeSession`
so a detached wineserver is not mistaken for a member of the original POSIX group.

## Environment and ownership

The Wine environment carries only an allowlist of ordinary host values, plus
explicit `WINEPREFIX`, `WINEARCH=win64`, `WINEDEBUG=-all`, the validated library /
framework fallback paths, and a fresh `GAMEKIT_SESSION_ID` for managed operations.
Inherited API credentials and conflicting Wine/DYLD/renderer controls are not
forwarded. Optional MetalFX, MSync/ESync and AVX controls remain unset.

`RuntimeProcessObserver` enumerates the current user's processes, filters by the
selected runtime/prefix executable paths, and reads kernel arguments only for
those candidates. It retains the prefix and operation tag, not unrelated
environment keys. No raw argument/environment dump is published or persisted.

The argument parser skips NUL padding before environment entries. Live E4.2
verification found that Wine's process-title rewriting leaves such gaps; treating
the first empty slot as the end loses otherwise intact prefix/session ownership.

Identity includes PID and start timestamp, with a second identity/path check after
reading arguments. Prefix matching uses path-component boundaries, not substring
matching. Executable-role classification uses the actual target argument: a later
argument merely mentioning `Steam.exe` is not a Steam process. Known Steam/CEF
targets are distinguished from installers, services and unknown work.

Incomplete inventories and service-only handoff gaps remain `notChecked`, not
`idle`. A saved installation cannot be interrupted just because its initial
launcher disappeared while Wine services or unknown work remain. Fresh scans
can identify a registered environment after an app restart without restoring PIDs.

## Exclusive sessions and cleanup

`RuntimeSession.start` requires an already registered, existing, path-checked
prefix, the matching validated runtime, and a complete empty-prefix process scan.
The [installation coordinator](steam-installation.md) performs exclusive prefix
creation. An execution
lease prevents duplicate operations and pins the directory identity. Runtime or
Steam-executable selection changes are rejected while that lease is active.

```swift
let session = try await RuntimeSession.start(
    store: store, id: record.id, layout: layout,
    arguments: [steamExecutable.path],
    workingDirectory: steamExecutable.deletingLastPathComponent(),
    timeout: 1200
)
let lifecycle = try await session.waitUntilStopped()
let output = await session.command.result()
// Lifecycle completion means quiescence; inspect the command result and the
// installer/Steam-specific evidence before marking an operation successful.
```

The caller owns the session: wait, stop or cancel it. The timeout defaults to
60 seconds (configurable up to one day); it is an operation deadline, not a Steam
UI idle timer. `stop()` and `cancel()` use the selected Wine server's `-k` protocol
with the exact prefix and dependency environment, then finish the original owned
command's cleanup. Cancellation of `waitUntilStopped` awaits this cleanup before
throwing `CancellationError`.

Before prefix-wide cleanup, the directory identity must still match and every
observed process must carry this session's tag. Foreign activity or uncertain
ownership causes refusal, not a best-effort PID sweep. Cleanup failures are
exposed for recovery; a replacement prefix is not killed to hide an error.
Sessions discovered after an app restart are observable, but are not silently
adopted as cancellable sessions. Explicit recovery policy belongs to the later
installer/lifecycle work.

This is cooperative ownership of one managed prefix, not a security sandbox.
Another process with the same user's privileges can deliberately ignore locks
or mutate the namespace. The prefix stop is environment-wide: it is not a
selective “kill just Steam but leave another app in the same prefix” API.

## Reconciliation and UI

The startup/Reload summary shows the real prerequisite report. Registered records
with the selected runtime use fresh process inventories and file inspection.
Unselected/unsupported runtime identities remain unverified. No Steam launch or
installer action is attached to the summary UI in this milestone.

Async callers pass `expectedRevision` into the store's reconciliation method. A
changed revision rejects stale observations. Persisting an interruption also
requires an available execution lease, closing the race where an idle scan was
taken just before a new operation began.

## Verification

Normal CI uses isolated fixtures and does not install Wine or inspect authenticated
Steam data. Tests cover literal arguments/paths, missing executables, nonzero
exits, concurrent pipe draining, output bounds, timeout escalation, cancellation,
leader/pipe completion races, unsafe runtime paths, version/digest mismatches,
host/Rosetta/disk readiness, PID identity, environment filtering, detached-child
handoffs, cooperative prefix cleanup, unrelated-prefix preservation, foreign
activity refusal, prefix replacement and stale reconciliation.

The opt-in installed-runtime test runs only when requested:

```bash
GAMEKIT_RUNTIME_SMOKE=1 swift test --filter installedRuntime
```

It validates the actual pinned installation, registers a fresh temporary metadata
root/prefix, launches Windows `cmd` through the Swift session API, observes its
tagged Wine processes, and verifies the prefix is empty of live processes after
scoped stop before removing the fixture. This passed on the target M4 Pro/macOS
27 host. It does not sign into Steam, use the E2 prefixes, or claim new game or
rendering compatibility. The normal test suite reports this opt-in case as skipped.
