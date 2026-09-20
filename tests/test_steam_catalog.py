import importlib.util
from pathlib import Path
import struct
import unittest

SPEC = importlib.util.spec_from_file_location("steam_catalog", Path(__file__).parents[1] / "tools/export_steam_catalog.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SteamCatalogTests(unittest.TestCase):
    def test_latest_listing_does_not_keep_historical_licenses(self):
        old = "License packageID 0:\nActive\n- Apps :\n111,\n- Depots :\n"
        new = "License packageID 0:\nActive\n- Apps :\n222,\n- Depots :\n"
        self.assertEqual(MODULE.licensed_apps(old + new), {222})

    def test_active_apps_not_depots_or_inactive_licenses(self):
        log = """[date] License packageID 10:
[date] - State :
[date] Active
[date] - Purchased : PRIVATE
[date] - Apps :
[date] 10, 20,
[date] (2 in total)
[date] - Depots :
[date] 999,
[date] License packageID 11:
[date] - State :
[date] Expired
[date] - Apps :
[date] 30,
"""
        self.assertEqual(MODULE.licensed_apps(log), {10, 20})

    def test_only_game_identity_is_exported(self):
        result = MODULE.catalog({1, 2, 3}, {
            1: {"common": {"name": "A & B", "type": "Game"}, "secret": "PRIVATE"},
            2: {"common": {"name": "Expansion", "type": "DLC"}},
            3: {"common": {"name": "Tool", "type": "Tool"}},
            4: {"common": {"name": "Not licensed", "type": "Game"}},
        })
        self.assertEqual(result, [{"app_id": 1, "name": "A & B"}])

    def test_appinfo_string_table(self):
        keys = ["appinfo", "common", "name", "type"]
        blob = b"\x00" + struct.pack("<I", 0) + b"\x00" + struct.pack("<I", 1)
        blob += b"\x01" + struct.pack("<I", 2) + b"Example\0"
        blob += b"\x01" + struct.pack("<I", 3) + b"Game\0\x08\x08\x08"
        entry = struct.pack("<II", 42, 60 + len(blob)) + bytes(60) + blob
        offset = 16 + len(entry) + 4
        data = struct.pack("<IIQ", 0x07564429, 1, offset) + entry + bytes(4)
        data += struct.pack("<I", len(keys)) + b"\0".join(k.encode() for k in keys) + b"\0"
        self.assertEqual(MODULE.appinfo(data)[42]["common"]["name"], "Example")
        with self.assertRaises(ValueError):
            MODULE.appinfo(data[:20])

    def test_missing_metadata_refuses_silent_partial_inventory(self):
        with self.assertRaises(ValueError):
            MODULE.catalog({42}, {})
