# Wine 10 remote-window surface module

`win32u-remote-surface-2.so` is an x86_64 Wine `win32u.so` derived from
[Sikarugir-App/wine](https://github.com/Sikarugir-App/wine) tag `wine-10.0`
(commit `b073859675060c9211fcbccfd90e4e87520dc2c2`), licensed under
LGPL-2.1-or-later (`COPYING.LIB`). Apply `wine-10-remote-surface.patch` to that
exact tree. The shared-memory child surface is adapted from the public
[CrossOver CX 23950 implementation](https://github.com/PhoenicisOrg/winecx/blob/aa5ddd8eae4d785a95a6199f17e9deed6625f07f/dlls/win32u/dce.c),
with a bounded cross-process GDI bitmap transfer and an immediate parent-surface
flush. The implementation contains no launcher- or game-specific parameters.

To reproduce a functionally equivalent module on macOS 27 with Xcode 27,
Homebrew Bison 3.8.2, FreeType 2.14.3 headers and Vulkan 1.4.357 headers, use
an **owner-supplied** x86_64 Wine runtime with FreeType and MoltenVK libraries.
From a temporary directory containing this patch:

```sh
git clone --depth 1 --branch wine-10.0 https://github.com/Sikarugir-App/wine.git wine-10.0
git -C wine-10.0 apply ../wine-10-remote-surface.patch
ln -s "$RUNTIME_FRAMEWORKS" wine-frameworks-x86_64
(
  cd wine-10.0
  arch -x86_64 env PATH="/opt/homebrew/opt/bison/bin:$PATH" \
    CC='clang -arch x86_64' CXX='clang++ -arch x86_64' OBJC='clang -arch x86_64' \
    CPPFLAGS='-I/opt/homebrew/opt/vulkan-headers/include' \
    LDFLAGS="-L$(pwd)/../wine-frameworks-x86_64" \
    FREETYPE_CFLAGS='-I/opt/homebrew/opt/freetype/include/freetype2' \
    FREETYPE_LIBS="-L$(pwd)/../wine-frameworks-x86_64 -lfreetype" \
    ac_cv_lib_soname_freetype=libfreetype.dylib ./configure --enable-win64
  arch -x86_64 env PATH="/opt/homebrew/opt/bison/bin:$PATH" make -j8 dlls/win32u/win32u.so
  install_name_tool -id win32u.so dlls/win32u/win32u.so
  codesign --force --sign - --timestamp=none dlls/win32u/win32u.so
)
```

Set `RUNTIME_FRAMEWORKS` to the selected runtime app's `Contents/Frameworks`
directory; it is used for **link-time checks only** and is not redistributed.
The `ac_cv_lib_soname_freetype` value is required: with this runtime's relative
install name, Wine's configure script otherwise embeds the entire `otool -L`
line, including version text, as a library name. Check the output using
`strings wine-10.0/dlls/win32u/win32u.so` before testing: it must contain the
plain `libfreetype.dylib`, not a versioned description. Copy/sign the rebuilt
module into the bundled resource only after testing; set its SHA-256 in the
launcher JSON and the shared test fixture. Code-signing, paths and toolchain
versions can change the binary hash without changing its source behavior.

The tested signed module is SHA-256
`791440e7394236738f8ffefbf6ce7643e801aa5d74e3a092e2dd755eeec020c5`.
The earlier recovered local experiment has a different hash and no retained
matching source; it is not included in this revision. Steam's Wine module and
the original runtime remain unchanged.
