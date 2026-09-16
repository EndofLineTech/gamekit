# Windows Steam application identity

Follow-up `gamekit-75s` addresses the acceptance report of generic/duplicate `wine`
Dock icons and apparent Gamekit quit/reopen trouble while Steam remained alive.

## Launch path

Persistent Steam launches now go through macOS Launch Services using a separately
named, local application bundle and an independent launch helper:

```text
~/Library/Application Support/Gamekit/Launchers/Windows Steam.app/
  Contents/Info.plist
  Contents/Gamekit-runtime.json
  Contents/MacOS/Windows Steam
  Contents/MacOS/wineserver
  Contents/bin -> MacOS
  Contents/lib/...
  Contents/share/...
```

The launcher is an `LSUIElement` agent, so its otherwise-empty launcher process
does not add a second foreground Dock application. Wine GUI children run from the
copied executable named **Windows Steam**. The original runtime is neither renamed
nor patched. Steam still uses the same managed prefix, session tag, Wine version,
packaged dependency environment and unchanged Apple graphics payload.

The complete Wine engine is copied because Wine 10 derives its child-loader path
from the real path of `ntdll.so`. A loader-only wrapper with symlinks back to the
source engine re-executes the original `wine` binary and loses the desired name.
Renaming argv[0] did not change the macOS application name in the isolated probe.

Creation uses a private staging directory, a cooperative creation lock,
descriptor-relative copy/move operations and no-clobber publication. APFS file
clones share unchanged binary data where supported; other filesystems use a normal
copy. Source symlinks are copied literally, not traversed. Failed staging cleanup
does not follow symlinks. The source runtime remains intact.

The derived bundle's manifest, exact Info.plist, internal bin alias and pinned
critical-file hashes are validated before reuse. An altered existing bundle is
refused rather than overwritten. This is a local generated cache, not permission
to redistribute Wine or Apple's payloads. Future runtime revisions require a
corresponding cache migration/revalidation. An app crash during initial creation
can leave a private staging directory; automatic orphan-cache management is not
part of this change.

Process observation recognizes the derived bundle path in addition to the source
engine. UID/start-time, prefix, session-token and prefix-identity checks continue
to apply. The `/usr/bin/open` helper receives literal arguments and explicit
`--env` entries, with the launched application's standard streams connected to
`/dev/null`. Use Gamekit to initiate launches.

## Independent macOS ownership

Direct `NSWorkspace.openApplication` from Gamekit linked the hidden UI-element
launcher as a subordinate application. On normal Quit, Gamekit's process exited,
but Launch Services retained it as **`exited-with-subordinates`** while Steam lived.
The Dock consequently reported Gamekit as “Running in Background.” This was not
the thirty-second Stop timeout and was invisible to a PID-only quit test.

The short-lived `open` helper now disclaims inherited macOS process responsibility
before requesting the launch. This prevents the hidden launcher from retaining
Gamekit's application entry. It does not bypass permissions or change the prefix
ownership checks. Ordinary subprocesses retain the previous behavior.

The native bridge dynamically resolves `responsibility_spawnattrs_setdisclaim`,
the macOS SPI used for independent application launches by
[Chromium](https://github.com/chromium/chromium/blob/main/base/process/launch_mac.cc)
and [Qt Creator/LLDB](https://www.qt.io/blog/the-curious-case-of-the-responsible-process).
This is an explicit dependency of the personal macOS 27 prototype, not an App Store
compatibility claim. If unavailable, launch fails with `ENOTSUP`; it does not
silently fall back to subordinate ownership. A native test verifies that the
independent child is its own responsible process.

## Quit/reopen verification boundary

The previous UI smoke test used forced process termination, which did not prove
the user-facing normal Quit path. A new opt-in test sends the normal Quit Apple
event, checks that Gamekit exits promptly while Steam remains running, then uses
ordinary `open` (not `open -n` or XCTest relaunch) to reopen it.

The strengthened live test reproduced the reported failure on the previous build:
Gamekit's PID exited, but `lsappinfo list` still marked it exited-with-subordinates.
With independent launch ownership, that regression passes: normal Quit completed
in about 0.12 seconds, no retained Gamekit entry remained, Steam stayed running,
and ordinary reopening succeeded. The same test observed one regular/foreground
managed application named **Windows Steam** and a non-Dock launcher agent.

The user subsequently confirmed the single correctly named Dock entry, normal
Command-Q quitting without “Running in Background,” and Stop/relaunch. The keyboard UI test
also passed after an earlier automation-mode initialization failure: it used
Command-Q, ordinary Launch Services reopening, verified Steam was still running,
and stopped the managed session through the UI.

```bash
GAMEKIT_REAL_QUIT_PROBE=1 \
GAMEKIT_APP_PATH="$PWD/.build/xcode/Build/Products/Debug/Gamekit.app" \
swift test --filter realGamekitQuit
```

This test requires the existing managed Steam to be stopped, performs real
launch/quit/reopen/stop operations, and never resets the prefix. It waits for GUI
registration before checking names, rather than treating initial process startup
as proof of the final Dock presentation.
