# Gamekit library — design review 01

Epic: `gamekit-vwq`. **Owner approved the visual/navigation direction and the
revised game-case icon.** Children `.1` and `.3` are closed; `.2` still covers
implementation-detail specification. These are design artifacts, not a replacement
Gamekit application or evidence of new launcher support. See [the implementation
handoff](HANDOFF.md) before starting work.

## Open the mockup

Open [index.html](index.html) directly in a browser; it uses local SVG files and
needs no server or network connection. Keep this directory together when sharing.

```sh
open docs/design/library-v1/index.html
```

Try grid/list switching, selecting a game, searching, launcher filters, favorites,
the inspector, Settings, and the **Icon concepts** button. The review bar switches
appearance and loading/empty/offline/error scenarios. Settings and game actions
are simulated; no game, launcher, user preference or filesystem is modified.
Mockup preferences last only for the browser session; persistence is a production
requirement, not implemented in this artifact. Some advanced actions explain the
intended flow rather than opening a fully designed sheet.

## Design decisions and latest feedback

- Default destination: **All Installed Games**, art-led grid; list is an equal
  alternative with the same selection, filtering and actions.
- A single click selects and opens the inspector. Play is explicit; double-click
  is a shortcut. Context-menu and arrow-key grid behavior remain implementation
  requirements rather than completed prototype interactions.
- **Settings replaces the left library sidebar** with General, Game defaults,
  Runtime and Storage. **Back to Launchers** returns to the launcher-management
  destination. This owner-requested navigation supersedes the initial separate
  Settings-window proposal. The macOS Settings menu/Command-comma should enter
  this same destination in production.
- **Transparent launcher marks appear in the upper-left artwork corner**, without
  an opaque badge; favorites occupy the upper-right. Launcher text remains below
  covers and in list columns so meaning never relies on the mark alone.
- The owner clarified after native review that the artwork mark should be the
  actual launcher's icon, not an abstract source glyph. Production uses the
  transparent Steam icon for Windows Steam in grid and table. The older mockup's
  drawn marks remain illustrative; the app-icon concepts remain separate
  original editable SVG artwork.
- Configured launchers filter the library; launcher setup/lifecycle lives under
  Management. Only Windows Steam exists in the current product. Ubisoft and Epic
  entries in this prototype explicitly preview future integration. Delivery order
  is Ubisoft, Epic, Battle.net, GOG; the latter two appear as planned providers.
- Satisfactory appears twice deliberately, once per sample launcher installation.
  Do not silently merge ownership, settings or install locations by title.
- All cover compositions, game sizes, counts and operational states are sample
  design data. These are original geometric placeholders, not licensed box art
  or a scan of the user's machine. Real cover acquisition is a separate bead.
- Delivery scope is **the existing Steam UI only**. Implement this visual design
  using native SwiftUI/AppKit and current core services. Do not ship the mockup's
  Ubisoft/Epic sample entries or add launcher integrations. Generalized provider
  execution architecture is deferred; retain only the source-aware identity and
  presentation boundaries useful to the redesign.

## Screens and service responsibilities

The real implementation uses native SwiftUI/AppKit over `GamekitCore`, not a web
view or new HTTP backend. Proposed names below are contracts, not existing APIs.

| Surface | Data / action contract | States and behavior |
| --- | --- | --- |
| Library sidebar and toolbar | Application-scoped library snapshot, provider instances, local preferences | Filter installed entries by source/favorite/state; search and sort without triggering a new launch |
| Cover grid / table | Stable installation ID, title, source, state, reported bytes, artwork reference | One selection model; unknown size distinct from zero; refresh cannot discard focus or selection |
| Inspector | Selected installation, provider capabilities, resolved profile, saved overrides | Play enabled only by authoritative readiness; refresh/prepare/Cloud attention/process-created distinct; unsupported actions omitted |
| Launchers | Provider-instance status and setup/show/start/stop/recovery capabilities | Explain Stop scope; future providers unavailable; absent launcher leads to setup, then library |
| Settings | Local browsing preferences and shared runtime/game settings services | Preserve graphics, Space and cursor choices; enforce existing operation/session locks at service boundary |
| Diagnostics | Existing private diagnostic store and safe summary exporter | Context link from failure; preserve redaction, capture lifecycle and ownership |
| Artwork | Provider-aware cache keyed by installation and artwork kind | Portrait separate from header; no stretching; placeholder on failure; bounded memory/downloads |

