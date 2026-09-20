# Balatro functional acceptance

Issue: `gamekit-igd`. User-reported acceptance on **2026-09-20**.

**Result: Playable.** The user reported “Balatro works great” and then explicitly
confirmed that saving/resuming a run, audio and controls all work. No defect was
reported in this session.

## Recorded setup

| Item | Evidence |
| --- | --- |
| Steam AppID | 2379780 |
| Installed build | 17459173, from the managed Steam manifest |
| Host | M4 Pro, 24 GB RAM; macOS 27 build 26A428 |
| Selected runtime | Sikarugir Wine 10 rev6, `driver-version-1` |
| Shared setting | Metal 3; no per-game graphics override |
| Framework | Installed `love.dll` and `SDL2.dll`; bundled readme identifies LÖVE |
| Active graphics API | Not independently traced |
| Additional launch options | None reported; no Gamekit title-specific options added |

The saved Metal 3 selection is not proof that Balatro renders through D3DMetal.
The wiki records this under **Other API**, with API confirmation explicitly
unknown. It does not qualify the game on DXMT or DXVK.

This is a user-confirmed functional result, not a performance benchmark. No
measured FPS, exact session duration, independently verified resolution or precise
framework version is claimed. The update required no settings or save changes.
