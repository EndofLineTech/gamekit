# Stardew Valley: profile-driven native cursor guard

Issue: `gamekit-vl6`. On macOS 27.0 (26A428), M4 Pro/24 GB, the managed Windows
Stardew Valley build 16826371 showed both Wine's macOS cursor and the game's
drawn brown cursor. The ordinary game remained playable with saving and reloading.

The earlier hardware-cursor preference and true-fullscreen/display-capture trials
did not resolve the duplicate. The user's shake-to-locate test did not either;
all experimental game/Wine settings were restored. A short `CGDisplayHideCursor`
trial from another host process returned success but did not hide the cursor in
Stardew. A screenshot without cursor overlay contained the brown in-game cursor
but not the white host arrow, confirming that the latter is a separate macOS
cursor rather than part of the game's rendered image.

## Qualified mechanism and limits

An isolated candidate loaded by the existing owned x86_64 Wine helper replaced
Wine's `NSCursor.set` selection with a transparent cursor **inside the game's
process** while its window was active. The user observed only Stardew's brown
cursor. The user confirmed that the macOS pointer returned when Gamekit took
focus and reported choosing Exit in Stardew; there was no observed crash.
This was menu and focus/exit acceptance, not a gameplay, save/reload, or
multi-display trial with the guard enabled.

The normal Gamekit build then offered the profile-declared toggle off by default.
With managed Steam stopped, enabling it persisted in `GamePresentation.json`
without changing the existing Helldivers fullscreen preference. The next owned
session projected only the matching Stardew executable into the session map and
loaded the packaged helper into the running game. The user again confirmed one
usable brown game cursor, then confirmed the macOS pointer returned on switching
to Gamekit. The game was closed through Gamekit's scoped Stop after this check.

Gamekit's generic mechanism activates only if the effective per-game setting is
enabled and the session-bound mapping matches the game AppID, installation
directory and profile-declared executable. The mapping originates in the
validated JSON profile; the executable and default do not live in native code.
Steam and other games have no mapped guard. Wine's files, game files, registry,
save data and global macOS cursor state are not modified. An app switch restores
the system pointer; if needed, **Stop Windows Steam** ends the game process and
the cursor substitution. The original option is one toggle away with a stopped
session.

Revision 3 of `413150.json` offered the guard off by default. At the user's
request, revision **4** enables it by default for this tested game and setup.
New installs therefore use the guard on the next fresh managed Steam session.
**Stop Windows Steam** before changing the toggle in Stardew's gear; an explicit
saved **Off** choice takes precedence over the profile's default, including after
downloads or updates, and can be reversed there. The portable profile is published
on the wiki; the user's saved preference stays local. The menu/focus acceptance
supports the changed default, but gameplay and save/reload with it on remain a
separate follow-up (`gamekit-np5`). If an imported profile replaces the bundled
profile, it must explicitly declare the
capability or the toggle is unavailable. Source and acceptance apply only to
the recorded Mac/runtime and game build, not to other games by inference.
