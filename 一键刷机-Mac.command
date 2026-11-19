#!/bin/bash
# Double-click from a fully extracted release package.
set -u
cd -- "$(dirname -- "$0")" || exit 1
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PYTHONUTF8=1
inspection=0
no_pause=0
for argument in "$@"; do
    case "$argument" in
        --check|--dry-run|--help|-h) inspection=1; no_pause=1 ;;
        --no-pause) no_pause=1 ;;
        --install-deps) export CHROMATIC_INSTALL_DEPS=1 ;;
    esac
done
finish() {
    result=$?
    if [ "$no_pause" -eq 0 ] && [ -t 0 ]; then
        read -r -p "按回车关闭窗口。" ignored
    fi
    exit "$result"
}
trap finish EXIT
python_command=$(command -v python3 || true)
if [ "$python_command" = /usr/bin/python3 ] && ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
    python_command=""
fi
if [ -n "$python_command" ] && ! "$python_command" -c 'import sys; sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1; then
    python_command=""
fi
if [ -z "$python_command" ]; then
    if [ "$inspection" -eq 1 ]; then
        echo "缺少 Python 3.9 或更新版本。检查模式已结束。" >&2
        exit 1
    fi
    if ! command -v brew >/dev/null 2>&1; then
        echo "请先按 https://brew.sh 安装 Homebrew，再重新打开本脚本。" >&2
        exit 1
    fi
    if [ "${CHROMATIC_INSTALL_DEPS:-0}" != 1 ]; then
        echo "首次准备需要通过 Homebrew 安装 Python，并安装刷机工具及本目录的 Python 依赖。"
        read -r -p "允许安装所需依赖？输入 Y 继续 [y/N] " answer
        case "$answer" in
            y|Y) export CHROMATIC_INSTALL_DEPS=1 ;;
            *) echo "已取消。"; exit 1 ;;
        esac
    fi
    brew install python || exit 1
    hash -r
    python_command=$(command -v python3 || true)
fi
if [ -z "$python_command" ]; then
    echo "未找到 Python，请重新打开脚本。" >&2
    exit 1
fi
"$python_command" tools/bootstrap_installer.py "$@"
