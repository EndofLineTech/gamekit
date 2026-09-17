# E1.1 — GPTK 4 package inspection

Inspected 2026-09-15 for `gamekit-wxz.1`. This is static inspection, not a claim
that Steam or the runtime works. No prerequisites or runtime were installed.

## Artifact identity

The user-supplied outer image was already mounted at `/Volumes/Game Porting
Toolkit`. Its nested evaluation image was mounted read-only for inspection.

| Artifact | SHA-256 |
|---|---|
| `Game_Porting_Toolkit_4.0_beta_2.dmg` | `03893ac4fab94ad9ff6aa32e887e2854bbf40fd90796f78a1d9bdbc02526ee5b` |
| `Evaluation environment for Windows games 4.0 beta 2.dmg` | `6248a0edc61553790753e5e9c060b8e53c940ed197f11409dcc34a35e05becc1` |

These locally calculated hashes identify the inspected artifacts; they are not
independent Apple-published authenticity checks. The nested image's filesystem
checksum verified when mounted. `codesign --verify --deep --strict` succeeds for
its D3DMetal framework; record signature details again before E2 installation.

## Primary package sources

Inside `/Volumes/Evaluation environment for Windows games 4.0 beta 2`:

- `Read Me.rtf`: Requirements, Installation and Setup, Environment Variables,
  Logging, Debugging, and Troubleshooting sections.
- `License.rtf`: Apple agreement EA18380, dated 2023-08-17; particularly sections
  2A, 2B and 2C. The older agreement date is what this beta package contains.
- `redist/lib/external/D3DMetal.framework/Versions/A/Resources/Info.plist`
  and `version.plist`.
- `redist/` file inventory and native/PE binary architecture inspection.

The public entry point is [Apple's GPTK page](https://developer.apple.com/games/game-porting-toolkit/).
These notes summarize the supplied documents; the Apple documents and binaries
are not copied into the source repository.

## Supplied versus separately required

The outer toolkit includes sample source, Metal-cpp, Metal Shader Converter and
Mac Remote Developer Tools installers, plus the nested evaluation image. The
evaluation image contains README/license/acknowledgements and `redist/lib`.
`PackageContent/` is empty in this image. There is **no Wine executable or Wine
build script in the inspected evaluation image**, despite the README mentioning
included build instructions/scripts.

The redistributables include:

- `external/D3DMetal.framework` and `external/libd3dshared.dylib`;
- D3DMetal's shader-conversion support libraries and `default.metallib`;
- `wine/x86_64-windows/{d3d10,d3d11,d3d12,dxgi,nvapi64}.dll`;
- `wine/x86_64-windows/nvngx-on-metalfx.dll`.

Wine and its 32-/64-bit Windows support must come from a separate distribution.
Rosetta supplies host Intel instruction translation. Neither Wine nor Rosetta is
installed by mounting these images. The outer Shader Converter and remote-build
packages are not prerequisites for installing Steam through a prebuilt runtime.

## Requirements and version details

The README states:

- Apple silicon and macOS **15 Sequoia or newer**;
- **16 GB RAM or more recommended**;
- the graphics bridge must be paired with a custom Wine environment.

The framework declares `CFBundleVersion` and `CFBundleShortVersionString` **4.0b2**,
`ProjectName` **D3DRendererMetal**, `SourceVersion` **33024000000000**, and
`BuildVersion` **2**. Its main Mach-O binary is **x86_64**. Its plist minimum is
14.0, but use the stronger package-level macOS 15 requirement rather than treating
that individual binary's metadata as the full support contract.

This Mac is M4 Pro/24 GB, macOS 27.0 build 26A428, Xcode 27.0 build 27A266a,
with Metal 4 support. It meets the documented hardware/OS baseline. Rosetta's
receipt is still absent at inspection time; previous actual x86 probes failed.

## Documented integration routes

Apple explicitly names:

1. [GCenx's prebuilt game-porting-toolkit](https://github.com/Gcenx/game-porting-toolkit/releases)
   and [Homebrew tap](https://github.com/Gcenx/homebrew-wine).
2. [CrossOver](https://www.codeweavers.com/crossover), including its trial.

The README explains replacing a prebuilt runtime's graphics libraries with this
distribution's `redist/lib`. This supports a composition of a separately versioned
Wine runtime and D3DMetal 4; a runtime archive named 3.x is not itself GPTK 4.

There are stale details: the update paragraph mentions the macOS **26** beta
period, and its sample moves whole `external` and `wine` directories aside.
The actual prebuilt runtime contains core DLLs in `wine/` that the Apple overlay
does not supply. Do not mechanically replace the entire core Wine directory.
Preserve the full runtime and merge only the supplied graphics files into an
isolated working copy. E2 must verify the composed runtime's dependencies and
loaded graphics path rather than assuming the README sample is exhaustive.

## Graphics and diagnostic behavior

The supplied README documents:

| Variable | Documented behavior | First-test policy |
|---|---|---|
| `D3DM_MTL4` | Metal 4 backend for D3D12 defaults on under macOS 27+; `0` selects Metal 3 | Leave unset for baseline; explicit `0` only as a labeled comparison |
| `D3DM_SUPPORT_DXR` | Defaults on for M3 and later, off on M1/M2 | Leave unset |
| `ROSETTA_ADVERTISE_AVX` | Defaults off; changes advertised CPU capabilities, not instruction availability | Leave unset unless a reproducible requirement appears |
| `D3DM_ENABLE_METALFX` | Experimental DLSS-to-MetalFX path, defaults off | Leave unset; omit optional DLL renaming/copy steps |
| `D3DM_MAX_FPS` | Optional frame-rate cap | Leave unset |

These are the original E1 first-test choices. The later reproducible Helldivers
CPU gate led to [AVX capability verification and explicit advertisement](avx-capability.md).

Graphics messages are prefixed `D3DM` and use the `D3DMetal` system-log category.
The debugging section discusses SIP changes for debugging CrossOver processes;
that is **not** a prerequisite for basic launch or this feasibility test. Keep
SIP enabled and use ordinary process/library diagnostics and graphics output.

## License implications for this prototype

The included agreement grants installation/internal use/testing for developing,
testing or evaluating video games on Apple-branded products. It restricts
distribution to non-commercial purposes and permits the complete framework or
individual redistributables to be distributed separately subject to those terms.
Copyright/proprietary notices must be preserved. Third-party materials must be
ones the user is authorized to use.

The selected scope is local evaluation with user-obtained Apple components and
authorized Steam content. Publishing Gamekit source does not by itself authorize
publishing arbitrary Apple package content or commercial runtime distribution.
Any future bundling/distribution decision must revisit these exact terms and the
Wine distribution's separate open-source licenses.

## Explicit unknowns handed to E2

- Whether current Steam/its updater and web UI actually work with the selected
  runtime on this exact macOS build.
- Whether the composed graphics libraries resolve and load correctly after local
  signing/setup; static file presence is not execution evidence.
- Actual final Steam helper architectures/build numbers after bootstrap.
- Actual install footprint and necessary overrides, if any.

These are feasibility-test questions, not missing package-access blockers.
