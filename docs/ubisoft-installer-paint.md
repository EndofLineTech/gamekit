# Ubisoft Connect installer rendering

The managed Ubisoft Connect client uses a separate Wine prefix from Steam. Its
CEF main window needs the earlier generic cross-process `win32u.so` surface
revision. The separate, layered `uplay_download` installer window draws a full
714×454 bitmap, but on the default GPU path only the upper-left part has source
alpha. Wine cannot stretch missing source pixels into usable controls.

On 2026-09-30, an isolated, signed-in disposable Ubisoft prefix on macOS 27.0.1
updated its client from build 13333 to 13368. The owner entered credentials in
the client; Gamekit did not read them. We searched the owned library and opened
The Division's language-selection download dialog without continuing or starting
the game download. With the same pinned GDI module and build 13368:

| Launch choice | Main window | Installer alpha pixels (TL/TR/BL/BR, 714×454 points) |
| --- | --- | --- |
| No GPU argument | Painted | 324116 / 153904 / 65136 / 40688 |
| `--disable-gpu` | Painted | 324116 / 324116 / 324136 / 324136 |
| No GPU argument, after scoped restart | Painted | 324116 / 153904 / 65136 / 40688 |
| `--disable-gpu`, after scoped restart | Painted | 324116 / 324116 / 324136 / 324136 |

`--disable-gpu-compositing` fixed the installer source in an earlier isolated
trace but made the main window uncapturable on this host, even alongside
`--in-process-gpu` and `--use-angle=swiftshader-webgl`. Stock Wine plus the flag
also left the main window uncapturable. The narrower flag is therefore **not**
the accepted launcher choice. Production launcher arguments are in the Ubisoft
JSON profile, not embedded in Swift. The native module is applied only to a
hash-checked, side-by-side Ubisoft derived loader; the selected runtime and
Windows Steam remain unchanged.

The old local module (SHA-256 `a08bbfada402803c831622e492ad85839c137a8f5b2358a8df2ba3c5ac50a814`)
could not be shipped because its source worktree disappeared on reboot. This
revision instead builds a **source-complete equivalent** from Wine 10 and the
LGPL patch `Sources/GamekitCore/RuntimeModules/wine-10-remote-surface.patch`.
`Sources/GamekitCore/RuntimeModules/README.md` records the upstream commit,
CX 23950 attribution, build options, selected runtime dependencies and signing
steps. The tested replacement is `win32u-remote-surface-2.so`, signed SHA-256
`791440e7394236738f8ffefbf6ce7643e801aa5d74e3a092e2dd755eeec020c5`.
It is a new build, **not** a byte-for-byte reproduction of the old module.
The package contains the patch, build instructions and LGPL license.

A bounded cross-process GDI control paints a 160×100 two-color child bitmap in
the native parent window with the new module; the same `StretchBlt` reports
success on stock Wine while its parent window stays blank. The rebuilt module
also painted the full empty-email/empty-password login form in a fresh,
unsigned-in disposable Ubisoft environment; no account data was copied there.
An initial rebuild without FreeType support, followed by one with a malformed
FreeType library name from `configure`, exited before the login window. Those
candidates were rejected. The final build links the selected x86_64 FreeType
and MoltenVK support and has a plain `libfreetype.dylib` install name.

The owner's saved managed Ubisoft environment was initially blocked after
reboot: its lifecycle receipt had the prior volume device number while the
prefix retained its inode. Gamekit correctly reported it as unverified instead
of silently rewriting ownership. The explicit `gamekit-to6` recovery control
verified that the same prefix was idle, cleared only the stale receipt, and
restored Launch without resetting the signed-in environment.

The owner authorized a local managed-session test. The signed candidate's
normal Gamekit Launch started the saved client (build 13333) with `--disable-gpu`
and the hash-checked Ubisoft-only `win32u.so`. The library and owned The Division
page painted; clicking its Download button opened the language-selection
`uplay_download` window. A private window-only capture at 714×454 points
(1428×908 pixels) showed the complete dialog, including visible Cancel and
Continue. Its nonzero-alpha quadrant counts were
`324116 / 324116 / 324136 / 324136`, with full-window alpha bounds. No Continue
action or game download was started. Gamekit's **Stop Ubisoft Connect** control
then returned Ubisoft to **stopped** while Windows Steam remained **running**.
This verifies the previously inaccessible managed download *dialog*, not game
download completion, installation or Play. Window images remain private and
are not included in the repository.

With the **source-built** replacement, a fresh, signed local Gamekit package
normally launched the same saved prefix, now updated to Ubisoft build 13368.
The Home, My games library and The Division detail page were interactive. Its
714×454 language-selection window painted completely, including Cancel and
Continue; the window-only capture at 1428×908 pixels again measured nonzero
alpha `324116 / 324116 / 324136 / 324136` (TL/TR/BL/BR) and full bounds.
Gamekit stopped only Ubisoft afterward. Steam stayed running and macOS Game Mode
reported off. The source Wine runtime and saved sign-in files were not replaced;
no game download was initiated.
