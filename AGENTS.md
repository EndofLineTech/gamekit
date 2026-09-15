# Agent Instructions

## Branch and Pull Request Policy

- `dev` is the default integration branch. Start all implementation from an
  up-to-date `origin/dev` on a dedicated task branch (for example,
  `task/gamekit-wxz.1-runtime-contract`).
- Open a pull request targeting `dev` for every change. Never commit or push
  directly to `dev` or `main` after the initial repository bootstrap.
- `main` is the stable branch; promote accepted work via a release PR from `dev`.
- Both branches enforce PR-only changes for administrators too, and prohibit
  force pushes and deletion. Do not disable or bypass protection to deliver work.
- Independent review approval is not required for this personal prototype;
  the pull request itself is mandatory.
- Session-completion push instructions below apply to the task branch. Report
  its PR URL when a PR has been requested and created. Check branch and tracking
  state before editing, committing, or pushing.

This project uses **bd** (beads) with a Dolt SQL server for issue tracking.
Run `bd prime` for CLI workflow context. See [the Beads runbook](docs/beads.md)
for startup, backup, fresh-clone recovery, and troubleshooting.

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --status in_progress  # Claim work
bd close <id>         # Complete work
bd dolt test --json    # Verify the local SQL server connection
python3 scripts/beads_service.py backup  # Snapshot board to GitHub
```

<!-- BEGIN BEADS INTEGRATION -->
## Issue Tracking with bd (beads)

**IMPORTANT**: This project uses **bd (beads)** for ALL issue tracking. Do NOT use markdown TODOs, task lists, or other tracking methods.

### Why bd?

- Dependency-aware: Track blockers and relationships between issues
- Versioned database: Dolt snapshots include board history and working sets
- Agent-optimized: JSON output, ready work detection, discovered-from links
- Prevents duplicate tracking systems and confusion

### Quick Start

**Check for ready work:**

```bash
bd ready --json
```

**Create new issues:**

```bash
bd create "Issue title" --description="Detailed context" -t bug|feature|task -p 0-4 --json
bd create "Issue title" --description="What this issue is about" -p 1 --deps discovered-from:bd-123 --json
```

**Claim and update:**

```bash
bd update bd-42 --status in_progress --json
bd update bd-42 --priority 1 --json
```

**Complete work:**

```bash
bd close bd-42 --reason "Completed" --json
```

### Issue Types

- `bug` - Something broken
- `feature` - New functionality
- `task` - Work item (tests, docs, refactoring)
- `epic` - Large feature with subtasks
- `chore` - Maintenance (dependencies, tooling)

### Priorities

- `0` - Critical (security, data loss, broken builds)
- `1` - High (major features, important bugs)
- `2` - Medium (default, nice-to-have)
- `3` - Low (polish, optimization)
- `4` - Backlog (future ideas)

### Workflow for AI Agents

1. **Check ready work**: `bd ready` shows unblocked issues
2. **Claim your task**: `bd update <id> --status in_progress`
3. **Work on it**: Implement, test, document
4. **Discover new work?** Create linked issue:
   - `bd create "Found bug" --description="Details about what was found" -p 1 --deps discovered-from:<parent-id>`
5. **Complete**: `bd close <id> --reason "Done"`

### Database and Backup

- Tested tooling: Beads 0.56.1 and Dolt 2.3.4. Evaluate upgrades separately.
- Beads connects to `127.0.0.1:3307`, database `beads_gamekit`. Local data is
  under `.beads/dolt/`; `.beads/` is excluded from source commits.
- The macOS LaunchAgent starts Dolt at user login and restarts it after failure.
- A second LaunchAgent snapshots the database hourly and at login. Check
  `~/Library/Application Support/Gamekit/Beads/backup-status.json` for its result.
- Run `python3 scripts/beads_service.py backup` after board changes and at handoff.
- The approved **public** backup is stored in this repository's `refs/dolt/data`.
  It contains the board, audit/author information and Dolt history. Do not put
  secrets in beads. This is a database snapshot, not a source-code branch or PR.
- Ordinary `git push` and `git pull` do **not** synchronize the board. Do not rely
  on JSONL auto-export, `bd sync`, or Git hooks to do so in this version.
- We configured a Dolt **backup**, not a collaboration remote; `bd dolt push/pull`
  are not the snapshot workflow. Use the helper and runbook instead.
- One Mac is the active board writer. Restore on a second Mac before handoff;
  coordinate writers rather than overwriting divergent snapshots.
- Never remove live Dolt lock files or reset/reinitialize a populated database.

### Important Rules

- ✅ Use bd for ALL task tracking
- ✅ Always use `--json` flag for programmatic use
- ✅ Link discovered work with `discovered-from` dependencies
- ✅ Check `bd ready` before asking "what should I work on?"
- ❌ Do NOT create markdown TODO lists
- ❌ Do NOT use external issue trackers
- ❌ Do NOT duplicate tracking systems

For more details, see README.md and [docs/beads.md](docs/beads.md).

<!-- END BEADS INTEGRATION -->

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   python3 scripts/beads_service.py backup
   git push -u origin HEAD  # task branch only; never push directly to dev/main
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Inspect stashes and branches; preserve unrelated user work
6. **Verify** - Intended source changes pushed and latest board backup successful
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
