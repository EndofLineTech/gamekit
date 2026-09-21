import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from game_fixtures import GAMES

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("wiki_profiles", ROOT / "tools/build_compatibility_wiki.py")
wiki = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wiki)


class GameProfilesTests(unittest.TestCase):
    def test_execution_config_is_validated_and_generic_adapter_has_no_game_identity(self):
        profile = json.loads((ROOT / "Sources/GamekitCore/GameProfiles/553850.json").read_text())
        wiki.validate_profile(profile, 553850)
        self.assertEqual(profile["execution"]["driver"]["replacementVersion"], GAMES["primary"]["replacementVersion"])
        for invalid in ("../game.exe", "game.exe\\Mac Driver", "game.exe\nInjected=1"):
            profile["execution"]["executable"] = invalid
            with self.assertRaises(ValueError):
                wiki.validate_profile(profile, 553850)
        payload = (ROOT / "Sources/GamekitCore/ExecutionAdapters/dxgi-version-v1.dll").read_bytes()
        for name in (GAMES["primary"]["executable"], str(GAMES["primary"]["appId"]), str(GAMES["renderer"]["appId"])):
            self.assertNotIn(name.encode(), payload)
            self.assertNotIn(name.encode("utf-16le"), payload)
        for name in ("GameCompatibilityStore.swift", "SteamApplicationBundle.swift", "SteamLifecycle.swift"):
            source = (ROOT / "Sources/GamekitCore" / name).read_text()
            self.assertNotIn("553850", source)
            self.assertNotIn("526870", source)
            self.assertNotIn(GAMES["primary"]["executable"], source)

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
