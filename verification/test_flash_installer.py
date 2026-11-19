#!/usr/bin/env python3
"""Installer regression checks. All USB, serial and flash operations are mocked."""
from contextlib import nullcontext
import hashlib
import importlib.util
import io
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools/flash_firmware.py"
spec = importlib.util.spec_from_file_location("flash_firmware", SCRIPT)
installer = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = installer
spec.loader.exec_module(installer)


def partition(kind, subtype, offset, size, label, flags=0):
    return struct.pack("<HBBII16sI", 0x50AA, kind, subtype, offset, size, label, flags)


def table(entries=None):
    if entries is None:
        entries = [partition(1, 2, 0x9000, 0x6000, b"nvs"),
                   partition(1, 1, 0xF000, 0x1000, b"phy_init"),
                   partition(0, 0, 0x10000, 0x177000, b"factory")]
    body = b"".join(entries)
    body += b"\xeb\xeb" + b"\xff" * 14 + hashlib.md5(body).digest()
    return body.ljust(0xC00, b"\xff")


def serial_port(device="COM8", vid=0x374E, pid=0x0101, interface=None):
    return SimpleNamespace(device=device, vid=vid, pid=pid, interface=interface)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.package = Path(self.temp.name) / "固件包 with spaces"
        self.package.mkdir()
        files = {"fpga/evt1_x2.fs": b"test-fpga-image",
                 "esp32/mcu_fw.bin": b"test-esp32-application",
                 "esp32/partition_table/partition-table.bin": table(),
                 "说明.txt": "安装说明".encode()}
        self.hashes = {}
        for relative, data in files.items():
            destination = self.package / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            self.hashes[relative] = hashlib.sha256(data).hexdigest()
        self.pins = patch.object(installer, "EXPECTED_HASHES", {
            name: self.hashes[name] for name in ("fpga/evt1_x2.fs", "esp32/mcu_fw.bin")})
        self.pins.start()
        self.addCleanup(self.pins.stop)
        self.manifest()

    def manifest(self):
        (self.package / "SHA256SUMS").write_text("".join(
            f"{digest}  {name}\n" for name, digest in self.hashes.items()), encoding="utf-8")

    def test_valid_package_and_unicode_paths(self):
        entries = installer.validate_package(self.package)
        self.assertEqual(set(entries), set(self.hashes))

    def test_manifest_damage_and_different_paired_image_stop(self):
        (self.package / "fpga/evt1_x2.fs").write_bytes(b"changed")
        with self.assertRaises(installer.InstallError):
            installer.validate_package(self.package)
        self.hashes["fpga/evt1_x2.fs"] = hashlib.sha256(b"changed").hexdigest()
        self.manifest()
        with self.assertRaises(installer.InstallError):
            installer.validate_package(self.package)

    def test_manifest_duplicate_and_unsafe_paths(self):
        manifest = self.package / "SHA256SUMS"
        original = manifest.read_text()
        for relative in ("../outside", "/absolute", "C:\\device", "./说明.txt", "a//b", "a/../b"):
            with self.subTest(relative=relative):
                manifest.write_text(original + "0" * 64 + "  " + relative + "\n")
                with self.assertRaises(installer.InstallError):
                    installer.validate_package(self.package)
        manifest.write_text(original + original.splitlines()[0] + "\n")
        with self.assertRaises(installer.InstallError):
            installer.validate_package(self.package)

    def test_manifest_missing_file_stops(self):
        (self.package / "说明.txt").unlink()
        with self.assertRaises(installer.InstallError):
            installer.validate_package(self.package)

    def test_partition_structure_and_digest(self):
        installer.parse_partition_table(table(), 0x13FAC0)
        damaged = bytearray(table())
        damaged[10] ^= 1
        with self.assertRaises(installer.InstallError):
            installer.parse_partition_table(bytes(damaged), 100)
        with self.assertRaises(installer.InstallError):
            installer.parse_partition_table(table()[:-1], 100)
        with self.assertRaises(installer.InstallError):
            installer.parse_partition_table(table()[:96].ljust(0xC00, b"\xff"), 100)

    def test_partition_layout_constraints(self):
        nvs = partition(1, 2, 0x9000, 0x6000, b"nvs")
        factory = partition(0, 0, 0x10000, 0x177000, b"factory")
        cases = [
            [nvs, partition(0, 0, 0x20000, 0x177000, b"factory")],
            [nvs, partition(0, 0, 0x10000, 0x1000, b"factory")],
            [nvs, partition(0, 0, 0x10000, 0x177000, b"factory", 1)],
            [nvs, factory, partition(0, 0x10, 0x200000, 0x100000, b"ota_0")],
            [nvs, factory, partition(1, 0, 0x180000, 0x2000, b"otadata")],
            [nvs, factory, partition(1, 0x81, 0x11000, 0x1000, b"overlap")],
            [nvs, partition(0, 0, 0x10000, 0x400000, b"factory")],
            [factory],
        ]
        for entries in cases:
            with self.subTest(entries=entries), self.assertRaises(installer.InstallError):
                installer.parse_partition_table(table(entries), 0x2000)

    def test_both_usb_scan_formats_and_multiple_devices(self):
        modern = "Bus device vid:pid probe_type manufacturer serial product\n001 007    0x33aa:0x0120 gwu2x Gowin secret Chromatic\n"
        legacy = "33aa:0120 (bus 1, device  7), manufacturer: Gowin\n"
        self.assertEqual(installer.parse_probes(modern), [installer.Probe(1, 7)])
        self.assertEqual(installer.parse_probes(legacy), [installer.Probe(1, 7)])
        self.assertEqual(installer.parse_probes(modern + legacy), [installer.Probe(1, 7)])
        self.assertEqual(installer.parse_probes("001 009 0x374e:0x0101 Chromatic"), [])
        with self.assertRaises(installer.InstallError):
            installer.parse_probes("unknown-format 33aa:0120 address=?")

    def test_trusted_serial_identification(self):
        candidates = installer.port_candidates([
            serial_port(), serial_port("COM9", pid=0x0108), serial_port("COM10", pid=0x0110),
            serial_port("COM11", vid=0x1234), serial_port("COM12", interface="Audio"),
            serial_port("com8"), serial_port("COM13", interface="CDC data")])
        self.assertEqual([p.device for p in candidates], ["COM8", "COM9", "COM13"])

    def test_serial_explicit_port_and_multiple_rejection(self):
        ports = SimpleNamespace(comports=lambda: [serial_port()])
        with patch.dict(sys.modules, {"serial": SimpleNamespace(), "serial.tools": SimpleNamespace(list_ports=ports)}):
            self.assertEqual(installer.choose_port("com8"), "COM8")
            with self.assertRaises(installer.InstallError):
                installer.choose_port("COM99")
            ports.comports = lambda: [serial_port(), serial_port("COM9")]
            with self.assertRaises(installer.InstallError):
                installer.choose_port()

    def test_wrong_fpga_and_multi_chain_rejection(self):
        installer.ensure_fpga("idcode 0x1281b\nmodel GW5A-25\n")
        for output in ("idcode 0x1281b\nmodel GW5A-138\n", "idcode 0x123456\nmodel GW5A-25\n",
                       "idcode 0x1281b\nidcode 0x1281b\nmodel GW5A-25\n"):
            with self.assertRaises(installer.InstallError):
                installer.ensure_fpga(output)

    def test_offline_modes_never_instantiate_usb_runner(self):
        with patch.object(installer, "Commands", side_effect=AssertionError("USB must stay untouched")), \
                patch.object(installer, "check_dependencies", return_value="tool") as dependencies, \
                patch("sys.stdout", new_callable=io.StringIO):
            self.assertEqual(installer.main(["--package", str(self.package), "--dry-run"]), 0)
            dependencies.assert_not_called()
            self.assertEqual(installer.main(["--package", str(self.package), "--check"]), 0)
        self.assertFalse((self.package / ".flash-logs").exists())

    def test_declined_warning_never_touches_hardware(self):
        with patch.object(installer, "check_dependencies", return_value="tool"), \
                patch.object(installer, "install") as install, \
                patch("builtins.input", return_value="n"), patch("sys.stdout", new_callable=io.StringIO) as printed:
            self.assertEqual(installer.main(["--package", str(self.package)]), 0)
            self.assertIn("非官方、个人分享的开源固件", printed.getvalue())
            install.assert_not_called()

    def execute_install(self, bad_table=False, fail_fpga=False, fail_mcu=False, wrong_fpga=False,
                        second_probe=None, third_probe=None):
        calls = []
        objects = []
        package = self.package

        class FakeCommands:
            def __init__(self, root):
                self.path = package / "mock-private.log"
                self.completed = []
                self.result = None
                objects.append(self)

            def phase(self, name):
                pass

            def run(self, command, timeout=60, echo=False):
                calls.append(command)
                if "--scan-usb" in command:
                    number = sum("--scan-usb" in c for c in calls)
                    probe = second_probe if number == 2 else third_probe if number == 3 else None
                    return probe or "001 007 0x33aa:0x0120 gwu2x\n"
                if "--detect" in command:
                    return "idcode 0x123456\nmodel GW5A-25\n" if wrong_fpga else "idcode 0x1281b\nmodel GW5A-25\n"
                if "read_flash" in command:
                    Path(command[-1]).write_bytes(b"\0" * 0xC00 if bad_table else table())
                if "--write-flash" in command and fail_fpga:
                    raise installer.InstallError("injected FPGA failure")
                if "write_flash" in command and fail_mcu:
                    raise installer.InstallError("injected MCU failure")
                return "Hash of data verified.\n"

            def done(self, name):
                self.completed.append(name)

            def finish(self, result):
                self.result = result

        with patch.object(installer, "Commands", FakeCommands), \
                patch.object(installer, "flash_lock", return_value=nullcontext()), \
                patch.object(installer, "choose_port", side_effect=["COM8", "COM12"]), \
                patch("sys.stdout", new_callable=io.StringIO):
            entries = installer.validate_package(self.package)
            try:
                installer.install(self.package, entries, "tool", "COM8")
            except installer.InstallError:
                pass
        return calls, objects[0]

    def test_preflight_before_writes_and_application_only(self):
        calls, run = self.execute_install()
        read = next(i for i, c in enumerate(calls) if "read_flash" in c)
        fpga = next(i for i, c in enumerate(calls) if "--write-flash" in c)
        mcu = next(i for i, c in enumerate(calls) if "write_flash" in c)
        self.assertLess(read, fpga)
        self.assertLess(fpga, mcu)
        self.assertIn("--verify", calls[fpga])
        self.assertEqual(calls[mcu][-2], "0x10000")
        self.assertEqual(calls[mcu][calls[mcu].index("--port") + 1], "COM12")
        self.assertTrue(all("erase_flash" not in c and "--bulk-erase" not in c for c in calls))
        self.assertEqual(run.result, "success")
        self.assertEqual(run.completed, ["preflight", "fpga", "mcu"])

    def test_bad_table_or_wrong_device_blocks_all_writes(self):
        for options in ({"bad_table": True}, {"wrong_fpga": True},
                        {"second_probe": "001 008 0x33aa:0x0120 gwu2x\n"}):
            with self.subTest(options=options):
                calls, run = self.execute_install(**options)
                self.assertFalse(any("--write-flash" in c or "write_flash" in c for c in calls))
                self.assertEqual(run.result, "incomplete")

    def test_failed_fpga_never_starts_mcu_and_no_automatic_retry(self):
        calls, run = self.execute_install(fail_fpga=True)
        self.assertEqual(sum("--write-flash" in c for c in calls), 1)
        self.assertFalse(any("write_flash" in c for c in calls))
        self.assertEqual(run.result, "incomplete")
        calls, run = self.execute_install(fail_mcu=True)
        self.assertEqual(sum("write_flash" in c for c in calls), 1)
        self.assertEqual(run.completed, ["preflight", "fpga"])
        self.assertEqual(run.result, "incomplete")

    def test_probe_change_after_fpga_blocks_mcu(self):
        calls, run = self.execute_install(third_probe="001 008 0x33aa:0x0120 gwu2x\n")
        self.assertTrue(any("--write-flash" in c for c in calls))
        self.assertFalse(any("write_flash" in c for c in calls))
        self.assertEqual(run.result, "incomplete")

    def test_redaction(self):
        text = installer.redact("MAC: 12:34:56:78:9a:bc\nSerialNumber: private\n" + str(self.package), self.package)
        self.assertNotIn("12:34:56", text)
        self.assertNotIn("private", text)
        self.assertNotIn(str(self.package), text)

    def test_flash_lock_blocks_another_process(self):
        code = """import importlib.util,sys,tempfile
s=importlib.util.spec_from_file_location('flash_firmware',sys.argv[1]);m=importlib.util.module_from_spec(s);sys.modules[s.name]=m;s.loader.exec_module(m)
tempfile.gettempdir=lambda:sys.argv[2]
try:
 with m.flash_lock():sys.exit(7)
except m.InstallError:sys.exit(0)
"""
        with patch.object(installer.tempfile, "gettempdir", return_value=self.temp.name):
            with installer.flash_lock():
                result = subprocess.run([sys.executable, "-B", "-c", code, str(SCRIPT), self.temp.name])
                self.assertEqual(result.returncode, 0)
            with installer.flash_lock():
                pass


if __name__ == "__main__":
    unittest.main(verbosity=2)
