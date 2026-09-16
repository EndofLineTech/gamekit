# Gamekit personal prototype — operating guide

## Scope and prerequisites

This prototype targets **Apple silicon on macOS 27**. It uses Rosetta and the
validated Sikarugir Wine 10.0 revision 6 / Template 1.0.11 runtime with Apple's
unchanged D3DMetal 4.0b2 payload. Steam client readiness is not game compatibility.
macOS 28 and public distribution are not validated.

Gamekit does not bundle the third-party runtime or accept prerequisite licenses.
Follow the [runtime setup guide](https://github.com/EndofLineTech/gamekit/blob/dev/docs/runtime-revision.md)
and Apple's [Rosetta instructions](https://support.apple.com/en-us/102527).
Keep at least 15 GiB free on the app-data volume for setup and updates.

## Open or build

A local package contains `Gamekit.app`, this guide and `build-manifest.json`.
Open `Gamekit.app`, or copy it to your own Applications folder first. The app is
ad-hoc signed for personal local use, not a notarized public distribution.

To build from the repository with Xcode 27 and XcodeGen installed:

```bash
make check
make ui-test
make run
# Build and validate a separate Release candidate without replacing older packages:
make package
```

Packages are created under `.build/packages/Gamekit-<UTC timestamp>/`.
The manifest records executable/source fingerprints, source commit and dirty-tree
status, toolchain/OS identities, signing scope and validated recipe. A candidate
manifest does not assert that release acceptance or reboot testing has passed.

## First setup

1. Review **Setup and prerequisites**. Each failed check explains its next step.
2. Use **Choose runtime…** if the validated runtime app is in another local
   location, or **Use managed runtime** for the default. The prefix storage stays
   fixed. Runtime selection cannot change while a managed session owns it.
3. Click **Refresh checks** (Command-Shift-R) after fixing prerequisites.
4. Click **Install Steam**. Gamekit downloads and validates Valve's installer,
   initializes its prefix, and invokes the installer silently with `/S`.
5. Steam updates and starts. Gamekit waits for a consistently owned client and
   browser process with a visible browser window stable for three seconds.
6. Gamekit finishes setup and reopens Steam in normal persistent mode. Sign in and
   complete Steam Guard inside Steam when requested.

There are no installer-wizard clicks or separate Gamekit readiness confirmation.
Automatic readiness means the Steam web UI is available; it does not authenticate
your account or guarantee every Library feature or game works. A persistent status
bar shows the current stage, with no invented progress percentages.

## Everyday use

- **Launch Windows Steam** (Command-L) starts one managed session. Repeated requests
  do not create a second session.
- Quitting Gamekit leaves Steam open. Reopen Gamekit to recover status/control.
- **Stop Windows Steam** (Command-Shift-S) requests graceful shutdown, then uses
  the managed Wine server after 30 seconds if needed. If a tagged Wine service
  survives, the final fallback uses kernel audit-token/PID-generation checked
  signalling. Uncertain or foreign ownership is refused.
- Stop affects games in the same managed environment; save your work first.
- Settings/runtime changes and conflicting operations are disabled while busy.

Steam should appear as **Windows Steam** in the Dock. The hidden launcher does not
retain Gamekit as “Running in Background.” These behaviors depend on the tested
macOS/runtime combination and must be rechecked after upgrades.

## Recovery

**Retry interrupted install** inspects saved progress and current files. It can
redownload a failed installer, finish a partial setup, or repeat automatic Steam
readiness checks. If interrupted setup still has a tagged session running, use
the explicitly confirmed **Force-stop interrupted setup…** first.

Reset choices are behind **Show reset options…**:

- **Reset, preserve downloads…** archives the old prefix. During fresh setup,
  preserved `steamapps`/`depotcache` directories are restored **after** successful
  installer execution, before bootstrap.
- **Reset and delete downloads…** permanently removes the current prefix and its
  games, settings, sign-in data and saves. It does not purge older recovery archives,
  external libraries, runtimes or diagnostics.

Each choice has its own confirmation and requires a stopped, verified environment.
If a reset is interrupted, Retry resumes its journal. Do not manually combine
partially restored directories or delete a pending reset's archive. Non-empty
destination conflicts and unsafe paths are refused to protect data.

## Diagnostics and storage

Default locations:

| Data | Location under `~/Library/Application Support/Gamekit/` |
|---|---|
| Managed Windows environment | `Environments/steam/` |
| Saved progress and runtime selection | `Metadata/` |
| Downloaded installer receipts/artifacts | `InstallerDownloads/` |
| Derived local Windows Steam launcher | `Launchers/Windows Steam.app/` |
| Old recovery environments | `Recovery/steam/` |
| Separate acceptance environments | `Acceptance/` (development verification only) |

Local diagnostic records are under `~/Library/Logs/Gamekit/`. **View local output**
can show sensitive runtime text. **Export summary** emits a separate allowlisted
summary without raw output, paths or session/account fields. Share the summary,
not the whole prefix, archive or raw log directory.

Recovery archives retain old settings/sign-in data and consume disk space. Archive
inspection/cleanup UI is tracked separately. Never remove an archive referenced by
an unfinished recovery journal.

## Removal

Stop managed Steam, then quit Gamekit before removing its `.app` copy. Removing
the app alone retains your runtime and Steam data. To remove the current prefix,
use the confirmed clean reset before deleting the app. Older archives and logs
require a separate deliberate removal decision.

Do not blindly delete the entire Gamekit support directory: it may also contain
repository Beads service tooling (`Beads/`) and independent evaluation environments.
The generated launcher cache can be recreated from the selected runtime, but only
remove it while all managed sessions are stopped.

## After OS, runtime or Steam updates

Refresh prerequisite checks, then repeat Launch, normal Gamekit Quit/reopen, Stop
and relaunch. Confirm login/Library behavior and record the new versions. Recheck
after a Mac reboot. Do not claim support for a different OS or runtime from version
numbers alone. The packaged manifest and the repository's acceptance record state
what was actually verified and what remains pending.
