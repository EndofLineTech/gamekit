# E6 game test matrix

## Selection and scope

E6.1 (`gamekit-ec8.1`) planning snapshot: 2026-09-16. The user selected
**Helldivers 2, Satisfactory, and Stardew Valley**, with separate caps of
**75 GiB total downloads** and **75 GiB additional installed data**. Retain at
least **15 GiB free working space**. About 120 GiB was available when planning.

The user selected 1080p Medium, keyboard/mouse, ray tracing and upscaling off
where supported, 15 minutes of gameplay per title, and a stable 30 FPS target.
The user approved a hands-on budget of **90 minutes total**, approximately
30 minutes per title, plus download time, and publication of this matrix through
a documentation PR into `dev` on 2026-09-16.

E6.2 performs the tests using Windows Steam through the accepted Gamekit
package. All execution results are currently **not tested**. This is a baseline
evaluation; game-specific fixes, renderer replacements and compatibility
workarounds are outside its scope.

## Selected builds and size estimates

| Title | Steam AppID | Public-branch BuildID at planning | Download (GiB) | Installed (GiB) |
| --- | --- | --- | ---: | ---: |
| Helldivers 2 | 553850 | 24826606 | 20.988 | 22.246 |
| Satisfactory | 526870 | 24656030 | 12.125 | 28.124 |
| Stardew Valley | 413150 | 16826371 | 0.423 | 0.644 |
| **Base total** | | | **33.536** | **51.014** |

