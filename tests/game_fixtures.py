"""Shared JSON fixtures for game-specific diagnostic expectations."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAMES = json.loads((ROOT / "tests/fixtures/games.json").read_text(encoding="utf-8"))
SETTINGS = json.loads((ROOT / "tests/fixtures/game-settings.json").read_text(encoding="utf-8"))
