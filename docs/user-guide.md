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

1. Gamekit opens to **All Installed Games**. Choose **Settings → Launchers**,
   then review **Setup and prerequisites**. Each failed check explains its next step.
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
your account or guarantee every Library feature or game works. An operation
status row appears below the library while work is active, with no invented
progress percentages.

## Everyday use

The native macOS sidebar opens to **All Installed Games** on every app launch.
The sidebar button sits in the titlebar above the left pane, beside the window
controls; use it to slide the pane closed or open. The game-details
inspector opens when you select a game or press the toolbar's info button. Both
panes follow your system appearance and accessibility settings. Switch between
box-art grid and native table using the toolbar buttons; selection, search and filters
are shared. **Cover size** sets the width of grid artwork; resizing the window
rearranges columns without stretching the covers. The toolbar Sort menu can
order by name, launcher, state or Steam-reported size (unknown sizes sort last).
Use the **Favorites** sidebar destination and the star in a cover's upper-right
corner to keep a local list. The star appears when you hover over or select a
cover; the sidebar star animates when the Favorites list changes.
The game library lists managed Windows Steam and verified Ubisoft Connect
installations. Each configured launcher has its own sidebar row. Ubisoft games
appear in **All Installed Games** and the **Ubisoft Connect** source view in the
same portrait cover layout as Steam. Ubisoft's registered game icon appears in
the cover placeholder; verified Ubisoft Store edition packshots appear for
explicitly mapped game IDs when available. Offline or unavailable artwork
returns to the icon/title placeholder. Steam's transparent mark appears on
Steam covers and compact table thumbnails. The launcher marks sit at the
lower-left of covers; a ready cover's hover Play control sits at the lower-right.
Steam Favorites, per-game compatibility settings, uninstall and reported-size controls apply
only to Steam games. Gamekit remembers browsing preferences;
installed games, saves, graphics overrides and imported profiles are preserved.
The original game-case app icon comes from the approved
[editable SVG](https://github.com/EndofLineTech/gamekit/blob/dev/docs/design/library-v1/icon-case.svg);
its asset-generation instructions are in the
[design README](https://github.com/EndofLineTech/gamekit/blob/dev/docs/design/library-v1/README.md#icon-review).
Use arrow keys to move between focused covers or adjacent table rows; Home/End
move to the first/last game. Return or Space selects and opens the inspector;
movement alone does not start a game. Hover a ready cover for its Play button;
**Command-F** focuses the native toolbar search field, and
Escape collapses the inspector. Clicking a title or row once also selects;
double-clicking a ready title requests Play once.
Hover over buttons, including icon-only controls, for a description of their action.

**Settings** (Command-comma) replaces the sidebar with **General**, **Game
defaults**, **Launchers**, **Storage** and **Diagnostics**. **Back to Library** returns to your
previous library filter. The Settings category sidebar appears even if you hid
the library sidebar; collapsing Settings does not change the saved library
preference, and Back to Library stays in the toolbar. Shared graphics and
fullscreen-Space defaults are under **Game defaults**. **Settings → Launchers**
holds Steam setup/recovery, prerequisite checks, validated runtime selection
and rollback, Launch/Show/Stop, and the managed environment summary together.
Archive/cache inspection and the steamapps Finder shortcut are under **Storage**;
logs and safe exports are under **Settings → Diagnostics**. Successful managed Steam setup
returns from Settings → Launchers to the library; if it is empty, install games
within Windows Steam.
Changing destinations does not stop Steam or cancel a launch being observed.
Setup, library and Steam status remain visible near their controls and in the
window status area. **Diagnostics** beside a status routes to the related local
operation when one was recorded, without putting raw logs in the library.

### Ubisoft Connect setup

**Settings → Launchers** also offers a separate managed Ubisoft Connect
environment. Install uses the pinned official Windows installer and requires
successful runtime checks; it never installs into the Steam prefix. If setup
is interrupted, use the stage-specific **Retry Ubisoft installer** or **Verify
Ubisoft Connect** action instead of repeating a fresh install. **Launch Ubisoft
Connect** opens its own window for you to sign in; Gamekit never reads your
password. **Show** brings that verified client forward, while **Stop** shuts
down only its owned Wine environment. Ordinary Gamekit Quit leaves it running.
If the owned client exits on its own, a brief **Starting** status settles to
**Stopped** after Gamekit confirms the environment has been empty for five
seconds; **Launch Ubisoft Connect** then becomes available again.

After a game finishes installing in Ubisoft Connect, use **Refresh** in Gamekit's
All Installed Games or Ubisoft Connect view. Gamekit matches Ubisoft's registered
install ID and uninstall title/location to files in its own managed prefix; it
does not enumerate your account, infer installed games from Library tiles, or
report an estimated disk size. Selecting a Ubisoft game opens its inspector.
When the owned client is running and its install record is current, **Play**
in the inspector or the cover's lower-right hover control sends one request
through that client. A request is not proof of gameplay; check the game's
window. If Ubisoft is stopped, last-known entries remain visible but
Play stays disabled until you launch Ubisoft Connect and the record is verified.
See [Ubisoft game discovery](ubisoft-game-catalog.md) for evidence and limits.

### Debug capture

Under **Settings → Diagnostics**, enable **Debug mode — capture game startup
performance** before launching a game from Gamekit. It records up to 60 seconds
of read-only CPU, memory and disk-I/O counters for one identified owned game
process. **Stop debug capture** stops only the sampler. Debug mode starts off
on each fresh app launch.

Read the resulting **performanceCapture** record using **View local output**;
**Open local logs** reveals the private records. Summary exports omit the raw
counters. No screenshots or shader hooks are enabled. See
[debug capture details and retained developer tools](debug-performance-capture.md).

### Helldivers driver alert

Select Helldivers, open the inspector's **gear icon** for compatibility settings and
use **Avoid the virtual-GPU driver warning** to enable or disable the workaround
for that game. It requires
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
**Stop Windows Steam**, then choose **Metal 3 compatibility** in the shared
graphics backend dropdown under **Settings → Game defaults**. This is the default for
Windows Steam and games with no override, and survives app and Steam restarts.
Each game's compatibility sheet has its own dropdown: **Use shared default**,
**Automatic (Apple default)**, or **Metal 3 compatibility**. It shows the
effective next-launch backend. Changing it affects only that game, including
launches from managed Steam. **Automatic (Apple default)** restores Apple's default
backend using the same stopped-session flow. See
[persistent graphics settings](persistent-graphics-backend.md) for scope and verification.
See [per-game backend overrides](per-game-graphics-backends.md) for inheritance
and migration details.

The dropdown also lists optional **DXVK** and **DXMT** Direct3D 10/11 backends.
They are disabled when their qualified payloads are unavailable. See
[graphics backends](graphics-backends.md) for installation, tested Satisfactory
launch options and rollback. Keep an Apple backend for Direct3D 12 games.
For Satisfactory, DXMT passed hands-on gameplay and save/reload testing with
temporary stuttering reported; the tested DXVK payload was unplayable and is
not recommended. The Apple/Metal 3 path remains the accepted default. See
[Satisfactory gameplay results](satisfactory-backend-gameplay.md).

For Helldivers 2, keep **Metal 3 compatibility**: testing `--use-d3d11` with both
installed alternatives still ended in startup crashes, with logs showing a
rejected D3D11 feature-level `12_0` request. See the
[Helldivers DX11 findings](helldivers-dx11-backends.md).

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

After Play, Gamekit tracks Steam's fresh launch events for up to two minutes.
It distinguishes a queued request, preparation, Cloud synchronization, prompts
needing attention, and reported process creation. Use **Settings → Launchers →
Show Windows Steam** to resolve Steam's own prompts. Gamekit never automatically retries Play,
accepts a Cloud conflict, or disconnects another session. Play controls unlock
after tracking ends; if startup is unconfirmed, check Steam before trying again.
See [cold-start launch feedback](cold-steam-game-launch.md).

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

Install games using **Windows Steam**, in its default managed library. **All
Installed Games** shows Steam's installed records as portrait covers or list rows.
Click once to select a game and open its inspector; click the **Play** triangle
there or on a hovered ready cover to send a launch request. When the owned game
process is observed running, the control becomes a **Stop** square for that
game alone; save your progress first. Stop requests termination of only its
verified processes; check the game window afterward. Windows Steam and other
games remain open. If process ownership
cannot be verified, the control is disabled instead of assuming the game has
stopped. The inspector's
star toggles Favorites, the folder opens game files in Finder, and the trash
requests uninstall. Double-clicking a ready game is a shortcut. Neither
switching views nor browsing Settings sends Play. Gamekit shows
each title with artwork, status, and its Steam-reported installed size. The
size may be unavailable while a download or update is incomplete, if game files
are missing, or if Steam has not recorded a valid size. It is not a measurement
of saves, shader caches or other files outside the game directory. The list
refreshes every three seconds, when Gamekit becomes active, or with **Refresh**.
On a library read error, last-known entries may remain visible as stale, but
Play, uninstall and file-reveal actions stay disabled until a successful refresh.
Use **View diagnostics** for further context. Uninstalled titles disappear after
a complete scan.

**Open steamapps folder** under **Settings → Storage** opens the managed Windows
Steam library directory in Finder. Installed game files are under its `common`
subfolder. Windows Steam does not need to be running to use this button.
For a ready individual game, **Open game files in Finder** in its inspector or
context menu rechecks the current managed manifest and folder first. Per-game
graphics and fullscreen-Space choices are summarized as **next launch** values
in the inspector; its gear icon opens the full editable compatibility sheet.

To uninstall, select the game and click the trash icon in its inspector (or use
the game's context menu), then choose **Continue in Windows Steam**. Steam opens
its uninstall flow; review and confirm
or cancel there. Gamekit brings the owned Steam window forward for confirmation,
starts managed Windows Steam if needed, and updates the
tile list after Steam removes the installation record. **Cancel** in Gamekit's
confirmation sends no request. Incomplete or missing-file installations also
offer Uninstall, provided the runtime and Steam controls are ready.

An **Uninstall requested** message means the request was sent, not that removal
finished. Use **Show Windows Steam** if its prompt is hidden. Steam controls
which files are removed; Gamekit does not directly delete game folders or saves.
See [uninstall behavior](uninstall-games.md) for details.

Click **Play** in the inspector or double-click a ready game. Gamekit starts its
managed Windows Steam session if necessary and sends that game's AppID to the Windows client. The native macOS
Steam app is not used. A launch-request message means Steam received the request;
confirm the game window, first-run setup and actual gameplay separately.

Incomplete downloads, pending updates and missing game directories disable
Play. Let Steam complete installation or repair it there. Runtime checks and the
shared operation gate also apply to game launches. Steam's installation record
does not prove compatibility or verify every installed game file.

Portrait artwork uses Steam's local portrait cache first and then its public
2:3 Steam CDN image. A missing, corrupt or offline cover shows a title fallback;
the existing landscape header is never stretched into portrait art. Artwork
loading does not prevent browsing or Play.
External Steam libraries and the native macOS library are not scanned in this
version. See the repository's [library contract](https://github.com/EndofLineTech/gamekit/blob/dev/docs/installed-games.md)
for detection and launch details.

New Steam sessions also load Gamekit's small Intel Wine-side helper. The first
Gamekit Play request prepares a game-named Wine bundle so the game uses its own Dock
title while Steam remains **Windows Steam**.
Restart Steam after updating Gamekit to pick up this helper. Keep the app bundle
in place while Steam is running; stop Steam before moving/removing it. The helper
routes the Wine child to that identity and retains the game's Windows-provided icon.
Gamekit's library opts out of Game Mode; the game-named bundle opts in.
macOS controls Game Mode for eligible games and turns it off when a game quits.
See the [Dock identity contract](https://github.com/EndofLineTech/gamekit/blob/dev/docs/game-dock-identity.md)
for scope and validation.

## Per-game compatibility

Select a game and click the gear icon in its inspector.
Every ready installed game offers an independent graphics-backend override and
displays its effective next-launch choice. **Use shared default** follows the
shared selection under **Settings → Game defaults**; explicit
Automatic or Metal3 choices leave Steam and other games on their own settings.

**Settings → Game defaults** has a **Shared fullscreen Space for games** toggle,
off by default. In each game's compatibility sheet, choose **Use shared
default**, **Use fullscreen Space**, or **Keep on desktop** independently of its
graphics choice. Only a managed game window covering a display can enter a
separate macOS Space; a smaller/windowed game remains on the desktop even when
the setting is on. Gamekit does not change the game's own fullscreen setting or
resolution. Stop Windows Steam before changing the shared or per-game choice;
saved per-game choices override the shared default.

Helldivers 2 additionally offers the validated **Fullscreen display capture**
override for the Dock-edge cursor issue:

- **Enable capture** saves the game-specific override.
- **Disable capture** explicitly disables it for this game.
- **Restore capture default** removes that override and inherits Wine's global
  setting (disabled when no global override exists).

The panel shows the saved override, inherited setting and effective capture state.
Select **Fullscreen** inside Helldivers itself. The capture controls do not change
its resolution or suppress the GPU-driver warning.

Helldivers' **Use fullscreen Space** path is validated for its full-display game
window, including behind the notch. Keep the game's own Fullscreen mode selected.
Stardew's existing borderless window also passed a separate-Space and automatic
foreground check on this Mac's built-in display. The Space closes with the game.
Other games have the same controls, but their window sizes and focus behavior
have not been individually qualified.

For Stardew Valley's Windows build, the optional **Hide duplicate macOS pointer**
toggle is under **Game cursor guard** in its compatibility sheet. Stop Windows Steam and
its games before changing the toggle, then start a fresh session. It substitutes
a transparent macOS cursor only inside Stardew's owned Wine process while its
window is active; the game's drawn cursor stays visible. Command-Tab to another
app or exit Stardew to restore the normal pointer. Disable the toggle with Steam
stopped to revert.
The revision-5 wiki profile enables the guard by default; an explicit saved Off
choice remains local and takes precedence even after profile updates. The scoped
menu/focus/exit check does not establish a new full gameplay/save-reload pass
with the guard enabled.

Stop Windows Steam and all its games before making changes; launch a fresh session
after saving. The existing accepted override is displayed as-is on first use.
For capture, Gamekit reads the saved registry, changes only the supported
app-specific value, and verifies it after saving. Driver and Space preferences
are stored separately in Gamekit metadata, as are the shared Space default and
cursor guard preference.
Other registry settings, saves, runtime binaries and launcher caches are preserved.
Unsupported or ambiguous registry values are refused. The driver and display
capture fixes remain profile-qualified for Helldivers.

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

Under **Settings → Storage**, choose **Inspect recovery archives** to list each
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

Use **Settings → Storage → Inspect launcher caches** to review game launcher
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
