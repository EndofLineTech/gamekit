"""Exercise the native helper's bounded, read-only identity selection."""
import json
import os
import plistlib
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest


class GameDockIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory()
        cls.binary = Path(cls.workspace.name).resolve() / "identity-reader"
        source = Path(__file__).resolve().parents[1] / "Sources/WineGameIdentity/GameIdentity.m"
        subprocess.run([
            "xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
            "-DGAMEKIT_IDENTITY_READER_TEST", "-framework", "AppKit",
            str(source), "-o", str(cls.binary),
        ], check=True, capture_output=True)
        cls.helper = Path(cls.workspace.name).resolve() / "WineGameIdentity.dylib"
        cls.probe = Path(cls.workspace.name).resolve() / "dock-probe"
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                        "-dynamiclib", "-framework", "AppKit", str(source), "-o", str(cls.helper)],
                       check=True, capture_output=True)
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "AppKit",
                        str(source.parents[2] / "tools/dock_identity_probe.m"), "-o", str(cls.probe)],
                       check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.workspace.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.mapping = self.root / "names.json"
        self.prefix = str(self.root / "Environments/steam")
        self.session = "59435B07-8324-4A5D-AD68-578E7AA813DB"
        self.document = {
            "schemaVersion": 1, "prefix": self.prefix,
            "sessionID": self.session, "games": {"526870": "Satisfactory"},
            "directories": {"526870": "c:\\program files (x86)\\steam\\steamapps\\common\\satisfactory\\"},
        }

    def run_reader(self, app_id="526870", **overrides):
        env = dict(os.environ, WINEPREFIX=self.prefix,
                   GAMEKIT_SESSION_ID=self.session,
                   GAMEKIT_GAME_NAMES_FILE=str(self.mapping), SteamAppId=app_id)
        env.update(overrides)
        return subprocess.run([str(self.binary)], env=env, capture_output=True,
                              text=True, check=True).stdout.strip()

    def write(self):
        self.mapping.write_text(json.dumps(self.document), encoding="utf-8")

    def test_maps_only_the_matching_installed_app(self):
        self.write()
        self.assertEqual(self.run_reader(), "Satisfactory")
        self.assertEqual(self.run_reader("413150"), "")
        self.assertEqual(self.run_reader("0"), "")
        self.assertEqual(self.run_reader("526870;bad"), "")
        self.assertEqual(self.run_reader("4294967296"), "")

    def test_matches_actual_windows_image_when_native_appid_is_absent(self):
        self.write()
        image = "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Satisfactory\\FactoryGame\\Binaries\\Win64\\FactoryGameSteam-Win64-Shipping.exe"
        self.assertEqual(self.run_reader("", GAMEKIT_TEST_WINDOWS_IMAGE=image), "Satisfactory")
        self.assertEqual(self.run_reader("", GAMEKIT_TEST_WINDOWS_IMAGE=image.replace("Satisfactory\\", "Satisfactory-other\\")), "")
        self.assertEqual(self.run_reader("", GAMEKIT_TEST_WINDOWS_IMAGE=image.replace("FactoryGame\\", "..\\Other\\")), "")
        self.assertEqual(self.run_reader("", GAMEKIT_TEST_WINDOWS_IMAGE="C:\\Program Files (x86)\\Steam\\Steam.exe"), "")
        self.document["directories"]["413150"] = self.document["directories"]["526870"]
        self.write()
        self.assertEqual(self.run_reader("", GAMEKIT_TEST_WINDOWS_IMAGE=image), "")

    def test_prefix_and_session_must_match(self):
        self.write()
        self.assertEqual(self.run_reader(WINEPREFIX="/other"), "")
        self.assertEqual(self.run_reader(GAMEKIT_SESSION_ID="foreign"), "")
        self.assertEqual(self.run_reader(GAMEKIT_SESSION_ID="59435B07-8324-4A5D-AD68-578E7AA813DA"), "")

    def test_rejects_invalid_or_oversized_documents(self):
        for data in [b"not JSON", b"[]", b" " * (1_048_576 + 1)]:
            self.mapping.write_bytes(data)
            self.assertEqual(self.run_reader(), "")
        self.document["schemaVersion"] = 2
        self.write()
        self.assertEqual(self.run_reader(), "")

    def test_rejects_non_string_or_control_character_names(self):
        for name in [12, "", "bad\nname", "x" * 1025]:
            self.document["games"]["526870"] = name
            self.write()
            self.assertEqual(self.run_reader(), "")

    def test_refuses_symlinks_in_the_mapping_path(self):
        self.write()
        alternate = self.root / "linked.json"
        alternate.symlink_to(self.mapping)
        self.assertEqual(self.run_reader(GAMEKIT_GAME_NAMES_FILE=str(alternate)), "")
        alias = self.root / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        self.assertEqual(self.run_reader(GAMEKIT_GAME_NAMES_FILE=str(alias / "names.json")), "")

    def test_refresh_reads_new_names_and_unicode_without_shell_interpretation(self):
        self.write()
        self.assertEqual(self.run_reader(), "Satisfactory")
        self.document["games"]["526870"] = 'A "quoted" game — 森'
        self.write()
        self.assertEqual(self.run_reader(), 'A "quoted" game — 森')

    def make_bundle(self, title, executable):
        bundle = self.root / "Launchers" / (title + ".app")
        binary = bundle / "Contents/MacOS" / title
        binary.parent.mkdir(parents=True)
        shutil.copy2(executable, binary)
        with (bundle / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "tech.endofline.gamekit.test." + title.replace(" ", ""),
                           "CFBundleExecutable": title, "CFBundleName": title,
                           "CFBundleDisplayName": title, "CFBundlePackageType": "APPL", "LSUIElement": True}, handle)
        return binary

    def routing_fixture(self, executable, helper):
        source = self.make_bundle("Windows Steam", executable)
        target = self.make_bundle("Gamekit Route Probe", executable)
        self.document["games"]["526870"] = "Gamekit Route Probe"
        self.document["loaders"] = {"526870": str(target)}
        self.document["defaultLoader"] = str(source)
        self.write()
        env = dict(os.environ, WINEPREFIX=self.prefix, GAMEKIT_SESSION_ID=self.session,
                   SteamAppId="526870", GAMEKIT_GAME_NAMES_FILE=str(self.mapping),
                   DYLD_INSERT_LIBRARIES=str(helper))
        return source, target, env

    def test_routes_to_identical_named_loader_and_refuses_changed_bytes(self):
        source, target, env = self.routing_fixture(self.probe, self.helper)
        result = subprocess.run([str(source), "Gamekit Route Probe"], env=env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.strip(), "Gamekit Route Probe")
        target.write_bytes(b"not the validated loader")
        refused = subprocess.run([str(source), "Windows Steam"], env=env,
                                 capture_output=True, text=True, timeout=15)
        self.assertEqual(refused.returncode, 0, refused.stdout + refused.stderr)

    def test_refuses_redirected_or_external_loader(self):
        source, target, env = self.routing_fixture(self.probe, self.helper)
        target.unlink()
        target.symlink_to(source)
        refused = subprocess.run([str(source), "Windows Steam"], env=env,
                                 capture_output=True, text=True, timeout=15)
        self.assertEqual(refused.returncode, 0, refused.stdout + refused.stderr)
        self.document["loaders"]["526870"] = str(self.probe)
        self.write()
        refused = subprocess.run([str(source), "Windows Steam"], env=env,
                                 capture_output=True, text=True, timeout=15)
        self.assertEqual(refused.returncode, 0, refused.stdout + refused.stderr)

    @unittest.skipUnless(os.environ.get("GAMEKIT_IDENTITY_X86_HELPER"), "Opt-in packaged x86_64 helper")
    def test_packaged_x86_helper_under_rosetta(self):
        probe = self.root / "rosetta-dock-probe"
        source = Path(__file__).resolve().parents[1] / "tools/dock_identity_probe.m"
        subprocess.run(["xcrun", "clang", "-arch", "x86_64", "-fobjc-arc", "-framework", "AppKit",
                        str(source), "-o", str(probe)], check=True, capture_output=True)
        source, _, env = self.routing_fixture(probe, os.environ["GAMEKIT_IDENTITY_X86_HELPER"])
        result = subprocess.run([str(source), "Gamekit Route Probe"], env=env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
