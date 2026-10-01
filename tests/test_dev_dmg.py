import pathlib
import tempfile
import unittest
from unittest import mock

from tools import package_dev_dmg


class DevDmgTests(unittest.TestCase):
    def test_preview_tag_requires_a_distinct_app_build(self):
        package_dev_dmg.validate_version("v0.1.0-dev.1", {
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "2"})
        for tag, info in [
            ("v0.1.0-dev.1", {"CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"}),
            ("v0.1.0", {"CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "2"}),
            ("v0.1.0-dev.2", {"CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "2"}),
            ("v0.1.0-dev.1", {"CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "2"}),
        ]:
            with self.subTest(tag=tag, info=info), self.assertRaises(ValueError):
                package_dev_dmg.validate_version(tag, info)

    def test_rejects_dirty_or_non_dev_sources_before_packaging(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            def git(result):
                def command(*arguments):
                    return result[arguments[-1]]
                return command
            with mock.patch.object(package_dev_dmg.package_local, "command", side_effect=git({
                    "--porcelain": " M App/Main.swift"})):
                with self.assertRaisesRegex(ValueError, "dirty"):
                    package_dev_dmg.clean_dev_source(root)
            with mock.patch.object(package_dev_dmg.package_local, "command", side_effect=git({
                    "--porcelain": "", "HEAD": "abc", "origin/dev": "abc", "--show-current": "task/candidate"})):
                with self.assertRaisesRegex(ValueError, "origin/dev"):
                    package_dev_dmg.clean_dev_source(root)
            with mock.patch.object(package_dev_dmg.package_local, "command", side_effect=git({
                    "--porcelain": "", "HEAD": "abc", "origin/dev": "def", "--show-current": "dev"})):
                with self.assertRaisesRegex(ValueError, "origin/dev"):
                    package_dev_dmg.clean_dev_source(root)

    def test_stage_has_drag_to_applications_link_and_no_runtime(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            docs = root / "docs/releases"
            docs.mkdir(parents=True)
            (docs / "v0.1.0-dev.1-install.txt").write_text("Preview: per-app Open Anyway\n", encoding="utf-8")
            (docs / "v0.1.0-dev.1.md").write_text("# Release\n", encoding="utf-8")
            (root / "LICENSE").write_text("fixture license", encoding="utf-8")
            source = root / "package"
            app = source / "Gamekit.app/Contents/MacOS"
            app.mkdir(parents=True)
            (app / "Gamekit").write_text("fixture app", encoding="utf-8")
            (source / "USER-GUIDE.md").write_text("[Included](guide.md)\n", encoding="utf-8")
            (source / "guide.md").write_text("# Guide\n", encoding="utf-8")
            payload = root / "payload"
            package_dev_dmg.prepare_payload(source, payload, root, "v0.1.0-dev.1")
            self.assertEqual((payload / "Applications").readlink(), pathlib.Path("/Applications"))
            self.assertTrue((payload / "Gamekit.app/Contents/MacOS/Gamekit").is_file())
            self.assertFalse((payload / "Gamekit.app/Contents/SharedSupport/wine").exists())
            self.assertEqual((payload / "Documentation/LICENSE").read_text(), "fixture license")
            self.assertTrue((payload / "READ-ME-FIRST.txt").is_file())
            (source / "redirect.md").symlink_to(root / "LICENSE")
            with self.assertRaisesRegex(ValueError, "redirect"):
                package_dev_dmg.prepare_payload(source, root / "second-payload", root, "v0.1.0-dev.1")


if __name__ == "__main__":
    unittest.main()
