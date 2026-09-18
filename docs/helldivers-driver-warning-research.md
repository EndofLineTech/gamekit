# Helldivers driver warning: research before automation

## Delivery update

The user confirmed the substituted-version trial needed no dismissal and
authorized delivery. The fix is now a selectable `driver-version-1` runtime;
see [managed delivery and rollback](helldivers-driver-runtime.md). The managed
form uses a Helldivers-only derived-loader module and does not install the
experimental prefix overrides described below. Real-prefix query/rollback and
packaged warm/cold game launches have been validated. Earlier experimental
status statements below are retained as investigation history.

## Authorized driver-version experiment

The user subsequently authorized substituting a driver version. An APFS-cloned
runtime **and prefix** under the private `.build/p92-driver-experiment` root
were used. The primary runtime selection and runtime binaries remain unchanged.
This is a compatibility version, **not the actual installed Apple GPU driver**.

The independently implemented diagnostic shim substitutes **35.0.15.6094** only
when `CheckInterfaceSupport` succeeds and returns `-1`. Existing non-sentinel
versions, failure HRESULTs, null output pointers and last-error values pass
through. Its substitution gate recognizes `helldivers2.exe` and the explicit
`gamekit-dxgi-probe.exe` probe. It does not patch game or anti-cheat binaries.

### Measured results

| Check | Outcome |
| --- | --- |
| Baseline DXGI probe | S_OK, `ffffffffffffffff` (all-65535); D3D12 device creation S_OK |
| Substituted DXGI probe | S_OK, `00230000000f17ce` (35.0.15.6094); D3D12 device creation S_OK |
| Non-target executable control | Original all-65535 value retained; D3D12 device creation S_OK |
| Windows-side contract test | Sentinel/non-sentinel, failure, null and last-error cases passed |
| PE staging tests | Bounded module-name rename/round-trip and invalid layout/marker rejection passed |
| First, global-builtin shim trial | Steam web helper crashed before game launch; not a successful warning test; forced scoped cleanup |
| First retry after scope change | Stale generated launcher rejected as invalid; no game launch |
| Helldivers-only native override trial | Reached rendered ship interior; shim logged substitutions in game; zero driver-warning observations at 100 ms polling; graceful cleanup |

The successful launch is `.build/p92-substituted-launch-3`. No automated driver
dialog action was enabled; the user was asked to leave any alert untouched.
The evidence combines the version probe, substitution log, warning polling and
rendered game screenshots. Polling cannot prove absence of every arbitrarily
brief window, and **user confirmation is still requested before calling this
a resolved user-facing fix**. This is startup validation, not a full-mission
compatibility result.

The global-builtin approach was rejected after the Steam failure. The refined
trial restores the original runtime `dxgi.dll`, places the native shim in the
cloned prefix, and explicitly selects builtin DXGI globally with native/builtin
overrides only for Helldivers and the test probe. The renamed original
`dxgm.dll` and `dxgm.so` mapping live only in that isolated runtime/prefix.
Generated launchers from the earlier trial were archived and rebuilt against
the corrected hash manifest. No existing shared DLL inode was edited in place.

The primary runtime DXGI hash remains
`522a8b37216afb09e614489d88a74118076f4d7e08d2b289df6a6eb6f3e817af`.
The experiment is stopped and is **not installed as the normal Gamekit runtime**.
Promoting it would require a managed runtime revision, rollback and broader
graphics/lifecycle validation; the current scripts are opt-in experimental tools.

### Trial tools

- `Sources/HelldiversDriverVersion/dxgi.c` and `.def`: final game-scoped shim,
  evolved from the experimental `dxgi_driver_trial` implementation.
- `diagnostics/dxgi_driver_probe.cpp`: real query/device probe and isolated
  override setup; run only through the explicit experiment harness.
- `diagnostics/dxgi_driver_trial_test.c`: Windows-side substitution contract.
- `tools/stage_driver_trial.py`: pinned-original PE staging restricted to the
  named private experiment. Run only while its managed session is stopped.
- `DriverVersionExperimentTests`: leased stopped-source APFS cloning and
  bounded probe sessions; copies accepted fullscreen-Space metadata and uses
  Metal3. `GameEvaluationLaunchTests` accepts `GAMEKIT_DRIVER_EXPERIMENT`,
  forbids warning click automation for that mode, and records warning polling.

