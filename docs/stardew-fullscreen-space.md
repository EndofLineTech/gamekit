# Stardew Valley fullscreen Space and launch focus

Issues: `gamekit-c52`, `gamekit-b84`. Live user acceptance on 2026-09-26.

The Windows Stardew Valley build **16826371** previously remained behind Gamekit
when launched and shared the current macOS desktop. The existing generic native
Space helper was already qualified for Helldivers, but Stardew had no profile
declaration for it. The user asked for a shared Space setting and a per-game
override, as with graphics selection. Gamekit offers both to installed games;
the shared default is off and only a screen-covering managed Wine window can
create the Space.

## Bounded Stardew qualification

With managed Steam stopped and no local profile import, a temporary JSON profile
declared the Stardew executable and `fullscreenSpace` capability. The user enabled
**Use fullscreen Space** in Stardew's gear. The session-bound mapping contained
only the matching AppID and executable. The user's saved `fullscreen=false` and
`windowedBorderlessFullscreen=true` preferences were read before and after and
did not change. The cursor guard remained enabled, as did the pre-existing
Helldivers Space setting. No save or game binary was edited.

Gamekit sent a single normal Play request. The user confirmed that Stardew
opened in a **separate macOS fullscreen Space** and came to the foreground
automatically, without a manual switch. The game was later exited by the user.
This qualifies the existing borderless game window on the tested built-in
display; it does not establish all display geometries, every game, or a full
gameplay/save-reload pass in this Space.

The production revision-5 `413150.json` retains the cursor guard and adds
Stardew-specific Space guidance with `defaultEnabled=false`. The user's saved
per-game **Use fullscreen Space** selection remains in `GamePresentation.json`;
there is no need to change the shared default or force other games into Spaces.
Games without a profile can still choose **Use shared default**, **Use fullscreen
Space** or **Keep on desktop** from their gear. The native helper checks the owned
session, installation path and a screen-covering window before creating a Space.
