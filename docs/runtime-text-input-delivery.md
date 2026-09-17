# Managed text-input runtime revision

`gamekit-64o` delivers the [tested Helldivers backport](helldivers-text-input-backport.md)
as the selectable **Gamekit text-input 1** component revision of the existing
Sikarugir 10.0 revision 6 / D3DMetal 4.0b2 recipe.

## Selection and rollback

After preparing the runtime below, open a current Gamekit build, save/exit games
and **Stop Windows Steam**. In Setup and prerequisites, choose **Use updated
runtime**, then wait for the checks to pass. Subsequent game tiles and Steam
launches use this persisted selection. **Use original runtime** switches back.
**Choose runtime…** selects another local app for the currently displayed revision.

The switch changes one atomically written settings document. It does not copy,
reset or reinstall the prefix. A real-prefix probe verified both directions:
the revised runtime provides the text-input interfaces, the original returns
its previous missing-interface result, and the prefix's `msctf.dll` bytes and
environment record remain identical. Wine resolves its builtin module from the
selected runtime, so patching the prefix's system DLL is unnecessary.

Existing selections, including an absent settings file, keep the original
revision until an explicit switch. This preserves control of any recorded
legacy session. The UI and backend prohibit switching while a lifecycle receipt,
installation lease, execution lease or observed process owns an environment.

Selection schema 2 records `revision` as `original` or `text-input-1`, alongside
the optional custom bundle URL. Schema 1 is read as the original revision;
unknown revisions and unsupported schema/revision combinations are rejected.
Use the current app for rollback: older app builds cannot read schema 2.

The environment's existing `RuntimeIdentity` continues to describe the shared
base Wine/prefix ABI. The separate component revision identifies the backport,
pins its DLL hash and selects its cache namespace. This avoids rewriting saved
installation history merely to change a compatible builtin component.

## Cache isolation

- Original: `Launchers/Windows Steam.app` and `Launchers/Games/…`.
- Text-input 1: `Launchers/Revisions/text-input-1/Windows Steam.app` and
  `Launchers/Revisions/text-input-1/Games/…`.

Old caches remain available for rollback. Revised caches are built from the
revised runtime and pin the new DLL in their manifests. Games hard-link Windows
PE files to **their own revision's** Steam cache, preserving the shared mappings
needed by Steam and games. A revision never reuses an old component's cache.
Process observation and game-name routing use the selected namespace.

## Prepare the local runtime

Gamekit still does not bundle third-party runtime binaries inside `Gamekit.app`.
The local preparation tool requires the exact tested original bundle, backported
DLL and corresponding source inputs. It verifies hashes, creates an APFS clone,
replaces only the cloned DLL, includes sources/license/build instructions, and
publishes with an atomic no-overwrite rename. It never replaces an existing
destination. See the [backport build instructions](helldivers-text-input-backport.md)
for obtaining/building the inputs.

After creating the destination's parent under the managed `Runtimes` directory:

```bash
python3 tools/prepare_text_input_runtime.py \
  --source "$HOME/Library/Application Support/Gamekit/Runtimes/sikarugir10.0_6-d3dmetal4.0b2/Template-1.0.11.app" \
  --destination "$HOME/Library/Application Support/Gamekit/Runtimes/sikarugir10.0_6-d3dmetal4.0b2-text-input1/Template-1.0.11.app" \
  --dll .build/text-input-candidate/backport-msctf.dll \
  --archive .build/text-input-candidate/wine-10.0.tar.gz \
  --idl .build/text-input-candidate/wine-wine-10.0/include/ctffunc.idl
```

The changed DLL SHA-256 is
`bb8db266526cff89c2bc6a436482b24c632c13596c1864adb4cb2e42e58fca8b`.
Wine executables and the Apple graphics payload retain the accepted hashes.
`Contents/Resources/GamekitTextInputSources/` contains:

- Wine 10 source archive and `COPYING.LIB` (LGPL-2.1-or-later);
- the pinned upstream `ctffunc.idl` and adapted backport patch;
- `BUILD.md` with source commits and build instructions;
- `manifest.json` with the component, source and artifact identities.

The preparation tool and Gamekit independently verify the executable/component
identities. An invalid revised DLL fails the **Wine runtime** prerequisite;
it is not presented as a D3DMetal failure.

## Why not switch to Apple's Wine build?

Apple's supplied GPTK 4 beta 2 image contains D3DMetal/graphics DLLs but no Wine
executable; see the [package inspection](gptk-package-inspection.md). Apple's
[Homebrew formula](https://github.com/apple/homebrew-apple/blob/main/Formula/game-porting-toolkit.rb)
currently labels its build 1.1 and uses CrossOver 22.1.1 source.
The Apple-documented [GCenx prebuilt release](https://github.com/Gcenx/game-porting-toolkit/releases/tag/Game-Porting-Toolkit-3.0-3)
has tagged source whose `ThreadMgr_GetFunctionProvider` still returns
`E_NOTIMPL`. Its published source therefore does not supply this fix.

Our earlier [local runtime comparison](runtime-revision.md) also found that
GCenx's Wine 7.7 paired with D3DMetal 4.0b2 fails graphics initialization with
the missing-dispatcher/1114 failure. Its original D3DMetal 3.0 pairing passed a
device probe, which is a different recipe and not Steam/game acceptance.
The delivered revision retains the tested Wine 10/Apple 4.0b2 pairing.

## Verification

The opt-in `RuntimeRevisionAcceptanceTests` exercises selection, a real Windows
capability probe, rollback and cleanup against the stopped managed prefix.
Unit tests cover legacy metadata, preserved prefix/record bytes, revised cache
contents and intra-revision PE sharing. Runtime preparation tests cover source
preservation, mismatched DLL rejection, no-overwrite publication and redirected
provenance paths.

Packaged-app game/lifecycle acceptance and the selected default are recorded
after the local candidate checks. Mission stability, audio and measured FPS are
separate from runtime delivery and startup acceptance.
