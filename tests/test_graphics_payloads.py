import io
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
import prepare_graphics_payloads as payloads
from qualify_graphics_backends import digest, member


class GraphicsPayloadTests(unittest.TestCase):
    def test_wrong_archive_is_rejected_before_destination_creation(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            archive = root / "wine.tar"
            archive.write_bytes(b"untrusted archive")
            with self.assertRaisesRegex(ValueError, "Wine archive digest"):
                payloads.prepare(root, archive, root / "output")
            self.assertFalse((root / "output").exists())

    def test_archive_member_must_be_a_bounded_regular_file(self):
        for link in [tarfile.SYMTYPE, tarfile.LNKTYPE]:
            data = io.BytesIO()
            with tarfile.open(fileobj=data, mode="w") as archive:
                entry = tarfile.TarInfo("module.dll")
                entry.type = link; entry.linkname = "/outside"
                archive.addfile(entry)
            data.seek(0)
            with tarfile.open(fileobj=data) as archive:
                with self.assertRaises(ValueError):
                    member(archive, "module.dll")

    def test_pinned_extraction_and_refusal_to_replace(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            def archive(path, prefix, names):
                with tarfile.open(path, "w:gz") as output:
                    for name in names:
                        data = ("fixture " + name).encode()
                        info = tarfile.TarInfo(prefix + "/" + name); info.size = len(data)
                        output.addfile(info, io.BytesIO(data))
            dlls = [f"{arch}/{name}" for arch in ["x86_64-windows", "i386-windows"] for name in ["d3d11.dll", "d3d10core.dll"]]
            dxgi = [f"{arch}/dxgi.dll" for arch in ["x86_64-windows", "i386-windows"]]
            archive(root / "wine.tar", "wswine.bundle/lib/wine", dxgi)
            archive(root / "dxvk.tar", "vk", dlls)
            archive(root / "dxmt.tar", "mt", dlls + dxgi + ["x86_64-windows/winemetal.dll", "i386-windows/winemetal.dll", "x86_64-unix/winemetal.so"])
            manifests = {key: (key + ".tar", digest(root / (key + ".tar")), prefix) for key, prefix in [("dxmt", "mt"), ("dxvk", "vk")]}
            with patch.object(payloads, "ARCHIVES", manifests), patch.object(payloads, "WINE_SHA256", digest(root / "wine.tar")):
                payloads.prepare(root, root / "wine.tar", root / "output")
                for revision in payloads.REVISIONS.values():
                    self.assertEqual((root / "output" / revision / "x86_64-windows/dxgi.dll").read_bytes(), b"fixture x86_64-windows/dxgi.dll")
                with self.assertRaisesRegex(ValueError, "Refusing to replace"):
                    payloads.prepare(root, root / "wine.tar", root / "output")
                (root / "redirect").symlink_to(root / "output")
                with self.assertRaisesRegex(ValueError, "symlink"):
                    payloads.prepare(root, root / "wine.tar", root / "redirect")


if __name__ == "__main__":
    unittest.main()
