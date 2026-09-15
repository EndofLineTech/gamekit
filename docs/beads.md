# Beads operations and recovery

## Tested configuration

- Beads **0.56.1**, Dolt **2.3.4**, Xcode Python **3.9.6**, macOS **27**.
- SQL listener: `127.0.0.1:3307`; database: `beads_gamekit`.
- Database directory: `<checkout>/.beads/dolt/beads_gamekit`.
- GitHub backup: `git+https://github.com/EndofLineTech/gamekit.git`, named `github`.
- Git data ref: **`refs/dolt/data`**, separate from `refs/heads/dev` and
  `refs/heads/main`. Backup updates never modify either protected source branch.
- This backup is **public**, as requested. It includes Dolt history, issue text,
  dependencies, and author/audit metadata. Keep credentials out of issue content.

The Git source branch (`dev` or a task branch) is independent of Dolt's internal
database branch (`main`). Source branch switching does not switch the board.
`.beads/` is machine-local and ignored by Git. Ordinary `git clone`, `pull`, and
`push` do not fetch or upload the database snapshot. This Beads release does not
provide the old JSONL auto-sync workflow described by its generated template.

## Automatic operation on this Mac

Two user LaunchAgents are installed under `~/Library/LaunchAgents/`:

| Label | Behavior |
|---|---|
| `tech.endofline.gamekit.dolt` | Starts at login, restarts after a process exit, listens only on loopback |
| `tech.endofline.gamekit.beads-backup` | Backs up at login and every hour; waits for SQL readiness |

These are **login services**, not pre-login system daemons. After reboot, sign
into this macOS account to start them. Sleep/offline time may delay backups;
failures remain visible until a later successful run. Maximum intended online
backup interval is one hour; run a manual backup for immediate durability.

Service settings, an installed copy of the helper, and logs live in:

```text
~/Library/Application Support/Gamekit/Beads/
  service.json
  beads_service.py
  server.log
  backup.log
  backup-status.json
```

The installed helper is independent of source branch switching. Python and Dolt
must remain installed at the paths in the plists. The database stays in the
checkout: moving/deleting that checkout requires service reconfiguration first.
Server logs are warning-level; inspect log size periodically and rotate them when
needed. Scheduled backups use the existing Git credential helper/Keychain, never
credentials embedded in source or plists. GitHub authentication must remain valid.

```bash
bd dolt test --json
bd ready --type task --json
launchctl print "gui/$(id -u)/tech.endofline.gamekit.dolt"
launchctl print "gui/$(id -u)/tech.endofline.gamekit.beads-backup"
```

Read `backup-status.json` to check `ok`, UTC `time`, and any failure message. A
working SQL server does not imply the last backup succeeded.

## Manual backup and restore verification

From this checkout:

```bash
python3 scripts/beads_service.py backup
python3 scripts/beads_service.py verify-restore
git ls-remote origin refs/dolt/data
```

The backup command invokes Dolt's `backup sync github` against the live SQL
server. This captures branches, tags, working sets and history, including pending
database changes. A Dolt commit is not required merely to preserve the working
set. No raw copying of open database files is performed. A local advisory lock
prevents the manual and scheduled helper invocations from overlapping.

`verify-restore` uploads a snapshot, downloads it into a temporary isolated
database, and compares the working-set hash (schema and data), issue/dependency
counts and current-branch commit history. It removes only its own temporary
workspace afterward. Keep the board idle while it runs; concurrent writes cause
a verification failure and should be followed by another run.

The configured object is a **backup**, not a Dolt collaboration remote, so
`bd dolt push`, `bd dolt pull`, and `bd sync` are not substitutes. Treat this as a
single-writer board: do not run independent scheduled writers on several Macs.
GitHub's custom ref is not a PR branch and does not appear in a normal source
clone. Keep an independently retained local snapshot before migrations if you
need an additional recovery point.

## Fresh clone / disaster recovery

The `restore` command needs Python, Dolt and network access, but does not require
the live server, service settings, or any original database files.

1. Clone the source repository and check out `dev` (or the recovery-tool PR branch
   until merged). Install the tested tools if absent.
2. Create the parent directories `.beads/dolt/` in that fresh checkout. The target
   database directory below **must not exist**.
