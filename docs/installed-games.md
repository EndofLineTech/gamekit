# Installed Windows Steam games

User-requested feature `gamekit-cmm`, introduced while starting E6.2. The native
list reads the registered managed Windows Steam environment; gameplay evaluation
remains a separate outcome.

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
  records produce a visible count while valid records remain available; an
  unreadable library clears the list and reports the problem.
- The native model scans off the main actor every three seconds, on app activation
  and on explicit refresh. It pauses while a shared operation is active. Names
  sort naturally, and removal of a manifest removes the corresponding tile.

## Artwork and interaction

Tiles contain a game title, installation state, header image and play symbol, with
a named accessible button and native keyboard focus. Images are decorative to
accessibility because the button already names the game.

Artwork is read from `appcache/librarycache/<AppID>/header.jpg`, falling back to
the older `<AppID>_header.jpg` cache naming. Each local image read is bounded to
256 KiB and uses the same no-follow file access. Missing, oversized or undecodable
artwork falls back to an HTTPS request for
`https://cdn.akamai.steamstatic.com/steam/apps/<AppID>/header.jpg`. Only a numeric
AppID selects the remote resource; manifests cannot supply arbitrary URLs. A
controller symbol plus title remains usable when artwork cannot load. Remote
artwork uses the platform image loader and its normal caching behavior.

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

Core regressions cover nested/escaped KeyValues, ambiguous/malformed/oversized
records, AppID mismatches, installation flags, missing directories, redirected
paths, local artwork, uninstall refresh and scoped launch dispatch/refusal.
Native UI regression covers named game tiles, prerequisite gating and disappearance
after uninstall. Read-only real-library inspection can be run with:

```bash
GAMEKIT_LIBRARY_INSPECTION=1 swift test --filter SteamGameLibraryTests.liveLibrary
```

Live acceptance requires installing a real game through the managed Windows Steam
client, observing its artwork tile, launching it from Gamekit with Steam stopped
and already running, and confirming the expected game window. E6.2 separately
records graphics, input, audio, saves, performance and repeatability.
