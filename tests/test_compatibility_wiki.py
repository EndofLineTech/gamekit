import copy
from html.parser import HTMLParser
import importlib.util
from pathlib import Path
import tempfile
import unittest
from urllib.parse import urlsplit

SPEC = importlib.util.spec_from_file_location("wiki", Path(__file__).parents[1] / "tools/build_compatibility_wiki.py")
WIKI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WIKI)


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []

    def handle_starttag(self, tag, attrs):
        for name, value in attrs:
            if name in ("href", "src"):
                self.links.append(value)


class WikiTests(unittest.TestCase):
    def setUp(self):
        self.games = [{"app_id": 1, "name": '<script>alert("x")</script> & Game'}, {"app_id": 2, "name": "Untested Game"}]
        self.reports = {
            "schema_version": 1, "catalog_date": "2026-09-20",
            "environments": {"test": {"hardware": "M4", "os": "macOS 27", "runtime": "Wine 10", "note": "Fixture"}},
            "games": {"1": {"recommendation": "No recommendation", "recommended_backend": None,
                "summary": "Failed fixture", "issues": ["gamekit-test"], "results": [{
                    "backend": "dxvk", "status": "fails", "version": "1.10.3", "api": "D3D11 requested",
                    "api_evidence": "requested", "build": "123", "date": "2026-09-20", "environment": "test",
                    "launch_options": ["--flag=<untrusted>"], "notes": "No <guarantee>", "evidence": ["docs/e6-game-results.md"]
                }]}}
        }

    def test_unknowns_are_untested_and_failed_backend_is_not_recommended(self):
        WIKI.validate(self.games, self.reports)
        matrix = WIKI.matrix(self.games, self.reports)
        self.assertIn('data-id="2" data-apple="untested" data-dxmt="untested" data-dxvk="untested"', matrix)
        self.assertIn("No backend is recommended yet", WIKI.game_page(self.games[1], self.reports))
        bad = copy.deepcopy(self.reports)
        bad["games"]["1"]["recommended_backend"] = "dxvk"
        with self.assertRaisesRegex(ValueError, "positive evidence"):
            WIKI.validate(self.games, bad)

    def test_escape_titles_notes_and_arguments(self):
        html = WIKI.game_page(self.games[0], self.reports)
        self.assertNotIn('<script>alert(', html)
        self.assertIn("&lt;script&gt;", html)
        self.assertIn("--flag=&lt;untrusted&gt;", html)
        self.assertIn("No &lt;guarantee&gt;", html)

    def test_caveated_playability_supports_recommendations_and_has_its_own_filter(self):
        report = self.reports["games"]["1"]
        report["results"][0]["status"] = "caveats"
        report["recommended_backend"] = "dxvk"
        report["recommendation"] = "Use windowed mode"
        WIKI.validate(self.games, self.reports)
        self.assertIn('<option value="caveats">Playable with caveats</option>', WIKI.matrix(self.games, self.reports))
        page = WIKI.game_page(self.games[0], self.reports)
        self.assertIn("Playable with caveats", page)
        self.assertIn("Use windowed mode", page)

    def test_no_private_inventory_fields(self):
        for mutation in ({"steam_id": "PRIVATE"}, {"playtime": 123}, {"token": "SECRET"}):
            games = copy.deepcopy(self.games)
            games[0].update(mutation)
            with self.assertRaisesRegex(ValueError, "only AppID"):
                WIKI.validate(games, self.reports)

    def test_duplicate_id_and_invalid_evidence(self):
        with self.assertRaisesRegex(ValueError, "duplicate"):
            WIKI.validate(self.games + [self.games[0]], self.reports)
        for path in [".build/raw.log", "docs/../private.log", "docs/missing-report.md"]:
            bad = copy.deepcopy(self.reports)
            bad["games"]["1"]["results"][0]["evidence"] = [path]
            with self.assertRaises(ValueError):
                WIKI.validate(self.games, bad)

    def test_orphan_report_and_duplicate_backend_refused(self):
        with self.assertRaises(ValueError):
            WIKI.validate(self.games[1:], self.reports)
        bad = copy.deepcopy(self.reports)
        bad["games"]["1"]["results"] *= 2
        with self.assertRaisesRegex(ValueError, "duplicate backend"):
            WIKI.validate(self.games, bad)

    def test_build_is_deterministic_links_resolve_and_only_site_files_publish(self):
        with tempfile.TemporaryDirectory() as directory:
            left, right = Path(directory) / "one", Path(directory) / "two"
            for output in (left, right):
                WIKI.build(self.games, self.reports, output)
            files = {str(path.relative_to(left)) for path in left.rglob("*") if path.is_file()}
            self.assertEqual(files, {"index.html", "guide.html", "contributing.html", "games/1.html", "games/2.html",
                "assets/site.css", "assets/site.js", "games.json", "reports.json", ".nojekyll",
                "profiles/1.json", "profiles/2.json"})
            for name in files:
                self.assertEqual((left / name).read_bytes(), (right / name).read_bytes())
            for page in left.rglob("*.html"):
                parser = Links()
                parser.feed(page.read_text())
                for link in parser.links:
                    url = urlsplit(link)
                    if not url.scheme and url.path:
                        self.assertTrue((page.parent / url.path).is_file(), f"Broken link in {page}: {link}")
            with self.assertRaises(FileExistsError):
                WIKI.build(self.games, self.reports, left)
