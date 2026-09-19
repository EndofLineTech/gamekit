# Gamekit DXMT compatibility revision 2

This is an **altered version**, based on 3Shain/dxmt v0.80 at
`589adb780354b461645b29999cefaf533594ee99`, under its original MIT license.
It is not an upstream DXMT release.

`compatibility.patch` contains all source/build changes:

- Event-query readiness waits nonblockingly for both GPU completion and the
  finishing thread's CPU query publication. Timestamp values use release/acquire
  atomics. No fabricated timestamps or sleeps.
- On Wine without D3DKMT shared objects, ordinary single-mip, single-sample 2D
  shared textures support **same-process** import between devices on the same
  physical GPU. Weak state records preserve imported texture lifetime without
  leaking COM references. Live tokens use prefix-global atoms to avoid collisions
  across processes; lookups never dereference handles as pointers.
- NT shared handles and keyed mutexes remain unsupported on that fallback path.
  The ordinary Wine 10.18+ D3DKMT path is retained unchanged.
- Header hygiene for the pinned compiler and deterministic PE timestamps.
- Build only the PE side against the identical v0.80 `winemetal` import library;
  the pinned Unix library and shader converter are unchanged.

The earlier same-process feature and its removal are discussed in upstream
[PR 105](https://github.com/3Shain/dxmt/pull/105). This implementation does not
restore the old raw-COM-pointer handle approach.

Build from a clean recursive checkout of that revision with
`tools/build_graphics_compatibility.py --backend dxmt`. Required arguments:
`--source`, `--toolchain` (LLVM-MinGW's bin directory), `--wine-build` (Wine 10
build tree containing winebuild), `--stock-payload` (pinned v0.80 payload).
Meson and Ninja must be on PATH. See `docs/graphics-backends.md` for tool versions,
installation, qualification scope and rollback. A clean independent rebuild
matched all four pinned PE module hashes.
