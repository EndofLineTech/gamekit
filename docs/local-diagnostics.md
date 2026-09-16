# Local diagnostics

E3.4 (`gamekit-m19.4`) adds bounded operation records, failure classification and
JSON summary exports. The foundation app records the commands used by runtime
checks and displays them under **Local diagnostics**.

## Viewing and exporting

1. Open Gamekit with `make run`. Startup and environment **Reload** run prerequisite
   checks; commands that actually execute produce diagnostic records.
2. Scroll to **Local diagnostics**. Each row shows its stage, component, category
   and a suggested next step. **Reload logs** refreshes the stored records.
3. **View local output** opens the captured stdout/stderr in a separate sheet.
4. **Export summary** opens the macOS save dialog for a JSON summary.

Local output is private diagnostic material and can contain account data emitted
by a command. The export contains only the structured summary: it never attaches
raw output, environment IDs, command arguments, environment variables, paths,
arbitrary error messages or Steam session files. There is no automatic upload.

## Storage and retention

Records live separately from environment metadata:

```text
~/Library/Logs/Gamekit/Operations/<operation-uuid>.json
```

The store uses the shared descriptor-relative file-access layer, private directory
and file permissions, cooperative writer locks, and atomic replacement. Records
are schema version 1 JSON; captured byte streams use JSON's base64 Data encoding.
Encoding is not encryption. Unsafe symlinks, corrupt owned records and oversized
documents produce storage errors rather than being followed or silently discarded.

Default `DiagnosticsPolicy` limits:

| Limit | Default |
|---|---|
| Retained operations | 20 |
| Age since last update | 7 days |
| Captured bytes per stdout/stderr stream | 262,144 each |
| Stage events | 64, preserving the first and most recent events |
| Active checkpoint interval | 1 second |
| Encoded document ceiling | 1 MiB |

Capture keeps the beginning of each stream and continues counting all received
bytes after truncation. Signature detection also continues after that limit.
Retention runs when beginning an operation or listing summaries, removing oldest
eligible records first. Per-operation leases protect active operations even from
another store instance. If active operations fill capacity, new recording is
unavailable; active records are never evicted to make room. Unknown files are
preserved; strictly named abandoned diagnostic temporary files are cleaned under
the catalog lock.

An interrupted app leaves the latest checkpoint with no final outcome. Its
category is `incomplete`; it does not establish that the runtime stopped or that
installation failed. Check live process state before recovery. Checkpoints reduce
lost output on interruption but do not promise power-loss durability. Retention
does not run while the app/store is inactive.

## Core integration

For bounded one-shot commands, use the recording decorator:

```swift
let diagnostics = try DiagnosticStore()
let execution = await DiagnosticCommandRunner(store: diagnostics).run(
    CommandRequest(executable: URL(fileURLWithPath: "/usr/bin/true")),
    stage: .runtimeProbe,
    context: .init(component: .application)
)
let command = try execution.value()
// Inspect command.termination and execution.storageIssue independently.
```

`value()` returns the real command result or throws the original launch error.
`storageIssue` reports unavailable recording or a failed final write. A logging
failure never changes a successful process result into a missing-runtime report.
The app retains its recording warning after a failure, even if later commands log
successfully.

Longer coordinators can use `begin`, `transition`, `checkpoint` and `finish`.
Pass the returned operation's `receive` method through a process output callback;
it performs bounded in-memory capture under a lock, with disk writes performed by
the store. Keep the store alive and finish each operation on every terminal path.
`finish` can record the overall outcome separately from the original command's
termination and duration. A failed finish releases the active lease and throws;
the preceding checkpoint may be all that survives.

Runtime-session and installer coordinators must choose their own stage transitions
and completion evidence. The current app integration records runtime probe
commands, not a whole `RuntimeSession` lifecycle. A launcher exiting successfully
does not prove that Steam finished starting or that rendering works.

## Summary schema and classification

`DiagnosticSummary` is a separate, allowlisted `Encodable` type. It includes a
fresh diagnostic UUID, timestamps, monotonic elapsed time, stage history, numeric
app/OS versions, component, outcomes and command duration, byte counts, truncation,
incomplete-output and checkpoint-failure flags, a typed signature and fixed advice.
The selected runtime identity is exported only when it exactly matches the pinned
catalog entry; this is a selection label, not proof that validation passed.

Failure categories distinguish download, installation, bootstrap, rendering and
runtime stages. Timeout, cancellation and incomplete operations have explicit
categories. Bounded per-stream signature scanning recognizes known loader,
exception, permission and network symptoms, including signatures split between
chunks. A recognized failure signature can flag an exit-zero operation for
inspection. These are diagnostic hints, not an automatic root-cause determination
or stage-acceptance verdict. Only typed signature labels and fixed advice are
exported; source text is never copied into an export.

## Verification

`DiagnosticsTests` exercises a real shell command that emits a DLL initialization
failure and exits 23. Its saved summary identifies bootstrap, the loader signature,
the exit code and runtime-integrity advice. Other tests verify bounded capture,
split signatures, stage categories, count/age retention, cross-store active leases,
periodic checkpoints, unfinished records, record-size limits, corrupt/symlink
preservation, orphan cleanup, timeout and missing-executable behavior.

Export tests include split bearer tokens, account identifiers, unlabeled secrets,
paths, arbitrary runtime strings and an unrelated session file. They verify both
the excluded values and the summary's allowed top-level fields. A native UI test
seeds a real failed command, verifies the viewing/export controls, and checks the
core-export bytes. The system save-dialog interaction itself is not automated.
Tests use temporary roots and do not access authenticated Steam prefixes.
