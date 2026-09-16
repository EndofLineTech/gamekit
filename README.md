# Gamekit

A native macOS launcher for installing and running Windows Steam through
Apple's Game Porting Toolkit 4.

## Build the native foundation

With Xcode 27 and XcodeGen 2.46.0 or later installed:

```bash
make check
make ui-test
make run
```

The SwiftUI foundation app and separate `GamekitCore` module are in place,
including [environment metadata and restart reconciliation](docs/environment-state.md).
The core also provides [runtime checks and scoped process execution](docs/runtime-execution.md).
[Local diagnostics](docs/local-diagnostics.md) record runtime probe commands and
offer private output viewing and structured summary exports.
The core now supports [Steam installer acquisition](docs/installer-acquisition.md)
with HTTPS policy, artifact validation and persisted provenance.
[Managed Steam setup](docs/steam-installation.md) creates a fresh prefix, runs the
installer silently, follows bootstrap, and detects stable web-UI readiness automatically.
[Steam lifecycle controls](docs/steam-lifecycle.md) launch, observe and stop the
managed installation, including after Gamekit restarts.
[Recovery controls](docs/steam-recovery.md) retry interrupted setup and support a
confirmed reset that archives the old environment and preserves game downloads.
An explicitly confirmed clean reset can instead delete the current prefix and its
downloads while retaining older archives and external libraries.
See [native development](docs/development.md) for setup, local signing, module
boundaries, CI and generated-file handling.
The [operating guide](docs/user-guide.md) covers setup, shortcuts, recovery and local
packages. [E5 acceptance](docs/e5-acceptance.md) records completed checks and remaining gates.

## Initial scope

The first release is a personal SwiftUI prototype targeting macOS 27 on Apple
silicon. It will validate prerequisites, manage a dedicated Wine environment,
install Windows Steam, and provide launch, stop, recovery, and diagnostic controls.
Game evaluation follows the Steam milestone; game-specific fixes are future work.

The E5 local candidate provides validated setup, silent installation, automatic
Steam UI readiness, lifecycle and recovery controls. Post-reboot release acceptance
is tracked separately. Work is tracked with Beads (`bd`).

## Development workflow

- `dev` is the default integration branch and the starting point for new work.
- Create a task branch from an up-to-date `dev`, then open a pull request into `dev`.
- `main` is the stable branch. Promote changes through a release PR from `dev`.
- Both branches require pull requests, including for administrators. Direct pushes,
  force pushes, and branch deletion are prohibited after repository bootstrap.
- A PR is required, but an independent approving review is not currently required,
  allowing the personal prototype to be maintained by one person.

See [AGENTS.md](AGENTS.md) for agent workflow instructions.

## Phase 1: runtime contract

- [GPTK 4.0 beta 2 package inspection](docs/gptk-package-inspection.md)
- [Selected runtime and prerequisite checklist](docs/runtime-contract.md)
- [Steam and graphics feasibility test](docs/steam-feasibility-test.md)

The original candidate failed prerequisite validation. The
[tested runtime revision](docs/runtime-revision.md) selects Sikarugir Wine 10.0
revision 6 with Apple's unchanged D3DMetal 4.0b2; its prerequisite checks pass.
Full Steam installation and rendering/launcher results are recorded below.

The [E2.1 prerequisite validation report](docs/prerequisite-validation.md)
preserves the initial Wine/graphics ABI blocker and installed-tool evidence.

## Steam feasibility

The [Steam feasibility evaluation](docs/steam-evaluation.md) passed in two fresh
environments: rendering/readback, current-client installation, login, Library
stability and three exit/relaunch cycles per environment. E2 is accepted; E3
builds the native Gamekit application around this validated recipe.
