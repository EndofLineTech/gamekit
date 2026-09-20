# Downloadable game profiles

Gamekit matches installed games by numeric Steam AppID and downloads
`https://endoflinetech.github.io/gamekit/profiles/<AppID>.json` in the background.
Every wiki game page has a **Download Gamekit profile JSON** link, including
untested titles. An empty `launchArguments` object means no automatic adjustments,
not a compatibility certification.

Open a game's gear to see the profile revision, source, guidance and the exact
arguments for the selected backend. **Update profile** checks the wiki immediately.
Normal library polling attempts each AppID at most once per day per app session;
opening the gear also checks that game. Downloads do not block Play. A completed
update applies to the next Gamekit Play request, not a running game.

## Resolution and offline use

1. The game's explicit graphics override wins over the shared graphics default,
   exactly as before. Profiles do not select or install a backend.
2. A valid downloaded profile supersedes the bundled profile when its revision is
   at least as new. Equal revisions must have identical content.
3. Invalid, missing or unavailable downloads leave the last valid cache intact.
   Corrupt/unreadable caches fall back to bundled rules; without either, no extra
   arguments are supplied.

Cache: `Metadata/GameProfiles/<AppID>.json` under Gamekit's application-support
root. Downloads are bounded to 32 KiB and 15 seconds, from the fixed HTTPS wiki
origin with redirects refused. Schema, AppID, runtime family, backend names,
argument syntax and monotonic revision are checked before atomic publication.
The cache uses the existing descriptor-relative, no-symlink storage implementation.

Profile arguments are passed as separate arguments to the owned Windows Steam
`-applaunch` request. They do not overwrite Steam's saved Launch Options or game
configuration files. Steam's handling of conflicts with its own saved options
remains Steam behavior. Direct Play inside Steam does not get Gamekit's extra
arguments; the gear panel shows what to copy when desired.

## Execution parameters: JSON is the source of truth

Schema 2 adds `execution`. It declares the target executable and any supported
driver-version, fullscreen capture and fullscreen Space mechanisms. AppID-specific
branches, executable names, driver-version values, per-game defaults and per-game
guidance are not part of the app's execution code. The UI renders the capabilities
and guidance declared by the profile. Missing capabilities are not offered.

For example, Helldivers' `553850.json` declares `helldivers2.exe`, the eligible
runtime/backend combinations, the all-65535 match version and 35.0.15.6094
replacement, driver enabled by default, optional capture controls and a fullscreen
Space disabled by default. It explicitly supplies no extra launch arguments:
`--use-d3d11` is not a validated workaround for its alternate backends.

Saved user preferences override profile defaults. Existing driver/Space preference
documents and Wine capture overrides are preserved; preference validation accepts
canonical numeric AppIDs rather than a built-in game allowlist. Wine's absent
global capture key means disabled, so `capture.inheritedDefault` currently supports
only `false`; explicit capture choices use the per-executable registry setting.

The native fullscreen helper receives executable selectors in the session JSON.
The generic DXGI adapter receives a bounded, private UTF-16 INI projection of the
same validated JSON, scoped by executable **and installation directory**. That
projection is generated data, not another hand-maintained configuration source.
Removing a game clears its projected rules. Each process initializes its adapter
parameters once; existing initialized adapters are not reconfigured by downloads.

The adapter implementation is bundled and hash-verified. JSON selects parameters;
it cannot download or select an arbitrary DLL. A fresh derived-loader cache format
preserves old caches and never overwrites shared PE inodes. The historical external
runtime shim remains an immutable component of its pinned runtime manifest; new
driver-enabled game loaders use the generic adapter.

After installing this engine update, save/exit games and stop/relaunch Windows
Steam once so its children inherit the new native helper and parameter-file path.
Subsequent profile updates for supported mechanisms are data updates.

## Authoring

