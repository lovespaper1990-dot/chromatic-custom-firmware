#!/bin/sh
set -eu
cd "$(dirname "$0")"
# Set GOWIN_SH to the installed gw_sh executable, or put it on PATH.
gw_sh=$(command -v "${GOWIN_SH:-gw_sh}")
platform=$(uname -s)
gowin_bin=$(cd "$(dirname "$gw_sh")" && pwd)
gw_sh="$gowin_bin/$(basename "$gw_sh")"
route_tmp=/tmp
if [ "$platform" = Darwin ]; then
    gowin_lib="$gowin_bin/../lib"
    export DYLD_FRAMEWORK_PATH="$gowin_lib" DYLD_LIBRARY_PATH="$gowin_lib"
    route_tmp=/private/tmp
fi
GOWIN_BUILD_STEP=syn "$gw_sh" build.tcl
python3 ../tests/check_snapshot_netlist.py impl/gwsynthesis/evt1_x2.vg
attempt=1
while :; do
    # A fresh route directory pairs the report and both bitstreams to this run.
    stage_dir=$(mktemp -d "$route_tmp/chromatic-route-XXXXXX")
    mkdir -p "$stage_dir/impl/gwsynthesis" "$stage_dir/src"
    cp impl/gwsynthesis/evt1_x2.vg "$stage_dir/impl/gwsynthesis/"
    cp impl/evt1_x2_process_config.json "$stage_dir/impl/"
    cp -R src/board "$stage_dir/src/"
    cp build.tcl build_options.tcl evt1_x2.gprj "$stage_dir/"
    if (cd "$stage_dir" && GOWIN_BUILD_STEP=pnr "$gw_sh" build.tcl); then
        routed="$stage_dir/impl/pnr/evt1_x2"
        python3 ../tests/check_routed_timing.py "$routed.tr"
        if [ ! -s "$routed.fs" ] || [ ! -s "$routed.bin" ]; then
            echo "Missing routed bitstream. See $stage_dir/" >&2
            exit 1
        fi
        mkdir -p impl/pnr build
        cp -Rf "$stage_dir/impl/pnr/." impl/pnr/
        cp -f "$routed.fs" build/evt1_x2.fs
        cp -f "$routed.bin" build/evt1_x2.bin
        rm -rf "$stage_dir"
        break
    else
        result=$?
    fi
    # Only retry the macOS vendor startup SIGTRAP, before placement finishes.
    if [ "$platform" != Darwin ] || [ "$result" -ne 133 ] || [ -f "$stage_dir/impl/pnr/evt1_x2.p" ] || [ "$attempt" -ge 5 ]; then
        echo "Routing failed. See $stage_dir/" >&2
        exit "$result"
    fi
    echo "Gowin stopped during router startup. Retrying the same netlist." >&2
    rm -rf "$stage_dir"
    attempt=$((attempt + 1))
done
