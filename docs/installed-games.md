# Installed Windows Steam games

The native **All Installed Games** grid and table read the registered managed
Windows Steam environment. Selection, installation evidence and gameplay
evaluation remain separate outcomes.

## Detection contract

`SteamGameLibrary.scan` reads `steamapps/appmanifest_<AppID>.acf` beside the
registered Steam executable. It does not infer installation from owned-library
artwork or a directory name. It does not scan macOS Steam or external libraries.
Steamworks Common Redistributables (228980) are omitted.

- The manifest filename and positive UInt32 AppID must agree. Name and install
  directory are validated; nested depot data cannot supply top-level fields.
- Steam's fully-installed state (4), optionally with the app-running bit (64),
  plus an existing `steamapps/common/<installdir>` directory permits a launch.
  Other flags appear as incomplete installation/update. An installed receipt with
  a missing directory appears as unavailable. Steam still verifies/updates its
  own files; Gamekit does not claim file integrity or compatibility.
- Descriptor-relative reads refuse symlinked roots, directories and manifests.
  Manifests are bounded to 1 MiB, nesting to 16 levels, and a scan to 512 ACF
  entries. Duplicate keys and malformed input are rejected. Individual bad
  records produce a warning while valid records remain available. The window
  retains last-known entries on an unreadable or partially unreadable scan, marks
  the library stale, and disables Play/uninstall until a successful full scan.
- The window-owned model scans off the main actor every three seconds, on app
  activation and on explicit refresh. It pauses while a shared operation is
  active. A complete scan removes uninstalled entries; a temporarily unreadable
  manifest does not discard its last-known selection.
- A tile shows Steam's `SizeOnDisk` receipt value as a formatted, decimal byte
  count for complete installs whose game directory exists. Missing, invalid or
  out-of-range sizes and incomplete/missing-file installs show **unavailable**.
  This is Steam-reported installed size, not a recursive measurement or a total
  of saves, shader caches, downloads, or other files outside the game directory.
  Reading the receipt adds no filesystem walk to the three-second refresh.

## Artwork and interaction

The art-led grid uses 2:3 portrait covers, readable titles, Windows Steam source
text, installation status, Steam-reported size and a separate favorite control.
The native table shows a compact portrait beside title, source, state and size.
The upper-left artwork mark is the transparent Steam launcher icon. The
**Windows Steam** text beneath the cover and in the table also identifies the
source. A single click selects and opens the inspector; Play requires an
explicit button or ready-game double-click. Moving focus with arrows or
Home/End never sends Play; Return/Space selects a focused item. Search, source,
installation filters, favorites and deterministic sorting are shared across
both views. Unknown sizes sort after known sizes, including known zero.

Portraits are read separately from Steam's landscape headers, from
`appcache/librarycache/<AppID>/library_600x900.jpg` or the flat cache naming,
with no-follow reads bounded to 1 MiB. Missing or invalid local art may load
from the fixed numeric-AppID-only Steam CDN portrait URL. The shared portrait
cache bounds concurrent downloads, decoded dimensions and retained entries;
failure or offline access leaves the original title fallback and never blocks
Play. Legacy `header.jpg` artwork remains separate and is never stretched into
a portrait.

The inspector reads effective shared and per-game graphics/Space choices for
the **next** launch. The full compatibility sheet retains profile source,
import/export/update, explicit overrides (including Off), cursor-guard and
profile-gated options. A ready game's **Open game files in Finder** action
rechecks the manifest and directory under the managed prefix before opening
Finder; unavailable, stale or redirected locations are not offered. Gamekit
does not expose per-game Stop without an authoritative owned-game control.

## Launch contract

`SteamLifecycle.launchGame(appID:)` checks a fresh installation snapshot, starts
or reuses the owned Windows Steam session, then acquires installation/execution
leases and revalidates the receipt, prefix identity, runtime and process tags.
It rechecks the game immediately before sending:

```text
<selected wine> <managed Steam.exe> -applaunch <numeric AppID>
```

The command carries the existing explicit prefix/session environment and packaged
runtime library paths. It does not execute paths from ACF files or use macOS's
global `steam://` handler. UI clicks share the existing setup/Stop/recovery gate;
backend leases still protect other controllers. A successful command means a
request was sent, not that the game launched or is playable. Steam owns any
first-run dependencies, updates and authentication.

Gamekit does not yet classify game-specific running state or expose per-game Stop.
Normal Quit leaves the session running; **Stop Windows Steam** includes games in
that managed environment.

[Running-game Dock identity](game-dock-identity.md) uses a session-bound title map
and an embedded Wine-side helper. It does not change the game's Steam AppID or
launch route.

## Verification

Core regressions cover nested/escaped KeyValues, malformed/oversized records,
AppID mismatches, installation flags, reported sizes, missing directories,
redirected paths, bounded portrait artwork, safe Finder folder resolution,
uninstall refresh and scoped launch dispatch/refusal. Synthetic libraries
exercise 512 manifest scans and 128-title native search/sort/stale retention
without touching a user's games. Native UI regressions cover grid/table keyboard
selection, filters, favorites, readiness gating and disappearance after uninstall.
Read-only real-library inspection can be run with:

```bash
GAMEKIT_LIBRARY_INSPECTION=1 swift test --filter SteamGameLibraryTests.liveLibrary
```

Live acceptance requires installing a real game through the managed Windows Steam
client, observing its artwork tile, launching it from Gamekit with Steam stopped
and already running, and confirming the expected game window. E6.2 separately
records graphics, input, audio, saves, performance and repeatability.
