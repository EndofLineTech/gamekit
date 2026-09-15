# Gamekit

A native macOS launcher for installing and running Windows Steam through
Apple's Game Porting Toolkit 4.

## Initial scope

The first release is a personal SwiftUI prototype targeting macOS 27 on Apple
silicon. It will validate prerequisites, manage a dedicated Wine environment,
install Windows Steam, and provide launch, stop, recovery, and diagnostic controls.
Game evaluation follows the Steam milestone; game-specific fixes are future work.

The project is currently in planning. Work is tracked with Beads (`bd`) using a
local Dolt server and a public GitHub database backup. See the
[Beads operations runbook](docs/beads.md) for startup, backup and recovery.

## Development workflow

- `dev` is the default integration branch and the starting point for new work.
- Create a task branch from an up-to-date `dev`, then open a pull request into `dev`.
- `main` is the stable branch. Promote changes through a release PR from `dev`.
- Both branches require pull requests, including for administrators. Direct pushes,
  force pushes, and branch deletion are prohibited after repository bootstrap.
- A PR is required, but an independent approving review is not currently required,
  allowing the personal prototype to be maintained by one person.

See [AGENTS.md](AGENTS.md) for agent workflow instructions.
