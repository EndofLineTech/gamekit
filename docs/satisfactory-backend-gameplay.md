# Satisfactory: optional-backend gameplay acceptance

Issue: `gamekit-9ay`. User-controlled testing on **2026-09-19** extends the
earlier menu-only qualification in [graphics backends](graphics-backends.md).

## Results and recommendation

| Backend | Result | Qualification |
| --- | --- | --- |
| Apple/Metal 3 | Previously accepted gameplay path; restored after comparison | Prior user-confirmed rendering/audio/input/save-reload acceptance; not a new timed run here |
| DXMT `dxmt-0.80-compat2` | **Functional pass** | User confirmed gameplay, audio, controls, manual test save and reload successful |
| DXVK `dxvk-macos-1.10.3-compat2` | **Gameplay failed: unplayable** | User reported very slow loading, extreme choppiness and poor responsiveness; exited successfully |

Keep **Apple/Metal 3 as the default**. DXMT is a functionally tested alternative,
with a temporary-stuttering caveat. **Do not recommend the tested DXVK payload
for this game.** Its earlier successful device/render probes and rendered menu
did not predict acceptable gameplay.

During DXMT testing, movement was initially quite choppy and settled afterward.
The user reported similar temporary behavior in the default graphics mode.
This is not evidence of a DXMT-specific regression or proof of a common cause.
Shader compilation, asset streaming and other causes remain unconfirmed.

The user described DXVK as “unplayable,” “really slow to load,” “super super
choppy,” and not responding well. DXVK save/reload acceptance was not completed;
the unusable gameplay result was sufficient to end that comparison.
Follow-up **`gamekit-7j9`** tracks evidence-led performance investigation.

## Tested setup

- Satisfactory AppID **526870**, installed build **24656030** from the qualified
  setup (game 1.2.4.0 / UE 5.6.1).
- M4 Pro, 24 GB RAM; macOS 27 build 26A428.
- Sikarugir Wine 10 revision 6, selected `driver-version-1` runtime.
- Accepted package `Gamekit-20260919T192107Z`, source `117c988`.
- Per-game backend selected and read back before each run; shared backend
  remained Metal 3. Actual Gamekit **Play** invoked both sessions.
- Gamekit's transient options for both alternatives:
  `-dx11 -ini:Engine:[SystemSettings]:r.Streamline.InitializePlugin=0`.
  DXVK additionally uses
  `-ini:Engine:[SystemSettings]:r.PostProcessing.PreferCompute=1`.

These are user-reported functional/performance observations, not an instrumented
benchmark. No measured FPS, exact test duration, fresh per-run API trace, or
matched-scene/settings performance ranking is claimed. The existing qualification
documents establish the launch recipe; this report adds hands-on results.

## Session sequence and restoration

1. Original Satisfactory selection was **Use shared default**, effective Metal 3.
2. Selected DXMT and launched from the packaged app. Left the game running for
   the user to test gameplay/audio/controls and a separately named manual test
   save/reload. The user confirmed all checks successful.
3. After game exit, the first backend-edit attempt correctly refused while
   Steam was still running. Scoped managed shutdown completed gracefully.
4. Selected/read back DXVK and launched from the same packaged app. The user
   reported unplayable behavior, then confirmed successful game exit.
5. Scoped Steam shutdown completed gracefully. Restored and read back
   `override=inherit`, `shared=metal3`, `effective=metal3`.

The agent did not edit or remove saves, migrate the prefix, or change the
accepted runtime. This task establishes a mixed acceptance result; it does not
require both backends to succeed in order to report the comparison accurately.
