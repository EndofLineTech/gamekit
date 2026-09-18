"""Validate bounded PE edits used only in the isolated runtime experiment."""
import importlib.util
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location("stage_driver_trial", Path(__file__).resolve().parents[1] / "tools/stage_driver_trial.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DriverTrialStagingTests(unittest.TestCase):
    def fixture(self):
        data = bytearray(1024)
        struct.pack_into("<I", data, 0x3C, 0x80)
        data[0x80:0x84] = b"PE\0\0"
        struct.pack_into("<H", data, 0x86, 1)
        struct.pack_into("<H", data, 0x94, 240)
        struct.pack_into("<H", data, 0x98, 0x20B)
        struct.pack_into("<I", data, 0x98 + 112, 0x1000)
        struct.pack_into("<IIII", data, 0x98 + 240 + 8, 512, 0x1000, 512, 512)
        struct.pack_into("<I", data, 512 + 12, 0x1080)
        data[640:649] = b"dxgi.dll\0"
        return bytes(data)

    def test_rename_roundtrip_changes_only_module_name(self):
        original = self.fixture()
        renamed = module.renamed_dxgi(original)
        self.assertEqual(len(original), len(renamed))
        self.assertEqual([i for i, (a, b) in enumerate(zip(original, renamed)) if a != b], [643])
        self.assertEqual(module.renamed_dxgi(renamed, b"dxgm.dll\0", b"dxgi.dll\0"), original)
        with self.assertRaises(ValueError):
            module.renamed_dxgi(renamed)

    def test_marker_and_invalid_layouts(self):
        original = self.fixture()
        stamped = module.stamp_builtin(original)
        self.assertEqual(stamped[0x40:0x60], b"Wine builtin DLL" + bytes(16))
        self.assertEqual(stamped[0x60:], original[0x60:])
        invalid = bytearray(original)
        struct.pack_into("<I", invalid, 0x3C, 0x40)
        with self.assertRaises(ValueError):
            module.stamp_builtin(invalid)
        invalid = bytearray(original)
        struct.pack_into("<I", invalid, 0x98 + 112, 0x2000)
        with self.assertRaises(ValueError):
            module.renamed_dxgi(invalid)
