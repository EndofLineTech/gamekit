# Visual C++ prerequisites under managed Wine

Investigation `gamekit-5se`, discovered during Satisfactory E6.2 acceptance on
2026-09-17 UTC (local evening of September 16).

## Observed failure

Satisfactory (AppID 526870, Steam BuildID 24656030, game CL 502094) reached its
menu and gameplay, but every launch offered to install Microsoft Visual C++
2015–2022 Redistributable x64. Accepting dismissed the installer almost immediately
before the game opened.

Steam's shared redistributable log records successful installation of both x64
minimum/additional packages for **14.51.36247**, with exit code zero. The registry
reports Installed=1 and version 14.51.36247 in both applicable views. The game's
bundled **14.42.34438** installer detects those newer packages and exits with
`0x80070666` / `0x666`: a newer version is installed. Reinstalling that older
package therefore does not resolve the repeated prompt.

Inspection of the installed bootstrapper confirms checks for registry version,
file-version resources and loadability of `msvcp140_2.dll` and
`vcruntime140_1.dll`, requiring at least **14.42.34438**. A successful DLL load
alone is insufficient. Raw installer/game logs and registry files remain local.

## Reproduced cause and launch policy

The scoped Windows probe in `tools/vc_runtime_probe.c` reproduced the discrepancy:

| Check | Previous Wine default | Microsoft DLL preference |
| --- | --- | --- |
| Registry | Installed, 14.51.36247 | Installed, 14.51.36247 |
| Critical DLL load | Succeeds | Succeeds |
| Critical DLL file-version query | Fails with Win32 1812 (resource data not found) | 14.51.36247.0 |
| Bootstrap-equivalent probe | Exit 1 | Exit 0 |

Wine's built-in DLL handling hid the genuine installed runtime's version resources
from the check. Gamekit now supplies a fixed, non-inherited load preference for
the VC++ v14 family in its runtime environment:

```text
WINEDLLOVERRIDES=msvcp140,msvcp140_1,msvcp140_2,msvcp140_atomic_wait,vcruntime140,vcruntime140_1,concrt140=n,b
```

This prefers the installed Microsoft libraries, with Wine built-ins as fallback.
It does not forge installation markers, downgrade redistributables, bypass the
game bootstrapper or patch game files. Steam remains responsible for installing
prerequisites. A missing native runtime can still legitimately require installation.
The graphics payload and Wine binaries are unchanged.

**Restart managed Steam after opening a Gamekit build with this policy.** Games
inherit the long-lived Steam client's environment; sending a new launch request
to an old Steam session is not enough. Save and exit games, use Gamekit's Stop,
then launch the game again from its tile. Quitting/reopening Gamekit alone leaves
the old Steam session running.

## Verification and reproduction

The environment isolation regression rejects inherited arbitrary DLL overrides.
The opt-in test acquires installation/execution leases, checks the live receipt's
prefix identity and matching process tags, and runs a read-only probe with the
same session token. It compares the old policy with the managed policy without
changing prefix registry settings or installing anything.

With the validated runtime, Steam running in its owned session, the installed
VC++ redistributable and MinGW-w64 available:

```bash
x86_64-w64-mingw32-gcc -Wall -Wextra -Werror -static \
  -o .build/vc-runtime-probe.exe tools/vc_runtime_probe.c -ladvapi32 -lversion
GAMEKIT_VC_PROBE=1 GAMEKIT_VC_PROBE_PATH="$PWD/.build/vc-runtime-probe.exe" \
  swift test --filter VCPrerequisiteInspectionTests
```

The managed-policy assertion failed before the environment change and passed
afterward on the actual primary prefix. Live acceptance still requires a restarted
Steam session, repeated Satisfactory launches without the prompt, and gameplay/
save-reload checks. This probe is not itself game compatibility evidence.
