#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ -x .toolchain/iverilog/bin/iverilog ]; then
    export PATH="$PWD/.toolchain/iverilog/bin:$PATH"
    export IVERILOG_LIB="$PWD/.toolchain/iverilog/lib/ivl"
fi
if [ -x .toolchain/ghdl/bin/ghdl ]; then
    export PATH="$PWD/.toolchain/ghdl/bin:$PATH"
fi
tmp=$(mktemp -d)
trap 'rm -f "$tmp/slot-test"; rmdir "$tmp"' EXIT
cc -std=c11 -Wall -Wextra -Werror -Imcu/components/snapshot \
  mcu/tests/snapshot_slot_test.c mcu/components/snapshot/slot.c -o "$tmp/slot-test"
"$tmp/slot-test"
python3 fpga/tests/run_snapshot.py
