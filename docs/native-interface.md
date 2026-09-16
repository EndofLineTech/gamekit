# Native setup and operation interface

E5.1/E5.2 keep the SwiftUI layer over the existing validated core APIs.

## Everyday workflow

The lifecycle controls are near the top of the window. Setup lists host, Rosetta,
runtime, graphics and storage checks with concrete next steps and official links.
Install and Launch require successful checks. **Refresh checks** (Command-Shift-R)
clears stale readiness while it runs. Launch is Command-L; Stop is Command-Shift-S.

**Choose runtime…** selects the local `.app` containing the pinned Sikarugir/GPTK
recipe. This does not install a runtime, accept licenses, or permit arbitrary Wine
versions. **Use managed runtime** restores the conventional path. The selection
persists in `Metadata/RuntimeSelection.json`; prefixes and logs do not move.
Selection is blocked during operations, while registered processes are active,
or while a persistent launch receipt exists. Use Stop to clear the old session
before changing its source. A positively idle receipt can be cleared even if the
old runtime has disappeared; uncertain or active ownership cannot.

Storage paths and the 15 GiB working allowance are visible. Downloaded games remain
inside the managed prefix unless Steam is configured with external libraries.
Older recovery archives retain data and consume storage independently.

## Controls and state

`SetupModel` owns a single window operation token. All launch, setup, recovery and
selection actions acquire it synchronously before beginning async work. This
prevents conflicting clicks between cards. Core leases and validation still guard
cross-process races and changes after a button was enabled.

`SteamActionPolicy` derives availability from prerequisites, saved progress, file
facts and complete process observations:

- A fresh idle environment can Install after prerequisite validation.
- An installed idle environment can Launch, not reinstall.
- Interrupted setup offers Retry when idle, or explicit interrupted-session Stop
  when one consistent owned tag is observed.
- Reset requires registered metadata and a complete empty process inventory.
- Busy, corrupt or uncertain state disables conflicting/destructive actions.
- Setup is silent. Readiness requires stable client, web-helper and visible-window
  evidence. The app finishes setup and opens Steam for normal use automatically.

Progress stays in a persistent top-of-window bar, with stage-based indeterminate
activity indicators. No download or
Steam-update percentages are invented. Reset controls require opening **Show reset
options…** and then a distinct confirmation; they are not adjacent substitutes for
Retry. Errors provide a next action rather than raw enum descriptions. If a clean
reset is interrupted, its message explains that Retry continues prior confirmed
deletion rather than promising all files were preserved.

The standard SwiftUI controls retain native keyboard focus and accessibility roles.
Named accessibility identifiers support UI regressions; dynamic status is readable
as text and is not conveyed by color alone. Full screen-reader usability remains
part of hands-on release acceptance.

## Tests

Core tests cover persisted selection, redirected paths, ownership locks, missing
runtime status and the action-state matrix. UI tests cover Rosetta/storage/runtime
failure guidance, disabled Install, readiness after Refresh, keyboard Refresh and
conflicting controls while checks are pending. Debug-only prerequisite fixtures
require an explicit temporary metadata root and never bypass core preflight.

Acceptance uses the real runtime separately. GUI tests must not terminate a live
setup until its completion record has been verified. Keep destructive tests in
disposable roots and preserve the user's installed environment.