3. Restore the latest GitHub snapshot:

   ```bash
   python3 scripts/beads_service.py restore "$PWD/.beads/dolt/beads_gamekit"
   ```

   Dolt 2.3.4's Git-backup restore requires an initialized scratch repository for
   its Git cache. The helper creates that scratch repository automatically, then
   removes it. It never uses `--force` or overwrites an existing destination.
4. Create `.beads/metadata.json` with:

   ```json
   {
     "database": "dolt",
     "jsonl_export": "issues.jsonl",
     "backend": "dolt",
     "dolt_mode": "server",
     "dolt_database": "beads_gamekit"
   }
   ```
5. Ensure port 3307 is free and install the login services:

   ```bash
   python3 scripts/beads_service.py install-service --repo "$PWD"
   bd dolt test --json
   bd info --json
   bd dep cycles --json
   ```

6. Backup destination configuration is local Dolt configuration and may need
   adding after restore. Inspect before adding; do not overwrite another target:

   ```bash
   dolt --host 127.0.0.1 --port 3307 --no-tls --use-db beads_gamekit backup -v
   # If github is absent:
   dolt --host 127.0.0.1 --port 3307 --no-tls --use-db beads_gamekit \
     backup add github git+https://github.com/EndofLineTech/gamekit.git
   python3 scripts/beads_service.py verify-restore
   ```

   A first scheduled backup may fail until this configuration and GitHub write
   authentication are ready; its status file records the failure. Keep only the
   intended active Mac's backup scheduler enabled.
7. If the Git remote identity differs, inspect it and run
   `bd migrate --update-repo-id --json`. Do not reinitialize the restored board.

To recover an existing machine, first stop its two LaunchAgents and **retain the
old database**. Restore into a separate directory, inspect the restored board,
then deliberately move the old database aside and put the validated replacement
at the configured path. Restart the service only after that decision. The helper
does not automate overwriting production data.

## Service reinstall, upgrade, and removal

To unload the services without deleting database data:

```bash
launchctl bootout "gui/$(id -u)/tech.endofline.gamekit.beads-backup"
launchctl bootout "gui/$(id -u)/tech.endofline.gamekit.dolt"
```

After retaining any needed logs, remove the two corresponding plist files from
`~/Library/LaunchAgents/`. Then rerun `install-service` from the intended checkout
to regenerate paths and refresh the installed helper. Removing the agents and
their plists leaves the Dolt database and GitHub backup intact. To temporarily
stop/restart without reinstalling, use `bootout` followed by `launchctl bootstrap
"gui/$(id -u)" <path-to-plist>` for each agent, server first.

Before a tool upgrade: take and verify a backup, stop the services, upgrade
explicitly, reinstall/update paths if necessary, and repeat restart plus restore
verification. Beads upgrades are not part of this setup change.

## Troubleshooting

- **Connection refused:** inspect `launchctl print` and `server.log`; confirm the
  selected database exists, Dolt binary exists and port 3307 is not occupied by
  another server. Never start two servers against the same database.
- **Lock warnings:** `bd doctor` 0.56.1 warns about locks legitimately held by the
  SQL server. Confirm ownership with `lsof`; do not delete live locks.
- **Wrong repository fingerprint:** verify the Git remote, then use
  `bd migrate --update-repo-id --json` after an intentional remote change.
- **Missing table/empty board:** check `.beads/metadata.json` selects
  `beads_gamekit`, not the empty `beads` database left by initial setup.
- **Backup fails:** inspect `backup-status.json` and `backup.log`; check network,
  `gh auth status`, the configured backup URL, and Git credential-helper access.
  Retry `backup`, then `verify-restore`. Do not report a successful handoff until
  backup succeeds. Failed uploads do not delete the local board.
- **Doctor warns about hooks or a newer CLI:** hooks do not replace the snapshot
  workflow. Review upgrades separately; do not run a blanket `doctor --fix`.

## Verification evidence for this setup

Record actual checks and results in bead `gamekit-8gp`, including launchd restart,
scheduled backup result, isolated restore hash/history comparison and preservation
of 6 approved epics, 21 tasks, 21 parent links and 20 execution dependencies.
Additional operational beads are expected and are also included in backups.