Identity is `(providerID, launcherInstanceID, providerGameID)`. A provider game ID
is opaque, not universally a Steam AppID. Existing Steam execution/profile code
stays scoped to Steam until an explicit provider-specific contract exists.

Operation coordination survives navigation and view changes. Selecting another
launcher must not kill a session, lose its launch observation or resend Play.
On read errors, cached entries may remain visible as stale but execution needs
fresh ownership/readiness checks. With no games, guide to setup/install; with no
search matches, offer clear filters. Offline display does not promise offline
authentication or gameplay. Uninstall remains provider-mediated and confirmed.

## Native implementation specification

- Default window target: approximately 1200×800 points, resizable; collapsible
  sidebar about 210–240 points and inspector about 280–320. At narrow widths the
  inspector becomes an overlay/panel. Final minimum size is subject to testing.
- Use system typography and semantic colors/materials; the prototype's CSS colors
  illustrate the intended indigo accent and restrained chrome, not a replacement
  for native controls. Primary content spacing 24–32 points, control groups 8–12.
- Portrait art is 2:3; tile size adjustable. Retain readable titles and source/size
  labels below the art at every size. Textual launcher labels supplement marks.
- Keyboard: Command-F search, Command-comma Settings, Escape dismiss inspector;
  production grid arrow navigation and explicit Play shortcuts must avoid
  conflicts with text fields. VoiceOver announces title, launcher, state and size.
- Remember view mode, sort, cover size and favorites locally in the real app.
  This mockup demonstrates transient changes only. All Installed Games remains
  the startup destination regardless of last launcher filter.
- Preserve visible feedback through loading, partial installs and errors. Do not
  equate a process-created event with gameplay readiness or label Steam-reported
  sizes as exact total physical disk usage.

## Icon review

1. [Game case + controller](icon-case.svg) — owner-selected direction; library-first
   identity. Revised with two analog sticks, four face buttons, a D-pad and center
   buttons at the owner's request; this revision is approved.
2. [Collection](icon-stack.svg) — layered cases with a play motif.
3. [Toolkit](icon-toolkit.svg) — emphasizes compatibility tooling.

The review page shows each at large, 64, 32 and 16 pixel sizes on light and dark
backgrounds. These are concept vectors, not final macOS icon assets. Production
requires small-size optical refinements, appropriate macOS variants, and a
current-Xcode/Icon Composer assessment before asset catalog/build integration.

The approved vector now generates the macOS `AppIcon` asset catalog at
`App/Assets.xcassets/AppIcon.appiconset/`. Regenerate after editing the vector:

```sh
NODE_PATH="$PWD/.build/wiki-browser/node_modules" \
  GAMEKIT_DESIGN_BROWSER="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  node tools/generate_app_icon.cjs
```

Playwright and Chrome are used only to render the checked-in PNGs; neither is
bundled with the application. Xcode 27 includes Icon Composer, but the approved
single-layer SVG does not require an Icon Composer document to ship a standard
macOS asset catalog. Keep the SVG as the source and inspect the built app icon
at Finder/Dock/Command-Tab sizes in both appearances after building.

## Verification and remaining design gaps

`capture.cjs` exercises navigation, launcher filtering, search including duplicate
titles, view/selection retention, favorites, settings navigation/back, artwork
marks, simulated preferences and error/empty/offline/loading states. It emits
11 screenshots under `.build/library-design-v1/` and checks for JavaScript errors
and horizontal overflow at a compact window size. Generated screenshots are
private local review artifacts; the HTML and SVG sources are versioned.

With Playwright available locally:

```sh
NODE_PATH="$PWD/.build/wiki-browser/node_modules" \
  GAMEKIT_DESIGN_BROWSER="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  node docs/design/library-v1/capture.cjs
```

Omit `GAMEKIT_DESIGN_BROWSER` to use Playwright's installed Chromium. No runtime
dependencies are added to Gamekit. Reviewer checked grid/inspector and icon/Settings
captures in addition to the automated smoke checks.

Heuristic review: library-first hierarchy addresses the current major information
overload; visible source labels and separate duplicate-title installations improve
recognition; explicit Play and provider-mediated uninstall preserve user control.
Browser checks do not replace VoiceOver, native window or packaged-app acceptance.
The visual direction is approved; the shipping interaction contract follows.

## Steam-only native interaction contract (`gamekit-vwq.2`)

### Navigation, identity and operation lifetime

- Start every app launch at **All Installed Games**, even if the previous session
  ended in Settings or with a Steam filter. Keep one stable installation key per
  managed Steam environment and AppID; never select, favorite or launch by title.
  The initial source filter is only **Windows Steam**. Do not show future-launcher
  cards, counts, authentication or configuration in the shipped UI.
