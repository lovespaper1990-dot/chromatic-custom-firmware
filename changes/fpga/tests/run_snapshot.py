#!/usr/bin/env python3
"""Run the snapshot regressions. Requires Icarus Verilog 13 and GHDL with VHDL 2008."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from xml.etree.ElementTree import parse

tests = Path(__file__).resolve().parent
project = tests.parent / "esp32t"
rtl = project / "src/rtl"
compiler = shutil.which("iverilog")
runtime = shutil.which("vvp")
ghdl = shutil.which("ghdl")
if not (compiler and runtime and ghdl):
    raise SystemExit("Install iverilog/vvp and ghdl, then put them on PATH.")
library = os.environ.get("IVERILOG_LIB")
ivl = [compiler] + (["-B", library] if library else []) + ["-g2012"]
vvp = [runtime] + (["-M", library] if library else [])


def run(command, directory, quiet=False):
    result = subprocess.run(command, cwd=directory, text=True,
                            stderr=subprocess.PIPE if quiet else None)
    if result.returncode:
        raise SystemExit(result.stderr or f"Command failed: {command}")


with tempfile.TemporaryDirectory() as temp:
    # Other modules in the vendor USB top use syntax Icarus cannot parse.
    # Compile the endpoint and its dependencies directly from that source.
    usb_source = (rtl / "USB/USBUVCUART/usbuvcuart_top.v").read_text()
    usb_audio = Path(temp) / "usb_audio.v"
    with usb_audio.open("w") as extracted:
        for unit in ("usbuac_ep", "audioclk_gen", "sync_audio", "sample_get_p", "delay"):
            module = re.search(r"^module " + unit + r"\b.*?^endmodule\b", usb_source, re.M | re.S)
            if not module:
                raise SystemExit(f"USB audio module missing: {unit}")
            print(module.group(), file=extracted)
    for name, sources in [
        ("usb_audio_endpoint_tb", [usb_audio]),
        ("snapshot_mbc5_bus_tb", [rtl / "EMU/snapshot_mbc5_bus.v", rtl / "EMU/snapshot_mbc5_mapper.v"]),
        ("snapshot_mbc5_tb", [rtl / "EMU" / filename for filename in
                              ("snapshot_mbc5.v", "snapshot_mbc5_bus.v", "snapshot_mbc5_mapper.v")]),
        ("snapshot_cart_mbc5_tb", [rtl / "EMU/snapshot_cart.v"]),
        ("snapshot_ram_tb", [rtl / "EMU/CORE/dpramV.v"]),
        ("snapshot_tb", [rtl / "EMU/snapshot_cart.v", rtl / "EMU/snapshot_control.v",
                        rtl / "BSP/snapshot_psram.v"]),
        ("headphone_audio_tb", [rtl / "BSP/qspi_slave.v"]),
        ("snapshot_uart_tb", [rtl / "BSP" / filename for filename in
                             ("system_monitor.sv", "system_monitor_arbiter.sv",
                              "uart_packet_wrapper_rx.sv", "uart_packet_wrapper_tx.sv")]),
    ]:
        variants = (0, 2, 3) if name == "snapshot_tb" else (0,)
        for ram_code in variants:
            params = [f"-Psnapshot_tb.RAM_CODE={ram_code}"] if ram_code else []
            run(ivl + params + ["-s", name, "-o", "model", tests / (name + ".sv"), *sources], temp, True)
            run(vvp + ["model"], temp)
    bulk_sources = [rtl / "EMU/snapshot_control.v", rtl / "BSP/snapshot_block_transfer.v",
                    rtl / "BSP/snapshot_spi_buffer.v", rtl / "BSP/qspi_slave.v"]
    for code in (0, 2, 3):
        run(ivl + [f"-Psnapshot_bulk_tb.RAM_CODE={code}", "-s", "snapshot_bulk_tb",
                   "-o", "bulk", tests / "snapshot_bulk_tb.sv", *bulk_sources], temp, True)
        run(vvp + ["bulk"], temp)
    # snapshot_bulk_tb.sv also supplies the portable dual-port memory model.
    run(ivl + ["-s", "osd_snapshot_isolation_tb", "-o", "osd_rows",
               tests / "osd_snapshot_isolation_tb.sv", tests / "snapshot_bulk_tb.sv",
               rtl / "BSP/qspi_slave.v", rtl / "BSP/mm_burst_write.v"], temp, True)
    run(vvp + ["osd_rows"], temp)
    for ram_code, rom_bits in ((3, 5), (2, 7), (0, 2), (0, 4), (0, 6), (0, 7)):
        run(ivl + [f"-Psnapshot_mbc1_tb.RAM_CODE={ram_code}",
                   f"-Psnapshot_mbc1_tb.ROM_BITS={rom_bits}",
                   "-s", "snapshot_mbc1_tb", "-o", "mbc1",
                   tests / "snapshot_mbc1_tb.sv",
                   *[rtl / "EMU" / filename for filename in
                     ("snapshot_mbc5.v", "snapshot_mbc5_bus.v", "snapshot_mbc5_mapper.v")]],
            temp, True)
        run(vvp + ["mbc1"], temp)
    for rom_code, ram_code, mapper, multicart, alias in (
        (0, 0, 1, 0, 0), (1, 0, 1, 0, 0), (3, 0, 2, 0, 0),
        (4, 3, 3, 0, 0), (5, 2, 3, 0, 0), (6, 2, 3, 0, 0),
        (5, 2, 3, 1, 0), (5, 2, 3, 0, 1),
    ):
        run(ivl + [f"-Psnapshot_cart_mbc1_tb.{key}={value}" for key, value in
                   zip(("ROM_CODE", "RAM_CODE", "MAPPER", "MBC1M", "ALIAS_LOGO"),
                       (rom_code, ram_code, mapper, multicart, alias))]
            + ["-s", "snapshot_cart_mbc1_tb", "-o", "probe_mbc1",
               tests / "snapshot_cart_mbc1_tb.sv", rtl / "EMU/snapshot_cart.v"], temp, True)
        run(vvp + ["probe_mbc1"], temp)
    # A physical mapper can retain a previous game's selected bank through
    # an FPGA-only reset. Fingerprints must use an explicitly selected bank1.
    for start_bank in (0, 257):
        run(ivl + [f"-Psnapshot_cart_mbc5_tb.START_BANK={start_bank}",
                   "-s", "snapshot_cart_mbc5_tb", "-o", "prior_bank",
                   tests / "snapshot_cart_mbc5_tb.sv", rtl / "EMU/snapshot_cart.v"], temp, True)
        run(vvp + ["prior_bank"], temp)
    for mode, high in ((0, 2), (1, 0), (1, 1)):
        run(ivl + ["-Psnapshot_cart_mbc1_tb.ROM_CODE=5",
                   "-Psnapshot_cart_mbc1_tb.RAM_CODE=2",
                   "-Psnapshot_cart_mbc1_tb.START_LOW=7",
                   f"-Psnapshot_cart_mbc1_tb.START_HIGH={high}",
                   f"-Psnapshot_cart_mbc1_tb.START_MODE={mode}",
                   "-s", "snapshot_cart_mbc1_tb", "-o", "prior_mbc1",
                   tests / "snapshot_cart_mbc1_tb.sv", rtl / "EMU/snapshot_cart.v"], temp, True)
        run(vvp + ["prior_mbc1"], temp)
    # ROM-only terminal CRC drains without starting another physical read.
    run(ivl + ["-Psnapshot_cart_mbc5_tb.ROM_ONLY=1", "-s", "snapshot_cart_mbc5_tb",
               "-o", "rom_only", tests / "snapshot_cart_mbc5_tb.sv",
               rtl / "EMU/snapshot_cart.v"], temp, True)
    run(vvp + ["rom_only"], temp)
    if os.environ.get("SNAPSHOT_FULL_ROM") == "1":
        run(ivl + ["-Psnapshot_cart_mbc5_tb.ROM_CODE=8", "-s", "snapshot_cart_mbc5_tb",
                   "-o", "full_rom", tests / "snapshot_cart_mbc5_tb.sv",
                   rtl / "EMU/snapshot_cart.v"], temp, True)
        run(vvp + ["full_rom"], temp)

    # Exercise the board's real cartridge debounce, reset and scanner across
    # both clocks. Unrelated PLL, memory and USB blocks are left unelaborated.
    run(ivl + ["-i", "-s", "snapshot_hotplug_tb", "-o", "hotplug",
               tests / "snapshot_hotplug_tb.sv", project / "src/top.v",
               rtl / "EMU/snapshot_cart.v"], temp, True)
    run(vvp + ["hotplug"], temp)
    run(ivl + ["-i", "-s", "esp32_sd_strap_tb", "-o", "strap",
               tests / "esp32_sd_strap_tb.sv", project / "src/top.v"], temp, True)
    run(vvp + ["strap"], temp)

    for source in [tests / "snapshot_psram_model.vhd", rtl / "BSP/MultiPortRamCtrl.vhd",
                   tests / "snapshot_arbiter_tb.vhd", rtl / "EMU/CORE/bus_savestates.vhd",
                   rtl / "EMU/CORE/gb_savestates.vhd", rtl / "EMU/CORE/speedcontrol.vhd",
                   project / "src/Gameboy_MiSTer/rtl/gb_statemanager.vhd",
                   tests / "savestate_engine_tb.vhd"]:
        # GHDL stores paths in a VHDL work index; use ASCII source basenames.
        shutil.copyfile(source, Path(temp) / source.name)
        run([ghdl, "-a", "--std=08", source.name], temp)
    for design in ("snapshot_arbiter_tb", "savestate_engine_tb"):
        run([ghdl, "-e", "--std=08", design], temp)
        for args in ([[], ["-gram_code=2"], ["-gram_code=3"]] if design == "savestate_engine_tb" else [[]]):
            run([ghdl, "-r", "--std=08", design, *args, "--assert-level=error"], temp)

    # Drive the Verilog video unit with the project's VHDL load sequencer and
    # clock-enable generator. Keep translated modules inside the test directory.
    palette_sources = [tests / "snapshot_palette_tb.sv"]
    for unit in ("gb_savestates", "speedcontrol"):
        translated = Path(temp) / (unit + ".v")
        with translated.open("w") as netlist:
            subprocess.run([ghdl, "--synth", "--std=08", "--out=verilog", unit],
                           cwd=temp, stdout=netlist, check=True)
        palette_sources.append(translated)
    # Match the request manager generics in gb.v. Keep its translated module
    # available for both direct-engine and complete request-manager tests.
    manager = Path(temp) / "gb_statemanager.v"
    with manager.open("w") as netlist:
        subprocess.run([ghdl, "--synth", "--std=08", "--out=verilog",
                        "-gSoftmap_SaveState_ADDR=58720256",
                        "-gSoftmap_Rewind_ADDR=33554432", "gb_statemanager"],
                       cwd=temp, stdout=netlist, check=True)
    # Joint save/load with the real state sequencer, physical MBC5 RAM bridge,
    # mailbox and independently clocked variable-latency backing memory. The
    # manager variants also exercise edge buffering and the board slot base.
    for mbc1 in (0, 1):
        for use_manager in (0, 1):
            for ram_code in (2, 3):
                run(ivl + [f"-Psnapshot_mbc5_system_tb.RAM_CODE={ram_code}",
                           f"-Psnapshot_mbc5_system_tb.USE_MANAGER={use_manager}",
                           f"-Psnapshot_mbc5_system_tb.MBC1={mbc1}",
                           "-s", "snapshot_mbc5_system_tb", "-o", "mbc5_system",
                           tests / "snapshot_mbc5_system_tb.sv",
                           Path(temp) / "gb_savestates.v", Path(temp) / "speedcontrol.v", manager,
                           *[rtl / "EMU" / filename for filename in
                             ("snapshot_mbc5.v", "snapshot_mbc5_bus.v", "snapshot_mbc5_mapper.v",
                              "snapshot_control.v")]], temp, True)
                run(vvp + ["mbc5_system"], temp)
    # The USB top contains vendor syntax outside the Icarus subset. Retain
    # its actual pin declaration to check the board's standby wiring.
    usb_ports = re.search(r"^module usbuvcuart_top\b.*?^\);", usb_source, re.M | re.S)
    usb_stub = Path(temp) / "usb_ports.v"
    usb_stub.write_text(usb_ports.group() + "\nendmodule\n")
    run(ivl + ["-i", "-s", "standby_tb", "-o", "standby", tests / "standby_tb.sv",
               project / "src/top.v", usb_stub, Path(temp) / "speedcontrol.v",
               rtl / "EMU/emu_system_top.v", rtl / "EMU/cart.v",
               rtl / "EMU/snapshot_mbc5.v", rtl / "EMU/snapshot_mbc5_bus.v",
               rtl / "EMU/snapshot_mbc5_mapper.v",
               rtl / "BSP/system_monitor.sv", rtl / "BSP/button_debounce.v",
               rtl / "BSP/mem_system_top.sv", rtl / "BSP/aud_system_top_8_16.sv",
               rtl / "BSP/polling_master_8_16.v"], temp, True)
    run(vvp + ["standby"], temp)
    run(ivl + ["-s", "cart_standby_tb", "-o", "cart_standby",
               tests / "cart_standby_tb.sv", rtl / "EMU/cart.v", Path(temp) / "speedcontrol.v"], temp, True)
    run(vvp + ["cart_standby"], temp)
    run(ivl + ["-s", "cart_snapshot_tb", "-o", "cart_snapshot",
               tests / "cart_snapshot_tb.sv", rtl / "EMU/cart.v",
               Path(temp) / "speedcontrol.v"], temp, True)
    run(vvp + ["cart_snapshot"], temp)

    # Check all ten-bit register addresses against the previous masked-OR
    # read path before exercising the complete palette capture/restore flow.
    video_sources = [rtl / "EMU/CORE" / name for name in ("video.v", "sprites.v", "dpramV.v")]
    run(ivl + ["-s", "snapshot_palette_readback_tb", "-o", "palette_readback",
               tests / "snapshot_palette_readback_tb.sv", *video_sources], temp, True)
    run(vvp + ["palette_readback"], temp)
    palette_sources.extend(video_sources)
    run(ivl + ["-s", "snapshot_palette_tb", "-o", "palette", *palette_sources], temp, True)
    run(vvp + ["palette"], temp)
    run(ivl + ["-s", "standby_dma_tb", "-o", "standby_dma", tests / "standby_dma_tb.sv",
               project / "src/Gameboy_MiSTer/rtl/hdma.v", *palette_sources], temp, True)
    run(vvp + ["standby_dma"], temp)

    # Use the Gowin manifest to resolve the actual sources. Icarus omits mixed-
    # language and vendor IP; the capture/read/upload/restore tests above use
    # actual control RTL and the independent 16-bit PSRAM transaction model.
    nodes = parse(project / "evt1_x2.gprj").findall(".//File")
    sources = [project / n.get("path") for n in nodes
               if n.get("type") == "file.verilog" and n.get("enable") == "1"]
    sources = [f for f in sources if "USB" not in f.parts and "fifo1k" not in f.parts
               and not any(part.startswith("gowin_") for part in f.parts)]
    run(ivl + ["-i", "-s", "top", "-o", "top", *sources], temp, True)
    print("PASS: mixed-language black-box elaboration of the board, game core and snapshot connections")

    # Elaborate the project VHDL separately, using the real PSRAM controller.
    # Its Gowin serializer and pin primitives require the vendor model library.
    vhdl_work = Path(temp) / "board-vhdl"
    vhdl_work.mkdir()
    vhdl_sources = [project / n.get("path") for n in nodes
                    if n.get("type") == "file.vhdl" and n.get("enable") == "1"]
    for source in vhdl_sources:
        shutil.copyfile(source, vhdl_work / source.name)
    run([ghdl, "-i", "--std=08", "-fsynopsys", *[s.name for s in vhdl_sources]], vhdl_work)
    for unit in ("gbse", "gbc_snd", "speedcontrol", "gb_savestates",
                 "gb_statemanager", "multiportRamCtrl", "uart_rx", "uart_tx"):
        run([ghdl, "-m", "--std=08", "-fsynopsys", unit], vhdl_work, True)
    print("PASS: project VHDL elaboration for CPU, audio, clocks, state engine, PSRAM and UART")

    cpu_test = tests / "standby_cpu_tb.vhd"
    shutil.copyfile(cpu_test, vhdl_work / cpu_test.name)
    run([ghdl, "-a", "--std=08", "-fsynopsys", cpu_test.name], vhdl_work)
    run([ghdl, "-m", "--std=08", "-fsynopsys", "standby_cpu_tb"], vhdl_work, True)
    run([ghdl, "-r", "--std=08", "-fsynopsys", "standby_cpu_tb",
         "--assert-level=error", "--ieee-asserts=disable"], vhdl_work)

    # Compare resumed instruction/data traces after loading an earlier CPU and
    # physical-cart snapshot at a different running phase, at both CPU speeds.
    translated_cpu = Path(temp) / "gbse.v"
    with translated_cpu.open("w") as netlist:
        subprocess.run([ghdl, "--synth", "--std=08", "-fsynopsys", "--out=verilog", "gbse"],
                       cwd=vhdl_work, stdout=netlist, check=True)
    for auto_capture in (0, 1):
        run(ivl + [f"-Psnapshot_cart_cpu_tb.AUTO_CAPTURE={auto_capture}",
                   "-s", "snapshot_cart_cpu_tb", "-o", "cart_cpu",
                   tests / "snapshot_cart_cpu_tb.sv", translated_cpu,
                   rtl / "EMU/cart.v", Path(temp) / "speedcontrol.v",
                   Path(temp) / "gb_savestates.v", manager], temp, True)
        run(vvp + ["cart_cpu"], temp)
    run(ivl + ["-s", "snapshot_cart_sleep_cpu_tb", "-o", "cart_sleep_cpu",
               tests / "snapshot_cart_sleep_cpu_tb.sv", translated_cpu,
               rtl / "EMU/cart.v", Path(temp) / "speedcontrol.v"], temp, True)
    run(vvp + ["cart_sleep_cpu"], temp)
