# E5 personal-prototype acceptance

Status: **accepted for the recorded personal-use scope**. The user confirmed all
seven post-reboot steps passed. This acceptance does not create a stable release
tag, promote `dev` to `main`, or establish game compatibility.

## Recorded environment

- M4 Pro / Apple silicon; macOS 27.0 build 26A428.
- Xcode 27.0 build 27A266a, Swift 6.4 in Swift 6 mode, XcodeGen 2.46.0.
- Validated runtime/template/graphics identities are in `validated-versions.json`.
- Every local package additionally records actual build toolchain, executable hash,
  source-tree hash, commit and dirty-tree status in `build-manifest.json`.
- Authentication remains inside Steam. Account/session files and raw logs are not
  included in source control or package manifests.

## Coverage and evidence

| Check | Evidence / status |
|---|---|
| Missing Rosetta/runtime/disk guidance | Native UI fixtures; install disabled; corrective refresh enables it |
| Local runtime selection | Atomic persisted selection; source validation; operation/receipt locks; managed data root unchanged |
| Conflicting clicks / keyboard | Shared synchronous operation token; core action matrix; Command-Shift-R UI regression |
| Fresh installation with paths containing spaces | Isolated acceptance roots under Gamekit/Acceptance; external selected runtime |
| Login, Steam Guard, Library | User confirmed on the first fresh E5 environment; saved installed revision 6 |
| Silent installer and automatic readiness | Second fresh environment ran `/S`, reached installed revision 6 in approximately 63 seconds without installer or confirmation clicks |
| Readiness evidence | Complete consistently tagged client + web-helper set and visible web-helper window; three-second stability interval |
| Repeated lifecycle / Dock | Isolated acceptance cycles passed twice with visible usable UI, one foreground Windows Steam entry, and complete Stop |
| Normal Quit/reopen | Live regression verifies process exit, absence of exited-with-subordinates, and Steam surviving ordinary reopen |
| Packaged app | Release candidate passed Launch, Command-Q, ordinary reopen and Stop through native UI |
| Interrupted downloads / invalid responses | URLSession transport fixtures cover disconnection, short body, HTTP errors, redirects, size/encoding/range failures; real official-source download was verified separately |
| Interrupted setup and reset | Persisted-state/journal replay tests, original real interrupted-setup recovery, clean-reset and preserve/reset Wine smoke tests in disposable prefixes |
| Runtime disappearance | Unverified state rather than guessed stopped; no unsafe cleanup; positively idle receipt release without running a missing runtime |
| Orphan Wine service | Real tagged winedevice survivor captured; audit-token/PID-generation checked fallback added; native identity test and actual scoped orphan cleanup passed |
| Post-reboot lifecycle | User confirmed all seven steps passed on the checkpointed package: open, refresh/detection, launch/UI/Dock, normal Quit, reopen/control, Stop and relaunch |
| Real game compatibility / real-game rediscovery after reset | E6 scope; no claim from Steam Library readiness |

The macOS-native UI suite uses XCTest; headless CI tests do not replace the real
runtime/GUI checks above. Synthetic roots are used for destructive and failure
injection tests to preserve the authenticated primary environment.

## Findings incorporated

- Confirmation below the scroll fold confused “detected” with “waiting for user.”
  User-directed scope change removed that extra confirmation and made setup silent.
  A persistent top status bar now reports the actual stage.
- A Wine device service survived the server protocol. The final fallback uses a
  kernel audit token, never an unchecked PID or process-name sweep; access denial
  still refuses cleanup.
- Steam's bootstrapper could retain an empty foreground Dock application. Persistent
  launch starts with `-silent` and requests `steam://open/main` after its web helper
  appears. The main UI can also be reopened with **Show Windows Steam**.
- Repeated GUI inspection must run on the main actor so AppKit application-state
  observations stay current. Window/process evidence remains separately checked.

## Post-reboot procedure

After the candidate source and CI are checkpointed, stop all Gamekit-managed sessions
and quit Gamekit. Reboot normally when convenient. Open the supplied package's
`Gamekit.app`, refresh checks, and verify:

1. Correct saved runtime and installed state; no duplicate installation requested.
2. Launch reaches Steam's usable sign-in/Library UI with one active Windows Steam entry.
3. Normal Command-Q quits Gamekit fully while Steam stays running.
4. Reopening Gamekit restores control without another Steam instance.
5. Stop reaches stopped, and relaunch works.

## Accepted package identity

- Package: `.build/packages/Gamekit-20260916T212536Z/Gamekit.app`.
- App version/build: `0.1.0` / `1`, arm64, ad-hoc signed for local execution.
- Source commit: `27c1f74500bda1eb390788feec67addc30502b59`; source tree was clean.
- Executable SHA-256: `5e60e54730a43c6139e87ddfd27575b429caa05060d93ea656ec312c09a864c5`.
- Source-tree SHA-256: `d0e0593646e17f799c2c30bb5ba781196331f0de593cb21e222881c76704275a`.
- Result: the user reported **“All seven steps passed.”** The executable hash was
  rechecked afterward and still matches the checkpointed manifest.

The packaged manifest is retained unchanged as build provenance; its candidate
label predates acceptance. This document records the subsequent acceptance result.
The acceptance-record update changes documentation only, not the tested executable.
