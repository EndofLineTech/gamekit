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

## Authoring

The source of configured profiles is `Sources/GamekitCore/GameProfiles/`. SwiftPM
bundles these exact JSON documents for offline use, and the wiki builder validates
and publishes the same documents. No separate Swift argument table exists.
Catalog entries without a configured source get stable, empty revision-1 profiles.
To add adjustments for such a game, create its source JSON at revision **2 or later**.

```json
{
  "schemaVersion": 1,
  "revision": 2,
  "appId": 526870,
  "name": "Satisfactory",
  "runtime": "sikarugir-10.0_6",
  "launchArguments": {"dxmt": ["-dx11"]},
  "notes": "Example only: consult the actual shipped profile for all required options."
}
```

All fields are required; unknown fields and schemas are rejected. Runtime family
is currently `sikarugir-10.0_6`; backend keys are `automatic`, `metal3`, `dxmt`,
`dxvk`. Omitted backends get no arguments. Up to 16 argument tokens per backend
are supported, each 2–512 ASCII characters beginning with `-`, followed only by
letters, digits, `_ : . [ ] = , + / -` (without spaces). There is no shell,
executable path, environment, registry, DLL download or game-file editing action.
New action types require a schema and app implementation change.

Increment the revision for **every content change**, including names or notes.
To roll back a bad rule, publish the old content with a higher revision. Never
silently reuse a revision. Keep profile guidance consistent with
`compatibility/reports.json` and its sanitized evidence documents. Failed test
launch options are not automatically promoted into profiles.

Satisfactory's existing DXMT/DXVK argument rules are migrated unchanged. Its DXVK
profile retains the existing workaround for explicit DXVK selections, despite
that path's recorded unplayable result. Helldivers has guidance and no extra launch
arguments; its qualified driver shim, capture/Space implementation and saved
preferences remain in the native compatibility subsystem.

## Validation and publication

Run `make check` and `python3 tools/build_compatibility_wiki.py --check`. The profile
tests exercise request handling, offline fallback, identity/schema validation,
rollback refusal, bounded responses, symlink refusal, actual launch argument
routing and all catalog download links. Open a PR targeting `dev`; the existing
Pages workflow publishes validated profiles after merge.
