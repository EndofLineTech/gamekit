"""Validate the public compatibility catalog and build a dependency-free Pages site."""
import argparse
from datetime import date
from html import escape
import json
import re
from pathlib import Path
import shutil
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
REPO = "https://github.com/EndofLineTech/gamekit"
BACKENDS = {"apple": "Apple / D3DMetal", "dxmt": "DXMT", "dxvk": "DXVK", "other": "Other API"}
STATUSES = {
    "untested": ("Untested", "No recorded test on this backend. Not a failure or a recommendation."),
    "startup": ("Startup only", "Menu or ship reached; gameplay and save/reload are not established."),
    "gameplay": ("Gameplay observed", "Interactive play observed; the complete functional checklist is not established."),
    "verified": ("Playable", "Gameplay, rendering, audio, controls and save/reload accepted for the recorded setup."),
    "caveats": ("Playable with caveats", "Functional checks passed with a required workaround or known limitation. Read the game report before choosing settings."),
    "fails": ("Unplayable", "The tested launch failed before usable gameplay."),
    "unplayable": ("Unplayable", "Startup fails or gameplay is unusable. Read the game report for the failure details."),
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def text(value, limit=4096):
    return isinstance(value, str) and 0 < len(value.strip()) <= limit and not any(ord(c) < 32 for c in value)


def validate_profile(profile, app_id):
    require(isinstance(profile, dict) and set(profile) == {
        "schemaVersion", "revision", "appId", "name", "runtime", "launchArguments", "notes"
    }, "Invalid profile fields")
    require(type(profile["schemaVersion"]) is int and profile["schemaVersion"] == 1, "Unsupported profile schema")
    require(type(profile["appId"]) is int and profile["appId"] == app_id and 0 < app_id < 2**32, "Profile AppID mismatch")
    require(type(profile["revision"]) is int and 0 < profile["revision"] <= 1000000, "Invalid profile revision")
    require(profile["runtime"] == "sikarugir-10.0_6", "Unknown profile runtime")
    for key, limit in (("name", 256), ("notes", 4096)):
        require(text(profile[key]) and len(profile[key].encode("utf-8")) <= limit
                and not any(127 <= ord(c) <= 159 for c in profile[key]), "Invalid profile description")
    arguments = profile["launchArguments"]
    require(isinstance(arguments, dict) and set(arguments) <= {"automatic", "metal3", "dxmt", "dxvk"}, "Unknown profile backend")
    for values in arguments.values():
        require(isinstance(values, list) and len(values) <= 16 and all(
            isinstance(value, str) and re.fullmatch(r"-[A-Za-z0-9_:.\[\]=,+/\-]{1,511}", value) for value in values
        ), "Invalid profile launch arguments")
    require(len((json.dumps(profile, ensure_ascii=False, indent=2) + "\n").encode("utf-8")) <= 32768, "Profile too large")


def game_profiles(games, root=ROOT):
    directory = root / "Sources/GamekitCore/GameProfiles"
    for path in directory.glob("*.json"):
        require(path.stem.isdigit() and str(int(path.stem)) == path.stem, "Invalid profile filename")
        validate_profile(json.loads(path.read_text(encoding="utf-8")), int(path.stem))
    profiles = {}
    for game in games:
        app_id = game["app_id"]
        source = directory / f"{app_id}.json"
        profile = json.loads(source.read_text(encoding="utf-8")) if source.exists() else {
            "schemaVersion": 1, "revision": 1, "appId": app_id, "name": game["name"],
            "runtime": "sikarugir-10.0_6", "launchArguments": {},
            "notes": "No automatic launch adjustments are supplied. Your saved backend and game settings apply. Consult the compatibility wiki for test evidence and manual guidance."
        }
        validate_profile(profile, app_id)
        profiles[app_id] = profile
    return profiles


def validate(games, reports, root=ROOT):
    require(isinstance(games, list) and 0 < len(games) <= 20000, "Invalid game inventory")
    ids = set()
    for game in games:
        require(isinstance(game, dict) and set(game) == {"app_id", "name"}, "Inventory permits only AppID and name")
        app_id = game["app_id"]
        require(type(app_id) is int and 0 < app_id < 2**32 and app_id not in ids, "Invalid/duplicate AppID")
        require(text(game["name"], 256), "Invalid game name")
        ids.add(app_id)
    require(isinstance(reports, dict) and set(reports) == {"schema_version", "catalog_date", "environments", "games"}, "Invalid report document")
    require(reports["schema_version"] == 1, "Unsupported catalog schema")
    date.fromisoformat(reports["catalog_date"])
    require(isinstance(reports["environments"], dict) and isinstance(reports["games"], dict), "Invalid report maps")
    for environment in reports["environments"].values():
        require(set(environment) == {"hardware", "os", "runtime", "note"} and all(text(v) for v in environment.values()), "Invalid environment")
    for app_id, report in reports["games"].items():
        require(app_id.isdigit() and str(int(app_id)) == app_id and int(app_id) in ids, "Report missing inventory entry")
        require(set(report) == {"recommendation", "recommended_backend", "summary", "issues", "results"}, "Invalid game report")
        require(text(report["recommendation"]) and text(report["summary"]), "Missing report summary")
        require(isinstance(report["issues"], list) and all(text(i, 80) and i.startswith("gamekit-") for i in report["issues"]), "Invalid bead references")
        require(isinstance(report["results"], list) and report["results"], "Report requires evidence")
        seen = {}
        for result in report["results"]:
            require(set(result) == {"backend", "status", "version", "api", "api_evidence", "build", "date", "environment", "launch_options", "notes", "evidence"}, "Invalid result fields")
            backend, status = result["backend"], result["status"]
            require(backend in BACKENDS and backend not in seen and status in STATUSES and status != "untested", "Invalid/duplicate backend result")
            seen[backend] = status
            require(result["environment"] in reports["environments"], "Unknown environment")
            require(result["api_evidence"] in {"confirmed", "requested", "reported", "unknown"}, "Invalid API evidence level")
            require(all(text(result[key]) for key in ("version", "api", "build", "notes")), "Missing result metadata")
            date.fromisoformat(result["date"])
            require(isinstance(result["launch_options"], list) and all(text(v) for v in result["launch_options"]), "Invalid launch options")
            require(isinstance(result["evidence"], list) and result["evidence"], "Test result requires evidence links")
            for path in result["evidence"]:
                require(isinstance(path, str) and path.startswith("docs/") and ".." not in Path(path).parts, "Evidence must be a repository doc")
                target = (root / path).resolve()
                require(target.is_relative_to((root / "docs").resolve()) and target.is_file(), f"Missing evidence: {path}")
        recommended = report["recommended_backend"]
        require(recommended is None or seen.get(recommended) in {"startup", "gameplay", "verified", "caveats"}, "Recommendation lacks positive evidence")


def badge(status):
    label, explanation = STATUSES[status]
    return f'<span class="badge {status}" title="{escape(explanation, quote=True)}">{label}</span>'


def layout(title, body, *, prefix="", source="compatibility/README.md"):
    return f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{escape(title)} · Gamekit Compatibility</title>
<meta name="description" content="Evidence-backed Windows game compatibility on Gamekit for Apple silicon.">
<link rel="stylesheet" href="{prefix}assets/site.css"><script defer src="{prefix}assets/site.js"></script></head>
<body><a class="skip" href="#content">Skip to content</a>
<header><a class="brand" href="{prefix}index.html">Gamekit <span>Compatibility wiki</span></a>
<nav aria-label="Main"><a href="{prefix}index.html">Matrix</a><a href="{prefix}guide.html">Choosing a backend</a><a href="{prefix}contributing.html">Contribute</a><a href="{REPO}">GitHub</a></nav></header>
<main id="content">{body}</main>
<footer>Personal Apple-silicon prototype · Results are version-specific, not guarantees.
<a href="{REPO}/edit/dev/{source}">Edit this page’s source</a> · <a href="{prefix}games.json">Game inventory JSON</a> · <a href="{prefix}reports.json">Reports JSON</a></footer></body></html>'''


def matrix(games, reports):
    rows = []
    for game in sorted(games, key=lambda g: (g["name"].casefold(), g["app_id"])):
        app_id = game["app_id"]
        report = reports["games"].get(str(app_id))
        results = {r["backend"]: r for r in report["results"]} if report else {}
        attrs = " ".join(f'data-{b}="{results.get(b, {}).get("status", "untested")}"' for b in BACKENDS)
        recommendation = BACKENDS[report["recommended_backend"]] if report and report["recommended_backend"] else "No recommendation yet"
        api = " · ".join(dict.fromkeys(r["api"] for r in results.values())) or "Unknown / untested"
        tested = max((r["date"] for r in results.values()), default="—")
        cells = "".join(f'<td>{badge(results.get(b, {}).get("status", "untested"))}</td>' for b in BACKENDS)
        rows.append(f'<tr data-name="{escape(game["name"].lower(), quote=True)}" data-id="{app_id}" {attrs}><th scope="row"><a href="games/{app_id}.html">{escape(game["name"])}</a><small>AppID {app_id}</small></th><td>{escape(recommendation)}</td>{cells}<td class="api">{escape(api)}</td><td>{tested}</td></tr>')
    tested_count = len(reports["games"])
    highlights = " · ".join(f'<a href="games/{g["app_id"]}.html">{escape(g["name"])}</a>' for g in games if str(g["app_id"]) in reports["games"])
    options = "".join(f'<option value="{key}">{value[0]}</option>' for key, value in STATUSES.items() if key != "fails")
    backends = "".join(f'<option value="{key}">{value}</option>' for key, value in BACKENDS.items())
    return layout("Compatibility matrix", f'''
<section class="intro"><p class="eyebrow">Windows games · Apple silicon · Evidence first</p><h1>Choose a backend with evidence.</h1>
<p>Start with a game’s report. A DX11 launch option alone does not establish compatibility, and reaching a menu is not a gameplay pass.</p>
<div class="stats"><strong>{len(games)} games</strong><span>{tested_count} with evidence</span><span>{len(games) - tested_count} untested</span></div>
<p class="muted">Steam library snapshot: {reports["catalog_date"]}. Game titles and AppIDs only; DLC, tools and demos excluded.</p>
<p>Reports: {highlights}</p></section>
<aside class="notice"><strong>Current guidance:</strong> keep Metal 3 for Helldivers. Satisfactory’s DXMT functional checks passed with temporary stuttering; the tested DXVK path was unplayable. Read each report for versions and limits.</aside>
<section aria-labelledby="matrix-title"><h2 id="matrix-title">Compatibility matrix</h2>
<form id="filters" role="search"><label>Game or AppID<input id="search" type="search" placeholder="Search your game…" autocomplete="off"></label>
<label>Backend<select id="backend"><option value="any">Any backend</option>{backends}</select></label>
<label>Result<select id="status"><option value="all">All results</option><option value="tested">With evidence</option>{options}</select></label>
<button type="reset">Reset</button></form><p id="result-count" role="status" aria-live="polite">Showing {len(games)} games</p>
<noscript><p>The complete matrix and every game page work without JavaScript. Use your browser’s Find function to search.</p></noscript>
<div class="table-wrap" tabindex="0" role="region" aria-label="Scrollable compatibility matrix"><table id="matrix"><caption>Results apply only to the versions and setups recorded in each game’s report.</caption>
<thead><tr><th scope="col">Game</th><th scope="col">Recommended path</th>{''.join(f'<th scope="col">{b}</th>' for b in BACKENDS.values())}<th scope="col">API evidence</th><th scope="col">Last tested</th></tr></thead>
<tbody>{''.join(rows)}</tbody></table></div><p id="empty" hidden>No matching games. Try another search or reset the filters.</p></section>''')


def game_page(game, reports):
    report = reports["games"].get(str(game["app_id"]))
    body = f'<p><a href="../index.html">← All games</a></p><h1>{escape(game["name"])}</h1><p class="muted">Steam AppID {game["app_id"]} · <a href="https://store.steampowered.com/app/{game["app_id"]}/">Steam store</a></p>'
    body += f'<p><a href="../profiles/{game["app_id"]}.json" download>Download Gamekit profile JSON</a> · Gamekit downloads matching profiles automatically. Empty launch arguments preserve existing defaults; a profile does not certify compatibility.</p>'
    if not report:
        body += f'<section class="panel">{badge("untested")}<h2>No compatibility report yet</h2><p>This game is in the catalog, but its graphics API and behavior on Gamekit have not been evaluated. No backend is recommended yet.</p><p><a href="../contributing.html">Contribute a test result</a></p></section>'
    else:
        body += f'<aside class="notice"><h2>Recommendation</h2><p>{escape(report["recommendation"])}</p></aside><p>{escape(report["summary"])}</p>'
        for result in report["results"]:
            environment = reports["environments"][result["environment"]]
            evidence = "".join(f'<li><a href="{REPO}/blob/dev/{quote(path, safe="/")}">{escape(Path(path).stem.replace("-", " "))}</a></li>' for path in result["evidence"])
            options = " ".join(result["launch_options"])
            body += f'''<section class="panel"><h2>{BACKENDS[result["backend"]]} {badge(result["status"])}</h2>
<dl><dt>Backend version</dt><dd>{escape(result["version"])}</dd><dt>Graphics API</dt><dd>{escape(result["api"])} <span class="muted">({result["api_evidence"]})</span></dd>
<dt>Game build</dt><dd>{escape(result["build"])}</dd><dt>Test date</dt><dd>{result["date"]}</dd><dt>Hardware / OS</dt><dd>{escape(environment["hardware"])} · {escape(environment["os"])}</dd>
<dt>Runtime</dt><dd>{escape(environment["runtime"])}</dd></dl><p>{escape(result["notes"])}</p>
<h3>Tested launch options</h3>{f'<pre><code>{escape(options)}</code></pre>' if options else '<p>No additional launch options recorded.</p>'}
<p class="muted">Options describe the test, including failed tests; they are not automatically recommendations. Gamekit Play supplies the qualified Satisfactory options for installed optional backends.</p>
<h3>Evidence</h3><ul>{evidence}</ul></section>'''
        untested = [BACKENDS[b] for b in BACKENDS if b not in {r["backend"] for r in report["results"]}]
        if untested:
            body += f'<p><strong>No result recorded:</strong> {escape(", ".join(untested))}. Do not infer support from another API’s result.</p>'
        if report["issues"]:
            body += '<h2>Tracked follow-up</h2><p>' + escape(", ".join(report["issues"])) + ' (repository Beads tracker)</p>'
    return layout(game["name"], body, prefix="../", source="compatibility/reports.json" if report else "compatibility/games.json")


def build(games, reports, output, root=ROOT):
    validate(games, reports, root)
    profiles = game_profiles(games, root)
    output.mkdir(parents=True, exist_ok=False)
    (output / "profiles").mkdir()
    for app_id, profile in profiles.items():
        (output / "profiles" / f"{app_id}.json").write_text(json.dumps(profile, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (output / "games").mkdir()
    (output / "assets").mkdir()
    for name in ("site.css", "site.js"):
        shutil.copyfile(root / "compatibility/assets" / name, output / "assets" / name)
    (output / "index.html").write_text(matrix(games, reports), encoding="utf-8")
    for game in games:
        (output / "games" / f'{game["app_id"]}.html').write_text(game_page(game, reports), encoding="utf-8")
    legend = "".join(f'<tr><th scope="row">{badge(key)}</th><td>{escape(value[1])}</td></tr>' for key, value in STATUSES.items() if key != "fails")
    guide = f'''<h1>Choosing a graphics backend</h1><p>Find your game in the matrix and read its exact tested setup. Untested means unknown, not incompatible.</p>
<h2>Backend and API are different</h2><p>Apple/D3DMetal supplies the D3D11/D3D12 paths used by the accepted runtime. The installed DXMT and DXVK payloads are D3D10/11 backends, not D3D12 implementations. Some games use other APIs, such as OpenGL.</p>
<p>A game can offer more than one API. A DX11 flag can still lead to an unsupported feature-level request. Device creation and loaded DLLs alone do not prove which API renders gameplay.</p>
<h2>What each result means</h2><table><tbody>{legend}</tbody></table>
<h2>Change a selection</h2><p>Save and exit games, then Stop Windows Steam in Gamekit. Open the gear beside a game’s Play button and select its backend. Use shared default restores inheritance. Optional payloads must be installed and qualified before selection.</p>
<p><a href="{REPO}/blob/dev/docs/user-guide.md">Read the Gamekit operating guide</a> and <a href="{REPO}/blob/dev/docs/graphics-backends.md">backend installation and launch options</a>.</p>
<h2>Scope and currency</h2><p>These results describe recorded builds on a personal Apple-silicon macOS 27 prototype. Updates to the game, OS or runtime can change behavior. Check test dates; do not generalize one report to all hardware or future versions. The site follows the dev integration branch.</p>'''
    (output / "guide.html").write_text(layout("Choosing a backend", guide), encoding="utf-8")
    contribute = f'''<h1>Contribute a compatibility result</h1><p>This is a wiki-style reference maintained through GitHub pull requests. Anyone can propose corrections; results are reviewed before publication.</p>
<ol><li>Find the game’s Steam AppID and record its exact build.</li><li>Record hardware, macOS, Wine/runtime and backend versions, selected API and how you confirmed it, and any launch options.</li><li>Separate installation/startup from gameplay, audio, input, save/reload and measured performance. Report failed tests too.</li><li>Add a sanitized evidence report in <code>docs/</code> and update <code>compatibility/reports.json</code>. New catalog entries need only AppID and title; they remain untested until evidence is added.</li><li>Run the catalog checks and preview the site, then open a pull request targeting <code>dev</code>.</li></ol>
<p><a href="{REPO}/blob/dev/compatibility/README.md">Contributor instructions and exact build commands</a> · <a href="{REPO}/edit/dev/compatibility/reports.json">Edit report data on GitHub</a></p>
<h2>Keep private data private</h2><p>Publish game identities and sanitized findings only. Exclude account identifiers, authentication data, purchases, raw runtime logs, save files and screenshots. The initial catalog is a local Steam active-license snapshot, not a live account connection.</p>
<h2>Publishing</h2><p>Validated changes deploy automatically to GitHub Pages after merging into dev. Failed builds preserve the previous site. Corrections and rollbacks use the same PR workflow.</p>'''
    (output / "contributing.html").write_text(layout("Contribute", contribute), encoding="utf-8")
    for name, data in (("games.json", games), ("reports.json", reports)):
        (output / name).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (output / ".nojekyll").touch()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if not args.check and args.output is None:
        parser.error("Supply --output (a fresh directory) or --check")
    games = json.loads((ROOT / "compatibility/games.json").read_text())
    reports = json.loads((ROOT / "compatibility/reports.json").read_text())
    validate(games, reports)
    game_profiles(games)
    if args.output:
        build(games, reports, args.output)
    print(f"Validated {len(games)} games; {len(reports['games'])} have evidence; {len(games) - len(reports['games'])} untested")


if __name__ == "__main__":
    main()
