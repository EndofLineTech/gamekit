import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).parents[1] / "scripts/verify_runtime_overlay.py"
LIB = Path("Contents/Resources/wine/lib")


class RuntimeOverlayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.base, self.overlay, self.composed = (root / name for name in ("base", "overlay", "composed"))
        self.write(self.base / LIB / "wine/ntdll.dll", "core Wine")
        self.write(self.base / LIB / "external/D3DMetal.framework/old", "old graphics")
        self.write(self.overlay / "external/D3DMetal.framework/new", "new graphics")
        self.write(self.composed / LIB / "wine/ntdll.dll", "core Wine")
        self.write(self.composed / LIB / "external/D3DMetal.framework/new", "new graphics")

    @staticmethod
    def write(path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def check(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--base-app", str(self.base),
                                 "--overlay-lib", str(self.overlay), "--composed-app", str(self.composed)],
                                text=True, capture_output=True, check=False)
        return result.returncode, json.loads(result.stdout)

    def test_valid_overlay_preserves_core_and_framework_symlinks(self):
        for root in (self.overlay, self.composed / LIB):
            (root / "external/current").symlink_to("D3DMetal.framework")
        code, report = self.check()
        self.assertEqual(code, 0)
        self.assertTrue(report["ok"])

    def test_missing_core_and_stale_graphics_are_rejected(self):
        (self.composed / LIB / "wine/ntdll.dll").unlink()
        self.write(self.composed / LIB / "external/D3DMetal.framework/old", "leftover")
        code, report = self.check()
        self.assertEqual(code, 1)
        self.assertIn(str(LIB / "wine/ntdll.dll"), report["mismatches"])
        self.assertIn(str(LIB / "external/D3DMetal.framework/old"), report["unexpected_entries"])

    def test_modified_overlay_bytes_are_rejected(self):
        self.write(self.composed / LIB / "external/D3DMetal.framework/new", "wrong graphics")
        code, report = self.check()
        self.assertEqual(code, 1)
        self.assertFalse(report["ok"])


if __name__ == "__main__":
    unittest.main()
