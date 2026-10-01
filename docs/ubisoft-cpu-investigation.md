# Ubisoft Connect idle CPU investigation

On 2026-10-01, the owner reported a hot CPU and macOS Game Mode while the
managed Ubisoft Connect client was open. The two observations had different
owners. `gamepolicyd` issued `IdentifiedGameGrant`, `FullScreenGrant` and
`ConsoleModeGrant` to the frontmost **Steam Link** app, not to Ubisoft Connect.
No Division game executable or Gamekit-derived game bundle was running during
the observation. The managed Ubisoft launcher bundle has no Game Mode opt-in;
the game-named bundles opt in independently.

The Ubisoft CPU usage was real. With the owner-managed, signed-in build 13368
running in its own prefix for over 13 minutes, two process snapshots five
seconds apart showed the `UplayWebCore.exe --type=gpu-process` child consume
4.62 CPU-seconds (about 92% of one core), `upc.exe` 2.02 CPU-seconds (40%),
one CEF renderer 0.74 CPU-seconds (15%), and the Ubisoft wineserver 0.33
CPU-seconds (7%). The GPU child remained hot when Steam Link was frontmost
and Ubisoft was in the background. Steam had independent CPU load at the same
time. A two-second sample identified the busy CEF `CrGpuMain` thread, but
Rosetta/Wine unwinding repeated `__wine_syscall_dispatcher`; it did not expose
the inner CEF operation. No account caches, credentials or raw client logs
were read for this investigation.

The owner authorized a scoped comparison. Gamekit's **Stop Ubisoft Connect**
stopped only the managed Ubisoft session; Steam stayed running. An isolated,
unsigned-in disposable Wine prefix under the session's temporary directory was
installed from the already pinned, locally SHA-256-verified official installer.
It contained Ubisoft Connect build 13333 and no copied account data. Both
variants used the same source-built Ubisoft-only Wine surface module, client,
host and disposable prefix, with a scoped wineserver shutdown between runs.
The first run used the existing `launchArguments` in
`Sources/GamekitCore/LauncherProfiles/ubisoft.json`; the second deliberately
omitted that flag for comparison. Only the empty login window was inspected.

| Disposable build 13333 launch | Login window | GPU helper CPU-time delta | Client CPU-time delta |
| --- | --- | --- | --- |
| Profile `--disable-gpu` | Painted, empty fields | 8.69 seconds / 30 wall seconds (~29% of one core) | 24.73 / 30 (~82%) |
| No GPU flag | Painted, empty fields | 52.46 / 30 (~175%) | 18.53 / 30 (~62%) |

The no-flag GPU child launched without `--use-gl=disabled`; the profile run
launched it with that CEF argument. Both variants still used significant CPU,
but omitting the profile flag made the GPU child substantially hotter in this
unsigned-in comparison. The earlier **signed-in build 13368** comparison in
[the installer paint evidence](ubisoft-installer-paint.md) also found that
omitting `--disable-gpu` left much of the 714×454 game-download dialog
unpainted. A painted login is therefore not sufficient to qualify removing
the flag. The signed-in and unsigned-in CPU figures are different versions
and pages; they must not be treated as a like-for-like performance benchmark.

The disposable prefix was stopped through its own wineserver. Gamekit then
relaunched the owner's original managed Ubisoft session from its unchanged
prefix. Its owned client and CEF helpers were observed running again and
Gamekit showed **running**; Steam remained running. No game Play request was
sent. The signed-in GPU helper still used roughly 93% of one core afterward.

**Result:** Keep the JSON launch policy and renderer module as qualified.
Further CPU reduction needs an independently validated CEF/rendering candidate
that lowers the sustained signed-in GPU-helper load *and* preserves the main
window and the complete download dialog; an unpainted dialog or a change to
the owner's signed-in prefix is not an acceptable performance fix.
