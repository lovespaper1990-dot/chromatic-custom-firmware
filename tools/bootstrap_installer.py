#!/usr/bin/env python3
"""Prepare local flash dependencies, then invoke the checked firmware installer."""

import argparse
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys


VERSIONS = {"esptool": "4.13.0", "pyserial": "3.5"}
MSYS2_PACKAGE = "mingw-w64-ucrt-x86_64-openFPGALoader"


def confirm_setup(already_approved):
    if already_approved:
        return
    print("首次准备需要联网安装刷机工具和本目录的 Python 依赖。")
    print("Windows 上安装 MSYS2 时可能出现系统权限提示。")
    answer = input("允许安装所需依赖？输入 Y 继续 [y/N] ").strip().lower()
    if answer != "y":
        raise RuntimeError("已取消依赖安装。")


def run(command, env=None):
    subprocess.run([str(part) for part in command], env=env, check=True)


def msys2_root():
    candidates = []
    configured = os.environ.get("MSYS2_ROOT")
    if configured:
        candidates.append(Path(configured))
    candidates.append(Path("C:/msys64"))
    for name in ("LOCALAPPDATA", "ProgramFiles"):
        if os.environ.get(name):
            candidates.append(Path(os.environ[name]) / "msys64")
    for candidate in candidates:
        if (candidate / "usr/bin/bash.exe").is_file():
            return candidate
    return None


def existing_tool(package):
    configured = os.environ.get("OPENFPGALOADER")
    if configured:
        found = shutil.which(configured)
        candidate = Path(configured).expanduser()
        if found:
            return Path(found)
        if candidate.is_file():
            return candidate.resolve()
        raise RuntimeError("OPENFPGALOADER 指定的文件不存在，请修正该环境变量。")
    found = shutil.which("openFPGALoader")
    if found:
        return Path(found)
    filename = "openFPGALoader.exe" if os.name == "nt" else "openFPGALoader"
    system = "windows" if os.name == "nt" else "macos"
    candidate = package / "tools/bin" / system / filename
    if candidate.is_file():
        return candidate
    if os.name == "nt":
        root = msys2_root()
        if root and (root / "ucrt64/bin/openFPGALoader.exe").is_file():
            return root / "ucrt64/bin/openFPGALoader.exe"
    return None


def install_tool():
    if platform.system() == "Darwin":
        brew = shutil.which("brew")
        if not brew:
            raise RuntimeError("请先按 https://brew.sh 安装 Homebrew，再双击 Mac 刷机脚本。")
        run([brew, "install", "openfpgaloader"])
        tool = shutil.which("openFPGALoader")
        if not tool:
            raise RuntimeError("Homebrew 安装完成后未找到 openFPGALoader，请重新打开脚本。")
        return Path(tool)
    if os.name == "nt":
        root = msys2_root()
        if not root:
            winget = shutil.which("winget")
            if not winget:
                raise RuntimeError("请先从 https://www.msys2.org 安装 MSYS2，或安装 Windows 应用安装程序以启用 winget。")
            run([winget, "install", "--id", "MSYS2.MSYS2", "--exact", "--source", "winget",
                 "--accept-package-agreements", "--accept-source-agreements", "--silent",
                 "--disable-interactivity"])
            root = msys2_root()
        if not root:
            raise RuntimeError("未找到 MSYS2。自定义安装位置可通过 MSYS2_ROOT 指定。")
        env = os.environ.copy()
        env.update(MSYSTEM="UCRT64", CHERE_INVOKING="1")
        run([root / "usr/bin/bash.exe", "-lc", "pacman -S --needed --noconfirm " + MSYS2_PACKAGE], env)
        tool = root / "ucrt64/bin/openFPGALoader.exe"
        if not tool.is_file():
            raise RuntimeError("MSYS2 工具安装后仍未找到 openFPGALoader.exe。请查看上方错误。")
        return tool
    raise RuntimeError("此启动器支持 macOS 和 Windows。其他系统可按安装说明手动准备依赖。")


def venv_python(package):
    base = package / ".installer-venv"
    return base / ("Scripts/python.exe" if os.name == "nt" else "bin/python")


def modules_ready(python):
    if not python.is_file():
        return False
    script = (
        "import importlib.metadata as m; "
        "assert m.version('esptool') == '4.13.0'; "
        "assert m.version('pyserial') == '3.5'"
    )
    result = subprocess.run([str(python), "-c", script], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    return result.returncode == 0


def execute_core(script, python, arguments, package, tool):
    env = os.environ.copy()
    env["PYTHONUTF8"] = "1"
    if tool:
        env["OPENFPGALOADER"] = str(tool)
        env["PATH"] = str(tool.parent) + os.pathsep + env.get("PATH", "")
    return subprocess.call([str(python), str(script), "--package", str(package), *arguments], env=env)


def main(arguments=None):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--package", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--install-deps", action="store_true")
    parser.add_argument("--no-pause", action="store_true")
    options, remaining = parser.parse_known_args(arguments)
    package = options.package.expanduser().resolve()
    print("ModRetro Chromatic 非官方、个人分享的开源测试固件", flush=True)
    core = Path(__file__).with_name("flash_firmware.py")
    if not core.is_file():
        raise RuntimeError("安装器文件不完整，请重新下载并完整解压 Release 固件包。")
    inspection = any(flag in remaining for flag in ("--check", "--dry-run", "--help", "-h"))
    tool = existing_tool(package)
    python = venv_python(package)
    if inspection:
        selected_python = python if python.is_file() else Path(sys.executable)
        return execute_core(core, selected_python, remaining, package, tool)
    if not (package / "fpga/evt1_x2.fs").is_file() or not (package / "esp32/mcu_fw.bin").is_file():
        raise RuntimeError("请下载 Releases 中的固件 ZIP 并完整解压。当前目录没有配套固件文件。")
    ready = modules_ready(python)
    if not tool or not ready:
        approved = options.install_deps or os.environ.get("CHROMATIC_INSTALL_DEPS") == "1"
        confirm_setup(approved)
        if not tool:
            tool = install_tool()
        if not python.is_file():
            run([sys.executable, "-m", "venv", str(python.parent.parent)])
        if not ready:
            run([python, "-m", "pip", "install", "--disable-pip-version-check",
                 *[name + "==" + version for name, version in VERSIONS.items()]])
        if not modules_ready(python):
            raise RuntimeError("本目录的 Python 依赖检查失败，请查看安装输出。")
    return execute_core(core, python, remaining, package, tool)


if __name__ == "__main__":
    try:
        if sys.version_info < (3, 9):
            raise RuntimeError("需要 Python 3.9 或更新版本。")
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print("准备失败。" + str(error), file=sys.stderr)
        print("可将本窗口的错误交给 AI，并让它阅读包内的 AI 安装说明。", file=sys.stderr)
        sys.exit(1)
    except (EOFError, KeyboardInterrupt):
        print("已取消。", file=sys.stderr)
        sys.exit(1)
