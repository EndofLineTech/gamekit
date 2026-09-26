# Ace Combat 7 — default launch and controller gameplay

Issue: `gamekit-77k`. User-reported result on **2026-09-26**.

**Gameplay observed.** The user reported that Ace Combat 7 “Works GREAT” with no
special changes after testing the controller in Windows Steam. This is a positive
play report, not a completed gameplay/audio/save-and-reload acceptance checklist.

## Recorded setup

| Item | Evidence |
| --- | --- |
| Game | ACE COMBAT™7: SKIES UNKNOWN, Steam AppID 502500 |
| Installed build | 9855922, from the managed Steam installation manifest |
| Host | Apple M4 Pro, 24 GB RAM; macOS 27.0 (26A428) |
| Runtime | Sikarugir Wine 10 rev6; selected `driver-version-1` revision |
| Graphics selection | Shared Metal 3; no Ace Combat 7 per-game backend override |
| Launch | Normal managed Windows Steam launch; no game-specific launch options reported |
| Controller connection | Xbox Wireless Controller connected to macOS via Bluetooth; macOS Bluetooth and HID inventories detected it |
| Windows Steam input | Steam displayed “Xbox Series X controller” in USB mode; user successfully tested its inputs |
| Game result | User reported that Ace Combat 7 works great with the default setup |

The USB mode label is Steam's presentation of the device, not evidence of a
physical USB connection to the Mac.

The selected Metal 3 backend is a Gamekit setting, not a trace of the game's
rendering API. No DXMT/DXVK qualification, measured frame rate, exact play
duration, separate audio check, or save/reload verification was reported. Those
checks would be needed before upgrading the wiki status to **Playable**.
