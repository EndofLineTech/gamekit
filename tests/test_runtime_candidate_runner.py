import hashlib
import io
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]


class RuntimeCandidateRunnerTests(unittest.TestCase):
    def test_private_scope_and_reserved_environment_refusal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "runtime"; runtime.mkdir()
            (runtime / "gamekit-intake.json").write_text(json.dumps({"candidate": "fixture", "archiveSHA256": "fixture"}))
            wine = runtime / "wine"
            wine.write_text('#!/bin/sh\nprintf "%s\\n%s\\n" "$WINEPREFIX" "$HOME"\n')
            wine.chmod(0o755)
            server = runtime / "server"; server.write_text("#!/bin/sh\nexit 0\n"); server.chmod(0o755)
            profile = root / "profile.json"
            value = {"candidate": "fixture", "archiveSHA256": "fixture", "wine": "wine", "wineserver": "server", "environment": {}}
            profile.write_text(json.dumps(value))
            output = root / "run"
            command = [sys.executable, str(ROOT / "tools/probe_runtime_candidate.py"), "--profile", str(profile),
                       "--runtime", str(runtime), "--output", str(output), "--timeout", "5", "--", "--version"]
            subprocess.run(command, check=True, capture_output=True)
            result = json.loads((output / "result.json").read_text())
            self.assertEqual(result["serverWaitExit"], 0)
            self.assertEqual((output / "stdout.log").read_text().splitlines(), [str(output.resolve() / "prefix"), str(output.resolve() / "home")])
            value["environment"] = {"WINEPREFIX": str(root / "forbidden")}
            profile.write_text(json.dumps(value))
            command[command.index(str(output))] = str(root / "refused")
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertFalse((root / "forbidden").exists())

    def test_cleanup_keeps_evidence_and_external_symlink_targets(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory).resolve()
            runtime = workspace / "runtime"; runtime.mkdir()
            (runtime / "gamekit-intake.json").write_text('{"candidate":"fixture"}')
            run = workspace / "run"; run.mkdir(); (run / "prefix").mkdir()
            outside = workspace / "preserve"; outside.mkdir(); (outside / "data").write_text("keep")
            (run / "prefix/linked").symlink_to(outside, target_is_directory=True)
            (run / "result.json").write_text(json.dumps({"candidate": "fixture", "session": str(uuid.uuid4()), "serverWaitExit": 0}))
            (run / "stdout.log").write_text("evidence")
            subprocess.run([sys.executable, str(ROOT / "tools/cleanup_runtime_probes.py"), "--runtime", str(runtime),
                            "--workspace", str(workspace), "--scanner", "/usr/bin/true", "--apply", str(run)], check=True, capture_output=True)
            self.assertFalse((run / "prefix").exists())
            self.assertEqual((outside / "data").read_text(), "keep")
            self.assertEqual((run / "stdout.log").read_text(), "evidence")

    def test_nested_app_archive_reports_real_architecture_without_installing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            nested = io.BytesIO()
            with zipfile.ZipFile(nested, "w") as archive:
                archive.writestr("Fixture.app/Contents/MacOS/fixture", b"\xcf\xfa\xed\xfe" + struct.pack("<I", 0x0100000C))
                archive.writestr("Fixture.app/Contents/Info.plist", plistlib.dumps({"CFBundleIdentifier": "fixture", "CFBundleExecutable": "fixture"}))
            path = root / "outer.zip"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("inner.zip", nested.getvalue())
            profile = root / "profile.json"
            profile.write_text(json.dumps({"candidate": "fixture", "archiveSHA256": hashlib.sha256(path.read_bytes()).hexdigest()}))
            output = root / "report.json"
            subprocess.run([sys.executable, str(ROOT / "tools/audit_native_app_archive.py"), "--profile", str(profile),
                            "--archive", str(path), "--output", str(output)], check=True, capture_output=True)
            self.assertEqual(json.loads(output.read_text())["binaryCounts"], {"Mach-O:arm64": 1})
            self.assertFalse((root / "Fixture.app").exists())
