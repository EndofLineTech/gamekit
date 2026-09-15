# E1.2 — Runtime contract and prerequisite checklist

Decision for `gamekit-wxz.2`, 2026-09-15. Selected **for the E2 feasibility test**;
runtime/Steam compatibility is not yet validated. Package evidence is in
[the inspection report](gptk-package-inspection.md).

**E2.1 result (2026-09-15): BLOCKED.** The exact composition below preserves the
expected files but fails Windows graphics DLL initialization. Apple 4.0b2's
D3D11 bridge requests `__wine_unix_call_dispatcher`, which this Wine 7.7 runtime
does not export. D3D11/D3D12/DXGI loader probes fail with error 1114. See
[prerequisite validation](prerequisite-validation.md) and blocker `gamekit-8sc`.
This E1 candidate is retained as a reproducible failed result, not a recommended
working runtime. A revised runtime must pass the gates before Steam installation.

## OS support horizon

[Apple's 2026-09-14 guidance](https://support.apple.com/en-us/102527) states that
general Rosetta availability ends after macOS 27. Under macOS 28 it remains only
for certain older, unmaintained games relying on Intel frameworks. There is no
verified entitlement for this Steam/Wine/GPTK combination to use that exception.
Both selected host Wine and D3DMetal are x86_64. ARM-native Gamekit UI code does
not remove their CPU-translation requirement; ARM-native Wine alone also does
not translate Intel Windows binaries.

Keep this prototype explicitly targeted at macOS 27. Runtime capability checks
must represent untested/unsupported OS versions rather than treating every newer
macOS as compatible. Preserve the runtime adapter boundary so another supported
translation path can be integrated if one becomes viable. Investigate and test
macOS 28 separately under `gamekit-6v1` before promising support; no replacement
path or exception coverage has been established.

## Selected composition

Use the **GCenx Game-Porting-Toolkit-3.0-3 prebuilt Wine distribution**, with the
user's **Apple D3DMetal 4.0b2** libraries overlaid into a dedicated local copy.
The component versions must be recorded separately; never label the unmodified
GCenx archive as GPTK 4.

| Component | Pinned identity / evidence |
|---|---|
| Wine distribution | [GCenx release Game-Porting-Toolkit-3.0-3](https://github.com/Gcenx/game-porting-toolkit/releases/tag/Game-Porting-Toolkit-3.0-3), published 2026-03-03 |
| Archive | `game-porting-toolkit-3.0-3.tar.xz`, 239,200,808 bytes |
| Archive SHA-256 | `d377683937340f914823dbb2e1252b329cbf834ff58907d0293db8cebf0e392e` — downloaded bytes match GitHub's release asset digest |
| Source revision | `2e232b59da4612f2f131bd2f690d70d8fbdf9b87` at release tag |
| Wine source version | Tag's `VERSION` says `Wine version 7.7`; capture actual `wine64 --version` after Rosetta is installed |
| Bundled graphics before overlay | D3DMetal **3.0**, confirmed by archive framework plist |
| Graphics after intended overlay | Apple **4.0b2**, source version **33024000000000**, from inspected evaluation image |
| Host | M4 Pro, 24 GB, macOS 27.0 **26A428**, Xcode 27.0 **27A266a** |

Why: Apple names this prebuilt route; it avoids compiling historical Wine sources
or installing Intel Homebrew. The current GCenx cask still pins **3.0-2**, while
the published release is **3.0-3**. Use the pinned archive directly instead of an
unpinned `brew install` that would select a different version. The original Apple
Homebrew formula version 1.1 is not the selected runtime recipe.

CrossOver remains an alternate route if the feasibility test fails; it is not an
automatic substitution. Any alternate version/product changes the manifest and
requires repeating E2 from fresh prefixes. The old Wine source lineage is an
explicit compatibility risk for Steam's current updater/web UI, not grounds to
declare success from a version string.

## Architecture and installed-file contract

Static archive inspection confirms:

- `Contents/Resources/wine/bin/wine64`: x86_64 macOS executable;
- sibling `wine64-preloader` and `wineserver`;
- `lib/wine/x86_64-windows` PE32+ DLLs;
- `lib/wine/i386-windows` PE32 DLLs and `x86_32on64-unix` host support;
- bundled GStreamer.framework (release advertises 1.28.1), SDL2, FreeType, GnuTLS
  and other support dylibs; extracted app uses about 804 MiB;
- the app bundle is unsigned in the downloaded archive.

This is a 64-bit host runtime with 32-on-64 Windows support. It does not require a
32-bit macOS process. Actual 32-/64-bit PE execution is an E2 gate.

Valve's [official installer](https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe)
was downloaded for static inspection and **not executed**. It is an Intel 80386
**PE32** NSIS bootstrapper. Its 2026-09-15 SHA-256 is
`7d3654531c32d941b8cae81c4137fc542172bfa9635f169cb392f245a0a12bcb`.
It downloads an evolving client: do not assume the entire client is 32-bit or that
this hash will identify future installer downloads. Record final Steam and web
helper versions/architectures after bootstrap.

Select a **win64 prefix reporting Windows 10** for the first test. Both 32- and
64-bit components must run in that one prefix. Do not set a win32-only prefix or
invent registry build-number overrides. Record `cmd /c ver` and winecfg settings;
change this baseline only for an evidenced failure and rerun the acceptance test.

## Installation checklist for E2.1

These are future actions, not commands run in E1.

| Prerequisite | Action | Verification / removal |
|---|---|---|
| Rosetta | `softwareupdate --install-rosetta`, with normal user agreement flow | `/usr/bin/arch -x86_64 /usr/bin/uname -m` must report x86_64; don't remove system Rosetta as part of Gamekit cleanup |
| GCenx runtime | Retrieve the exact release archive, verify digest and extract to app-owned runtime staging | Confirm app version 3.0-3 and `wine64 --version`; removal is limited to that version's managed directory after stopping its processes |
| Apple graphics | Apply supplied 4.0b2 graphics files to the staged runtime as below | Verify source framework signature/version, compare supplied-file inventory, record final hashes and actual loaded image paths in E2 |
| Local signing | Use the GCenx cask's local ad-hoc signing approach on the managed copy if needed: `codesign --force --deep --sign - "$APP"` | Record resulting signatures/final hashes; this is local signing, not Apple notarization. Original verified artifacts remain intact |
| Quarantine handling | Inspect `xattr` on the managed copy; if execution is blocked, use a targeted approval/removal for that verified copy | No global Gatekeeper/SIP changes; record any copy-local adjustment |
| Windows Steam | Retrieve official HTTPS installer and record download identity again | Inspect PE architecture; record hash, source and timestamp. Installation validation is E2.2 |
| Native build tools | Existing Xcode/CLT; no changes planned | `xcodebuild -version`, `xcrun --find clang` |
| Diagnostic compiler | ARM Homebrew `mingw-w64`, for the small owned D3D12 probe selected in E1.3 | `x86_64-w64-mingw32-g++ --version`; package version currently 14.0.0 revision 3. Installed formula can later be removed with `brew uninstall mingw-w64` if not needed |

The [Homebrew formula API](https://formulae.brew.sh/api/formula/mingw-w64.json)
currently lists a macOS 27 (`arm64_golden_gate`) bottle and runtime formula
dependencies `gmp`, `isl`, `libmpc`, `mpfr`, `zstd`. Let ARM Homebrew resolve them;
record the actual installed formula revisions. This compiler is a **development
test dependency**, not a dependency for end users launching Steam.

No Intel Homebrew, Wine source compiler, external GStreamer/SDL, CrossOver,
Winetricks, standalone .NET/VC runtimes, Metal Shader Converter installer, or Mac
Remote Developer Tools package is selected for the baseline. Add a dependency
only when the selected runtime/test demonstrates a need and document the reason.

Reserve **15 GiB of working headroom** for archives, two test prefixes, runtime
copies, diagnostic tools and logs. This is a conservative project allowance, not
an Apple/Valve published requirement. Check actual free space before installation
and record measured footprint afterward; game storage is budgeted separately.

## Local paths and overlay procedure

Use paths containing spaces deliberately, matching the future app's environment:

```text
~/Library/Application Support/Gamekit/
  Artifacts/                             # verified originals/manifests
  Runtimes/gcenx-3.0-3-d3dmetal-4.0b2/
    Game Porting Toolkit.app/
  Environments/steam-eval-a/              # first fresh Wine prefix
  Environments/steam-eval-b/              # reproduction prefix
  Diagnostics/                           # probe source/build outputs
~/Library/Logs/Gamekit/E2/                # logs/evidence, separate from prefixes
```

Existing `Gamekit/Beads` service data is unrelated: never remove the Gamekit root
directory as a shortcut for runtime cleanup. Existing macOS Steam and `~/.wine`
are not imported, modified or used.

For the managed runtime:

1. Keep the verified archive and a clean extracted base for reproduction.
2. Copy the entire base app into a new, previously absent versioned staging path.
3. Move only the old `lib/external/D3DMetal.framework` out of that staging copy
   into its own backup location, then merge Apple's `redist/lib/` into
   `Contents/Resources/wine/lib/` using `ditto` (preserving symlinks/metadata).
4. Replace matching supplied graphics files, but retain all unrelated Wine DLLs,
   32-on-64 support and bundled dependency libraries. Do not move/delete the whole
   core `lib/wine` directory as the older README example suggests.
5. Verify source and resulting file inventory, framework version, Wine core
   presence, and local signing as needed. Record provenance hashes before and
   after signing; re-signing changes bytes and is not an artifact-hash failure.
6. Publish that local runtime directory for E2 use only after checks pass. If
   composition fails, retain its logs and rebuild the staging copy from originals.

E1 inspected archive contents without making this overlay. E2 owns execution,
complete dependency resolution, signing validation and success/failure evidence.

## Runtime launch contract

The app/core will use explicit executable paths and an argument array, not the
bundle's Finder launcher or global `wine64` on PATH. Set `WINEPREFIX` explicitly
for every command, set `WINEARCH=win64` at prefix creation, and use the same
runtime's `wineserver` for that prefix's lifecycle.

Baseline: clean environment, `WINEDEBUG=-all` for normal use; a separate diagnostic
run enables `+loaddll` for loaded-module evidence. Leave optional D3DMetal knobs
unset; Metal 4 is the documented default on this host. Do not force DXVK, disable
Steam sandboxing, or add Steam compatibility flags without a reproduced need.

The first-test commands and evidence requirements are specified in
[the feasibility procedure](steam-feasibility-test.md).
