import io
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from stage_runtime_candidate import extract, safe_link


class RuntimeCandidateStagingTests(unittest.TestCase):
    def test_regular_files_then_internal_links_preserve_bytes_without_privilege_bits(self):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w") as archive:
            link = tarfile.TarInfo("root/entry"); link.type = tarfile.SYMTYPE; link.linkname = "bin/tool"
            archive.addfile(link)
            file = tarfile.TarInfo("root/bin/tool"); file.size = 4; file.mode = 0o6755
            archive.addfile(file, io.BytesIO(b"data"))
        stream.seek(0)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(extract(stream, "root", root), (4, 1, 1))
            self.assertEqual((root / "entry").read_bytes(), b"data")
            self.assertEqual((root / "bin/tool").stat().st_mode & 0o7777, 0o755)

    def test_external_links_and_symlink_parent_conflicts_are_refused(self):
        for target in ("/outside", "../../outside"):
            with self.assertRaises(ValueError):
                safe_link(Path("link"), target)
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w") as archive:
            link = tarfile.TarInfo("root/parent"); link.type = tarfile.SYMTYPE; link.linkname = "other"
            archive.addfile(link)
            file = tarfile.TarInfo("root/parent/file"); file.size = 1
            archive.addfile(file, io.BytesIO(b"x"))
        stream.seek(0)
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                extract(stream, "root", Path(directory))
