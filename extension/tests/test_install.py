import importlib.util
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("browser_install", Path(__file__).resolve().parents[1] / "install.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class BrowserInstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "Proximus.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        executable = self.app / "Contents/MacOS/Proximus"
        executable.write_text("fixture only")
        executable.chmod(0o700)
        self.info = {"CFBundleExecutable": "Proximus", "ProximusBrowserProtocol": 1,
                     "ProximusBrowserExtensionID": installer.extension_id()}
        self.write_info()
        self.hosts = self.root / "NativeMessagingHosts"

    def write_info(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))

    @patch.object(installer.subprocess, "run")
    def test_registers_only_expected_extension_and_executable(self, verify):
        path = installer.install(self.app, self.hosts)
        manifest = json.loads(path.read_text())
        self.assertEqual(manifest["allowed_origins"], ["chrome-extension://" + installer.extension_id() + "/"])
        self.assertEqual(manifest["path"], str((self.app / "Contents/MacOS/Proximus").resolve()))
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        verify.assert_called_once()
        self.assertIn("--verify", verify.call_args.args[0])

    def test_old_app_is_rejected_without_changing_registration(self):
        self.info["ProximusBrowserProtocol"] = 0
        self.write_info()
        with self.assertRaises(ValueError):
            installer.install(self.app, self.hosts)
        self.assertFalse(self.hosts.exists())

    @patch.object(installer.subprocess, "run")
    def test_symlink_registration_and_directory_are_rejected(self, verify):
        outside = self.root / "outside"
        outside.mkdir()
        self.hosts.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            installer.install(self.app, self.hosts)
        self.hosts.unlink()
        self.hosts.mkdir()
        (self.hosts / (installer.HOST + ".json")).symlink_to(outside / "foreign.json")
        with self.assertRaises(ValueError):
            installer.install(self.app, self.hosts)
        self.assertFalse((outside / "foreign.json").exists())

    @patch.object(installer.subprocess, "run")
    def test_failed_signature_never_registers(self, verify):
        verify.side_effect = installer.subprocess.CalledProcessError(1, ["codesign"])
        with self.assertRaises(installer.subprocess.CalledProcessError):
            installer.install(self.app, self.hosts)
        self.assertFalse(self.hosts.exists())
