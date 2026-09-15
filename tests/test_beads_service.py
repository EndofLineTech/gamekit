"""Safety checks that do not touch the real board or GitHub."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    "beads_service", Path(__file__).parents[1] / "scripts/beads_service.py"
)
service = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(service)


class RecoverySafetyTests(unittest.TestCase):
    def test_restore_never_overwrites_existing_data_or_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            existing = parent / "live"
            existing.mkdir()
            marker = existing / "important"
            marker.write_text("preserve me")
            alias = parent / "alias"
            alias.symlink_to(existing, target_is_directory=True)
            dangling = parent / "dangling"
            dangling.symlink_to(parent / "missing")
            with mock.patch.object(service, "run") as run:
                for destination in (existing, alias, dangling):
                    with self.subTest(destination=destination):
                        with self.assertRaisesRegex(RuntimeError, "must not exist"):
                            service.restore(destination)
                run.assert_not_called()
            self.assertEqual(marker.read_text(), "preserve me")
            self.assertTrue(dangling.is_symlink())

    def test_restore_requires_an_existing_parent(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "missing" / "db"
            with mock.patch.object(service, "run") as run:
                with self.assertRaisesRegex(RuntimeError, "parent must already exist"):
                    service.restore(target)
                run.assert_not_called()
            self.assertFalse(target.parent.exists())

    def test_backup_refuses_unexpected_destination_and_records_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            support = Path(directory)
            config = {"dolt": "dolt", "database": "beads_gamekit"}
            with mock.patch.object(service, "SUPPORT", support), \
                 mock.patch.object(service, "settings", return_value=config), \
                 mock.patch.object(service, "wait_for_server"), \
                 mock.patch.object(service, "query", return_value=[
                     {"name": "github", "url": "git+https://example.invalid/wrong.git"}
                 ]), \
                 mock.patch.object(service, "run") as run:
                with self.assertRaisesRegex(RuntimeError, "refusing to upload"):
                    service.backup()
                run.assert_not_called()
            status = json.loads((support / "backup-status.json").read_text())
            self.assertFalse(status["ok"])
            self.assertIn("refusing to upload", status["error"])


if __name__ == "__main__":
    unittest.main()
