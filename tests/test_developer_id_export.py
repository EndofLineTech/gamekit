import hashlib
import json
import pathlib
import tempfile
import unittest
from unittest import mock

from tools import export_developer_id


class SignedModuleProfileTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.resources = pathlib.Path(self.temporary.name)
        (self.resources / "RuntimeModules").mkdir()
        (self.resources / "LauncherProfiles").mkdir()
        self.module = self.resources / "RuntimeModules/fixture.so"
        self.module.write_bytes(b"original signed module")
        self.original = hashlib.sha256(self.module.read_bytes()).hexdigest()
        self.profile = self.resources / "LauncherProfiles/launcher.json"
        self.profile.write_text(json.dumps({"name": "Vendor launcher", "installer": {"url": "https://vendor.example"},
                                            "runtimeModule": {"resource": "fixture.so", "replacementSHA256": self.original}}))

    def test_signs_once_and_updates_all_referencing_json_profiles(self):
        second = self.resources / "LauncherProfiles/other.json"
        second.write_text(self.profile.read_text())
        calls = []

        def sign(path):
            calls.append(path)
            path.write_bytes(path.read_bytes() + b" developer-id signature")

        evidence = export_developer_id.sign_profile_modules(self.resources, sign)
        signed = hashlib.sha256(self.module.read_bytes()).hexdigest()
        self.assertEqual(calls, [self.module])
        self.assertEqual(evidence, {"fixture.so": {"sourceSHA256": self.original, "signedSHA256": signed}})
        for path in (self.profile, second):
            profile = json.loads(path.read_text())
            self.assertEqual(profile["runtimeModule"]["replacementSHA256"], signed)
            self.assertEqual(profile["installer"]["url"], "https://vendor.example")

    def test_refuses_unpinned_bytes_before_signing(self):
        self.module.write_bytes(b"changed source")
        calls = []
        with self.assertRaisesRegex(ValueError, "profile hash"):
            export_developer_id.sign_profile_modules(self.resources, calls.append)
        self.assertEqual(calls, [])

    def test_refuses_unreferenced_module_and_resource_redirect(self):
        unreferenced = self.resources / "RuntimeModules/unreferenced.so"
        unreferenced.write_bytes(b"other code")
        with self.assertRaisesRegex(ValueError, "unreferenced"):
            export_developer_id.sign_profile_modules(self.resources, lambda _: None)
        unreferenced.unlink()
        self.module.unlink()
        self.module.symlink_to(self.profile)
        with self.assertRaisesRegex(ValueError, "regular"):
            export_developer_id.sign_profile_modules(self.resources, lambda _: None)

    def test_refuses_profile_path_traversal(self):
        profile = json.loads(self.profile.read_text())
        profile["runtimeModule"]["resource"] = "../fixture.so"
        self.profile.write_text(json.dumps(profile))
        with self.assertRaisesRegex(ValueError, "resource name"):
            export_developer_id.sign_profile_modules(self.resources, lambda _: None)

    def test_export_reseal_updates_only_profile_hash_after_xcode_resigns_module(self):
        evidence = export_developer_id.sign_profile_modules(
            self.resources, lambda path: path.write_bytes(path.read_bytes() + b" first signature"))
        self.module.write_bytes(self.module.read_bytes() + b" export signature")
        exported = hashlib.sha256(self.module.read_bytes()).hexdigest()
        result = export_developer_id.sync_export_profiles(self.resources, evidence)
        self.assertEqual(result, {"fixture.so": {**evidence["fixture.so"], "exportedSHA256": exported}})
        self.assertEqual(json.loads(self.profile.read_text())["runtimeModule"]["replacementSHA256"], exported)

    def test_export_reseal_rejects_unexpected_profile_hash(self):
        evidence = export_developer_id.sign_profile_modules(
            self.resources, lambda path: path.write_bytes(path.read_bytes() + b" first signature"))
        profile = json.loads(self.profile.read_text())
        profile["runtimeModule"]["replacementSHA256"] = "0" * 64
        self.profile.write_text(json.dumps(profile))
        with self.assertRaisesRegex(ValueError, "archive-signed"):
            export_developer_id.sync_export_profiles(self.resources, evidence)

    def test_export_reseal_rejects_missing_profile(self):
        evidence = export_developer_id.sign_profile_modules(
            self.resources, lambda path: path.write_bytes(path.read_bytes() + b" first signature"))
        self.profile.unlink()
        with self.assertRaisesRegex(ValueError, "lost a launcher profile"):
            export_developer_id.sync_export_profiles(self.resources, evidence)


class SigningGuardTests(unittest.TestCase):
    def test_rejects_dirty_source_before_archiving(self):
        with mock.patch.object(export_developer_id, "run", return_value=" M project.yml") as command:
            with self.assertRaisesRegex(ValueError, "clean committed source"):
                export_developer_id.clean_source(pathlib.Path("/source"))
            command.assert_called_once_with("git", "status", "--porcelain", cwd=pathlib.Path("/source"))

    def test_rejects_wrong_team_or_adhoc_nested_signature(self):
        valid = ("Authority=Developer ID Application: Signer (RELEASE123)\n"
                 "TeamIdentifier=RELEASE123\nTimestamp=now\nflags=0x10000(runtime)\n")

        def check(details):
            with mock.patch.object(export_developer_id.subprocess, "run", side_effect=[
                    mock.Mock(stderr=details), mock.Mock(stdout="Executable=/fixture")]):
                export_developer_id.signature_details(pathlib.Path("/fixture"), "RELEASE123", executable=True)

        check(valid)
        for invalid in (valid.replace("RELEASE123", "OTHERTEAM0"), valid + "Signature=adhoc\n",
                        valid.replace("flags=0x10000(runtime)", "flags=0x0(none)")):
            with self.assertRaises(ValueError):
                check(invalid)


if __name__ == "__main__":
    unittest.main()