The researched Try Again outcome below remains **failed**, not superseded by
an assumption that its flag suddenly worked.

## Corrected trial outcome: warning still appears

On game build **24826606**, select the middle **Try Again** button once on
the "GPU drivers are out of date" dialog. In the approved local trial this
continued startup and the game saved `IGNORE_APPROVED_DRIVER_WARNING=true`.
A subsequent fresh managed Steam/game launch, with **all automatic warning
actions disabled**, reached the in-game UI, but the user confirms that the
warning appeared and they manually clicked **Try Again** again. It allowed
launch but did not resolve recurrence. The initial inference that
suppression worked was incorrect. The harness did not exclude or record user
input, so game progression cannot establish warning absence. The setting
remained enabled in the post-run snapshot. Both sessions stopped gracefully.

The first attempt was blocked by Steam Cloud's Unable to Sync warning;
no action was taken on that warning. After the user quit the Windows game
and confirmed cloud sync, the native-action trial succeeded. Private evidence:
`.build/p92-try-again-2/` and `.build/p92-relaunch-1/` in the primary workspace.
Before/after settings show the warning flag change plus tiny floating-point
serialization differences written by the game, not a graphics-settings edit.

This does not supersede the earlier unsuccessful manual flag-edit experiment.
The native action sets the flag but did not suppress the warning on the
reported relaunch. No causal explanation involving Steam Cloud is established.

**Status: unresolved; `gamekit-p92` reopened after correcting the false success
claim.** No recurring click automation, DXGI shim, driver-version substitution
or game-binary change has been applied. The research below is historical;
its proposed native-action experiment has now failed the persistence check.

`gamekit-p92`, researched 2026-09-18. The user requested investigation of
others' fixes before automating Continue. No runtime, game configuration or
dialog-handling implementation was changed during this research.

## Result

There are two concrete leads beyond repeated Continue clicks:

1. A Steam discussion claims the dialog's **Repeat** action means "don't
   remind me again." Our saved screenshot has **Cancel / Try Again /
   Continue**, making Try Again a plausible corresponding action. This is
   an unverified mapping and a small community report, not established game
   documentation. A one-time native-action test followed by a fresh launch
   is the lowest-impact next experiment.
2. The **frankea fork of Whisky**, backed by dappermint/winecx-gptk, shipped
   a DXGI driver-version shim explicitly addressing this exact all-65535
   warning. Source inspection shows that it substitutes a hard-coded version;
   it is not a game preference or evidence of a newer actual Mac GPU driver.

The previous local test of `IGNORE_APPROVED_DRIVER_WARNING=true` failed:
the setting persisted and the warning still appeared on game build 24826606.
That experiment remains valid evidence; the renewed search found no reason
to describe repeating the same edit as a verified fix.

## Evidence and applicability

### Native dialog action

[Steam: Driver check skip launch parameter][1], April 28, contains a reply
"click repeat worked for me" and an acknowledgement from the original poster
calling it the "don't remind me again option." The thread supplies no working
launch argument. It does not identify Wine, CrossOver, the current game build,
or the exact saved state the action changes.

Our existing local warning screenshot independently shows a middle Try Again
button. Testing that specific native action once is distinct from implementing
automatic clicks on every launch. Verify any resulting warning-related config
changes and at least one subsequent launch; do not infer permanent suppression
from dismissal alone. No such test has been performed for this research yet.

### DXGI shim with source and release provenance

[Upstream commit df88b180][2] (August 22) identifies the query as
`IDXGIAdapter::CheckInterfaceSupport`. D3DMetal returns S_OK with the
`LARGE_INTEGER` output set to `-1`, displayed as four unsigned 65535 words.
The commit reports a before/after probe of DXGI and SetupAPI. It also reports
that Helldivers loads DXGI dynamically and checks the driver before loading
D3D12, explaining why a D3D12-only interception cannot handle it.

[Whisky fork PR 227][3], merged August 27, integrates the shim. Its probe
shows DXGI `0xffffffffffffffff` becoming `0x00230000000f17ce`
(35.0.15.6094), matching that developer's Wine display-class registry value.
The [August 29 beta runtime release][4] includes it; [app release 3.7.0][5]
explicitly reports that Helldivers' driver-warning box is gone. This is a
maintainer-reported fix with inspectable code, not independent validation on
Gamekit. The beta release also distinguishes upstream game validation from
acceptance of its exact packaged runtime artifact.