- Keep the shared `SetupModel` operation gate, installed-library refresh/launch
  observer, installation coordinator and Steam lifecycle owner alive at window
  scope while navigating. A destination switch hides a screen, not its work:
  do not cancel a running install, lose a Steam prompt/launch message, call Play
  again or release backend ownership. Backend leases, fresh readiness and process
  ownership checks remain authoritative. Quit leaves Steam/games running; Stop
  explicitly stops the managed session and may close its games.
- Library grid, list, Favorites and Steam filter share one selection, query,
  installation-state filter and sort. Switching views or refreshing records
  retains the selected key and keyboard focus when it still exists. If a record
  disappears after a successful full scan, clear its selection and show the
  select-a-game inspector prompt. A temporarily unreadable scan must not imply
  removal. Keep per-destination scroll offsets in window memory across navigation
  and grid/list changes, restoring to the selected item when the collection
  changes; a new app launch may begin at the top. Persist view mode, sort, cover
  size and favorites locally without rewriting Steam manifests or profiles.
  Clearing filters clears the query and state filter, not favorites or sort.
- Settings/Command-comma opens the **in-window** Settings destination and replaces
  the *left sidebar* with General, Game defaults, Runtime and Storage. **Back to
  Launchers** always opens launcher management. Library selection is retained
  for return from other destinations; the inspector is visible only in library
  destinations. Command-F enters library search (navigating to All Installed
  Games first if needed), selects its text and does not launch anything.

### Library controls and accessibility

- A single click on a cover or list row selects it and opens the inspector;
  repeated single clicks do not Play. Double-click on a ready record and the inspector's
  explicit Play button each dispatch **one** launch request through
  `SteamLifecycle.launchGame(appID:)`, gated by `SetupModel.begin` and readiness.
  Ignore subsequent double-click/shortcut requests while one is being handled or
  observed. Return/Space on a focused item selects/opens the inspector; the
  focused inspector Play button uses Return/Space to Play. Do not bind an
  unmodified global Return, Space or letter shortcut to Play. Arrow keys move
  focus by a row/column in the grid (respecting the current column count), by
  adjacent row in the list; Home/End go to first/last. Movement alone never
  launches and is ignored while typing in a text field or using a picker.
- The item context menu exposes **Play** only when ready, **Show Windows Steam**,
  **Compatibility settings…**, **Add/Remove Favorite**, and **Uninstall…** when
  applicable. Play and uninstall use the same guarded actions as the inspector;
  unavailable actions explain readiness rather than silently retrying. A
  confirmation precedes the Steam-mediated uninstall request, and Steam owns its
  final confirmation. Escape closes a sheet/menu or collapses the inspector,
  returning focus to the selected item; it does not cancel install or launch
  observation. Focus stays visible when a tile is selected.
