# Running-game Dock identity

`gamekit-6h9` follows the installed-game tiles and VC++ prerequisite correction.
The user observed Satisfactory's bootstrapper and game both presenting Dock
entries named **Windows Steam**. Fixing the repeated VC++ dialog removed the
extra foreground bootstrapper entry; the actual game still inherited the shared
Wine loader's name.

## Process-self naming

Gamekit embeds `Contents/Frameworks/WineGameIdentity.dylib`, a small **x86_64**
native helper for the validated Intel Wine runtime. The Gamekit app itself remains
arm64. The helper is built from this repository and ad-hoc signed with the app;
neither the external Wine binary nor Apple's graphics payload is modified.

For managed sessions only, Gamekit supplies its own helper path using
`DYLD_INSERT_LIBRARIES`. Arbitrary inherited loader settings remain excluded.
Steam assigns `SteamAppId` to game children. A child helper uses that numeric ID
to find the installed title in Gamekit's private map, waits for its own regular
GUI application registration, then changes **its own** Launch Services display
name. It does not rename Steam, change another PID, hide applications, patch the
game executable or alter Steam's launch command. Windows/Wine continues supplying
the game icon.

On macOS 27, an external `lsappinfo setinfo` attempt did not update the game name.
A standalone process-self probe succeeded. The helper dynamically resolves
`_LSGetCurrentApplicationASN` (with the alternative symbol spelling as fallback)
and `_LSSetApplicationInformationItem`, using the tested default-session value
and `LSDisplayName` key. These are macOS-specific SPI, not a cross-version promise.
If unavailable, naming remains unchanged; gameplay is not terminated. Polling is
bounded to 120 seconds and does not initialize a GUI merely to name it.

## Identity map

`Metadata/GameDock/<environment>.json` stores schema version 1, the exact prefix,
the current session token and an AppID-to-title map from validated Steam manifests.
It is private runtime metadata, not an exportable diagnostic or a launch receipt.

The lifecycle writes it atomically under existing installation/execution leases
before a new Steam session or game launch. The installed-games view updates it
when its library snapshot changes while Gamekit is open. The reader requires
matching prefix/session and a positive UInt32 AppID, reads at most 1 MiB without
following symlinks, and accepts only bounded non-control-character titles from a
map of at most 512 games. Invalid or unrelated input leaves the process unchanged.

Games installed through Steam while Gamekit is closed may lack a current name
entry until the next Gamekit library refresh or launch request. Already-running
processes started without the helper cannot acquire it retroactively.

## Updating and verification

Save and exit games, **Stop Windows Steam**, then start a fresh session using the
new Gamekit build. Quitting/reopening Gamekit alone retains the old client's
environment. Keep the app bundle at its current location while that Steam session
is running: its child processes use the embedded helper. Stop Steam before moving
or removing the app bundle.

Unit tests exercise session/prefix binding, stale-map replacement, environment
isolation, invalid IDs/names/JSON, bounds and symlink refusal. A standalone native
probe verifies that a loaded helper changes the matching process name and leaves
a process without a game AppID unchanged. An opt-in test exercises the actual
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
