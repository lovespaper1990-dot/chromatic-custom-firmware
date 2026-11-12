`timescale 1ns/1ps

// Verilog interface shim for the parameterized VHDL register used by the video
// unit. The state engine and clock enables come from the actual VHDL sources.
module eReg_SavestateV #(
    parameter index = 0, address = 0, upper = 63, lower = 0,
    parameter [63:0] initial_value = 0
) (
    input clk, input [63:0] data, input [9:0] addr, input write_en, reset,
    output [63:0] readback, input [upper:lower] live,
    output reg [upper:lower] saved = initial_value[upper:lower]
);
    always @(posedge clk)
        if (reset) saved <= initial_value[upper:lower];
        else if (write_en && addr == address + index) saved <= data[upper:lower];
    assign readback = addr == address + index ? (64'(live) << lower) : 0;
endmodule

module snapshot_palette_tb;
    reg clk = 0;
    always #5 clk = ~clk;

    reg cold_reset = 1, reset_sampled = 1;
    reg load = 0, save = 0, abort_load = 0, bad_header = 0;
    reg done = 0;
    reg [63:0] mem_word = 0;
    reg [7:0] salt = 99;
    wire ce, ce_2x, sleep, busy, loaded, saving;
    wire reset, bus_reset, bus_write, request, mem_read;
    wire [25:0] mem_addr;
    wire [9:0] bus_addr;
    wire [63:0] bus_data, readback, captured;

    // gb.v samples the external reset on a normal guest enable.
    always @(posedge clk) if (ce) reset_sampled <= cold_reset;
    speedcontrol clocks(
        .clk_sys(clk), .pause(sleep), .speedup(1'b0), .cart_act(1'b0), .DMA_on(1'b0),
        .ce(ce), .ce_2x(ce_2x)
    );
    gb_savestates engine(
        .clk(clk), .reset_in(reset_sampled), .abort_state(abort_load), .reset_out(reset),
        .load_done(loaded), .increaseSSHeaderCount(1'b0), .save(save), .load(load),
        .savestate_address(32'd0), .savestate_busy(busy), .cart_ram_size(8'd0), .lcd_vsync(1'b1),
        .BUS_Din(bus_data), .BUS_Adr(bus_addr), .BUS_wren(bus_write),
        .BUS_rst(bus_reset), .BUS_Dout(readback),
        .saving_savestate(saving), .sleep_savestate(sleep), .clock_ena_in(ce_2x),
        .Save_RAMReadData_WRAM(8'd0), .Save_RAMReadData_VRAM(8'd0), .Save_RAMReadData_ORAM(8'd0),
        .Save_RAMReadData_ZRAM(8'd0), .Save_RAMReadData_CRAM(8'd0),
        .bus_out_Din(captured), .bus_out_Dout(mem_word), .bus_out_Adr(mem_addr),
        .bus_out_rnw(mem_read), .bus_out_ena(request), .bus_out_done(done)
    );

    always @(posedge clk) begin
        done <= request;
        if (request && mem_read) begin
            if (mem_addr == 0) mem_word <= bad_header ? 0 : 64'h0000b0ca00000001;
            else mem_word <= {4{salt, mem_addr[8:1]}} ^ 64'hacdac61a686b1541;
        end
    end

    reg cpu_write = 0;
    reg [7:0] cpu_addr = 8'h69, cpu_data = 0;
    reg [5:0] bg_addr = 0, obj_addr = 0;
    reg show_object = 0;
    wire [63:0] telemetry;
    wire [7:0] cpu_q;
    wire [14:0] pixel;

    video dut(
        .clk(clk), .reset(reset), .ce(ce), .ce_cpu(ce_2x), .isGBC(1'b1), .isGBC_mode(1'b1),
        .cpu_sel_oam(1'b0), .cpu_sel_reg(1'b1), .cpu_addr(cpu_addr), .cpu_wr(cpu_write),
        .cpu_di(cpu_data), .cpu_do(cpu_q), .customPaletteEna(1'b0), .gbc_color_temp(3'd0),
        .gpd_out(telemetry), .lcd_data(pixel), .SaveStateBus_Din(bus_data), .SaveStateBus_Adr(bus_addr),
        .SaveStateBus_wren(bus_write), .SaveStateBus_rst(bus_reset), .SaveStateBus_Dout(readback)
    );

    // Model atomic CSS commit independently of the FPGA palette storage.
    // Bytes 0..63 are BG; bytes 64..127 are OBJ.
    reg [7:0] active [0:127];
    reg [63:0] staged [0:15];
    reg [63:0] saved_index = 64'h00000000fffffc00;
    reg [5:0] bg_index = 0, obj_index = 0;
    reg bg_increment = 0, obj_increment = 0;
    reg [14:0] expected_pixel;
    wire [7:0] expected_cpu = cpu_addr == 8'h69 ? active[bg_index] : active[64 + obj_index];
    wire [63:0] expected_gpd = {active[2], active[3], active[4], active[5],
                                active[74], active[75], active[76], active[77]};
    function automatic [63:0] group(input integer row);
        for (int i = 0; i < 8; i++) group[i*8+:8] = active[row*8+i];
    endfunction
    function automatic [14:0] color_at(input integer address);
        color_at = {active[address+1][6:0], active[address]};
    endfunction
    initial for (int i = 0; i < 16; i++) staged[i] = 0;

    integer cycles = 0, commits = 0, captured_groups = 0;
    reg check_all_bytes = 0;
    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (cycles > 460000) $fatal(1, "Palette test timeout");
        if (loaded) commits <= commits + 1;
        if (cycles > 2 && telemetry !== expected_gpd)
            $fatal(1, "Partial palette visible on UART at cycle %0d", cycles);
        if (bus_write && ce_2x) $fatal(1, "Guest enabled during register restore");

        if (saving && request && !mem_read && mem_addr >= 24 && mem_addr <= 54) begin
            if (captured !== group((mem_addr-24)/2)) $fatal(1, "Wrong CSS word at %0d", mem_addr);
            captured_groups <= captured_groups + 1;
        end
        if (!cold_reset && !reset_sampled && !reset) begin
            if (pixel !== expected_pixel) $fatal(1, "Visible pixel changed at cycle %0d", cycles);
            if (ce_2x) begin
                if ((cpu_addr == 8'h69 || cpu_addr == 8'h6b) && cpu_q !== expected_cpu)
                    $fatal(1, "CPU palette read differs at cycle %0d", cycles);
                if (check_all_bytes) begin
                    for (int i = 0; i < 64; i++)
                        if (dut.bgpd[i] !== active[i] || dut.obpd[i] !== active[i+64])
                            $fatal(1, "Palette byte %0d not ready at the first guest enable", i);
                    check_all_bytes <= 0;
                end
            end
        end
        if (ce) expected_pixel <= color_at(show_object ? 64 + obj_addr : bg_addr);

        if (reset) begin
            for (int i = 0; i < 128; i++) active[i] <= staged[i/8][(i%8)*8+:8];
            bg_index <= saved_index[37:32];
            obj_index <= saved_index[43:38];
            bg_increment <= saved_index[44];
            obj_increment <= saved_index[45];
            check_all_bytes <= 1;
        end else if (ce_2x && cpu_write) begin
            case (cpu_addr)
                8'h68: begin bg_index <= cpu_data[5:0]; bg_increment <= cpu_data[7]; end
                8'h6a: begin obj_index <= cpu_data[5:0]; obj_increment <= cpu_data[7]; end
                8'h69: begin
                    active[bg_index] <= cpu_data;
                    if (bg_increment) bg_index <= bg_index + 1'b1;
                end
                8'h6b: begin
                    active[64 + obj_index] <= cpu_data;
                    if (obj_increment) obj_index <= obj_index + 1'b1;
                end
            endcase
        end
        if (bus_reset) begin
            for (int i = 0; i < 16; i++) staged[i] <= 0;
            saved_index <= 64'h00000000fffffc00;
        end else if (bus_write) begin
            if (bus_addr == 10) saved_index <= bus_data;
            if (bus_addr >= 11 && bus_addr <= 26) staged[bus_addr-11] <= bus_data;
        end
    end

    // Exercise both render read ports without a commercial game or a modeled CPU.
    always @(negedge clk) if (!sleep) begin
        bg_addr <= $random & 6'h3e;
        obj_addr <= $random & 6'h3e;
        show_object <= $random;
    end
    task cycle; @(negedge clk); #1; endtask
    task write_guest_palette;
        for (int i = 0; i < 128; i++) begin
            while (!ce_2x) cycle();
            cpu_write = 1; cpu_addr = i < 64 ? 8'h68 : 8'h6a; cpu_data = i % 64; cycle();
            while (!ce_2x) cycle();
            cpu_addr = i < 64 ? 8'h69 : 8'h6b; cpu_data = i*11 + salt; cycle();
        end
        cpu_write = 0;
    endtask
    task begin_load;
        load = 1; cycle(); load = 0;
        while (!busy) cycle();
    endtask
    task finish_operation;
        while (busy) cycle();
        repeat (32) cycle();
    endtask
    task abort_and_restart;
        abort_load = 1; cold_reset = 1; cycle(); abort_load = 0;
        repeat (64) cycle(); cold_reset = 0; repeat (20) cycle();
    endtask
    initial begin
        force dut.palette_index = bg_addr;
        force dut.sprite_palette_index = obj_addr;
        force dut.vram_cpu_allow = 1'b1;
        force dut.lcd_on = 1'b1;
        force dut.lcd_clk = 1'b1;
        force dut.sprite_pixel_visible = show_object;
        repeat (15) cycle(); cold_reset = 0; repeat (15) cycle();
        for (int written = 0; written <= 16; written++) begin
            write_guest_palette(); salt = salt + 1; begin_load();
            while (!bus_write || bus_addr != 10+written) cycle();
            abort_and_restart();
        end
        write_guest_palette(); begin_load();
        while (!(request && mem_read && mem_addr > 399)) cycle();
        abort_and_restart();
        repeat (2) begin
            write_guest_palette(); salt = salt + 1; begin_load(); finish_operation();
            save = 1; cycle(); save = 0;
            while (!busy) cycle();
            finish_operation();
        end
        write_guest_palette(); cold_reset = 1; repeat (32) cycle(); cold_reset = 0; repeat (20) cycle();
        write_guest_palette(); bad_header = 1; begin_load(); finish_operation();
        if (commits != 2 || captured_groups != 32) $fatal(1, "Missing restores or captures");
        $display("PASS: palette capture, UART atomicity, 16-row restore before first guest enable, partial abort and cold reset");
        $finish;
    end
endmodule
