# Third-Party Notices

This repository contains the following third-party derived source revisions.
Their original licenses remain in the indicated directories and take precedence
for that material.

| Component | Origin | License | Notice |
| --- | --- | --- | --- |
| DXMT compatibility revision | [3Shain/dxmt](https://github.com/3Shain/dxmt) at `589adb780354b461645b29999cefaf533594ee99` | MIT | `Sources/DXMTCompatibility/LICENSE` |
| DXVK compatibility revision | [Gcenx/DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) at `8f1e28deed3ad30802f7e1bdff428ec14e6e7817` | zlib/libpng | `Sources/DXVKCompatibility/LICENSE` |
| Scoped Wine 10 remote surface module | [Sikarugir-App/wine](https://github.com/Sikarugir-App/wine) `wine-10.0` at `b073859675060c9211fcbccfd90e4e87520dc2c2`, with shared-memory surface adapted from [CX 23950](https://github.com/PhoenicisOrg/winecx/blob/aa5ddd8eae4d785a95a6199f17e9deed6625f07f/dlls/win32u/dce.c) | LGPL-2.1-or-later | `Sources/GamekitCore/RuntimeModules/COPYING.LIB`, `wine-10-remote-surface.patch`, `README.md` |

The compatibility revisions are patches and build instructions, not claims of
upstream endorsement. Their exact changes and rebuild requirements are recorded
in the respective directory README files.

The Ubisoft candidate embeds a Wine-derived native module alongside its source
patch and rebuild instructions. It is scoped to an independently derived
launcher bundle and does not replace the selected runtime or Steam module.
Gamekit does not otherwise redistribute Apple software, Wine, Steam, Windows,
game content, or runtime downloads merely selected or used by the launcher.
Those components remain subject to their providers' terms and licenses.
