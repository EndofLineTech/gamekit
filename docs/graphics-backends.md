# Optional DXMT and DXVK backends

Gamekit supports independently selected **Automatic**, **Metal 3**, **DXMT** and
**DXVK** backends. Setup supplies the shared default; each installed game's gear
can override it. Stop managed Steam and games before changing a selection.

DXMT and DXVK are **Direct3D 10/11 paths, not Direct3D 12 backends**. Keep an
Apple backend for D3D12 games and for Helldivers 2, whose tested DX11 startup
also rejects these alternatives (see below). A renderer choice does not
automatically change an arbitrary game's selected graphics API.

## Installation and scope

The optional payloads live under `Gamekit/GraphicsBackends`, outside the prefix
and accepted runtime. The menu disables a backend if its pinned modules or
runtime dependencies are missing or changed. Refresh Setup after installation.
The qualified runtime remains Sikarugir 10.0 revision 6; no Wine upgrade is needed.

| Backend | Qualified payload | Dependencies |
|---|---|---|
| DXMT | `dxmt-0.80-compat2` | DXMT v0.80 Unix library, compatible Sikarugir macOS driver |
| DXVK | `dxvk-macos-1.10.3-compat2` | Sikarugir's original Wine DXGI and pinned `Frameworks/moltenvkcx/libMoltenVK.dylib` |

These are explicitly **Gamekit-modified** versions of the upstream renderers.
Source revisions, patches and license notices are in `Sources/DXMTCompatibility`
and `Sources/DXVKCompatibility`, and are copied into each prepared payload.
The local app package includes the same source notices. External runtime binaries
are not bundled into the app.

Preparation, for a developer reproducing this personal prototype:

1. Download the pinned upstream archives listed in
   `tools/qualify_graphics_backends.py` and retain the original Sikarugir engine
   archive. `tools/prepare_graphics_payloads.py` verifies their digests and stages
   the stock payloads into a new `GraphicsBackends` directory.
2. Check out the exact revisions identified in the source-notice directories.
   Build with `tools/build_graphics_compatibility.py --backend dxmt` or `dxvk`.
   The script's `--help` lists required local toolchain/source paths.
3. Run `tools/prepare_dxmt_compatibility_payload.py` and
   `tools/prepare_dxvk_compatibility_payload.py` with `--source` pointing to the
   respective build tree and `--payloads` pointing to `GraphicsBackends`.
   They verify the resulting module hashes and refuse existing destinations.

Build tools: LLVM-MinGW `20260908-ucrt-macos-universal` (archive SHA-256
`d1dc5d1ecf3a3ced5ed5544c72f1acd0c8e84eb3024d520ecc6b143eec62a149`),
Meson 1.11.2, Ninja 1.13.2, Xcode 27 Metal Toolchain, Wine 10 winebuild, and
glslangValidator 16.6.0 for DXVK. The DXMT build retains its pinned original
`winemetal.dll`/`winemetal.so` ABI rather than rebuilding the shader converter.

## Applying a backend

Only renderer modules in the selected game's derived loader are private copies.
Other PE images retain the shared identities required by Steam; shared files are
unlinked in staging before replacement, never edited in place. Each payload
revision has a separate cache directory. Source runtime, game binaries, prefix
graphics DLLs and registry are not rewritten by renderer selection.

Steam/services keep their Apple renderer. A shared DXMT/DXVK choice is a default
for games; Steam uses Metal 3 in that case. The image/AppID/prefix/session-bound
helper selects the paired MoltenVK path only for a DXVK game and restores the
normal library path for children such as Steam. It re-executes the identical
owned loader when necessary because dyld captures library paths at startup.

The Helldivers driver-version preference is retained but its Apple-DXGI shim is
not combined with DXMT or DXVK. These backends do not supply D3D12. Helldivers also
has a historically supported `--use-d3d11` flag, but the tested build still fails
startup with both installed alternatives: its D3D11 feature-level `12_0` request
is rejected. Keep the Apple backend for this game. See the
[DX11 investigation](helldivers-dx11-backends.md) for evidence and limitations.

## Satisfactory

**Gameplay update (2026-09-19, `gamekit-9ay`):** DXMT passed user-controlled
gameplay, audio, controls and manual save/reload checks. Temporary choppiness
settled during play; the user also observed that symptom in the default mode.
DXVK was **unplayable**: very slow loading, severe choppiness and poor
responsiveness. **Do not recommend this DXVK payload for Satisfactory** based
on the earlier menu-only result. Keep the accepted Apple/Metal 3 path as the
default; DXMT is a functionally tested alternative with the stuttering caveat.
See [hands-on results](satisfactory-backend-gameplay.md) for scope and restoration.

For build 24656030 (game 1.2.4.0 / UE 5.6.1), **Gamekit Play** adds these transient
options when selecting DXMT or DXVK:

```text
-dx11 -ini:Engine:[SystemSettings]:r.Streamline.InitializePlugin=0
```

DXVK additionally uses:

```text
-ini:Engine:[SystemSettings]:r.PostProcessing.PreferCompute=1
```

The Streamline option avoids the observed D3D11 initialization failure. Compute
post-processing restores the DXVK 3D scene that otherwise rendered black. This
uses an existing Unreal setting, not shader or game-binary modification.

Gamekit does not overwrite Steam's user-authored Launch Options or the game's
saved preferences. To launch directly from Steam with these backends, put the
same options in Steam's Launch Options yourself; the game gear displays them.
Apple-backend launches receive none of these additional options.

## Compatibility limits and evidence

- DXMT's query completion now observes CPU readback publication as well as GPU
  completion. Timestamp values are real; no sleeps or fabricated data are used.
- DXVK similarly waits nonblockingly for the event's submission completion. Its
  32-bit logger callback uses the cdecl ABI declared by Wine's ntdll.
- DXMT on Wine 10 supports legacy **same-process** shared 2D textures between
  devices on the same GPU. Cross-process import, NT shared handles and keyed
  mutexes are not implemented by this fallback. Tests verify pixel sharing,
  lifetime after owner release, rejection of stale/bogus/foreign-process handles,
  and rejection of unsupported handle types.
- x64 and x86 probes cover device creation, shader rendering, pixel readback and
  presentation. The timestamp comparison uses 100 tight-poll attempts, including
  initial/empty event handling. Apple rollback also passes.
- Satisfactory reached a visibly rendered 3D menu under both backends and the
  bounded sessions stopped gracefully. Those initial observations established
  startup/rendering scope only. Subsequent hands-on testing passed DXMT functional
  checks but found DXVK unplayable; see the Satisfactory section above.
- The packaged app's actual Play button was exercised for both backends. Game
  logs confirmed the transient options, and DXVK's module map confirmed the
  paired MoltenVK library. Its final run exited through the game's normal Exit
  command before observation ended, rather than crashing.
- Native UI tests verified installed choices, per-game/shared independence,
  restart persistence, missing-payload disablement and session locking. Initial
  local automation-session failures were resolved before these checks passed.
- The Helldivers Apple-backend regression reached the ship, recorded no driver
  alert in the bounded observation, and stopped gracefully. Original shared
  Metal 3 and Satisfactory inheritance were restored after acceptance.

## Rollback

Stop managed Steam, then select **Metal 3**, **Automatic**, or restore a game's
**Use shared default**. Existing Apple loaders, accepted runtime and earlier
renderer payloads remain available. No prefix migration or game reinstall is
required. A per-game choice does not alter another game's preference.

For investigated failures, rejected candidates and sources, see
`graphics-backend-research.md`. Raw logs, module maps and screenshots remain local.
