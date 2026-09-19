# Gamekit personal prototype — operating guide

## Scope and prerequisites

This prototype targets **Apple silicon on macOS 27**. It uses Rosetta and the
validated Sikarugir Wine 10.0 revision 6 / Template 1.0.11 runtime with Apple's
unchanged D3DMetal 4.0b2 payload. Steam client readiness is not game compatibility.
macOS 28 and public distribution are not validated.
The [macOS 28 runtime assessment](https://github.com/EndofLineTech/gamekit/blob/dev/docs/macos28-runtime-viability.md) documents Apple's
Rosetta policy, the native ARM64 Wine/FEX migration direction and the validation
required before extending support.

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
2. Choose **Use updated runtime** for the prepared runtime with per-game
   driver-compatibility support (includes text-input 1). **Use text-input runtime
   (rollback)** selects the previous text-input revision, and **Use original
   runtime** selects the original recipe. **Choose runtime…** locates the
   currently displayed revision elsewhere. See the
   [driver revision guide](helldivers-driver-runtime.md) and
   [text-input revision guide](runtime-text-input-delivery.md).
   Prefix storage stays fixed; Stop Steam before changing revisions.
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

### Debug capture

Under **Local diagnostics**, enable **Debug mode — capture game startup
performance** before launching a game from Gamekit. It records up to 60 seconds
of read-only CPU, memory and disk-I/O counters for one identified owned game
process. **Stop debug capture** stops only the sampler. Debug mode starts off
on each fresh app launch.

Read the resulting **performanceCapture** record using **View local output**;
**Open local logs** reveals the private records. Summary exports omit the raw
counters. No screenshots or shader hooks are enabled. See
[debug capture details and retained developer tools](debug-performance-capture.md).

### Helldivers driver alert

Open the **gear beside Helldivers' Play button** and use **Avoid the virtual-GPU
driver warning** to enable or disable the workaround for that game. It requires
the updated runtime and a stopped Steam session. Your existing enabled choice
is preserved when upgrading from the earlier driver-runtime release.

When enabled, the driver compatibility revision replaces D3DMetal's invalid all-65535 driver
version response with **35.0.15.6094**, only inside Helldivers. This is a
compatibility value, not an installed Windows or Apple driver update. It does
not automatically click dialogs. Steam and other games keep the original DXGI.
The toggle saves a per-game preference without changing the selected runtime,
prefix DLLs, registry overrides, saves or graphics preferences. Disabled and
enabled launchers are cached separately; a fresh launch applies the choice.
The game's **Try Again** button and ignore-warning preference did not prevent
recurrence in this setup; they are not the delivered fix.

### Graphics backend

To retain the tested Helldivers Metal 3 configuration, save/exit games and
**Stop Windows Steam**, then choose **Metal 3 compatibility** in the
**Shared graphics backend** dropdown under Setup. This is the default for
Windows Steam and games with no override, and survives app and Steam restarts.
Each game's gear panel now has its own dropdown: **Use shared default**,
**Automatic (Apple default)**, or **Metal 3 compatibility**. It shows the
effective next-launch backend. Changing it affects only that game, including
launches from managed Steam. **Automatic (Apple default)** restores Apple's default
backend using the same stopped-session flow. See
[persistent graphics settings](persistent-graphics-backend.md) for scope and verification.
See [per-game backend overrides](per-game-graphics-backends.md) for inheritance
and migration details.

The dropdown also lists **DXVK (In Dev)** and **DXMT (In Dev)** as disabled
development placeholders. They cannot be selected yet.

### Steam controls

- **Launch Windows Steam** (Command-L) starts one managed session. Repeated requests
  do not create a second session.
- Quitting Gamekit leaves Steam open. Reopen Gamekit to recover status/control.
- **Stop Windows Steam** (Command-Shift-S) requests graceful shutdown, then uses
  the managed Wine server after 30 seconds if needed. If a tagged Wine service
  survives, the final fallback uses kernel audit-token/PID-generation checked
  signalling. Uncertain or foreign ownership is refused.
- Stop affects games in the same managed environment; save your work first.
  Stop briefly retries incomplete process observations during exit. If inspection
  remains unavailable, it retains ownership and reports the error rather than
  assuming shutdown succeeded or escalating without verified ownership.
- Settings/runtime changes and conflicting operations are disabled while busy.

Steam should appear as **Windows Steam** in the Dock. The hidden launcher does not
retain Gamekit as “Running in Background.” These behaviors depend on the tested
macOS/runtime combination and must be rechecked after upgrades.

## Installed games

Current builds explicitly advertise Rosetta's supported AVX/AVX2 capabilities.
After this update, **Stop Windows Steam** and launch a fresh session so games
inherit the setting. This resolves Helldivers 2's AVX startup message. The
**updated text-input runtime** also resolves the reproduced subsequent startup
crash; Continue on the remaining GPU warning reached the ship in testing. See the
[AVX investigation](https://github.com/EndofLineTech/gamekit/blob/dev/docs/avx-capability.md).

After upgrading to the VC++ prerequisite fix, save and exit games, **Stop Windows
Steam**, then launch again. The new DLL preference takes effect in a fresh Steam
session. See the repository's
[VC++ prerequisite investigation](https://github.com/EndofLineTech/gamekit/blob/dev/docs/visual-cpp-prerequisites.md).

Install games using **Windows Steam**, in its default managed library. Gamekit's
**Installed games** section detects their Steam installation records and shows
each title with artwork and a play button. The list refreshes every three seconds,
when Gamekit becomes active, or with **Refresh games**. Uninstalled titles disappear.

Click a game's tile to launch it. Gamekit starts its managed Windows Steam session
if necessary and sends that game's AppID to the Windows client. The native macOS
Steam app is not used. A launch-request message means Steam received the request;
confirm the game window, first-run setup and actual gameplay separately.

Incomplete downloads, pending updates and missing game directories disable the
tile. Let Steam complete installation or repair it there. Runtime checks and the
shared operation gate also apply to game launches. Steam's installation record
does not prove compatibility or verify every installed game file.

Artwork comes from Steam's local header-image cache first. If unavailable or
invalid, Gamekit requests the title's public header image from Steam's CDN. An
offline/missing image falls back to a controller symbol beside the game title.
External Steam libraries and the native macOS library are not scanned in this
version. See the repository's [library contract](https://github.com/EndofLineTech/gamekit/blob/dev/docs/installed-games.md)
for detection and launch details.

New Steam sessions also load Gamekit's small Intel Wine-side helper. The first
game-tile launch prepares a game-named Wine bundle so the game uses its own Dock
title while Steam remains **Windows Steam**.
Restart Steam after updating Gamekit to pick up this helper. Keep the app bundle
in place while Steam is running; stop Steam before moving/removing it. The helper
routes the Wine child to that identity and retains the game's Windows-provided icon.
See the [Dock identity contract](https://github.com/EndofLineTech/gamekit/blob/dev/docs/game-dock-identity.md)
for scope and validation.

## Per-game compatibility

Choose the **gear icon beside Play** in an installed game's row. Every ready
installed game offers an independent graphics-backend override and displays its
effective next-launch choice. **Use shared default** follows Setup; explicit
Automatic or Metal3 choices leave Steam and other games on their own settings.

Helldivers 2 additionally offers the validated **Fullscreen display capture**
override for the Dock-edge cursor issue:

- **Enable capture** saves the game-specific override.
- **Disable capture** explicitly disables it for this game.
- **Restore capture default** removes that override and inherits Wine's global
  setting (disabled when no global override exists).

The panel shows the saved override, inherited setting and effective capture state.
Select **Fullscreen** inside Helldivers itself. The capture controls do not change
its resolution or suppress the GPU-driver warning.

Helldivers also offers **Use fullscreen Space**, an opt-in native macOS desktop
for its full-display game window. The image uses the entire display, including
behind the notch. Keep the game's own Fullscreen mode selected. **Use desktop
fullscreen** restores its original presentation; this choice is separate from
the capture override and Metal 3 selection. The Space closes with the game.
Stop Steam before changing it, then launch a fresh session. This option is
validated for Helldivers on this Mac's built-in display; other games retain their
current presentation.

Stop Windows Steam and all its games before making changes; launch a fresh session
after saving. The existing accepted override is displayed as-is on first use.
For capture, Gamekit reads the saved registry, changes only the supported
app-specific value, and verifies it after saving. Driver and Space preferences
are stored separately in Gamekit metadata. Other registry settings, saves, runtime binaries and
launcher caches are preserved. Unsupported or ambiguous registry values are
refused. Other titles offer backend selection but not the Helldivers-specific fixes.

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

Under **Show reset options…**, choose **Inspect recovery archives** to list each
archive's logical size and status:

- **Completed**: recovery finished and the archived prefix is eligible for cleanup.
- **Protected**: recovery is unfinished or completion/identity cannot be verified.
  Older archives without a retained completion receipt remain protected.
- **Cleaned**: the old prefix is gone; a small recovery receipt remains.

Stop managed Steam, then choose **Clean up archive…** on a completed archive and
review the confirmation. This permanently removes that archive's old settings,
sign-in data and any local saves remaining inside it. Restored downloads, the
current environment and external libraries are preserved. Cancel changes nothing.
Sizes exclude symbolic-link targets and are logical file bytes, not a guarantee of
reclaimed disk space (APFS clones, sparse files and hard links can differ).

If cleanup is interrupted, inspect again and explicitly retry the same archive.
Pending recovery sources are never eligible. Do not manually remove an archive
referenced by an unfinished recovery journal.

## Removal

### Obsolete generated launchers

Use **Show reset options… → Inspect launcher caches** to review game launcher
caches. Verified pre-`shared-pe-v2` bundles are **obsolete**; numeric probe folders
containing only their lock file are **empty**. Both have an explicit confirmed
cleanup action. **retained** marks the current `shared-pe-v2` layout, while
**protected** means provenance or content could not be verified. Steam launchers,
source runtimes, installed games and external symlink targets are preserved.

Stop managed Steam first. A saved session receipt, live launcher (including one
using another prefix), incomplete process inspection, or concurrent setup blocks
cleanup. Removal rechecks the selected directory's identity and the old format's
manifest, application identity and pinned runtime hashes. A small cleanup ticket
allows an interrupted deletion to appear as **cleanupPending** for explicit retry.
Logical sizes do not predict freed disk space when files share storage.

### Remove Gamekit

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
