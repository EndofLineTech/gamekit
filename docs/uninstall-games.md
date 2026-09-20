# Uninstall games from Gamekit

Issue: `gamekit-q28`; foreground handoff follow-up: `gamekit-29g`.

## User flow

1. In **Installed games**, click the trash button beside the game's gear.
2. Review the game name. Choose **Cancel** to leave it alone, or
   **Continue in Windows Steam** to open Steam's uninstall flow.
3. Review Steam's own confirmation or instructions. Steam handles a running
   game, pending downloads and file-removal policy.
4. Gamekit polls the managed library every three seconds and when reactivated.
   The tile disappears when Steam's installation record disappears; **Refresh
   games** is also available.

The action starts managed Windows Steam if necessary. It never invokes macOS
Steam. After sending the request, Gamekit explicitly transfers macOS focus to
the owned Steam window process so the confirmation is visible. The bounded
focus check never resends an uninstall request. If activation is unavailable,
the UI still reports the request as sent and offers **Show Windows Steam**.
The handoff waits for Gamekit's confirmation sheet to dismiss, uses the verified
session's Steam UI PID, and checks that activation remains stable. The same
handoff is used by the Show Windows Steam controls.
An **Uninstall requested** message reports dispatch, not completed file
removal. A cancellation in Steam leaves the tile installed. **Show Windows
Steam** exposes a hidden prompt. Steam owns local-file/save behavior; the feature
does not guarantee that every title stores or retains saves in the same way.

Uninstall is available for valid managed-library entries even when a download is
incomplete or the game directory is missing. It is disabled while another
Gamekit operation or a tracked Play request is pending, or when runtime/session
readiness is unavailable. External/native Steam libraries remain outside scope.

## Runtime contract

`SteamLifecycle.requestGameUninstall(appID:)`:

- Validates the numeric AppID against the current managed library before startup.
- Reuses the existing owned Steam launch, installation/execution leases, prefix
  identity, runtime preflight and bounded client-readiness checks.
- Revalidates the installation record immediately before dispatch.
- Executes the managed Wine loader with arguments
  `[managedSteamExecutable, "steam://uninstall/<AppID>"]`, the recorded prefix and
  session token, a ten-second command timeout and bounded output.
- Rejects foreign/uncertain ownership, cancellation, changed paths, conflicting
  leases and missing/invalid target records. No automatic retry is sent.
- Returns only after successful command dispatch; it does not remove files,
  edit a manifest, run a manifest-supplied executable or interpret dispatch as
  successful uninstallation.

The UI uses the shared operation gate and records an `uninstallation` diagnostic
stage. Its normal library refresh reports that a requested title is no longer
listed only after a complete readable manifest scan no longer contains it.
Launcher-cache cleanup remains a separate existing maintenance action.

## Verification

Core tests exercise cold/warm Steam, ready/updating/missing-file installations,
correct executable/URI/prefix/session routing, retained game/save bytes, invalid
and removed-during-startup targets, ownership/inspection failures, cancellation,
conflicting leases, prefix replacement and failed command dispatch.

Native UI coverage checks the game-specific confirmation, cancellation without
starting Steam, incomplete-install availability, busy/runtime gating and removal
from the list after a fixture manifest disappears. A direct local Accessibility
check opened **Uninstall Stardew Valley?**, cancelled, and confirmed that no
managed Steam process had started. The local XCTest runner initially timed out
enabling automation; CI runs the fixture-based UI checks separately.

Actual deletion of a user's installed game is not an acceptance-test prerequisite.
The cancellation check and deterministic command tests preserve the installed
library; Steam remains responsible for the final removal operation.
