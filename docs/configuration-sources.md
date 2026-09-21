# Game configuration sources

Game-specific execution settings belong in JSON, including diagnostic and test
settings. `AGENTS.md` records this as a repository policy.

| Purpose | Source |
| --- | --- |
| Published/bundled game execution profiles | `Sources/GamekitCore/GameProfiles/*.json` |
| Native diagnostic target selectors and experimental options | `diagnostics/profiles/games.json` |
| Historical driver artifact reproduction | `diagnostics/profiles/legacy-driver-version-1.json` (frozen) |
| Independent game baselines used by Swift/Python tests | `tests/fixtures/games.json` |
| Registry and synthetic-version test data | `tests/fixtures/game-settings.json` |

Swift unit and UI tests use `GameFixtures`; Python tests use `game_fixtures`.
Assertions, deliberately malformed inputs, and identifiers selecting a test's
subject remain test logic; they do not supply production game rules. Registry
baselines, target executable names, driver versions and launch workarounds are
read from JSON rather than repeated in setup code.

## Native diagnostics

`DiagnosticProfile.h` reads selectors from JSON at run time. Native trace helpers,
renderer experiments, save-guard targeting and device-API capture use this shared
reader. `GAMEKIT_DIAGNOSTIC_PROFILE` selects an explicit absolute JSON path.
For managed launches whose environment is filtered, compile the diagnostic helper
with `GAMEKIT_DIAGNOSTIC_PROFILE_PATH` set to the quoted absolute JSON path. When
compiled from absolute source paths, the default is the repository's diagnostic
profile. Relative or missing paths do not trigger a guessed game selection.

Win32 diagnostic tools receive parameters from the Swift JSON fixture reader:

- Cursor override: `<action> <executable-basename>`.
- Named desktop: `<query|apply|restore> <executable-basename> <desktop-name> <size>`.
- Display observation: `<width>x<height> [report-path]`.
- DXGI observation: `<expected-16-digit-hex-version> [DLL-path]`.
- Isolated DXGI registry setup: `configure <executable-basename> [...]`.

The existing opt-in Swift wrappers translate their symbolic actions into these
arguments. Rebuild old local diagnostic executables before using the updated
wrappers. These tools retain their existing scoped-prefix checks and bounded runs.

## Historical reproducibility

`tools/prepare_driver_runtime.py --build-only <new-output.dll>` generates a
temporary C parameter header from the frozen legacy JSON before compiling the
historical adapter. There are no literal game names or replacement versions in
the C implementation. Standalone historical diagnostic builds can generate the
same header with:

```sh
python3 tools/driver_profile.py --header .build/driver-parameters.h
# Pass -include .build/driver-parameters.h to the historical C compilation.
```

The current generic adapter still uses its run-time parameter projection.
Both forms were reproduced on 2026-09-21 without changing their qualified bytes:

- Historical adapter: `5ccd55cf94faaab72dcdef651aaccc7907c3eef46d0ecb1cb0f5de204940d2b2`.
- Generic adapter: `2658ec1e2c05b8cdf34072147b65b9e970efff8704c6c5f356b17c3346a8e7a4`.

## Regression gates

Run `python3 tools/check_game_configuration.py` and `make check`. The audit derives
known execution values from JSON and rejects copies in source code, diagnostics
and test setup. It additionally rejects fixed game selectors in production and
diagnostic code. A test introduces a new JSON game and confirms its values are
covered without extending a hardcoded list. The native reader test changes the
JSON target and verifies behavior changes without recompilation.

General mechanism constants—API names, buffer limits and protocol encodings—are
implementation details, not game-specific execution choices.
