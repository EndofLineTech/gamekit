"""Exercise the native helper's bounded, read-only identity selection."""
import json
import os
import plistlib
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest
from game_fixtures import GAMES


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
        cls.backend_probe = Path(cls.workspace.name).resolve() / "backend-probe"
        subprocess.run(["xcrun", "clang", "-x", "c", "-", "-o", str(cls.backend_probe)], input=r'''
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
int main(void) {
    char path[4096]; uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) || getenv("GAMEKIT_IDENTITY_ROUTED")) return 2;
    const char *actual = getenv("D3DM_MTL4"); if (!actual) actual = "unset";
    const char *name = strrchr(path, '/'); name = name ? name + 1 : path;
    printf("%s %s\n", name, actual);
    if (getenv("EXPECT_LIBRARY")) {
        void *library = dlopen("libGamekitBackendProbe.dylib", RTLD_NOW);
        if (!library) { puts(dlerror()); return 3; }
        const char *(*identity)(void) = dlsym(library, "identity");
        if (!identity || strcmp(identity(), getenv("EXPECT_LIBRARY"))) return 4;
    }
    return strcmp(actual, getenv("EXPECT_BACKEND")) || strcmp(name, getenv("EXPECT_LOADER"));
}
''', text=True, check=True, capture_output=True)
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

    def test_backend_override_is_image_and_session_scoped_and_restores_shared_default(self):
        image = r"C:\program files (x86)\steam\steamapps\common\satisfactory\game.exe"
        self.document["sharedGraphicsBackend"] = "metal3"
        self.document["graphicsBackends"] = {"526870": "automatic"}
        self.write()
        flags = dict(GAMEKIT_TEST_BACKEND_SETTING="1", GAMEKIT_TEST_WINDOWS_IMAGE=image, D3DM_MTL4="0")
        self.assertEqual(self.run_reader(**flags), "unset")
        self.assertEqual(self.run_reader("", **flags), "unset")
        # A Steam process must not adopt a game override even with inherited AppID.
        steam = flags | {"GAMEKIT_TEST_WINDOWS_IMAGE": r"C:\program files (x86)\steam\Steam.exe", "D3DM_MTL4": "1"}
        self.assertEqual(self.run_reader(**steam), "0")
        self.document["sharedGraphicsBackend"] = "automatic"
        self.document["graphicsBackends"] = {"526870": "metal3"}
        self.write()
        self.assertEqual(self.run_reader(**flags), "0")
        self.assertEqual(self.run_reader(**steam), "unset")
        self.assertEqual(self.run_reader("123456", **flags), "unset")
        self.assertEqual(self.run_reader(**(flags | {"GAMEKIT_SESSION_ID": "foreign", "D3DM_MTL4": "1"})), "1")
        for bad in ["unknown", True, 1, {}]:
            self.document["graphicsBackends"]["526870"] = bad
            self.write()
            self.assertEqual(self.run_reader(**flags), "unset")
        self.document["graphicsBackends"] = {"526870": "metal3"}
        self.document["directories"]["123456"] = self.document["directories"]["526870"]
        self.write()
        self.assertEqual(self.run_reader(**flags), "unset")

    def test_alternative_backend_is_game_scoped_and_preserves_dll_overrides(self):
        flags = dict(GAMEKIT_TEST_BACKEND_SETTING="1", GAMEKIT_TEST_DLL_SETTING="1",
                     GAMEKIT_TEST_WINDOWS_IMAGE=r"C:\program files (x86)\steam\steamapps\common\satisfactory\game.exe",
                     WINEDLLOVERRIDES="vcruntime140=n,b")
        for backend in ["dxmt", "dxvk"]:
            self.document["sharedGraphicsBackend"] = backend
            self.write()
            self.assertEqual(self.run_reader(**flags), "vcruntime140=n,b")
            child = flags | {"GAMEKIT_TEST_WINDOWS_IMAGE": r"C:\program files (x86)\steam\Steam.exe",
                             "WINEDLLOVERRIDES": "vcruntime140=n,b"}
            self.assertEqual(self.run_reader(**child), "vcruntime140=n,b")
            child.pop("GAMEKIT_TEST_DLL_SETTING")
            self.assertEqual(self.run_reader(**child), "0")

    def test_fullscreen_space_requires_boolean_opt_in_owned_session_and_main_image(self):
        self.document["games"]["553850"] = "Helldivers"
        self.document["directories"]["553850"] = "c:\\games\\"
        self.document["fullscreenSpaces"] = {"553850": True, "526870": True}
        self.document["fullscreenExecutables"] = {str(GAMES["primary"]["appId"]): GAMES["primary"]["executable"]}
        self.write()
        flags = dict(GAMEKIT_TEST_SPACE_SETTING="1", GAMEKIT_TEST_WINDOWS_IMAGE="C:\\games\\" + GAMES["primary"]["executable"])
        self.assertEqual(self.run_reader("553850", **flags), "enabled")
        self.assertEqual(self.run_reader("553850", **(flags | {"GAMEKIT_SESSION_ID": "foreign"})), "disabled")
        self.assertEqual(self.run_reader("553850", **(flags | {"GAMEKIT_TEST_WINDOWS_IMAGE": r"C:\games\crs-handler.exe"})), "disabled")
        self.assertEqual(self.run_reader("526870", **flags), "disabled")
        for value in [False, 1, "true", None]:
            self.document["fullscreenSpaces"]["553850"] = value
            self.write()
            self.assertEqual(self.run_reader("553850", **flags), "disabled")

    def test_fullscreen_space_accepts_an_arbitrary_profile_identity(self):
        self.document["games"]["42"] = "Fixture"
        self.document["directories"]["42"] = "c:\\fixture\\"
        self.document["fullscreenSpaces"] = {"42": True}
        self.document["fullscreenExecutables"] = {"42": "custom.exe"}
        self.write()
        flags = dict(GAMEKIT_TEST_SPACE_SETTING="1", GAMEKIT_TEST_WINDOWS_IMAGE=r"C:\fixture\custom.exe")
        self.assertEqual(self.run_reader("42", **flags), "enabled")
        self.assertEqual(self.run_reader("42", **(flags | {"GAMEKIT_TEST_WINDOWS_IMAGE": r"C:\fixture\other.exe"})), "disabled")
        self.document.pop("fullscreenExecutables")
        self.write()
        self.assertEqual(self.run_reader("42", **flags), "disabled")

    def test_matches_actual_windows_image_when_native_appid_is_absent(self):
        self.write()
        game = GAMES["renderer"]
        image = "C:\\Program Files (x86)\\Steam\\steamapps\\common\\" + game["name"] + "\\" + game["relativeExecutable"]
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

    def test_backend_survives_reexec_and_child_steam_does_not_inherit_game_choice(self):
        source, target, env = self.routing_fixture(self.backend_probe, self.helper)
        self.document["sharedGraphicsBackend"] = "metal3"
        self.document["graphicsBackends"] = {"526870": "automatic"}
        self.write()
        env.update(D3DM_MTL4="0", EXPECT_BACKEND="unset", EXPECT_LOADER="Gamekit Route Probe")
        image = r"C:\program files (x86)\steam\steamapps\common\satisfactory\game.exe"
        result = subprocess.run([str(source), image], env=env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.document["sharedGraphicsBackend"] = "automatic"
        self.document["graphicsBackends"] = {"526870": "metal3"}
        self.write()
        # Model a Steam child starting through a game's current loader/env.
        env.update(D3DM_MTL4="0", EXPECT_BACKEND="unset", EXPECT_LOADER="Windows Steam")
        child = subprocess.run([str(target), r"C:\program files (x86)\steam\Steam.exe"], env=env, capture_output=True, text=True, timeout=15)
        self.assertEqual(child.returncode, 0, child.stdout + child.stderr)

    def test_dxvk_library_pairing_reexecutes_even_same_loader_and_restores_steam(self):
        source, target, env = self.routing_fixture(self.backend_probe, self.helper)
        for name in ["base", "cx"]:
            directory = self.root / name
            directory.mkdir()
            subprocess.run(["xcrun", "clang", "-dynamiclib", "-x", "c", "-", "-o",
                            str(directory / "libGamekitBackendProbe.dylib")],
                           input=f'const char *identity(void) {{ return "{name}"; }}',
                           text=True, check=True, capture_output=True)
        base = str(self.root / "base")
        cx = str(self.root / "cx") + ":" + base
        self.document.update(sharedGraphicsBackend="metal3", graphicsBackends={"526870": "dxvk"},
                             defaultLibraryPath=base, dxvkLibraryPath=cx)
        self.write()
        image = r"C:\program files (x86)\steam\steamapps\common\satisfactory\game.exe"
        env.update(DYLD_FALLBACK_LIBRARY_PATH=base, EXPECT_LIBRARY="cx", EXPECT_BACKEND="unset", EXPECT_LOADER="Gamekit Route Probe")
        for loader in [source, target]:
            result = subprocess.run([str(loader), image], env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        env.update(DYLD_FALLBACK_LIBRARY_PATH=cx, EXPECT_LIBRARY="base", EXPECT_BACKEND="0", EXPECT_LOADER="Windows Steam")
        for loader in [source, target]:
            result = subprocess.run([str(loader), r"C:\program files (x86)\steam\Steam.exe"], env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

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