These are provisional public Steam metadata obtained through the third-party
[SteamCMD API](https://api.steamcmd.net), not installed versions or measured
downloads. Values use 1 GiB = 1,073,741,824 bytes and exclude shared prerequisites,
optional DLC, patch staging, shader caches and later updates. BuildIDs identify
Steam builds; in-game version strings must also be recorded during execution.

Reconcile the estimates with Windows Steam's current install dialog before each
download. Record language, selected DLC, download size and disk requirement.
Count prerequisites, updates and retries against the cumulative download cap;
uninstalling a game does not reset it. Check free space during staging as well
as after installation. Pause if a cap or the working-space reserve would be
exceeded and revise the budget before continuing.

Metadata inputs, public branch only:

| AppID | Base depot(s) counted | Public manifest ID(s) |
| --- | --- | --- |
| 553850 | 553851, 553853, 553854 | 5937460960958490081, 9020691380707780829, 6929803021334100650 |
| 526870 | 526871 (Windows) | 4522661880264054134 |
| 413150 | 413151 (Windows) | 4278718763097142923 |

Sources: [Helldivers metadata](https://api.steamcmd.net/v1/info/553850),
[Satisfactory metadata](https://api.steamcmd.net/v1/info/526870),
[Stardew metadata](https://api.steamcmd.net/v1/info/413150).
Recheck actual installed BuildIDs and depot manifests in E6.2; a newer public
build becomes the recorded test subject rather than silently inheriting results.

## Graphics, prerequisites and scenarios

| Title | Graphics and dependencies | Baseline scenario |
| --- | --- | --- |
| Stardew Valley | MonoGame/.NET game. Steam lists DirectX 10 as a requirement, but that does not establish the current build's active renderer. Record backend evidence if available; otherwise mark unknown. No dedicated anti-cheat or external account requirement disclosed in the reviewed store metadata. | Create a separate test farm. Walk outdoors and indoors, use tools, plant/water crops, interact with menus, hear music/effects, sleep to save, exit and reload that farm. |
| Satisfactory | DirectX 12 baseline. The official community wiki lists DX12 as default, DX11 as deprecated and Vulkan as experimental. No dedicated anti-cheat or external account requirement disclosed in the reviewed store metadata; use single-player. | Start a new Grass Fields session, record onboarding choice, explore, collect resources, craft and place available starter equipment. Save, exit and reload; verify position, inventory and placed equipment. |
| Helldivers 2 | Expected DX12 path, to be confirmed from the tested build where possible. Arrowhead documents kernel-level nProtect GameGuard. Steam metadata lists PlayStation Network account linking; record any actual account gate separately. Current compatibility with this Gamekit recipe is unverified. | Attempt normal launch. If usable, test the tutorial or a low-difficulty mission for 15 minutes, documenting which scenario and online conditions. Check movement, aiming, firing, audio and menus, then normal exit/relaunch and applicable server-side progression. A mission completion is not required within the time budget. |

Run Stardew first, Satisfactory second, and Helldivers third for a progression
from lightweight gameplay to 3D rendering and online/anti-cheat dependencies.
Use separate test saves/profiles where available. Record Steam Cloud state and
avoid overwriting existing progress; cloud-conflict choices remain user-owned.
Authentication stays in Steam or the publisher's UI.

For Stardew, use 1920×1080 where available and default visual options where no
Medium preset exists. Record zoom and display mode. For Satisfactory, select
Medium, 100% render scale, upscaling/frame generation off and Lumen global
illumination off; record the resulting Custom preset if applicable. Use DX12
through the normal settings UI. For Helldivers, use Medium and native rendering
where available. Record unavailable options as not applicable rather than
inventing equivalent settings. Record frame cap, VSync and display mode for
every title. Changing resolution, API or quality after failure is a separate
experiment, not a passing result for this baseline.

## Environment and evidence

Use the accepted [E5 package and runtime recipe](e5-acceptance.md): Gamekit
0.1.0/build 1 from source `27c1f74500bda1eb390788feec67addc30502b59`, packaged as
`Gamekit-20260916T212536Z`; M4 Pro, 24 GB RAM, macOS 27.0 (26A428),
Sikarugir Wine 10.0 revision 6 and unchanged Apple D3DMetal 4.0b2.
Recheck these facts at execution and record any changes. Use the normal managed
Steam environment without resetting it or modifying the manual evaluation
environments. Stardew's native macOS edition is not the subject of this test.

For each run record date/time, package identity, runtime/OS and Steam client
versions, environment label, Windows game executable, public branch, BuildID,
in-game version, language/DLC, sizes, settings, input/audio devices, display
resolution/refresh rate and power mode. Record startup time and shader-compilation
delays separately from gameplay. The user performs and confirms gameplay/input/
audio observations; a running process or screenshot alone is insufficient.

Keep evidence limited to settings, outcomes, timings and relevant diagnostic
summaries. Keep raw logs local; omit account identifiers, credentials and private
paths from committed evidence. Link Gamekit's safe diagnostic summaries where
relevant and record an exact error message without account data.

## Independent result criteria

| Result | Pass criterion | Failure or unresolved outcome |
| --- | --- | --- |
| Install | Steam completes the Windows installation and shows Play; BuildID and installed size recorded. | Download, disk or prerequisite error is an install failure. A budget/network interruption is recorded as blocked with its cause. |
| Launch | Normal Steam launch reaches an interactive game menu or playable scene. | A crash or explicit runtime/anti-cheat error is a launch failure. A visible launcher, splash screen or living process is insufficient. Account/service gates are reported separately. |
| Functional playability | Complete 15 minutes of actual gameplay with usable rendering, audio and keyboard/mouse input, no crash/hang or progression-blocking defect. | Record the failing dimension, elapsed time and reproduction steps. If launch fails, gameplay is not tested rather than an additional observed failure. |
| Persistence and relaunch | Normal exit, Steam returns to idle, second normal launch succeeds, and saved state/progression reloads where applicable. | Record exit, relaunch and persistence separately. For online progression, explain whether a save point was actually reached. |
| Performance | During gameplay, observed FPS is generally at least 30, without sustained drops below 30 for more than five seconds or repeated disruptive stalls. Report loading and first-use shader stalls separately. | Record available measurements and their method. If no reliable counter is available, report subjective responsiveness and performance **unverified**; do not fabricate FPS, averages or percentiles. |

A full baseline pass requires all applicable criteria. Functional playability
may pass while performance remains unverified or fails the target. Report that
distinction explicitly. Short sessions establish only the tested scenario's
behavior, not endgame factory performance, all multiplayer modes or long-term
stability.

Allow approximately 30 minutes per title including setup, startup, 15 minutes
of gameplay, save/load and relaunch. If startup or service waits consume that
budget, record the incomplete checks as blocked/not tested; do not infer a
compatibility failure from elapsed time alone. Record an observed failure before
one same-configuration reproduction attempt if time permits. Preserve the first
result and any intermittency. Game-specific remediation is separate follow-up
work.

## Source notes and candidates deferred

Sources reviewed 2026-09-16:

- [Stardew Steam requirements](https://store.steampowered.com/app/413150/)
  and [developer's MonoGame migration announcement](https://www.stardewvalley.net/stardew-valley-1-5-5-released-on-pc/).
- [Satisfactory Steam requirements](https://store.steampowered.com/app/526870/)
  and [official community wiki settings](https://satisfactory.wiki.gg/wiki/Settings).
- [Helldivers Steam requirements API](https://store.steampowered.com/api/appdetails?appids=553850&l=english)
  contains conflicting 135 GB minimum / 40 GB recommended storage figures.
  The publisher's [Large Build Delist announcement](https://steamstore-a.akamaihd.net/news/externalpost/steam_community_announcements/1826362059920469)
  and smaller public depots support using the current slim build estimate,
  subject to the client check.
- [Arrowhead's anti-cheat statement](https://steamcommunity.com/app/553850/discussions/2/4206994023681287288/)
  identifies kernel-level GameGuard; its [launch-error support article](https://arrowhead.zendesk.com/hc/en-us/articles/14732747845020-I-receive-Error-114-when-attempting-to-launch-HELLDIVERS-2)
  documents GameGuard errors. These establish a dependency/risk, not a measured
  failure on this Mac. Absence of an anti-cheat disclosure for another title is
  not independent proof that none exists.
- Balatro (2379780, public BuildID 17459173) was considered but the user selected
  Helldivers instead. Its Windows depot estimate was 0.056 GiB downloaded /
  0.062 GiB installed; Steam lists OpenGL 2.1.
- [Forza Horizon 4](https://store.steampowered.com/app/1293830/) (1293830,
  BuildID 12772551) exceeds both caps at approximately 78.187 / 82.100 GiB for
  the base depot. It requires Xbox Live and is delisted from sale.
- [Assassin's Creed Shadows requirements](https://store.steampowered.com/api/appdetails?appids=3159330&l=english)
  (3159330, BuildID 24716659) exceed the budget at approximately
  119.862 / 146.657 GiB for the base depot alone. Steam lists DX12, a Ubisoft
  account and Denuvo Anti-tamper with a five-per-day machine activation limit.
  Anti-tamper is not being classified as multiplayer anti-cheat.
