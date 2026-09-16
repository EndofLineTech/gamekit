# Environment metadata and restart reconciliation

E3.2 (`gamekit-m19.2`) adds the core record model, atomic storage and reconciliation
contract. The app reads registered records on startup and on Reload. E3.3 now
supplies [scoped runtime/process detection](runtime-execution.md). Unknown or
unsupported observations still say **Not checked**, rather than inferring readiness
from saved data.

## Storage layout and ownership

Default root: `~/Library/Application Support/Gamekit/`.

```text
Metadata/Environments/<environment-id>.json   # one versioned record
Metadata/Environments/.write.lock             # cooperative writer lock
Metadata/Environments/.<uuid>.tmp             # in-flight/orphan writes
Environments/<environment-id>/               # derived Wine prefix location
```

The store creates only the app root and metadata directories when explicitly
creating a record. Loading an absent catalog returns an empty array without
creating directories. Prefix paths are derived from validated IDs; display names
are never used as filesystem names. The Steam executable is a validated relative
path, defaulting to `drive_c/Program Files (x86)/Steam/Steam.exe`.

There is no prefix creation, deletion, reset or automatic adoption in this API.
Registering an ID whose prefix already exists fails with `prefixAlreadyExists`.
The manually evaluated `steam-eval-a`/`steam-eval-b` prefixes therefore do not
silently become app-owned records. Beads, runtimes and other Gamekit siblings are
not storage targets of this component.

## Record and encoding

`EnvironmentRecord` schema version **1** contains:

| Field | Meaning |
|---|---|
| `id` | Canonical lowercase single-component key: letters/digits, then letters/digits/underscore/hyphen; at most 64 characters |
| `name` | Human-readable name, independent of paths |
| `runtime` | Optional provider, distribution, Wine and graphics version identity |
| `installer` | Optional original HTTPS source URL, lowercase 64-character SHA-256, download timestamp |
| `steamExecutable` | POSIX-relative path within the derived prefix, beneath `drive_c` and ending in `.exe` |
| `installation` | Durable progress or recorded failure/interruption |
| `createdAt`, `updatedAt` | Milliseconds since Unix epoch in the JSON document |
| `revision` | Optimistic-concurrency revision, incremented by the store |

Use `EnvironmentDocument.encode/decode`, which define the timestamp format and
validate records on both boundaries. Unknown schema versions, malformed data,
invalid IDs/paths, invalid provenance and filename/record-ID mismatches are
errors. They do not cause a default record to be written over the original.

Runtime identity strings describe a selection; they are not paths or proof that
its binaries are installed. Resolve them through the runtime catalog/detector.
Provenance records artifact identity, not authentication of its contents. Store
the original public download URL, not a signed redirect containing credentials.
No Steam credentials, cookies, PIDs or live “running” flags belong in a record.

## Durable progress versus derived state

Persisted `InstallationProgress`:

- `notStarted`
- `installing(stage)`
- `installed` (explicit installation-completion marker)
- `failed(reason)`
- `interrupted(stage)`

Stages are downloading installer, creating prefix, running installer,
bootstrapping Steam and validating installation. Failures are stable reason codes,
not raw logs or potentially sensitive exception text.

`EnvironmentState` is derived from this progress plus fresh observations:
unverified, missing prerequisites, ready to install, installing, installed,
running, failed or interrupted.

Key reconciliation rules:

| Observation | Result |
|---|---|
| Process observation not checked | Unverified; durable progress unchanged |
| Verified active installer | Installing at the observed stage; save updated progress if it changed |
| Verified Steam process, prefix and executable present | Running; do not infer installation completion from that alone |
| Steam reported running but its required files are absent | Inconsistent-observation failure |
| Persisted installation in progress, process set positively idle | Interrupted at the saved stage, even if an installer left `Steam.exe` behind |
| Completed install and files present, process idle, prerequisites ready | Installed |
| Completed install but prefix/executable missing | Explicit missing-files failure; never “ready to install” |
| Prerequisites missing for otherwise eligible state | Missing prerequisites; installed history retained |
| No runtime identity recorded, otherwise ready | Missing runtime selection |
| Fresh record with unexpected prefix contents | Unexpected-prefix failure; no automatic adoption or repair |
| Recorded failure/interruption and idle process set | Preserve that failure/interruption until an explicit recovery action |