The source of configured profiles is `Sources/GamekitCore/GameProfiles/`. SwiftPM
bundles these exact JSON documents for offline use, and the wiki builder validates
and publishes the same documents. No separate Swift argument table exists.
Catalog entries without a configured source get stable, empty revision-2 profiles.
To add adjustments for such a game, create its source JSON at revision **3 or later**.

```json
{
  "schemaVersion": 2,
  "revision": 3,
  "appId": 526870,
  "name": "Satisfactory",
  "runtime": "sikarugir-10.0_6",
  "launchArguments": {"dxmt": ["-dx11"]},
  "notes": "Example only: consult the actual shipped profile for all required options.",
  "execution": {}
}
```

All schema-2 fields are required; unknown fields and schemas are rejected. Schema 1
is accepted as launch-arguments-only data for backward compatibility. Runtime family
is currently `sikarugir-10.0_6`; backend keys are `automatic`, `metal3`, `dxmt`,
`dxvk`. Omitted backends get no arguments. Up to 16 argument tokens per backend
are supported, each 2–512 ASCII characters beginning with `-`, followed only by
letters, digits, `_ : . [ ] = , + / -` (without spaces). There is no shell,
arbitrary executable path, shell environment, DLL download or game-file editing
action. Typed execution mechanisms select qualified code; new mechanism types
require an app implementation change rather than embedding a script in JSON.

`execution` may be empty. Otherwise it requires a lowercase executable basename
and at least one of:

- `driver`: nonempty `runtimeRevisions` and `backends` lists, `defaultEnabled`,
  four unsigned-16-bit components each for `matchVersion` and `replacementVersion`,
  and `guidance`. Current qualification is the driver-compatible runtime with
  Apple backends. JSON cannot bypass runtime or payload integrity checks.
- `capture`: `inheritedDefault` and `guidance` for the Wine fullscreen-capture
  control. Explicit user registry settings and the inherited Wine setting retain
  precedence.
- `fullscreenSpace`: `defaultEnabled` and `guidance`; the helper activates only
  for the profile's matching executable in the owned game directory/session.

Use `553850.json` as the complete concrete example. For every mechanism, absence
means unsupported/inactive, not an invitation to guess a game's configuration.

Increment the revision for **every content change**, including names or notes.
To roll back a bad rule, publish the old content with a higher revision. Never
silently reuse a revision. Keep profile guidance consistent with
`compatibility/reports.json` and its sanitized evidence documents. Failed test
launch options are not automatically promoted into profiles.

Satisfactory's existing DXMT/DXVK argument rules are migrated unchanged. Its DXVK
profile retains the existing workaround for explicit DXVK selections, despite
that path's recorded unplayable result. Helldivers has guidance and no extra launch
arguments; its driver, executable, capture/Space controls, defaults and guidance
are declared in its profile and consumed by generic implementations.

## Validation and publication

Run `make check` and `python3 tools/build_compatibility_wiki.py --check`. The profile
tests exercise request handling, offline fallback, identity/schema validation,
rollback refusal, bounded responses, symlink refusal, actual launch argument
routing and all catalog download links. Open a PR targeting `dev`; the existing
Pages workflow publishes validated profiles after merge.

Live adapter acceptance uses `ProfileDriverAcceptanceTests` with
`GAMEKIT_PROFILE_DRIVER_PROBE` pointing to a build of
`diagnostics/dxgi_driver_probe.cpp` and `GAMEKIT_PROFILE_IDENTITY_HELPER` pointing
to the newly built `WineGameIdentity.dylib`. It creates a fresh, private prefix
with a tiny fixture game, supplies an unrelated AppID and version 1.2.3.4 through
JSON, checks actual DXGI substitution and D3D12 device creation, then confirms
scoped cleanup before removing the fixture. No installed Steam library is cloned.

2026-09-20: this live test passed on the recorded M4 Pro/macOS 27 host, as did an
initial test using the existing 35.0.15.6094 value. These are adapter-contract
observations, not new Helldivers gameplay acceptance.
