# Gamekit

A native macOS launcher for installing and running Windows Steam through
Apple's Game Porting Toolkit 4.

## Initial scope

The first release is a personal SwiftUI prototype targeting macOS 27 on Apple
silicon. It will validate prerequisites, manage a dedicated Wine environment,
install Windows Steam, and provide launch, stop, recovery, and diagnostic controls.
Game evaluation follows the Steam milestone; game-specific fixes are future work.

The project is currently in planning. Work is tracked locally with Beads (`bd`).

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
Steam installation and rendering/launcher acceptance are the next milestone.

The [E2.1 prerequisite validation report](docs/prerequisite-validation.md)
preserves the initial Wine/graphics ABI blocker and installed-tool evidence.

## Steam feasibility

The [first Steam evaluation](docs/steam-evaluation.md) passed rendering/readback,
current-client installation, login, Library navigation and exit/relaunch checks.
The second fresh installation is the remaining E2 acceptance gate.