`ProcessObservation` must come from a detector that establishes ownership for this
specific environment. Failure to inspect processes means `notChecked`, **not**
`idle`. A PID by itself is insufficient because it may have been reused. E3.2
accepts these observations as inputs; it does not scan host processes or launch
Wine. Its integration test uses the lifetime of an owned child process as a
process-observation fixture, not as a real Steam detector.

The file inspector opens the real managed prefix and executable path to establish
directory/regular-file presence. Presence is not executable authenticity, payload
completeness or UI readiness. In particular, merely finding `Steam.exe` cannot
turn an interrupted bootstrap into an installed state.

## API usage

The caller must retain the record returned from create/save, including its new
revision and normalized timestamps. An example for a newly registered environment:

```swift
let store = try EnvironmentStore()
var record = try await store.create(EnvironmentRecord(
    id: EnvironmentID(UUID().uuidString.lowercased()),
    name: "Windows Steam",
    runtime: RuntimeIdentity(provider: "Sikarugir", distribution: "10.0_6",
                             wine: "10.0", graphics: "4.0b2")
))

record.installation = .installing(.creatingPrefix)
record = try await store.save(record)
// Only after save succeeds should a future installer mutate the prefix.

let snapshot = try await store.reconcile(
    record.id, process: .notChecked, prerequisites: .notChecked
)
// snapshot.state == .unverified; no guessed interruption or PID restoration.
```

`save` requires an existing record with matching revision and immutable creation
timestamp. Stale writes fail with `conflict`. Competing writer processes/actors
are coordinated with a nonblocking advisory lock; `busy` means reload/retry later,
not bypass the lock. The actor serializes one instance's own operations. Catalog
reads are per-record atomic, not a multi-record database transaction.

With asynchronous E3.3 observations, pass the source record's `expectedRevision`
to `reconcile`. It rejects stale observations, and will not persist an interruption
while a current execution lease is active. Runtime/executable selection changes
also require an available execution lease.

## Atomic writes and path handling

Writes use a unique same-directory temporary file, a complete write loop and
file `fsync`, then atomic publication. Creation uses a no-clobber hard-link
publication; replacement uses descriptor-relative `renameat`. Neither follows a
destination symlink. Files are created mode 0600 and new owned directories 0700.

Directory traversal and file opens use `openat`/`O_NOFOLLOW`; path traversal and
absolute/Windows/URL-style relative paths are rejected. Existing symlinks at the
app root, metadata directories/files, prefix or executable components are errors.
The trusted parent is canonicalized with POSIX `realpath`: Foundation's resolver
shortens `/private/var` back to `/var`, which would otherwise conflict with the
strict no-symlink traversal policy on macOS temporary directories.

Open directory descriptors pin the write location. Tests swap a metadata target
to an external symlink and rename/replace its directory during the commit window;
the external directory/file remain unchanged. If the directory was moved, the
commit stays in the originally opened directory and a subsequent load reports
the now-invalid path. This is path confinement for these operations, not a
security sandbox against arbitrary same-user modification of the whole data tree.

A pre-publication failure leaves the previous document intact (or no record for
an initial create). Only the current operation's own temporary name is cleaned
up. `.tmp` remnants from a process crash are ignored on reads rather than purged.
Documents larger than 1 MiB and non-regular metadata files are rejected. Per-file
atomic visibility is guaranteed by the filesystem operations; full power-loss
durability or automatic recovery from externally corrupted files is not claimed.

## Native UI and verification

The summary has no installation/reset controls. Startup and Reload use the store,
real file inspection and E3.3 observations; a confirmed interruption can be saved.
Errors are visible and do not replace corrupt records. Debug UI tests use an explicit
temporary `--metadata-root`; release builds do not accept that override.

Tests cover real temporary files, unknown/future schemas, provenance validation,
initial/replacement write interruption, orphan files, stale revisions, concurrent
writers, preexisting prefixes, path/symlink escapes and commit-time replacement,
oversized/corrupt documents, timestamp round-trips, and live/stopped owned-process
observations after store recreation. UI tests verify empty startup, metadata
surviving app restart without claiming readiness, and visible corruption errors
with byte-for-byte preservation. Existing Steam environments are not test fixtures.

Run `make check` and `make ui-test` as described in [development.md](development.md).