The [pinned shim source][6] does **not** dynamically read the registry. It
hard-codes `UMD_HIGH=(35<<16)|0` and `UMD_LOW=(15<<16)|6094`, replacing only
successful queries returning `-1`. It patches the adapter vtable and forwards
DXGI exports through a renamed Apple DLL. Whisky's deployment rewrites the
renamed DLL's PE export name and adds the corresponding Unix-library mapping.

Although the upstream description calls this "truthful," local read-only
inspection found Gamekit's display-class entry identifies **Apple M4 Pro**
and reports **31.0.10.1000**, not 35.0.15.6094. Copying the constant would
substitute a compatibility version, not recover this runtime's existing
reported version. Simply copying a registry value also does not establish
that the game would accept it. Do not transplant the shim blindly, alter
hard-linked runtime DLLs, or treat a whole-runtime upgrade as necessary.

If the native dialog action fails, this is a specific runtime-level approach
to evaluate and discuss before choosing click automation. It would require
an explicit decision about version substitution, a separately staged runtime,
API/graphics regression checks, and a verified rollback.

### Other reports

- [Steam: GPU drivers are out of date][7] contains the August 13 suggestion
  to edit `IGNORE_APPROVED_DRIVER_WARNING`; this is the already-failed local
  approach. Other replies discuss mod-related launch crashes, while the
  original poster clarifies their game runs and only the popup is unwanted.
  Do not conflate those outcomes with warning suppression.
- [CrossOver 26.1/M2 report][8] shows the exact AMD/all-65535 warning. Its
  May 31 reply says Proton Experimental fixed the issue on Linux/NVIDIA.
  That is a different graphics stack and an imprecisely described outcome,
  not a directly usable macOS fix.
- [GamingOnLinux's April 29 Proton Hotfix report][9] confirms recovery from a
  launch failure. It does not establish that the hotfix suppresses this driver
  dialog; do not treat every Helldivers launch fix as a warning fix.
- [Helldivers Wiki, GPU Driver Recommendation][10] says the check may flag
  current drivers and provide nonexistent recommendations. It advises
  continuing if the game works, but supplies no alternative suppression
  mechanism. Windows driver-installation instructions do not apply to the
  Apple GPU inside this Wine runtime.

Searches covered the exact version string, configuration flag, launch-switch
requests, Wine/CrossOver/Proton reports, and the Whisky fork's release history,
PR and source. Google returned a JavaScript interstitial, CodeWeavers' matching
forum page returned 403, and a later DuckDuckGo query hit a bot challenge.
Those unavailable pages are not counted as reviewed evidence. Search results
alone are not proof that no other fix exists.

## Recommended order

The native Try Again/Repeat experiment has failed the restart check. Do not
repeat it or the manual flag edit as a new fix. The remaining research lead
is the DXGI query compatibility approach, with its actual implementation
trade-offs and the mismatch between upstream's constant and our runtime's
registry value. Recurring click automation remains deferred at the user's
request; no version substitution has been approved or applied.

[1]: https://steamcommunity.com/app/553850/discussions/0/803471938699808143/
[2]: https://github.com/dappermint/winecx-gptk/commit/df88b1803b0a46c17d53375897b1fe100103a1b3
[3]: https://github.com/frankea/Whisky/pull/227
[4]: https://github.com/frankea/Whisky/releases/tag/v4.6.4-beta.1
[5]: https://github.com/frankea/Whisky/releases/tag/app-v3.7.0
[6]: https://github.com/frankea/winecx-gptk/blob/50a54af/gptk-video/dxgishim.c
[7]: https://steamcommunity.com/app/553850/discussions/0/803471938699811827/#c585057095914782729
[8]: https://steamcommunity.com/app/553850/discussions/1/833871839865437475/
[9]: https://www.gamingonlinux.com/2026/04/proton-hotfix-updated-to-fix-helldivers-2-on-linux-steamos-systems/
[10]: https://helldivers.wiki.gg/wiki/GPU_Driver_Recommendation
