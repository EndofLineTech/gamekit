"""Native diagnostics must obtain selectors from JSON at run time."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == "darwin", "Native Foundation fixture")
class DiagnosticProfilesTests(unittest.TestCase):
    def test_selectors_change_without_recompiling_and_missing_data_disables_matching(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "reader"
            source = '#include "DiagnosticProfile.h"\nint main(int argc, char **argv) { @autoreleasepool { if(argc != 3) return 2; puts(GamekitDiagnosticMatches(@"primary", @(argv[1]), @(argv[2])) ? "yes" : "no"); } }'
            subprocess.run(["xcrun", "clang", "-x", "objective-c", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                            "-I", str(ROOT / "diagnostics"), "-framework", "Foundation", "-", "-o", str(binary)],
                           input=source, text=True, check=True, capture_output=True)
            profile = root / "profile.json"
            env = dict(os.environ, GAMEKIT_DIAGNOSTIC_PROFILE=str(profile))

            def read(app, image):
                return subprocess.check_output([str(binary), app, image], env=env, text=True).strip()

            self.assertEqual(read("42", "custom.exe"), "no")
            document = {"schemaVersion": 1, "primary": {"appId": 42, "executable": "custom.exe"}}
            profile.write_text(json.dumps(document))
            self.assertEqual(read("42", "custom.exe"), "yes")
            self.assertEqual(read("43", "custom.exe"), "no")
            document["primary"]["executable"] = "changed.exe"
            profile.write_text(json.dumps(document))
            self.assertEqual(read("42", "custom.exe"), "no")
            self.assertEqual(read("42", "changed.exe"), "yes")
            document["schemaVersion"] = True
            profile.write_text(json.dumps(document))
            self.assertEqual(read("42", "changed.exe"), "no")
