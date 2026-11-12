# Build the complete project from the maintained IDE source list.
# Usage: gw_sh build.tcl (paths are relative to this script).
cd [file dirname [info script]]
set step all
if {[info exists ::env(GOWIN_BUILD_STEP)]} { set step $::env(GOWIN_BUILD_STEP) }
if {$step ni {all syn pnr}} { error "Unknown build step: $step" }
set project_file [open evt1_x2.gprj r]
set project_xml [read $project_file]
close $project_file
if {$step eq "pnr"} {
    add_file impl/gwsynthesis/evt1_x2.vg
}
foreach {entry path type enabled} [regexp -all -inline {<File path="([^"]+)" type="file\.([^"]+)" enable="([01])"/>} $project_xml] {
    if {$enabled eq "1" && ($step ne "pnr" || $type in {cst sdc})} { add_file -type $type $path }
}
set_device GW5A-EV25UG256CC1/I0 -device_version A
# Read the maintained IDE settings on both platforms. Do not silently use the
# CLI's different routing/clock-routing defaults.
source build_options.tcl
run $step
