#!/bin/sh
set -eu
cd "$(dirname "$0")"
# Set GOWIN_SH to the installed gw_sh executable, or put it on PATH.
gw_sh=$(command -v "${GOWIN_SH:-gw_sh}")
if [ "$(uname -s)" = Darwin ]; then
    gowin_bin=$(cd "$(dirname "$gw_sh")" && pwd)
    gw_sh="$gowin_bin/$(basename "$gw_sh")"
    gowin_lib="$gowin_bin/../lib"
    export DYLD_FRAMEWORK_PATH="$gowin_lib" DYLD_LIBRARY_PATH="$gowin_lib"
    # Start placement in a clean directory with a short ASCII path. On macOS
    # the .04-1 router can trap while allocating the GW5A device model.
    GOWIN_BUILD_STEP=syn "$gw_sh" build.tcl
    attempt=1
    while :; do
        stage_dir=$(mktemp -d /private/tmp/chromatic-route-XXXXXX)
        mkdir -p "$stage_dir/impl/gwsynthesis" "$stage_dir/src"
        cp impl/gwsynthesis/evt1_x2.vg "$stage_dir/impl/gwsynthesis/"
        cp impl/evt1_x2_process_config.json "$stage_dir/impl/"
        cp -R src/board "$stage_dir/src/"
        cp build.tcl build_options.tcl evt1_x2.gprj "$stage_dir/"
        if (cd "$stage_dir" && GOWIN_BUILD_STEP=pnr "$gw_sh" build.tcl); then
            mkdir -p impl/pnr
            cp -Rf "$stage_dir/impl/pnr/." impl/pnr/
            rm -rf "$stage_dir"
            break
        else
            result=$?
        fi
        # Only retry the vendor's startup SIGTRAP, before placement finishes.
        # An actual design error or a later crash retains its log and exit code.
        if [ "$result" -ne 133 ] || [ -f "$stage_dir/impl/pnr/evt1_x2.p" ] || [ "$attempt" -ge 5 ]; then
            echo "Routing failed. See $stage_dir/" >&2
            exit "$result"
        fi
        echo "Gowin stopped during router startup. Retrying the same netlist." >&2
        rm -rf "$stage_dir"
        attempt=$((attempt + 1))
    done
else
    "$gw_sh" build.tcl
fi
mkdir -p build
cp -f impl/pnr/evt1_x2.fs build/evt1_x2.fs
cp -f impl/pnr/evt1_x2.bin build/evt1_x2.bin
