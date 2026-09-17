# Running-game Dock identity

`gamekit-6h9` follows the installed-game tiles and VC++ prerequisite correction.
The user observed Satisfactory's bootstrapper and game both presenting Dock
entries named **Windows Steam**. Fixing the repeated VC++ dialog removed the
extra foreground bootstrapper entry; the actual game still inherited the shared
Wine loader's name.

## Filesystem identity and early routing

Dock uses the display name of the executable/app bundle on disk. Changing
`LSDisplayName` successfully changed the application registry but **did not**
change the visible Dock label. A direct Accessibility check reproduced that gap.
Wine mac-driver author Ken Thomases describes the distinction in
[this Dock-label explanation](https://stackoverflow.com/a/28825109) and
[this filesystem-identity explanation](https://stackoverflow.com/a/26452198).
Setting the process name earlier also failed the visible-Dock check.

When a game tile is launched, Gamekit prepares a separate derived Wine bundle at
`Launchers/Games/<AppID>/shared-pe-v2/<safe game name>.app`. Its bundle and loader
are named for the game. The source Wine/graphics payload remains unchanged.
Filesystem names replace unsupported separators and are bounded to 120 UTF-8
bytes. Existing modified caches are refused, not overwritten.

Gamekit embeds the signed **x86_64** helper
`Contents/Frameworks/WineGameIdentity.dylib` for the Intel Wine runtime; the app
itself remains arm64. The managed environment supplies this helper through
`DYLD_INSERT_LIBRARIES`, excluding arbitrary inherited loader settings.
Before Wine initializes a child, the helper matches its Steam AppID or Windows
image path to an installed game and re-execs the byte-identical Wine loader in
that game's prepared bundle. It preserves arguments, environment and the inherited
Wine server socket. A one-shot routing marker is removed before Windows children
are created. Generic children can return to the default Windows Steam loader.

Both loader paths must lie beneath the managed `Launchers/` root; reads refuse
symlinks, require owned regular files and compare the complete bounded loader
bytes before routing. Failure leaves the original Wine invocation intact. The
helper no longer uses Launch Services name-changing SPI or a polling GUI hook.
Steam still owns game launch, and Windows/Wine supplies the game icon.

### Shared Windows image identity

Separate PE DLL copies initially caused a Satisfactory bootstrap crash: the
Steam process and game received different `ntdll` mapping addresses. The runtime
probe reproduced the difference. Game bundles now hard-link their Windows PE
directories to the validated Windows Steam cache, preserving inode identity and
shared image addresses. Unix loader/engine paths remain game-specific. Validation
checks those shared identities and symlink targets; the runtime does not modify
these immutable PE files. The image comparison now confirms identical Steam/game
`ntdll` and thread-entry addresses, and actual Satisfactory startup passes.

Process observation includes the game-bundle cache, with the same exact prefix
and session-tag checks as Steam. Scoped Stop therefore still finds routed game
processes. No game executable or prerequisite installation marker is patched.

## Identity map

`Metadata/GameDock/<environment>.json` stores schema version 1, the exact prefix,
the current session token, an AppID-to-title map and corresponding Windows install
directories and prepared loader paths from validated Steam manifests/caches.
It is private runtime metadata, not an exportable diagnostic or a launch receipt.

The lifecycle writes it atomically under existing installation/execution leases
before a new Steam session or game launch. The installed-games view updates it
when its library snapshot changes while Gamekit is open. The reader requires
matching prefix/session, reads at most 1 MiB without following symlinks, and accepts
only bounded non-control-character titles from a map of at most 512 games. IDs
must be positive UInt32 values. The path fallback reads only the current process's
first three arguments using `KERN_PROCARGS2`, accepts executable descendants of one
mapped directory, and rejects traversal, sibling-prefix collisions and ambiguous
matches. Invalid or unrelated input leaves the process unchanged.

The first Gamekit tile launch prepares the named bundle. Games started directly
from Steam before preparation can retain the generic name. Already-running
processes cannot acquire a different loader identity retroactively. Old cache
revisions are retained separately rather than replaced while potentially in use.

## Updating and verification

Save and exit games, **Stop Windows Steam**, then start a fresh session using the
new Gamekit build. Quitting/reopening Gamekit alone retains the old client's
environment. Keep the app bundle at its current location while that Steam session
is running: its child processes use the embedded helper. Stop Steam before moving
or removing the app bundle.

Unit tests exercise session/prefix binding, stale-map replacement, environment
isolation, invalid IDs/names/JSON, bounds, path boundaries, shared PE identity and
symlink refusal. A standalone native probe verifies named-loader routing and
refusal of changed or external loader bytes. An opt-in test exercises the actual
embedded Intel helper under Rosetta:

```bash
GAMEKIT_IDENTITY_X86_HELPER="$PWD/.build/game-dock-xcode/Build/Products/Debug/Gamekit.app/Contents/Frameworks/WineGameIdentity.dylib" \
  python3 -m unittest discover -s tests -p test_game_dock_identity.py -v
```

The packager verifies the main arm64 executable and the embedded x86_64 helper,
records both hashes, and verifies both copies and the app's code signature.
Live acceptance must confirm **Windows Steam** plus one **Satisfactory** entry,
correct game artwork, repeated launch/exit, normal Gamekit Quit/reopen and scoped
Stop. Native probes alone do not establish Wine-child inheritance or gameplay.

Live inspection found no native `SteamAppId` on Satisfactory, so the image-path
fallback is required. The seven-second Windows GUI probe is spawned by a Windows
parent and checks the real **visible Dock label**, not only the application
registry. It uses a temporary mapping/executable and removes its own probe bundle:

```bash
x86_64-w64-mingw32-gcc -Wall -Wextra -Werror -static -municode -mwindows \
  -o .build/game-dock-wine-probe.exe tools/game_dock_wine_probe.c -luser32
GAMEKIT_WINE_DOCK_PROBE=1 GAMEKIT_DOCK_AX_TEST=1 \
GAMEKIT_IDENTITY_X86_HELPER="$PWD/.build/game-dock-xcode/Build/Products/Debug/Gamekit.app/Contents/Frameworks/WineGameIdentity.dylib" \
GAMEKIT_WINE_DOCK_PROBE_PATH="$PWD/.build/game-dock-wine-probe.exe" \
  swift test --filter GameDockNamesTests.liveWineName
```

The real Satisfactory acceptance test identifies the actual shipping process,
requires one **Satisfactory** Dock entry, opens Steam and requires one separate
**Windows Steam** entry, then closes the game/session on success or failure:

```bash
GAMEKIT_SATISFACTORY_DOCK_ACCEPTANCE=1 \
GAMEKIT_IDENTITY_X86_HELPER="$PWD/.build/game-dock-xcode/Build/Products/Debug/Gamekit.app/Contents/Frameworks/WineGameIdentity.dylib" \
  swift test --filter GameDockAcceptanceTests
```

This check passed on the recorded Mac with graceful cleanup. It validates launcher
identity, not the full E6 gameplay/performance matrix. Accessibility permission is
required for Dock inspection. User-authorized unattended tests are kept short,
and Satisfactory must not be left running afterward.
