import pathlib
import tempfile
import unittest
from unittest import mock

from tools import package_notarized_dmg


class NotarizationValidationTests(unittest.TestCase):
    def test_only_accepted_matching_submission_with_empty_issue_log_passes(self):
        submission = {"id": "1bb387c8-6565-4d06-bd68-cf932215c874", "status": "Accepted"}
        log = {"jobId": submission["id"].upper(), "status": "Accepted", "issues": []}
        self.assertEqual(package_notarized_dmg.validate_notary_result(submission, log), submission["id"])
        for bad_submission, bad_log in (
            ({**submission, "status": "In Progress"}, log),
            ({**submission, "status": "Invalid"}, log),
            (submission, {**log, "status": "Invalid"}),
            (submission, {**log, "jobId": "9" * 32}),
            (submission, {**log, "issues": [{"severity": "warning", "message": "timestamp missing"}]}),
            ({**submission, "id": "not-a-uuid"}, log),
        ):
            with self.subTest(submission=bad_submission, log=bad_log), self.assertRaises(ValueError):
                package_notarized_dmg.validate_notary_result(bad_submission, bad_log)

    def test_private_rehearsal_requires_matching_version_and_stable_tag(self):
        info = {"CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "2"}
        package_notarized_dmg.validate_version("v0.1.0", info)
        with self.assertRaises(ValueError):
            package_notarized_dmg.validate_version("v0.1.1", info)
        with self.assertRaises(ValueError):
            package_notarized_dmg.validate_version("v0.1.0-dev.1", info)

    def test_rehearsal_notice_explicitly_rejects_publishing(self):
        with tempfile.TemporaryDirectory() as temporary:
            notice = pathlib.Path(temporary) / "READ-ME-FIRST.txt"
            package_notarized_dmg.write_rehearsal_notice(notice, "v0.1.0")
            content = notice.read_text()
            self.assertIn("PRIVATE REHEARSAL", content)
            self.assertIn("Steam", content)
            self.assertIn("Ubisoft Connect", content)
            self.assertIn("not approved for public distribution", content)

    def test_dirty_source_or_invalid_tag_cannot_start_signing_or_publish(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            destination = root / "candidate"
            with mock.patch.object(package_notarized_dmg.export_developer_id, "export") as signer:
                with self.assertRaisesRegex(ValueError, "stable release tag"):
                    package_notarized_dmg.rehearse(root, destination, "../preview", "RELEASE123", "local-profile")
                signer.assert_not_called()
                with mock.patch.object(package_notarized_dmg.export_developer_id, "clean_source",
                                       side_effect=ValueError("clean committed source")):
                    with self.assertRaisesRegex(ValueError, "clean committed source"):
                        package_notarized_dmg.rehearse(root, destination, "v0.1.0", "RELEASE123", "local-profile")
                signer.assert_not_called()
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
