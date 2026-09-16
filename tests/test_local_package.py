import importlib.util
import pathlib
import plistlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("package_local", ROOT / "tools/package_local.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class LocalPackageTests(unittest.TestCase):
    def test_refuses_existing_destination_and_wrong_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            app = root / "Gamekit.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/MacOS/Gamekit").write_bytes(b"fixture")
            with (app / "Contents/Info.plist").open("wb") as handle:
                plistlib.dump({"CFBundleIdentifier": "unexpected", "CFBundleExecutable": "Gamekit"}, handle)
            with self.assertRaises(ValueError):
                MODULE.validate_app(app)
            destination = root / "existing"
            destination.mkdir()
            with self.assertRaises(FileExistsError):
                MODULE.validate_destination(destination)

    def test_source_fingerprint_covers_uncommitted_source_without_private_data(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "App").mkdir()
            source = root / "App/Main.swift"
            source.write_text("first", encoding="utf-8")
            first = MODULE.source_fingerprint(root)
            (root / ".beads").mkdir()
            (root / ".beads/private").write_text("private", encoding="utf-8")
            self.assertEqual(first, MODULE.source_fingerprint(root))
            source.write_text("second", encoding="utf-8")
            self.assertNotEqual(first, MODULE.source_fingerprint(root))


if __name__ == "__main__":
    unittest.main()
