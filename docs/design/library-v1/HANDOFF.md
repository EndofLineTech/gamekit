# Library redesign — implementation handoff

## Start here

This handoff is for a fresh coding session, including Sol. Work is tracked in
Beads under `library-redesign` / `ui-first`. Read each bead's description,
acceptance criteria, **design** field, and dependency links. The design field
contains the task-specific source pointers and verification plan.

The owner approved the look of the clickable prototype, then requested:

- Settings replaces the left sidebar with its categories and includes **Back to
  Launchers**, returning to the launcher-management destination.
- Transparent launcher icons in artwork corners, with no opaque background.
- The game-case icon, refined with two analog sticks, four face buttons, D-pad
  and center buttons.
- Implement the current Steam UI redesign first; additional launchers come later.

There is no approval to add Ubisoft, Epic, Battle.net or GOG integration in this
work. Their order is recorded for later planning only. Do not transplant the
prototype's fabricated library into the real application.

## Artifact location and branch state

Repository: `/Users/lecaptainc/Code/gamekit`.

The design is on `task/gamekit-vwq-library-design`, PR
[68](https://github.com/EndofLineTech/gamekit/pull/68), targeting `dev`. At this
handoff it is a draft and not merged. The initial artifacts are in commit
`dc84088`; the approved revised icon is in `f1f73e5`. Later commits on the same
branch carry this handoff. Fetch and check PR status rather than assuming the
files already exist on `origin/dev`.

Read artifacts from this branch while planning. Implementation must start from
current `origin/dev` on a dedicated task branch per `AGENTS.md`. Prefer landing
the approved artifact PR into `dev` through the normal PR/check workflow before
starting implementation; do not silently branch app work from an old baseline
or bypass protections. No work on `main` is required for the redesign.

Full paths:

```text
/Users/lecaptainc/Code/gamekit/docs/design/library-v1/index.html
/Users/lecaptainc/Code/gamekit/docs/design/library-v1/icon-case.svg
/Users/lecaptainc/Code/gamekit/docs/design/library-v1/README.md
/Users/lecaptainc/Code/gamekit/docs/design/library-v1/HANDOFF.md
/Users/lecaptainc/Code/gamekit/docs/design/library-v1/capture.cjs
```

The HTML runs directly from disk. It is a visual reference, not a proposed web
implementation. Generated captures are local under
`/Users/lecaptainc/Code/gamekit/.build/library-design-v1/` and can be regenerated
using the README command. The mockup uses a preview wrapper and simulated
management actions; do not ship that wrapper, its review controls, or sample data.

## Current application boundaries

The main view is `App/ContentView.swift`: one long scroll view currently hosts
Steam controls, installed games, prerequisites, environment details, installation
and diagnostics. `App/GamekitApp.swift` defines the window. `project.yml` is the
source for the generated Xcode project; edit it, not the generated project.

`App/InstalledGamesView.swift` contains a private model with library refresh,
launch observation and uninstall feedback; `App/SteamLifecycleView.swift` has
another view-owned lifecycle model. `App/SetupModel.swift` owns the UI operation
gate. These are the key lifetime concerns when introducing navigation: moving
between screens must not cancel observation, recreate work, lose messages or
resend launch commands. Preserve the backend's leases and ownership validation.

Core services remain authoritative:

| Concern | Existing source |
| --- | --- |
| Installed records, artwork headers and size | `Sources/GamekitCore/SteamGameLibrary.swift` |
| Managed launch/show/stop/uninstall | `Sources/GamekitCore/SteamLifecycle.swift` |
| Launch progress and prompt attention | `Sources/GamekitCore/SteamGameLaunchObservation.swift` |
| Shared graphics/runtime/Space settings | `Sources/GamekitCore/RuntimeSettingsStore.swift` |
| Per-game graphics/Space/cursor choices | `Sources/GamekitCore/GameCompatibilityStore.swift` |
| Profile resolution/import/export | `Sources/GamekitCore/GameProfile.swift` |
| Installation/readiness/recovery | `Sources/GamekitCore/SteamInstallationCoordinator.swift`, `SteamReadiness.swift`, `SteamRecovery.swift` |
| Session/process ownership | `Sources/GamekitCore/RuntimeSession.swift`, `ProcessObservation.swift` |
| Diagnostics and exports | `App/AppDiagnosticsModel.swift`, `Sources/GamekitCore/DiagnosticStore.swift` |

The new UI may use minimal presentation types and a thin service facade. It does
not need a provider plug-in system, a new network API, a new prefix layout or a
JSON execution-rule migration. Steam IDs can be wrapped in source/environment
identity without changing persisted execution settings.

## Behavior that must survive

Use real managed Steam installation records, including incomplete/missing-file
states. Unreadable libraries are not empty libraries. Size remains Steam-reported
bytes; unknown is not zero and summing known entries is not total disk usage.
Current artwork is a landscape header; portrait retrieval needs a separate cache
entry and a designed fallback. Missing art cannot block Play or browsing.

Play starts or reuses the managed session exactly once. Cloud/session prompts
belong to the user; show attention with a route to Steam. Process creation is not
a gameplay pass. Show Steam must retain the existing owned-window focus handoff.
Uninstall remains Steam-mediated and confirmed. Stop can close games in the
managed session; ordinary Quit leaves them running.

Shared and per-game graphics and fullscreen-Space controls exist today. Keep
inheritance and explicit overrides, including Off, intact. Cursor guard remains
profile-defined; fullscreen Space is available as shared/per-game choice, with
display-sized-window limitations. Retain profile import/export/update and local
import precedence. Game-specific execution parameters stay in JSON.

Runtime checks, rollback, archive/cache cleanup, local diagnostics, debug capture
and safe exports must be relocated rather than removed. Do not broadly clear
user metadata or reset games to simplify UI migration. Native Steam and unrelated
Wine environments remain outside scope.

## Execution and validation

Two entry points are ready: `gamekit-vwq.2` (finalize remaining interaction
details) and `gamekit-8n5.1` (native assets from approved icon). The rest are linked
through child-bead dependencies. Do not close the design epic until `.2` is
complete; approving the appearance is not acceptance of native implementation.

The unresolved design details are full compatibility/setup/recovery sheets,
precise keyboard activation and remembered scroll behavior, and detailed status
announcements. Resolve them in `.2` from existing behavior and the approved
direction; ask the owner about meaningful UX alternatives rather than inventing
new features. Later components must consume those decisions.

Use focused core and native UI tests during implementation. Full repository
delivery gates are `make check`, `make ui-test`,
`python3 tools/check_game_configuration.py`, and the wiki checks when public data
or documentation is changed. `make package` produces a local package with source
manifest and signing verification. Run Xcode builds/tests serially because they
share generated project/derived data. Inspect failing xcresults before retrying.
Opt-in live tests may start or stop real games; read them before execution.

Verify the actual packaged native app against the mockup in light/dark, with
keyboard and VoiceOver, and at compact/expanded sizes. Do not use passing HTML
smoke checks as native UI acceptance. User gameplay, save changes and destructive
recovery are not prerequisites for a visual review; use isolated fixtures for
those regressions. Record any necessary hands-on acceptance honestly.

All implementation changes require PRs into `dev`. Keep Beads updated and include
test results, artifact paths and PR URLs in completion notes. No new runtime tests
were run for this handoff-only audit.

## Handoff audit result

The audit read back all **28 redesign beads: six epics and 22 children**. Each
has a description, acceptance criteria and a current handoff design field. All
22 children include task-specific source entrypoints, implementation boundaries
and verification/completion evidence. All parent/dependency references resolve;
the blocking dependency graph is acyclic.

Dependency gaps corrected during this audit: Settings waits for the navigation
shell; list and inspector wait for artwork; accessibility/appearance review waits
for icon integration. The shell already waits for shared visual primitives and
application-scoped models. No new launcher integration is on this critical path.

The mockup navigation (`vwq.1`) and revised icon concept (`vwq.3`) are approved and
closed. The detailed interaction specification (`vwq.2`) remains open honestly;
the artifact README identifies its remaining details. The icon-production bead
(`8n5.1`) is also ready. Other implementation work follows those explicit links.
