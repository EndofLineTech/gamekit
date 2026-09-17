import io
import json
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / "tools"))
import prepare_text_input_runtime as runtime


class TextInputRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / "Original.app"
        self.destination = self.root / "Updated.app"
        original = self.source / runtime.DLL
        original.parent.mkdir(parents=True)
        original.write_bytes(b"original component")
        (self.source / "Contents/Resources").mkdir()
        self.dll = self.root / "backport.dll"
        self.dll.write_bytes(b"updated component")
        self.idl = self.root / "ctffunc.idl"
        self.idl.write_bytes(b"source interface")
        self.archive = self.root / "source.tar.gz"
        license_bytes = b"fixture source license"
        with tarfile.open(self.archive, "w:gz") as archive:
            member = tarfile.TarInfo("wine-wine-10.0/COPYING.LIB")
            member.size = len(license_bytes)
            archive.addfile(member, io.BytesIO(license_bytes))
        self.addCleanup(patch.stopall)
        patch.object(runtime, "BASE_HASHES", {runtime.DLL: runtime.digest(original)}).start()
        patch.object(runtime, "ARTIFACT_HASHES", {
            "msctf.dll": runtime.digest(self.dll), "wine-10.0.tar.gz": runtime.digest(self.archive),
            "ctffunc.idl": runtime.digest(self.idl),
        }).start()
        # Unit fixtures emulate clone semantics; the real APFS command is also
        # exercised when preparing the delivered runtime on the target Mac.
        self.copy = patch.object(runtime.subprocess, "run", side_effect=lambda args, **kwargs:
                                 shutil.copytree(args[-2], args[-1], symlinks=True)).start()

    def prepare(self):
        return runtime.prepare(self.source, self.destination, self.dll, self.archive, self.idl)

    def test_publishes_side_by_side_with_corresponding_sources(self):
        manifest = self.prepare()
        self.assertEqual((self.source / runtime.DLL).read_bytes(), b"original component")
        self.assertEqual((self.destination / runtime.DLL).read_bytes(), b"updated component")
        materials = self.destination / "Contents/Resources/GamekitTextInputSources"
        self.assertEqual((materials / "COPYING.LIB").read_bytes(), b"fixture source license")
        self.assertEqual(json.loads((materials / "manifest.json").read_text()), manifest)
        self.assertEqual(manifest["sourceFiles"]["wine-10.0.tar.gz"], runtime.digest(self.archive))
        with self.assertRaises(FileExistsError):
            self.prepare()
        self.assertEqual(self.copy.call_count, 1)

    def test_modified_component_is_rejected_before_copy(self):
        self.dll.write_bytes(b"wrong DLL")
        with self.assertRaises(ValueError):
            self.prepare()
        self.copy.assert_not_called()
        self.assertFalse(self.destination.exists())

    def test_redirected_provenance_directory_is_not_followed(self):
        outside = self.root / "preserve"
        outside.mkdir()
        (outside / "marker").write_bytes(b"preserve")
        (self.source / "Contents/Resources/GamekitTextInputSources").symlink_to(outside)
        with self.assertRaises(FileExistsError):
            self.prepare()
        self.assertEqual(list(outside.iterdir()), [outside / "marker"])
        self.assertFalse(self.destination.exists())
        self.assertEqual(list(self.root.glob(".text-input-*")), [])

    def test_redirected_resources_parent_is_not_followed(self):
        outside = self.root / "preserve"
        outside.mkdir()
        resources = self.source / "Contents/Resources"
        resources.rmdir()
        resources.symlink_to(outside)
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual(list(outside.iterdir()), [])
        self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main()
