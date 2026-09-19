# Cold Steam launch feedback (`gamekit-525`)

## What actually happened

The original "dropped request" interpretation was incorrect. The retained
Steam console log covers the same run as `.build/p92-packaged-ui-launch`:

| Local time, 2026-09-18 | Evidence |
| --- | --- |
| 17:03:26 | Steam starts with `-silent` |
| 17:04:12 | Steam reports startup took 45.47 seconds |
| 17:04:13 | Steam processes `-applaunch 553850` and begins its launch action |
| 17:04:15 | Launch waits for user response to Cloud synchronization, `syncfailed` |
| 17:04:55 | The original screenshot shows Steam's store, without a visible sync prompt |

There is no game-process creation event for that launch. The later warm launch
passes Cloud synchronization and creates a process. The screenshot alone was
insufficient to infer that Steam lost the command. The logs establish a queued,
accepted request blocked on user attention; they do not establish why the
prompt was not visible in that screenshot.

A new cold-start observation sent exactly one request at about 7 seconds,
observed Steam preparation at 55 seconds, Cloud synchronization at 56 seconds,
and process creation at 57 seconds. No retry was needed or issued.

## Delivered behavior

After sending a game request, Gamekit watches for up to 120 seconds and reports
fixed, game-specific feedback:

- Waiting for Steam to acknowledge the request.
- Steam is preparing the game or synchronizing Cloud data.
- Cloud synchronization, another-session handling, or another prompt needs the
  user's attention, with **Show Windows Steam** available.
- Steam reported creating a game process. This is not a rendering/gameplay pass.
- Tracking ended or could not confirm startup; check Steam before trying again.

Play controls are disabled while this bounded observation is pending. There is
no automatic resend, Cloud acknowledgement, account takeover or game shutdown
from launch tracking. Stopping Steam invalidates its observation; quitting
Gamekit does not cancel Steam's game request. After the observation window,
manual controls become available with explicit guidance rather than an invented
success claim.

The cold-start presentation wait for Steam's browser process was also expanded
from 30 to 90 seconds. This avoids silently abandoning the main-window request
solely because a cold client exceeds 30 seconds. Browser-process existence is
still not proof of login, Cloud readiness or command acceptance; launch feedback
uses fresh Steam events rather than that assumption.

## Evidence boundary

The reader starts at the current end of `logs/console_log.txt` before a launch.
It reads descriptor-relative, no-follow regular files owned by the current
user, and pins file identity/offset. Missing initial logs may be created later;
rotation, disappearance or observed truncation ends tracking rather than
replaying history. Reads are capped at 64 KiB per poll and 1 MiB total, with an
8 KiB partial-line limit. Prefix/session ownership is checked before and after
each read. Transient incomplete observations retain the cursor for a later
bounded poll; changed scope is refused.

Only fixed event forms for the exact requested numeric AppID affect feedback.
Unknown formats remain unconfirmed. A `Completed` task alone is not process
creation evidence. Raw arguments, file paths, network addresses, account details
and other-session game names are never surfaced by this parser. This log is an
observation source only and never authorizes process control or another launch.

Tests cover the Cloud incident, unrelated IDs, partial lines, stale historical
success, other-session prompts, bounds, file redirection/rotation/truncation,
scope changes, transient observation gaps, and exactly-one-request behavior.
Private logs/screenshots remain local under `.build/525-*`.

The packaged-app check observed Play disabled during the waiting phase and
enabled again after the fixed process-created message appeared. The game reached
the rendered ship, with no driver-alert intervention, and the session stopped
gracefully. The earlier short process-creation probe required scoped forced
cleanup while the game was still starting; that was test cleanup, not launch
tracking behavior. No Cloud conflict or account prompt was automatically answered
or deliberately induced for testing.
