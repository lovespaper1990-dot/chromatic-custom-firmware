#!/usr/bin/env python3
"""Exercise offline launcher guarantees and dependency setup without USB or downloads."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("bootstrap", REPO / "tools/bootstrap_installer.py")
bootstrap = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bootstrap)


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="chromatic-launch-中文 ")
        self.package = Path(self.temporary.name).resolve()
        (self.package / "tools").mkdir()
        (self.package / "tools/flash_firmware.py").write_text("# fixture only\n")
        self.location = mock.patch.object(bootstrap, "__file__", str(self.package / "tools/bootstrap_installer.py"))
        self.location.start()

    def tearDown(self):
        self.location.stop()
        self.temporary.cleanup()

    def firmware(self):
        (self.package / "fpga").mkdir()
        (self.package / "esp32").mkdir()
        (self.package / "fpga/evt1_x2.fs").write_bytes(b"fixture")
        (self.package / "esp32/mcu_fw.bin").write_bytes(b"fixture")

    def test_inspections_never_install_even_when_install_requested(self):
        for option in ("--check", "--dry-run", "--help"):
            with self.subTest(option=option), mock.patch.object(bootstrap, "existing_tool", return_value=None), \
                    mock.patch.object(bootstrap, "execute_core", return_value=7) as core, \
                    mock.patch.object(bootstrap, "run", side_effect=AssertionError("install")), \
                    mock.patch.object(bootstrap, "modules_ready", side_effect=AssertionError("setup")), \
                    mock.patch.object(bootstrap, "confirm_setup", side_effect=AssertionError("prompt")):
                self.assertEqual(bootstrap.main([option, "--install-deps", "--package", str(self.package)]), 7)
                self.assertIn(option, core.call_args.args[2])
                self.assertFalse((self.package / ".installer-venv").exists())

    def test_source_zip_fails_before_setup(self):
        with mock.patch.object(bootstrap, "existing_tool", return_value=None), \
                mock.patch.object(bootstrap, "confirm_setup", side_effect=AssertionError("prompt")), \
                self.assertRaisesRegex(RuntimeError, "Releases"):
            bootstrap.main([])

    def test_cancel_does_not_install_or_start_core(self):
        self.firmware()
        with mock.patch.object(bootstrap, "existing_tool", return_value=None), \
                mock.patch.object(bootstrap, "modules_ready", return_value=False), \
                mock.patch.dict(os.environ, {"CHROMATIC_INSTALL_DEPS": "0"}), \
                mock.patch("builtins.input", return_value="n"), \
                mock.patch.object(bootstrap, "run", side_effect=AssertionError("install")), \
                mock.patch.object(bootstrap, "execute_core", side_effect=AssertionError("core")), \
                self.assertRaisesRegex(RuntimeError, "取消"):
            bootstrap.main([])

    def test_ready_venv_reuses_tools_without_setup(self):
        self.firmware()
        tool = self.package / "tool folder/openFPGALoader"
        with mock.patch.object(bootstrap, "existing_tool", return_value=tool), \
                mock.patch.object(bootstrap, "modules_ready", return_value=True), \
                mock.patch.object(bootstrap, "confirm_setup", side_effect=AssertionError("prompt")), \
                mock.patch.object(bootstrap, "execute_core", return_value=0) as core:
            self.assertEqual(bootstrap.main(["--yes", "--no-pause"]), 0)
            self.assertEqual(core.call_args.args[2], ["--yes"])
            self.assertEqual(core.call_args.args[4], tool)

    def test_setup_pins_local_python_packages(self):
        self.firmware()
        tool = self.package / "tool folder/openFPGALoader"
        with mock.patch.object(bootstrap, "existing_tool", return_value=None), \
                mock.patch.object(bootstrap, "modules_ready", side_effect=[False, True]), \
                mock.patch.object(bootstrap, "install_tool", return_value=tool), \
                mock.patch.object(bootstrap, "run") as run, \
                mock.patch.object(bootstrap, "execute_core", return_value=0):
            self.assertEqual(bootstrap.main(["--install-deps"]), 0)
            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual(commands[0][1:3], ["-m", "venv"])
            self.assertIn("esptool==4.13.0", commands[1])
            self.assertIn("pyserial==3.5", commands[1])
            self.assertEqual(commands[1][0], bootstrap.venv_python(self.package))

    def test_tool_runtime_path_preserves_spaces(self):
        tool = self.package / "ucrt64/bin/openFPGALoader.exe"
        with mock.patch.object(bootstrap.subprocess, "call", return_value=0) as run:
            bootstrap.execute_core(Path("core script.py"), Path("python path/python.exe"),
                                   ["--dry-run"], self.package, tool)
            args, keywords = run.call_args
            self.assertEqual(args[0][0:2], ["python path/python.exe", "core script.py"])
            self.assertEqual(keywords["env"]["OPENFPGALOADER"], str(tool))
            self.assertTrue(keywords["env"]["PATH"].startswith(str(tool.parent) + os.pathsep))

    def test_msys2_custom_path_and_signed_package_command(self):
        root = self.package / "MSYS2 安装"
        (root / "usr/bin").mkdir(parents=True)
        (root / "usr/bin/bash.exe").write_text("fixture")
        (root / "ucrt64/bin").mkdir(parents=True)
        (root / "ucrt64/bin/openFPGALoader.exe").write_text("fixture")
        windows = mock.Mock(wraps=os)
        windows.name = "nt"
        windows.environ = dict(os.environ, MSYS2_ROOT=str(root))
        with mock.patch.object(bootstrap, "os", windows), \
                mock.patch.object(bootstrap.platform, "system", return_value="Windows"), \
                mock.patch.object(bootstrap, "run") as run:
            self.assertEqual(bootstrap.install_tool(), root / "ucrt64/bin/openFPGALoader.exe")
            command, environment = run.call_args.args
            self.assertEqual(command[0], root / "usr/bin/bash.exe")
            self.assertEqual(command[2], "pacman -S --needed --noconfirm " + bootstrap.MSYS2_PACKAGE)
            self.assertEqual(environment["MSYSTEM"], "UCRT64")

    @unittest.skipUnless(sys.platform == "darwin", "Mac shell smoke test")
    def test_mac_launcher_package_path_and_arguments(self):
        launcher = self.package / "一键刷机-Mac.command"
        shutil.copy2(REPO / launcher.name, launcher)
        result = self.package / "seen.json"
        (self.package / "tools/bootstrap_installer.py").write_text(
            "import json,sys\nfrom pathlib import Path\n"
            "Path('seen.json').write_text(json.dumps(sys.argv[1:]))\n")
        subprocess.run(["bash", str(launcher), "--check", "--no-pause", "--package", str(self.package)],
                       check=True, stdin=subprocess.DEVNULL)
        self.assertEqual(json.loads(result.read_text()),
                         ["--check", "--no-pause", "--package", str(self.package)])


if __name__ == "__main__":
    unittest.main()