- Use a true 2:3 portrait image or a readable original placeholder; never stretch
  the existing landscape header. Show a transparent Steam mark at upper left and
  the favorite control at upper right, with no opaque mark backing. Source text
  below the cover/list column supplements the mark. VoiceOver reads title, Windows
  Steam, installation state and **Steam-reported** size (or unavailable), then
  selected/favorite state and available actions. Do not equate a sum of known
  Steam-reported sizes with physical disk use; unknown is not zero.

  **Updated owner direction:** The corner mark identifies the actual launcher.
  For this Steam-only release, `App/Assets.xcassets/SteamLauncherMark.imageset/`
  contains the transparent Steam icon (from [Simple Icons, pinned SVG](https://github.com/simple-icons/simple-icons/blob/521c96fd04b0ea93034db8715eda5a4de27a58bb/icons/steam.svg),
  CC0 1.0). The earlier nonbranded managed-window glyph was not recognizable
  as Steam and is superseded. Keep “Windows Steam” text below the cover and in
  table/VoiceOver text; the icon is not an action or status indicator.
  Portrait art is fetched by validated numeric AppID from Steam's own local
  cache or `https://cdn.akamai.steamstatic.com/steam/apps/{AppID}/library_600x900.jpg`;
  this 2:3 resource was checked against the live Steam CDN. No game artwork is
  bundled. Failed/offline downloads show the original title fallback.

### Inspector and full compatibility sheet

- Inspector shows selected installation, Steam source, authoritative state,
  optional reported bytes, launch progress, favorite, Show Steam, confirmed
  uninstall, and the existing per-game graphics/Space choices. Not-ready games
  offer Show Steam rather than Play. Read errors leave last-known entries visible
  as stale but disable execution until ownership/readiness is checked afresh.
- **All compatibility settings…** opens a scrollable native sheet for that AppID,
  retaining `GameCompatibilityView`'s full capabilities: resolved bundled/wiki/
  locally imported profile source and notes, Profile JSON link, explicit update,
  JSON import/export and restore automatic profile; effective/shared/overridden
  graphics and fullscreen Space; backend-specific launch options; profile-gated
  driver compatibility, capture (inherit/enabled/disabled) and cursor guard;
  saved-setting refresh, status and Done. Show profile guidance and apply changes
  to the *next* launch only. Hide unsupported profile-defined controls instead
  of inventing generic per-title toggles. Imported profiles take precedence over
  wiki refresh; explicit overrides (including Off) take precedence over defaults.
  Keep current session locks and `GameCompatibilityStore` inspection/setters;
  don't dismiss or reset a sheet when a background library refresh occurs.

### Launchers, setup, Settings and diagnostics routing

| Destination | Existing UI/service contract to carry forward |
| --- | --- |
| Launchers → Windows Steam | `SteamLifecycleView` status plus Launch/Show and Stop, using `SteamLifecycle.status/launch/show/stop` and the existing owned-window focus handoff. Explain Stop scope and ordinary Quit. Browse games opens the Steam filter. |
| Launchers → Setup & recovery | `SetupView` prerequisite report/refresh and `SteamInstallationView` staged install, verification, retry and cancel. Keep stage/status feedback across navigation. Retry inspects saved state; it is not a reset. Preserve force-stop-interrupted-setup and its confirmation. |
| Setup & recovery → reset options | Explicitly expand preserve-downloads versus delete-downloads choices before their *separate* destructive confirmations. Preserve the current messages about archived prefix, sign-in, saves, external libraries, incomplete operations and ownership locks. No automatic cleanup, reset or response to Steam prompts. |
| Settings → General | Local library preferences (view mode, sort, cover size). Startup remains All Installed Games. Follow system appearance; do not replace macOS appearance controls with the mockup's review toggle. |
| Settings → Game defaults | Existing shared graphics backend and fullscreen Space in `SetupModel`/`RuntimeSettingsStore`; session and operation locks apply. Per-game settings remain in inspector/sheet and override shared choices. |
| Settings → Runtime | `SetupView` validated-runtime selection, updated/text-input/original rollback choices, prerequisite refresh and links; retain saved environment details from `EnvironmentSummaryView`. |
| Settings → Storage | Managed steamapps Finder shortcut; `RecoveryArchivesView` inspection and confirmed completed-archive cleanup; `LauncherCachesView` inspection and confirmed obsolete-cache cleanup. Show logical bytes as such. Keep recovery reset in Launchers → Setup & recovery, not an unlabeled storage cleanup. |
| Diagnostics | `DiagnosticsView` local summaries/output, debug capture toggle/stop, local log opening and safe JSON export with existing redaction. Route failures here without leaking raw logs into the library. |

### Loading, failures and announcements

- Distinguish no registered Steam setup (route to Launchers), an installed Steam
  library with no games (open Steam to install), zero search/filter matches (clear
  filters), partial install/update and missing files (Show Steam), and unreadable
  manifests (warning, not an empty library). Initial scan has a progress label;
  subsequent refreshes preserve artwork/selection and indicate stale results on
  failure. Offline artwork retrieval uses a placeholder; connectivity alone
  does not promise offline Steam authentication or game execution.
- Show one persistent, accessible status near the relevant control and in the
  window operation banner. Announce *transitions*, not every one-second poll:
  scan started/completed or failed, operation acquired/completed or failed, Steam
  prompt requiring user attention, and launch observation ended. Do not call a
  process-created event a gameplay pass. For Cloud/other-session/user attention,
  offer **Show Windows Steam** and leave the decision to the user; when tracking
  times out, say that Steam may still be starting and ask users to check Steam
  before requesting Play again. Disabled controls expose their reason to
  VoiceOver. Never clear an actionable error solely because a screen changed.

This contract maps to the current `InstalledGamesView`, `GameCompatibilityView`,
`SteamLifecycleView`, `SteamInstallationView`, `SetupView`, `DiagnosticsView`,
`RecoveryArchivesView`, `LauncherCachesView`, `SetupModel` and their existing
`GamekitCore` services. It specifies native shipping behavior; mockup simulated
actions and sample installations are not test fixtures or acceptance evidence.
