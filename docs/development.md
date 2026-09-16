# Native app development

E3.1 establishes a SwiftUI app, a separately testable core module and repeatable
build commands. `project.yml` and `Package.swift` are the project sources of truth.

## Toolchain

Tested locally: Apple silicon, macOS 27.0 (26A428), Xcode 27.0 (27A266a),
Swift 6.4 in Swift 6 language mode, and XcodeGen 2.46.0.

```bash
xcode-select -p
xcodebuild -version
swift --version
xcodegen --version
```

Use full Xcode 27 with first-launch setup completed. XcodeGen 2.46.0 or later is
required by the project specification; `brew install xcodegen` installs it if
absent. Python 3 runs the existing diagnostic-helper tests. Building/opening the
foundation app requires neither Wine/GPTK installation nor a Steam account.

## Commands

Run from the repository root:

| Command | Purpose |
|---|---|
| `make generate` | Generate `Gamekit.xcodeproj` from `project.yml` |
| `make build` | Generate and build the arm64 Debug app |
| `make core-test` | Run the core's Swift Testing suite via SwiftPM |
| `make python-test` | Run existing Python diagnostic tests |
| `make test` | Run core and Python tests |
| `make ui-test` | Build and run the native app-launch smoke test |
| `make check` | Run core/Python tests and build the native app |
| `make run` | Build and open the native app |
| `make package` | Build a local Release candidate, verify signing/architecture and write a versioned package with build manifest |

Default app: `.build/xcode/Build/Products/Debug/Gamekit.app`.

For Xcode, run `make generate`, open `Gamekit.xcodeproj`, and select **Gamekit**.
The scheme's test action runs the UI smoke test; use `swift test` / `make core-test`
for the separate core suite. UI testing requires a logged-in graphical session.
If macOS requests Developer Tools/automation access for Xcode's runner, use the
normal prompt and rerun. The smoke test launches and terminates only Gamekit;
results are under `.build/xcode/Logs/Test/`.

`DERIVED_DATA` and `CONFIGURATION` can be overridden in Make; Debug is the locally
verified default. Commands stop on failures. Use these targets serially: do not
regenerate the project while another Xcode build/test is reading it.

## Structure and boundaries

```text
App/                       SwiftUI entry point and foundation window
Sources/GamekitCore/        Domain, metadata, runtime detection and scoped execution
Sources/CProcessSupport/   Native spawn/wait and macOS process-inventory bridge
tests/GamekitCoreTests/     Swift Testing core suite
UITests/                   XCTest native-launch smoke test
project.yml                App, scheme and signing specification
Package.swift              Local core package and its test target
Makefile                   Shared local/CI command entry points
.github/workflows/build.yml GitHub Actions build and test workflow
```

The app imports the local `GamekitCore` product instead of duplicating its source.
There are no external Swift package dependencies. The first policy enforces the
approved prototype scope: arm64 and **macOS major version 27**, rejecting older
and unvalidated future systems, Intel and unknown architectures. Tests cover each
boundary and combined failures. This is host eligibility, not runtime readiness.

The core package targets macOS 15 because its pure policy needs no macOS 27 APIs.
The **app and UI tests target macOS 27**. The library deployment floor does not
expand the product's support promise. The UI displays the evaluated recipe, host
scope and a read-only saved-environment summary. E3.2 adds
[atomic metadata storage and restart reconciliation](environment-state.md).
E3.3 supplies [runtime detection and scoped process execution](runtime-execution.md),
including live observations for the summary. E3.4 adds
[bounded local diagnostics and allowlisted summary exports](local-diagnostics.md).
E4.1 supplies [Steam installer acquisition](installer-acquisition.md) for the
installation coordinator, with an opt-in official-download smoke test.
E4.2 adds the [managed Steam installation coordinator and setup UI](steam-installation.md).
E4.3 adds [persistent Steam lifecycle controls](steam-lifecycle.md).
E4.4 adds [stage-aware recovery and download-preserving reset](steam-recovery.md).

## Signing and generated artifacts

