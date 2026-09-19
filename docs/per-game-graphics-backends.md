# Per-game graphics backend overrides

Open a game's **gear beside Play** and choose:

- **Use shared default** — follow the backend selected in Setup.
- **Automatic (Apple default)** — remove the Metal3 fallback for this game.
- **Metal 3 compatibility** — set the Metal3 fallback for this game.

DXVK and DXMT are optional Direct3D 10/11 backends, enabled when their qualified
payloads are installed and verified. See [installation, game options and scope](graphics-backends.md).
The panel shows both the shared default and the effective
choice for the next launch. Steam and all games must be stopped before changes;
there is no automatic shutdown or live renderer switch.

## Independence and persistence

Setup chooses the shared game default. Windows Steam follows Apple selections
and retains Metal 3 when the shared game choice is DXMT/DXVK.
Changing a game's dropdown does not change `RuntimeSelection.json`, another
game's override, the driver-warning workaround, capture or fullscreen-Space
preferences. Choose **Use shared default** to remove an override.

`Metadata/GameCompatibility.json` schema 2 stores `graphicsBackends`, keyed by
canonical numeric Steam AppID, alongside the existing `driverVersions` map.
Values are `automatic`, `metal3`, `dxmt` or `dxvk`; absent entries inherit. Schema-1 driver
preferences are read without changing their values and upgraded on the next
write. Unknown schemas/backends, noncanonical IDs, malformed values and more
than 512 backend entries are rejected. Older apps that only understand schema 1
cannot read schema 2: use the current app to roll back settings or runtimes.

No game files, registry values or prefix graphics DLLs are modified for backend choices.
DXMT/DXVK use private renderer modules in revision-specific derived game loaders.
The option is available to every ready installed game in the managed library;
the additional Helldivers-specific fixes remain restricted to that title.

## Applying the choice

Steam's native environment is only the starting point. The session-bound
GameDock mapping publishes its shared backend and overrides for installed,
ready games. The Wine-side helper applies the choice before Wine initializes
the game's environment/graphics, including after a loader re-exec.

The helper authenticates the mapping against the current prefix/session and
resolves the actual Windows executable against a unique installed-game directory.
An inherited `SteamAppId` alone cannot apply a game override to Steam, a service
or an unrelated child. If present, it must agree with the image's directory.
This also supports game launches where Wine's native environment omits AppID.

For non-game images the helper restores the shared Apple backend (Metal 3 when
the game default is DXMT/DXVK), preventing an
override from leaking back into a child Steam process. Automatic unsets
`D3DM_MTL4`; Metal3 sets it to `0`. No guessed forced-Metal4 value is used.
Names remain display labels; executable-directory and AppID matching determine
the scope. Existing Dock routing, driver-shim selection and fullscreen-Space
preferences are retained.

The mapping is prepared for the managed Steam session, so launching from its
client does not depend on pressing Gamekit's Play button each time. A new game
installation refreshes the map through the existing library refresh flow.

## Verification

- Unit tests cover preference migration, independent game choices, restored
  inheritance, unchanged shared selection/registry, malformed values and
  active/uncertain-session guards.
- Native helper tests cover prefix/session scope, missing/conflicting AppIDs,
  ambiguous/outside paths, invalid values, actual loader re-exec, and a modeled
  Steam child resetting an inherited game override.
- Seven real Windows-process checks in a disposable prefix verified both
  directions of override and inheritance. A probe game was Automatic under a
  Metal3 shared default, then Metal3 under Automatic; a second game and an
  unconfigured process kept the shared value. Returning to inherit removed the
  override. Every case also created a D3D12 device successfully.
- UI tests verified a non-Helldivers game's dropdown, disabled unavailable
  payload entries, persistence across app restart, unchanged shared backend and restored
  inheritance, plus capture/Space regression and shared-selector persistence.
- With Steam set to Automatic and Helldivers set to Metal3, normal Gamekit Play
  and the owned Steam client's `steam://rungameid/553850` route both reached the
  rendered ship. Both bounded runs recorded no driver alerts and stopped
  gracefully. This is startup validation, not a full-mission performance claim.
- The user's original shared Metal3 default and Helldivers inheritance were
  restored after testing; driver compatibility/capture/Space settings were kept.
- Satisfactory's shipping process and separate game/Steam Dock identities also
  passed, with graceful cleanup. The original 45-second startup wait expired
  before the game appeared; the bounded wait now matches the 90-second game
  observation window. Inspection confirmed native SteamAppId was absent and
  the helper successfully used executable-directory matching.

Private evidence is under `.build/aty-*`. Tests use synthetic AppIDs in the
disposable prefix; no per-title names are hardcoded into backend selection.
