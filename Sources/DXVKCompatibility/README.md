# Gamekit DXVK compatibility revision 2

This is an **altered version** of Gcenx/DXVK-macOS at
`8f1e28deed3ad30802f7e1bdff428ec14e6e7817`
(`v1.10.3-20230507-repack`), under the attached zlib/libpng license.
It is not an upstream DXVK release.

The source patch tracks a GPU event as a pending resource write until its
submission completes. Event polling remains nonblocking, but no longer reports
completion before MoltenVK's prior timestamp-query results become available.
It also fixes the 32-bit Wine logger callback to use Wine's declared `__cdecl`
ABI, adds an explicit standard-library include and deterministic PE timestamps.

Build a clean checkout using `tools/build_graphics_compatibility.py --backend dxvk`
with `--source`, `--toolchain` and `--wine-build`. Meson, Ninja and glslangValidator
must be on PATH. The final DLLs receive Wine's builtin marker via winebuild;
Wine's original DXGI and the paired Sikarugir `moltenvkcx` library are retained.
See `docs/graphics-backends.md` for the supported paths and game options.
A clean independent rebuild matched all four pinned PE module hashes.
