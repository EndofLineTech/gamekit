import importlib.util
from pathlib import Path
import unittest
import json
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("configuration_audit", ROOT / "tools/check_game_configuration.py")
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class GameConfigurationTests(unittest.TestCase):
    def test_code_has_no_embedded_game_execution_values(self):
        self.assertEqual(AUDIT.violations(), [])

    def test_new_json_game_is_covered_without_extending_an_allowlist(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "diagnostics/profiles").mkdir(parents=True)
            (root / "App").mkdir()
            parameters = {"schemaVersion": 1, "example": {"appId": 987654, "executable": "future-game.exe"}}
            (root / "diagnostics/profiles/games.json").write_text(json.dumps(parameters))
            (root / "App/Bad.swift").write_text('let image = "future-game.exe"\nif appID == 987654 {}\n')
            failures = AUDIT.violations(root)
            self.assertEqual(len(failures), 2)
