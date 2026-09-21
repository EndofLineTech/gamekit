# Generic execution adapters

`dxgi-version-v1.dll` implements the DXGI version-substitution mechanism. Its
target image, installation directory, match version and replacement version
come exclusively from validated game profiles via the private session parameter
projection. No game-specific constants are compiled into this artifact.

Source: `Sources/HelldiversDriverVersion/dxgi.c` with
`GAMEKIT_PROFILE_DRIVER` and `profile_parameters.h`. The source retains a legacy
build mode, parameterized by a header generated from frozen JSON, solely to
reproduce the previously pinned external runtime payload;
Gamekit's new derived game loaders use this generic build instead.

Rebuild with `tools/build_profile_adapter.py` and LLVM-MinGW. The app verifies the
artifact hash before copying it into a newly staged per-game loader, without
overwriting shared runtime files. Original DXGI exports are forwarded to the
qualified runtime's original module. Failed results and nonmatching versions
pass through unchanged. Missing or ambiguous profile parameters disable substitution.

Qualified compiler: LLVM-MinGW `20260908-ucrt-macos-universal`, x86_64 target.
SHA-256: `2658ec1e2c05b8cdf34072147b65b9e970efff8704c6c5f356b17c3346a8e7a4`.
The actual derived Wine loader passed DXGI version substitution and D3D12 device
creation with an unrelated fixture AppID, executable and JSON-supplied 1.2.3.4
version on 2026-09-20. See `docs/game-profiles.md` for the acceptance command inputs.
