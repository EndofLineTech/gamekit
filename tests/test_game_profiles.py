import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("wiki_profiles", ROOT / "tools/build_compatibility_wiki.py")
wiki = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wiki)


class GameProfilesTests(unittest.TestCase):
    def test_every_catalog_game_gets_matching_profile_and_link(self):
        games = json.loads((ROOT / "compatibility/games.json").read_text())
        reports = json.loads((ROOT / "compatibility/reports.json").read_text())
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "site"
            wiki.build(games, reports, output)
            for game in games:
                profile = json.loads((output / "profiles" / f'{game["app_id"]}.json').read_text())
                self.assertEqual(profile["appId"], game["app_id"])
                self.assertIn(f'../profiles/{game["app_id"]}.json', (output / "games" / f'{game["app_id"]}.html').read_text())
                if str(game["app_id"]) not in reports["games"]:
                    self.assertEqual(profile["launchArguments"], {})
            self.assertEqual(json.loads((output / "profiles/526870.json").read_text()),
                             json.loads((ROOT / "Sources/GamekitCore/GameProfiles/526870.json").read_text()))

    def test_rejects_profile_commands_and_wrong_identity(self):
        profile = json.loads((ROOT / "Sources/GamekitCore/GameProfiles/526870.json").read_text())
        with self.assertRaises(ValueError):
            wiki.validate_profile(profile, 42)
        profile["launchArguments"]["dxmt"] = ["%command%"]
        with self.assertRaises(ValueError):
            wiki.validate_profile(profile, 526870)


if __name__ == "__main__":
    unittest.main()
