# Helldivers driver compatibility runtime

Revision `driver-version-1` retains Wine 10/Sikarugir revision 6, D3DMetal
4.0b2 and the text-input-1 backport. It substitutes **35.0.15.6094** only for
Helldivers' successful DXGI version queries returning the invalid `-1` sentinel.
This is an explicit compatibility value, not an actual Apple driver version.

## Selection and rollback

The workaround is controlled **per game**: stop managed Steam, open the gear
beside Helldivers' Play button, and toggle **Avoid the virtual-GPU driver warning**.
It requires the updated runtime; **Use updated runtime** in Setup selects that
capability if necessary. Toggling the per-game preference does not change the
runtime selection or shared graphics backend. An existing driver-version-1
installation with no preference file keeps its accepted enabled behavior.

To roll back the entire runtime, Stop again and choose **Use text-input runtime
(rollback)**. Original-runtime rollback is also retained. Selection preserves
the graphics backend, game settings, display capture and fullscreen-Space
preference. The runtime must first be staged at its managed revision path.

Selection is an atomic metadata change. No prefix DLL, registry value, game
binary or anti-cheat component is installed or edited by this revision.
Each revision has its own validated launcher namespace.

The per-game choice is saved in `Metadata/GameCompatibility.json`, now schema 2
(schema-1 driver preferences migrate on write),
with a boolean `driverVersions["553850"]`. Malformed values, unsupported game
IDs and changes during active/uncertain sessions are refused. The disabled
Helldivers loader uses `shared-pe-v2-driver-off`; the enabled loader retains
`shared-pe-v2`. Both caches are retained, so toggling never overwrites an
existing shared module. Session-bound loader routing selects the saved choice
for launches from Gamekit or from managed Steam.

## Game scope

Only the generated Helldivers (AppID 553850) loader has a private `dxgi.dll`.
Steam and other game loaders keep the original DXGI. All other PE files remain
hard-linked to their revision's Steam loader, preserving Wine's shared-image
identity requirements. The exception is checked by a pinned shim hash and a
single-link requirement; replacing it cannot overwrite Steam's shared inode.

The shim checks the Windows image name again before substituting a version.
It loads the separately named, pinned original DXGI from the selected runtime's
absolute path supplied by Gamekit. Typed export forwarding avoids requiring a
new prefix placeholder. No recurring dialog clicker is involved.

The earlier experiment used prefix-native overrides. This packaged form moves
that separation into the generated game loader so rollback needs no prefix
repair. The experimental prefix remains separate and is not promoted.

## Build and provenance

The shim is independently implemented in `Sources/HelldiversDriverVersion/`;
the approach was researched in dappermint/winecx-gptk commit df88b180 and
frankea/Whisky PR 227. It is compiled with MinGW-w64, stripped, and linked with
`--no-insert-timestamp` and a fixed preferred image base `0x22bf90000` (ASLR
remains enabled); staging adds Wine's builtin marker. Fixing the preferred base
prevents the temporary output path from changing the linked image's bytes.
The builder rejects a toolchain result that differs from its pinned SHA256:

`5ccd55cf94faaab72dcdef651aaccc7907c3eef46d0ecb1cb0f5de204940d2b2`

Apple's cloned DXGI is renamed at its PE export-module-name field only; it is
not redistributed. Expected renamed hash:
`5e80d3584e304ae1258aa13a1cf12830641dc2694988e670b7c7b5749f215c5c`.
The original `dxgi.dll` remains byte-identical. Runtime staging uses APFS clones,
validates base/input/output hashes, and publishes a new directory without
replacing the existing runtime. Source/provenance accompanies the new revision,
including the inherited text-input LGPL material.

```sh
python3 tools/prepare_driver_runtime.py --build-only .build/helldivers-dxgi.dll
python3 tools/prepare_driver_runtime.py \
  --source "<text-input-1>/Template-1.0.11.app" \
  --destination "<Gamekit>/Runtimes/sikarugir10.0_6-d3dmetal4.0b2-driver-version1/Template-1.0.11.app" \
  --shim .build/helldivers-dxgi.dll
```

The destination parent must exist and the final bundle must not exist. See
[research and experimental evidence](helldivers-driver-warning-research.md)
for the failed preference/button approaches and the isolated native-shim trial.
## Local acceptance, 2026-09-18

### Per-game controls follow-up (`gamekit-ri5`)

The real per-game store was toggled off and on without changing the selected
runtime or prefix DXGI bytes. The actual derived-loader probe returned the
original all-65535 response when off and 35.0.15.6094 when on; D3D12 device
creation passed in both cases. The prior enabled choice was restored.

In the app, Helldivers' gear opened the driver toggle, disabling it saved the
per-game preference, and closing/reopening Gamekit retained the disabled state.
Re-enabling it persisted successfully. Satisfactory's adjacent gear opened its
own panel without launching it or offering Helldivers-only overrides. Gear
actions retain game-specific accessibility labels and identifiers. The shared
Automatic/Metal3 backend remains explicitly labeled as shared in these panels.

Full follow-up checks: 232 Swift tests, 30 Python tests (one skipped), and the
native app build passed. Private evidence includes `.build/ri5-live-driver.log`.

### Original runtime delivery

- The real-prefix probe, launched through the actual derived game loader,
  returned `00230000000f17ce` for Helldivers in driver-version-1. Another
  loader returned the original `ffffffffffffffff`; rolling back to text-input-1
  restored that original response for Helldivers. All three created a D3D12
  device successfully. Prefix DXGI and registry bytes were unchanged by each
  selection operation. The final selection is driver-version-1/Metal3.
- The packaged app's normal Helldivers tile reached the rendered ship in both
  a warm-Steam run and a subsequent cold-Steam run. Warning monitoring started
  before the tile press, sampled at 100 ms, and recorded zero alerts. No warning
  clicks were enabled. Both sessions stopped gracefully.
- Setup's actual rollback and driver-compatibility buttons persisted the
  expected revisions; the driver revision was restored afterward.
- Satisfactory's live launch/Dock identity, separate Steam identity, no
  Helldivers Space host, and graceful cleanup checks passed. This was not a
  full gameplay/save validation.
- Full checks passed: 229 Swift tests; 30 Python tests, one skipped; native
  build. The production C substitution contract passed in Wine. Rebuilding
  with the fixed preferred base reproduced the pinned shim hash exactly.

An initial cold UI launch opened Steam without producing a game process in
the 90-second observation. It is not counted as successful game acceptance;
the subsequent cold launch did reach the ship. That startup-request behavior
is tracked separately. The isolated packaged-form run completed visual/warning
capture but its combined build/run shell hit its outer timeout; explicit
follow-up cleanup verified the isolated session was already stopped.

Private logs/screenshots are under the primary workspace's `.build/p92-*`.
The package is ad-hoc signed for personal use; its manifest records the dirty
source tree and executable fingerprints rather than asserting a merged release.