`project.yml` uses **Sign to Run Locally** (ad-hoc identity `-`) without a developer
team. App Sandbox and Hardened Runtime are off for this local prototype. Public
distribution must choose its own signing/entitlement/notarization policy later.

```bash
codesign --verify --deep --strict --verbose=2 \
  .build/xcode/Build/Products/Debug/Gamekit.app
file .build/xcode/Build/Products/Debug/Gamekit.app/Contents/MacOS/Gamekit
```

Generated projects, SwiftPM state, derived data, user settings, test results,
runtime binaries, evaluation prefixes, installers and logs are ignored. Edit
`project.yml`, not generated project files. Build cleanup is limited to
`.build/` and `Gamekit.xcodeproj/`; runtime/user data remain under
`~/Library/Application Support/Gamekit/`. The app reads only registered metadata
and its scoped file facts; it does not adopt the manual E2 prefixes. Core/UI tests
use isolated temporary roots.

## CI

The workflow runs `make check` and `make ui-test` for PRs into `dev`/`main` and
pushes to those branches or `task/**`. Repository permissions are read-only and
checkout is pinned to the v7.0.1 commit. The
[`xcode-27` runner](https://github.com/actions/runner-images/issues/14404) is a
public preview; the workflow reports its actual OS/Xcode/Swift/generator versions.

Reproducibility means the same source specification and command sequence, not
bit-identical app binaries across SDK versions. Local repeated generation using
XcodeGen 2.46.0 produced an identical project file. CI does not install Wine/GPTK,
sign into Steam, read Beads, or rerun hardware-specific E2 evaluations. Inspect
the PR's actual CI results before merging.

## Local verification recorded for E3.3

- Command tests were introduced before their implementation. Additional path,
  prerequisite and role-classification regressions failed before their fixes.
- `make check` passed: 59 ordinary Swift test functions (including parameterized
  edge cases), six Python tests, and the native arm64 app build. The 60th Swift
  test is an explicitly opt-in installed-runtime check and is skipped in CI.
- `make ui-test` passed: three tests covering empty startup, persisted metadata
  across app restart, and corruption handling without modifying the bad document.
- Core tests use real temporary directories and an owned child-process lifetime
  fixture; they never use the user's Steam environments as writable fixtures.
- `GAMEKIT_RUNTIME_SMOKE=1 swift test --filter installedRuntime` passed locally:
  actual Rosetta/runtime checks, Windows command execution, tagged process
  observation and scoped cleanup in a newly registered temporary prefix.

## Local verification recorded for E3.4

- `make check` passed: 77 Swift test functions reported, six Python tests and the
  native arm64 app build. The installed-runtime case remains explicitly opt-in.
- `make ui-test` passed: four tests, including a failed-command diagnostics fixture
  with local-output/export controls and a private sentinel excluded from export.
- Diagnostics tests cover real command failures, storage errors independent of
  execution results, bounded capture, retention, checkpoints and export privacy.
- Debug `--diagnostics-root` overrides the log root. When `--metadata-root` is
  supplied alone, logs use a sibling `GamekitLogs` directory to isolate UI tests.

## Local verification recorded for E4.1

- Tests were introduced before implementation; the missing acquisition types
  produced the initial red build.
- `make check` passed: 90 Swift test functions reported (two opt-in cases skipped
  by default), six Python tests and the native arm64 app build.
- `make ui-test` passed all four existing UI regression tests.
- `GAMEKIT_INSTALLER_SMOKE=1 swift test --filter officialInstaller` passed using
  Valve's current official HTTPS download. The complete artifact was saved and
  revalidated from its receipt without execution; see
  [acquisition evidence](installer-acquisition.md#verification).

## Local verification recorded for E4.2

- Coordinator tests were introduced before implementation. The Wine argv-padding
  regression separately failed before its evidence-driven parser fix.
- `make check` passed: 102 Swift test functions reported (four opt-in cases skipped
  by default), six Python tests and the native arm64 app build.
- `make ui-test` passed all four existing UI regression tests.
- Real setup created the fresh managed `steam` prefix and bootstrapped win64
  manifest 1788652215. The user confirmed its usable UI after the parser fix.
- `GAMEKIT_INSTALLATION_VERIFY=1 swift test --filter verifyManagedInstallation`
  passed: installed recipe 1, revision 17, complete/idle process inventory, and no
  record change or repeated installation on a second install request.
- See [setup verification](steam-installation.md#recorded-live-verification) for
  the observed failure, fix and verification-retry boundary.

## Local verification recorded for E4.3

- Tests-first red observed for the lifecycle API and output-discard mode.
- `make check` passed: 109 Swift functions reported (five opt-in skips), six Python
  tests and native build.
- Three live Steam launch/stop cycles passed with replacement controllers.
- All five UI tests passed with the real lifecycle opt-in, including Gamekit
  termination/reopen while Steam remained running. Normal CI skips that live case.

## Local verification recorded for E4.4

- Tests-first red observed for reset journaling, download preservation and retry.
- `make check` passed: 125 Swift functions reported (six opt-in skips), six Python
  tests and native build.
- Crash-injection tests cover reset preparation, prefix archival, metadata reset
  and library restoration; an end-to-end coordinator fixture resets/reinstalls
  with game bytes intact before bootstrap.
- The disposable real-Wine recovery smoke passed twice: a freshly initialized
  replacement prefix with unchanged game/depot bytes and the old client archived.
- Local UI testing hit the locked-desktop authentication barrier; the reset-dialog
  confirmation/Cancel regression is included in hosted CI. No attempt was made to
  bypass the user's screen lock.

## Quit/Dock acceptance follow-up (`gamekit-75s`)

- User acceptance found generic/duplicate Wine Dock entries and Gamekit retained
  as “Running in Background” after normal Quit.
- Launch Services inspection established `exited-with-subordinates` despite the
  Gamekit PID having exited. The stronger live regression failed on the old build
  and passed after independent launch responsibility was implemented.
- A derived Windows Steam bundle supplies the correct process name and hides its
  launcher agent. The source runtime and installed prefix remain intact.
- `make check` passed: 131 Swift functions reported (seven opt-in skips), six
  Python tests and native build. The normal UI suite passed five tests with two
  live cases skipped; the new live Command-Q/ordinary-reopen UI test passed separately.
- The user confirmed one correctly named entry and full Gamekit exit while Steam
  remained open. See [launch identity and ownership](windows-steam-launcher.md).

## Reset/reinstall follow-up (`gamekit-x5i`)

- Corrected preservation order: installer first, restored libraries second, then
  bootstrap. The installer fixture now rejects a non-empty destination, reproducing
  the reported failure before the fix.
- Added crash-safe re-staging for previously premature restoration and a separate
  explicitly confirmed clean reset of the current prefix/downloads.
- `make check` passed: 137 Swift functions reported (eight opt-in skips), six Python
  tests and native build. UI tests passed six cases with two live cases skipped.
- Disposable real-Wine clean reset passed. The user's preserving reinstall was
  confirmed installed at revision 33, idle, with unchanged repeat-install behavior.

## E5 candidate verification

- Persisted runtime selection, guided prerequisites, shared operation gating,
  keyboard controls, state-aware actions and persistent stage feedback are in place.
- User-requested silent `/S` installation and automatic client/browser/window
  readiness completed in a fresh isolated root in approximately 63 seconds.
- Latest `make check`: 154 Swift functions reported (12 opt-in skips), eight Python
  tests and native build passed. Normal UI suite: nine passed, three live skips.
- Live acceptance covered login/Library, paths with spaces, normal Quit/reopen,
  two isolated lifecycle cycles, and an orphan Wine service safely terminated via
  a kernel audit token. The packaged Release app passed its live UI lifecycle test.
- `make package` creates a new no-clobber candidate folder and manifest under
  `.build/packages/`. It does not bundle the Wine runtime or declare release acceptance.
- See [E5 acceptance](e5-acceptance.md) for exact coverage and the pending reboot gate,
  [native interface](native-interface.md) for action/state contracts, and the
  [operating guide](user-guide.md) for setup, recovery and removal.
