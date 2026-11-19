#!/usr/bin/env python3
"""Validate and install the paired Chromatic dev6.2 test firmware.

Platform launchers prepare dependencies. --check and --dry-run never probe USB.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
from importlib import metadata
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
from typing import Sequence
import uuid

VERSION = "4.6-dev6.2-test"
EXPECTED_HASHES = {
    "fpga/evt1_x2.fs": "ee797b615c4a043056a7dc94ee6cb08db6e109057c937f802a4fa575872c7f9c",
    "esp32/mcu_fw.bin": "4a3d01a3e2a97a00eb23cc362a14c9a2934210f10c66cd82262613a3c664413e",
}
MCU_OFFSET = 0x10000
PARTITION_OFFSET = 0x8000
PARTITION_BYTES = 0xC00
FLASH_BYTES = 4 * 1024 * 1024
DISCLAIMER = """这是非官方、个人分享的开源固件，属于开发测试版。
本版本按现状提供，作者和分享者不保证兼容性、稳定性或可恢复性。
刷写可能造成设备异常、数据丢失或实体卡带原生存档损坏，使用者自行评估并承担风险。
请先备份 microSD 的整个 SNAP 文件夹和重要游戏进度。
请确认当前仅连接一台 Chromatic，并断开其他 GWU2X 编程器。
"""


class InstallError(Exception):
    pass


@dataclass(frozen=True)
class Probe:
    bus: int
    address: int

    @property
    def selector(self) -> str:
        return f"{self.bus}:{self.address}"


def checked_path(root: Path, relative: str) -> Path:
    parts = PurePosixPath(relative).parts
    if (not relative or "\\" in relative or ":" in relative or "\0" in relative
            or relative.startswith("/") or relative != PurePosixPath(relative).as_posix()
            or any(p in (".", "..") for p in parts)):
        raise InstallError("校验清单含有不安全的文件路径。")
    path = root.joinpath(*parts)
    if not path.resolve().is_relative_to(root.resolve()):
        raise InstallError("校验清单中的文件超出了固件包目录。")
    if not path.is_file():
        raise InstallError(f"固件包缺少文件 {relative}，请重新解压完整的 Release ZIP。")
    return path


def validate_package(root: Path) -> dict[str, Path]:
    manifest = root / "SHA256SUMS"
    if not manifest.is_file():
        raise InstallError("缺少 SHA256SUMS。请下载包含固件的 Release ZIP，再解压运行。")
    entries = {}
    names = set()
    for line in manifest.read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        match = re.fullmatch(r"([0-9a-fA-F]{64})  (.+)", line)
        if not match or match[2].casefold() in names:
            raise InstallError("SHA256SUMS 格式错误或存在重复文件。")
        digest, name = match.groups()
        names.add(name.casefold())
        path = checked_path(root, name)
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest.lower():
            raise InstallError(f"文件校验失败 {name}，请重新下载和解压。")
        entries[name] = path
    for name, expected in EXPECTED_HASHES.items():
        if name not in entries or hashlib.sha256(entries[name].read_bytes()).hexdigest() != expected:
            raise InstallError(f"{name} 与本安装器的 {VERSION} 配套版本不一致。")
    partition = "esp32/partition_table/partition-table.bin"
    if partition not in entries:
        raise InstallError("固件包缺少已校验的分区表。")
    parse_partition_table(entries[partition].read_bytes(), entries["esp32/mcu_fw.bin"].stat().st_size)
    return entries


def parse_partition_table(table: bytes, app_size: int) -> None:
    if len(table) < 64 or len(table) > PARTITION_BYTES or len(table) % 32:
        raise InstallError("分区表长度无效。")
    partitions = []
    checksum_seen = False
    for position in range(0, len(table), 32):
        entry = table[position:position + 32]
        if entry == b"\xff" * 32:
            if any(byte != 0xFF for byte in table[position:]):
                raise InstallError("分区表结束标记后存在异常数据。")
            break
        if checksum_seen:
            raise InstallError("分区表校验项后存在异常条目。")
        if entry[:2] == b"\xeb\xeb":
            if entry[2:16] != b"\xff" * 14 or hashlib.md5(table[:position]).digest() != entry[16:]:
                raise InstallError("掌机分区表 MD5 校验失败。")
            checksum_seen = True
            continue
        if entry[:2] != b"\xaa\x50":
            raise InstallError("无法识别掌机分区表，请先使用官方流程恢复受支持的基础固件。")
        _, kind, subtype, offset, size, label, flags = struct.unpack("<HBBII16sI", entry)
        if (offset < 0x9000 or offset % 4096 or not size or size % 4096
                or offset + size > FLASH_BYTES):
            raise InstallError("掌机分区范围或对齐不适用于本固件。")
        partitions.append((kind, subtype, offset, size, label.rstrip(b"\0"), flags))
    if not checksum_seen:
        raise InstallError("掌机分区表缺少可验证的 MD5 校验项。")
    ordered = sorted(partitions, key=lambda p: p[2])
    if any(left[2] + left[3] > right[2] for left, right in zip(ordered, ordered[1:])):
        raise InstallError("掌机分区重叠，已停止刷写。")
    apps = [p for p in partitions if p[0] == 0]
    if len(apps) != 1 or apps[0][1] != 0 or apps[0][2] != MCU_OFFSET:
        raise InstallError("本安装器需要单个 factory 应用分区位于 0x10000，当前布局不匹配。")
    if apps[0][3] < app_size or apps[0][5] & 1:
        raise InstallError("应用分区容量不足或启用了分区加密，已停止刷写。")
    if any(p[0] == 1 and p[1] == 0 for p in partitions):
        raise InstallError("掌机使用 OTA 启动选择，无法确认本次应用写入会被启动。")
    if not any(p[0] == 1 and p[1] == 2 and p[4] == b"nvs" for p in partitions):
        raise InstallError("掌机缺少本固件需要的 nvs 设置分区。")


def find_program(root: Path) -> str | None:
    override = os.environ.get("OPENFPGALOADER")
    if override:
        path = Path(override).expanduser()
        return str(path.resolve()) if path.is_file() else shutil.which(override)
    name = "openFPGALoader.exe" if os.name == "nt" else "openFPGALoader"
    folder = "windows" if os.name == "nt" else "macos"
    bundled = root / "tools/bin" / folder / name
    if bundled.is_file():
        return str(bundled.resolve())
    found = shutil.which(name)
    if found:
        return found
    msys = os.environ.get("MSYS2_ROOT")
    candidate = Path(msys) / "ucrt64/bin/openFPGALoader.exe" if msys else None
    return str(candidate.resolve()) if candidate and candidate.is_file() else None


def check_dependencies(root: Path) -> str:
    missing = []
    for distribution, version in (("esptool", "4.13.0"), ("pyserial", "3.5")):
        try:
            installed = metadata.version(distribution)
        except metadata.PackageNotFoundError:
            installed = "未安装"
        if installed != version:
            missing.append(f"{distribution}=={version}（当前 {installed}）")
    program = find_program(root)
    if not program:
        missing.append("openFPGALoader")
    if missing:
        raise InstallError("缺少配套依赖 " + "、".join(missing) + "。请先运行本包的一键刷机入口安装依赖。")
    return program


def redact(text: str, root: Path) -> str:
    text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text)
    text = re.sub(r"(?i)\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b", "<设备地址>", text)
    text = re.sub(r"(?im)(\b(?:serial(?:\s*number)?|iSerial)\s*[:=]\s*)[^\r\n]+", r"\1<设备编号>", text)
    text = text.replace(str(root), "<固件包>")
    return text


class Commands:
    def __init__(self, root: Path):
        self.root = root
        folder = root / ".flash-logs"
        folder.mkdir(mode=0o700, exist_ok=True)
        run_id = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
        self.path = folder / (run_id + ".log")
        descriptor = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        self.log = os.fdopen(descriptor, "w", encoding="utf-8")
        self.state_path = folder / (run_id + ".json")
        self.state = {"version": VERSION, "phase": "preflight", "completed": [], "result": "incomplete"}
        self.save_state()

    def save_state(self):
        descriptor = os.open(self.state_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(self.state, output, ensure_ascii=False, indent=2)
            output.flush()
            os.fsync(output.fileno())

    def phase(self, name: str):
        self.state["phase"] = name
        self.save_state()

    def run(self, command: Sequence[str], timeout: int = 60, echo: bool = False) -> str:
        self.log.write("\nCOMMAND " + json.dumps(list(command), ensure_ascii=False) + "\n")
        self.log.flush()
        chunks = []
        process = subprocess.Popen(list(command), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, encoding="utf-8", errors="replace", start_new_session=os.name != "nt")

        def consume():
            for line in process.stdout:
                self.log.write(line)
                self.log.flush()
                chunks.append(line)
                if echo:
                    print(redact(line, self.root), end="", flush=True)

        reader = threading.Thread(target=consume, daemon=True)
        reader.start()
        try:
            code = process.wait(timeout=timeout)
        except (KeyboardInterrupt, subprocess.TimeoutExpired):
            if os.name == "nt":
                process.terminate()
            else:
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            raise InstallError("操作已中止或超时。请保留日志，按恢复说明检查设备状态。")
        finally:
            reader.join(timeout=5)
        if reader.is_alive():
            raise InstallError("工具输出未能正常结束，请保留日志并检查设备状态。")
        process.stdout.close()
        output = "".join(chunks)
        if code:
            raise InstallError(f"刷写工具退出码 {code}。已停止后续步骤，请查看本机 .flash-logs 和恢复说明。")
        return output

    def done(self, name: str):
        self.state["completed"].append(name)
        self.save_state()

    def finish(self, result: str):
        self.state["result"] = result
        self.save_state()
        self.log.close()


@contextmanager
def flash_lock():
    user = str(os.getuid()) if hasattr(os, "getuid") else os.environ.get("USERNAME", "user")
    suffix = hashlib.sha256(user.encode()).hexdigest()[:12]
    path = Path(tempfile.gettempdir()) / ("chromatic-firmware-" + suffix + ".lock")
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
    lock = os.fdopen(descriptor, "r+b")
    try:
        if os.name == "nt":
            import msvcrt
            lock.write(b"\0")
            lock.flush()
            lock.seek(0)
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        lock.close()
        raise InstallError("另一个刷机程序正在运行，请等它完成后再操作。")
    try:
        yield
    finally:
        lock.close()


def parse_probes(output: str) -> list[Probe]:
    probes = []
    modern = re.compile(r"^\s*(\d{1,3})\s+(\d{1,3})\s+(?:0x)?33aa:(?:0x)?0120\b", re.I)
    legacy = re.compile(r"\b(?:0x)?33aa:(?:0x)?0120\s*\(bus\s+(\d+),\s*device\s+(\d+)\)", re.I)
    for line in output.splitlines():
        match = modern.search(line)
        if not match:
            match = legacy.search(line)
        if match:
            probe = Probe(int(match[1]), int(match[2]))
            if probe not in probes:
                probes.append(probe)
        elif re.search(r"(?:0x)?33aa:(?:0x)?0120\b", line, re.I):
            raise InstallError("编程接口扫描结果无法完整识别，请更新 openFPGALoader 并检查驱动。")
    return probes


def discover_probe(commands: Commands, program: str) -> Probe:
    probes = parse_probes(commands.run([program, "--scan-usb"], timeout=20))
    if len(probes) != 1:
        raise InstallError("需要恰好一个可访问的 GWU2X 编程接口。请仅连接一台 Chromatic，并检查数据线和官方驱动。")
    return probes[0]


def port_candidates(ports) -> list:
    candidates = []
    seen = set()
    for port in ports:
        if port.vid != 0x374E or port.pid not in range(0x0100, 0x0109):
            continue
        interface = (getattr(port, "interface", None) or "").casefold()
        if any(word in interface for word in ("video", "audio", "jtag")):
            continue
        key = str(port.device).casefold()
        if key not in seen:
            seen.add(key)
            candidates.append(port)
    return candidates


def choose_port(requested: str | None = None, wait: float = 0) -> str:
    from serial.tools import list_ports
    deadline = time.monotonic() + wait
    while True:
        candidates = port_candidates(list_ports.comports())
        if len(candidates) > 1:
            raise InstallError("发现多个掌机串口，请仅保留一台 Chromatic 后重新运行。")
        if candidates:
            device = candidates[0].device
            if requested and requested.casefold() != device.casefold():
                raise InstallError("指定串口与识别出的 Chromatic 不一致，已停止刷写。")
            return device
        if time.monotonic() >= deadline:
            raise InstallError("未找到受支持的 Chromatic 串口，请确认掌机开机并使用 USB 数据线。")
        time.sleep(0.25)


def ensure_fpga(output: str):
    identities = re.findall(r"\bidcode\s+(0x[0-9a-f]+)", output, re.I)
    if len(identities) != 1 or int(identities[0], 16) != 0x0001281B:
        raise InstallError("FPGA 型号检测不匹配，本包只适用于已验证的 GW5A-25 配置。")
    if not re.search(r"\bmodel\s+GW5A-25\b", output, re.I):
        raise InstallError("无法确认 GW5A-25 FPGA 型号，已停止刷写。")


def install(root: Path, entries: dict[str, Path], program: str, requested_port: str | None):
    with flash_lock():
        commands = Commands(root)
        try:
            print("正在识别掌机与编程接口。", flush=True)
            probe = discover_probe(commands, program)
            port = choose_port(requested_port)
            selector = [program, "--cable", "gwu2x", "--busdev-num", probe.selector]
            ensure_fpga(commands.run(selector + ["--detect"], timeout=30))
            print("正在核对 ESP32 和现有分区布局。", flush=True)
            commands.phase("read-partition-table")
            partition_dump = commands.path.with_suffix(".partition.bin")
            commands.run([sys.executable, "-m", "esptool", "--chip", "esp32", "--port", port,
                          "--baud", "115200", "--after", "hard_reset", "read_flash",
                          hex(PARTITION_OFFSET), hex(PARTITION_BYTES), str(partition_dump)], timeout=90)
            os.chmod(partition_dump, 0o600)
            parse_partition_table(partition_dump.read_bytes(), entries["esp32/mcu_fw.bin"].stat().st_size)
            if discover_probe(commands, program) != probe:
                raise InstallError("预检期间编程接口发生变化，请重新确认设备后再运行。")
            commands.done("preflight")
            print("正在写入并校验 FPGA，请保持连接。", flush=True)
            commands.phase("write-fpga")
            commands.run(selector + ["--write-flash", "--verify", "--reset", str(entries["fpga/evt1_x2.fs"])],
                         timeout=600, echo=True)
            commands.done("fpga")
            print("正在等待掌机串口并写入 ESP32 应用，请保持连接。", flush=True)
            port = choose_port(wait=20)
            if discover_probe(commands, program) != probe:
                raise InstallError("FPGA 更新后编程接口发生变化，MCU 写入已停止。")
            commands.phase("write-mcu")
            commands.run([sys.executable, "-m", "esptool", "--chip", "esp32", "--port", port,
                          "--baud", "115200", "--after", "hard_reset", "write_flash", hex(MCU_OFFSET),
                          str(entries["esp32/mcu_fw.bin"])], timeout=300, echo=True)
            commands.done("mcu")
            commands.finish("success")
            print(f"两部分固件的写入和工具校验均已完成。请重新开机，在菜单核对 {VERSION}。")
            print("请用可重复测试的进度检查存档和读档。日志保存在本包 .flash-logs 文件夹。")
        except BaseException:
            commands.finish("incomplete")
            raise


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, default=Path(__file__).resolve().parent.parent)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--check", action="store_true", help="离线检查文件和依赖，不访问 USB")
    modes.add_argument("--dry-run", action="store_true", help="离线显示刷写步骤，不访问 USB")
    parser.add_argument("--port", help="明确选择已通过型号识别的掌机串口")
    parser.add_argument("--yes", action="store_true", help="已明确知晓风险并授权本次刷写")
    arguments = parser.parse_args(argv)
    root = arguments.package.resolve()
    try:
        if sys.version_info < (3, 9):
            raise InstallError("请使用 Python 3.9 或更高版本。")
        entries = validate_package(root)
        if arguments.dry_run:
            print("离线校验已通过，执行刷写时会先识别唯一掌机、GW5A-25 和现有分区表。")
            print("步骤一 openFPGALoader --cable gwu2x --busdev-num <检测值> --detect")
            print("步骤二 esptool --chip esp32 --port <掌机串口> read_flash 0x8000 0xc00 <本机临时文件>")
            print("步骤三 openFPGALoader --cable gwu2x --busdev-num <检测值> --write-flash --verify --reset fpga/evt1_x2.fs")
            print("步骤四 esptool --chip esp32 --port <掌机串口> --after hard_reset write_flash 0x10000 esp32/mcu_fw.bin")
            return 0
        program = check_dependencies(root)
        if arguments.check:
            print("固件清单、配套文件、目标分区结构及依赖检查通过，未访问 USB。")
            return 0
        print(DISCLAIMER)
        if not arguments.yes and input("确认本次刷写并承担上述风险，请输入 Y 后回车。 ").strip().upper() != "Y":
            print("已取消。")
            return 0
        install(root, entries, program, arguments.port)
        return 0
    except (InstallError, OSError, KeyboardInterrupt, EOFError) as error:
        print(redact(f"安装未完成。{error}", root), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
