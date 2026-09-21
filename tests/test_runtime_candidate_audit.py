import importlib.util
import io
from pathlib import Path
import struct
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("candidate_audit", ROOT / "tools/audit_runtime_candidate.py")
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class RuntimeCandidateAuditTests(unittest.TestCase):
    def test_binary_identity_distinguishes_host_and_guest(self):
        self.assertEqual(AUDIT.binary_kind(b"\xcf\xfa\xed\xfe" + struct.pack("<I", 0x0100000C)), "Mach-O:arm64")
        self.assertEqual(AUDIT.binary_kind(b"\xcf\xfa\xed\xfe" + struct.pack("<I", 0x01000007)), "Mach-O:x86_64")
        data = bytearray(128)
        data[:2] = b"MZ"; struct.pack_into("<I", data, 60, 64)
        data[64:68] = b"PE\0\0"; struct.pack_into("<H", data, 68, 0x8664)
        self.assertEqual(AUDIT.binary_kind(data), "PE:amd64-or-arm64ec")

    def test_links_are_only_recorded_and_traversal_is_refused(self):
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w") as output:
            metadata = tarfile.TarInfo("._candidate"); metadata.size = 4
            output.addfile(metadata, io.BytesIO(b"meta"))
            link = tarfile.TarInfo("candidate/link"); link.type = tarfile.SYMTYPE; link.linkname = "/outside"
            output.addfile(link)
            member = tarfile.TarInfo("candidate/link/metadata.txt"); member.size = 4
            output.addfile(member, io.BytesIO(b"safe"))
        archive.seek(0)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = AUDIT.inspect(archive, "candidate", ["link/*"], root)
            self.assertEqual(report["links"][0]["target"], "/outside")
            self.assertFalse((root / "link").is_symlink())
            self.assertEqual((root / "link/metadata.txt").read_bytes(), b"safe")
        for path in ("../outside", "/candidate/file", "candidate/../../outside", "other/file"):
            with self.assertRaises(ValueError):
                AUDIT.relative_member(path, "candidate")
