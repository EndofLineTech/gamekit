# Gamekit library — design review 01

Epic: `gamekit-vwq`; drafts for `.1` navigation, `.2` component/contracts and
`.3` icon concepts. **Awaiting owner approval.** These are design artifacts, not
a replacement Gamekit application or evidence of new launcher support.

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
- The marks are illustrative vector approximations for review. Production should
  use approved launcher brand assets and applicable usage rules. The app-icon
  concepts are original editable SVG artwork, separate from launcher branding.
- Configured launchers filter the library; launcher setup/lifecycle lives under
  Management. Only Windows Steam exists in the current product. Ubisoft and Epic
  entries in this prototype explicitly preview future integration. Delivery order
  is Ubisoft, Epic, Battle.net, GOG; the latter two appear as planned providers.
- Satisfactory appears twice deliberately, once per sample launcher installation.
  Do not silently merge ownership, settings or install locations by title.
- All cover compositions, game sizes, counts and operational states are sample
  design data. These are original geometric placeholders, not licensed box art
  or a scan of the user's machine. Real cover acquisition is a separate bead.

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
   buttons at the owner's request. Detail refinement awaits review.
2. [Collection](icon-stack.svg) — layered cases with a play motif.
3. [Toolkit](icon-toolkit.svg) — emphasizes compatibility tooling.

The review page shows each at large, 64, 32 and 16 pixel sizes on light and dark
backgrounds. These are concept vectors, not final macOS icon assets. Production
requires small-size optical refinements, appropriate macOS variants, and a
current-Xcode/Icon Composer assessment before asset catalog/build integration.

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
Remaining **major** specification work: full setup/recovery and compatibility
sheets; **minor** work: native keyboard-grid behavior, remembered per-library
scroll positions and detailed loading announcements. Browser checks do not replace
VoiceOver, native window or packaged-app acceptance. These are approval drafts,
and the epic and its children remain open for feedback.
