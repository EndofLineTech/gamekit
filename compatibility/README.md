# Gamekit compatibility wiki

Source for <https://endoflinetech.github.io/gamekit/>. The static site is built
with Python's standard library; no hosted database, account, or API key is needed.

## Update a game report

1. Find its Steam AppID in `games.json`; add an AppID/name entry if absent.
2. Edit its entry in `reports.json`. Each result records a backend, outcome,
   graphics API evidence, game build, tested environment/date, launch options,
   limitations, and links to evidence in `docs/`.
3. Use `verified` only for gameplay, audio, controls and save/reload acceptance.
   `gameplay` means interactive play was observed but that full checklist was
   not completed. `startup` means menu/ship startup only. `fails` and `unplayable`
   are different outcomes. Absence of a report always means **Untested**.
4. Record a new environment when hardware, OS, runtime or backend versions
   change. Preserve older results in the linked investigation report; update
   the public summary only when newer evidence supports it.
5. Run `python3 -m unittest discover -s tests -p 'test_*wiki*.py' -v` and
   `python3 tools/build_compatibility_wiki.py --output .build/wiki-preview`.
6. Preview with `python3 -m http.server 8000 --directory .build/wiki-preview`,
   check the matrix and edited game page, then submit a PR targeting `dev`.

Recommendations must point to a result with positive evidence. Untested games
get no backend recommendation. API selection and feature level are separate;
DLL loading, a launch flag, or device creation alone does not prove rendering API.
Do not copy another operating system's result into a macOS qualification.

## Refresh the Steam game inventory

The initial inventory is 708 games from an active Steam license listing on
2026-09-20 UTC, filtered by local app metadata's `Game` type. DLC, tools, demos
and other app types are excluded. It is a snapshot, not a live ownership service.

Use Steam's read-only `licenses_print` console command. The opt-in
`SteamLibraryInventoryTests.inventory` helper can request it from owned Windows
Steam and stop that managed session; it requires `GAMEKIT_EXPORT_STEAM_LICENSES=1`
and `GAMEKIT_INVENTORY_PACKAGE` pointing to an accepted Gamekit app bundle. Close
games first. Inspect the private console log to confirm a complete listing.

```sh
python3 tools/export_steam_catalog.py \
  --licenses '<Steam>/logs/console_log.txt' \
  --appinfo '<Steam>/appcache/appinfo.vdf' \
  --output .build/refreshed-games.json
```

Multiple `--appinfo` inputs can fill gaps from another local Steam installation.
The exporter refuses missing app metadata rather than silently publishing a
partial inventory. Review the exported AppID/name-only file before replacing
`games.json`; retain entries with historical reports even if ownership changes.
Update `catalog_date` in `reports.json`. Existing results are separate from the
inventory and must not be reset by a refresh.

**Only AppIDs and game titles are exported.** Keep raw console logs, license
metadata, account identifiers, tokens, purchases, achievements, playtime, saved
games and screenshots out of the repository and Pages artifacts.

## Publishing and rollback

`.github/workflows/pages.yml` validates/builds PR previews and deploys only pushes
to `dev` (or a manual dispatch on `dev`) through the `github-pages` environment.
GitHub Pages is configured for **GitHub Actions**. Only the generated static
artifact is uploaded. No runtime logs or source-tree copy is deployed.

The site follows the prototype integration branch; it is not a stable-release
support guarantee. Revert a bad data/site change through a PR to `dev`; the next
successful Pages deployment restores the site. A failed validation/build leaves
the previously deployed site available. Check the Pages workflow and live URL
after a merge. Generated output stays under `.build/` and is not committed.

## Optional browser verification

With the preview server running on port 8765:

```sh
npm install --prefix .build/wiki-browser --no-audit --no-fund playwright@1.63.0
.build/wiki-browser/node_modules/.bin/playwright install chromium
NODE_PATH="$PWD/.build/wiki-browser/node_modules" node tests/wiki_browser_smoke.cjs
```

`WIKI_URL` selects another preview/deployed URL. `WIKI_CHROMIUM` can point to an
existing compatible Chromium executable instead of downloading a browser.
`WIKI_SCREENSHOTS` optionally selects an existing private screenshot directory.
This checks filtering, query-string persistence, mobile overflow, per-game pages
and navigation without JavaScript. The Python checks also verify deterministic
output, escaping, internal links, evidence references and public-data fields.
