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
Sources/GamekitCore/        Pure domain logic; no UI/process/filesystem work
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
expand the product's support promise. The UI displays the evaluated recipe and
host scope, and links to the runtime guide. Persistence, runtime detection,
process execution and local diagnostics remain the subsequent E3 tasks.

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
`.build/` and `Gamekit.xcodeproj/`; the existing environments remain under
`~/Library/Application Support/Gamekit/` and are not accessed by the scaffold.

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

## Local verification evidence

- Core tests were written first and failed before the policy types existed.
- `make check` passed: four Swift test functions / eight test cases, six Python
  tests, and the native arm64 app build.
- `make ui-test` passed: one automated app launch/window/core-content smoke test.
- The local bundle's signature verified successfully.
- Two generations produced the same `project.pbxproj` SHA-256.
