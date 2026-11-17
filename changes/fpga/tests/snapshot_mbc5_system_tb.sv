`timescale 1ns/1ps

// The real translated VHDL state sequencer drives the real mailbox and MBC5
// bridge. Game RAM uses synchronous byte ports; the backing store and physical
// cartridge are independent models. No game ROM or commercial save is needed.
// USE_MANAGER=1 also exercises the board's actual edge-buffered request manager
// and its 0x3800000 state address. USE_MANAGER=0 retains direct engine coverage.
module snapshot_mbc5_system_tb #(parameter RAM_CODE = 3, parameter USE_MANAGER = 0);
    localparam RAM_BYTES = RAM_CODE == 3 ? 32768 : 8192;
    localparam WORDS = RAM_CODE == 3 ? 10341 : 7269;
    localparam [63:0] IDENTITY = {16'h1b03, RAM_CODE[7:0], 40'h7d12345678};
    localparam [15:0] EXPECTED_MAPPER = {1'b0, 2'b00, 4'd3, 9'h18e};

    reg clk = 0, mem_clk = 0, reset = 1, supported = 1;
    always #5 clk = ~clk;
    always #3 mem_clk = ~mem_clk;
    wire ce, ce2, sleeping, busy, loaded, engine_reset;
    wire capture, restore, active, abort_state, restart;
    wire take_bus, cart_frozen;
    reg game_write_n = 1;
    reg game_input_dir = 1;
    speedcontrol clocks(
        .clk_sys(clk), .pause(sleeping || take_bus), .standby_req(sleeping || take_bus),
        .cart_frozen(cart_frozen), .speedup(1'b0), .cart_act(!game_write_n),
        .DMA_on(1'b0), .ce(ce), .ce_2x(ce2)
    );

    wire [63:0] bus_data, raw_out, core_in;
    wire [9:0] bus_addr;
    wire bus_write, bus_reset, raw_req, raw_read, raw_done;
    wire [25:0] raw_addr;
    wire [19:0] ram_addr;
    wire [4:0] ram_write;
    wire [7:0] ram_data;
    reg [63:0] live_regs [0:63], staged_regs [0:63];
    wire [63:0] reg_readback = bus_addr == 32 ? 64'd0 : live_regs[bus_addr[5:0]];
    reg [7:0] wram [0:32767], vram [0:16383], oam [0:159], zram [0:127];
    reg [7:0] wram_q = 0, vram_q = 0, oam_q = 0, zram_q = 0;
    wire engine_save, engine_load;
    wire [31:0] engine_address;
    localparam [31:0] SLOT_BASE = USE_MANAGER ? 32'h03800000 : 32'd0;
    integer manager_saves = 0, manager_loads = 0;
    generate
        if (USE_MANAGER) begin : through_manager
            wire manager_save, manager_load;
            // Translate the maintained VHDL with generics
            // Softmap_SaveState_ADDR=58720256, Softmap_Rewind_ADDR=33554432,
            // exactly as instantiated by the real gb.v.
            gb_statemanager manager(
                .clk(clk), .reset(reset), .rewind_on(1'b0), .rewind_active(1'b0),
                .savestate_number(32'd0), .save(capture), .load(restore),
                .sleep_rewind(), .vsync(1'b1), .request_savestate(manager_save),
                .request_loadstate(manager_load), .request_address(engine_address),
                .request_busy(busy)
            );
            assign engine_save = manager_save && active;
            assign engine_load = manager_load && active;
            always @(posedge clk) if (!reset) begin
                if (manager_save) manager_saves <= manager_saves + 1;
                if (manager_load) manager_loads <= manager_loads + 1;
                if ((manager_save || manager_load) && engine_address !== SLOT_BASE)
                    $fatal(1, "Manager selected wrong board snapshot address");
            end
        end else begin : direct_engine
            assign engine_save = capture;
            assign engine_load = restore;
            assign engine_address = SLOT_BASE;
        end
    endgenerate
    always @(posedge clk) if (raw_req &&
            (raw_addr < SLOT_BASE || raw_addr >= SLOT_BASE + WORDS*2 || raw_addr[0]))
        $fatal(1, "State engine emitted address outside selected slot");
    gb_savestates engine(
        .clk(clk), .reset_in(reset), .abort_state(abort_state), .reset_out(engine_reset),
        .load_done(loaded), .increaseSSHeaderCount(1'b0), .save(engine_save), .load(engine_load),
        .savestate_address(engine_address), .savestate_busy(busy), .cart_ram_size(RAM_CODE[7:0]),
        .lcd_vsync(1'b1), .BUS_Din(bus_data), .BUS_Adr(bus_addr), .BUS_wren(bus_write),
        .BUS_rst(bus_reset), .BUS_Dout(reg_readback), .sleep_savestate(sleeping),
        .clock_ena_in(ce2), .Save_RAMAddr(ram_addr), .Save_RAMWrEn(ram_write),
        .Save_RAMWriteData(ram_data), .Save_RAMReadData_WRAM(wram_q),
        .Save_RAMReadData_VRAM(vram_q), .Save_RAMReadData_ORAM(oam_q),
        .Save_RAMReadData_ZRAM(zram_q), .Save_RAMReadData_CRAM(8'd0),
        .bus_out_Din(raw_out), .bus_out_Dout(core_in), .bus_out_Adr(raw_addr),
        .bus_out_rnw(raw_read), .bus_out_ena(raw_req), .bus_out_done(raw_done)
    );
    always @(posedge clk) begin
        wram_q <= wram[ram_addr[14:0]];
        vram_q <= vram[ram_addr[13:0]];
        oam_q <= ram_addr[7:0] < 160 ? oam[ram_addr[7:0]] : 8'hff;
        zram_q <= zram[ram_addr[6:0]];
        if (ram_write[0]) wram[ram_addr[14:0]] <= ram_data;
        if (ram_write[1]) vram[ram_addr[13:0]] <= ram_data;
        if (ram_write[2] && ram_addr[7:0] < 160) oam[ram_addr[7:0]] <= ram_data;
        if (ram_write[3]) zram[ram_addr[6:0]] <= ram_data;
        if (bus_write && bus_addr != 32) staged_regs[bus_addr[5:0]] <= bus_data;
        if (engine_reset && !reset)
            for (int i = 0; i < 64; i++) if (i != 32) live_regs[i] <= staged_regs[i];
        if (bus_write && ce2) $fatal(1, "CPU enabled during register staging");
        if ((|ram_write) && ce2) $fatal(1, "CPU enabled during RAM restore");
        if (take_bus && ce2) $fatal(1, "CPU enabled while snapshot owns cartridge");
    end

    wire mem_req, mem_read, mem_done;
    wire [25:0] mem_addr;
    wire [63:0] mem_out, mem_in;
    reg [15:0] game_addr = 0;
    reg [7:0] game_data = 0;
    wire [15:0] state_cart_addr;
    wire [7:0] state_cart_data;
    wire state_rd_n, state_wr_n, state_cs_n, state_input_dir;
    wire [15:0] cart_addr = take_bus ? state_cart_addr : game_addr;
    wire [7:0] cart_data = take_bus ? state_cart_data : game_data;
    wire cart_write_n = take_bus ? state_wr_n : game_write_n;
    wire cart_read_n = take_bus ? state_rd_n : 1'b1;
    wire cart_cs_n = take_bus ? state_cs_n : !(game_addr[15:13] == 3'b101);
    wire cart_input_dir = take_bus ? state_input_dir : game_input_dir;
    reg [8:0] physical_rom = 1;
    reg [3:0] physical_bank = 0;
    reg physical_enabled = 0;
    reg [7:0] cart_ram [0:32767];
    wire [14:0] physical_addr = RAM_CODE == 3 ? {physical_bank[1:0], cart_addr[12:0]} :
                                                               {2'b00, cart_addr[12:0]};
    wire [15:0] physical_mapper = {physical_enabled, 2'b00, physical_bank, physical_rom};
    wire [7:0] cart_in = !cart_cs_n && !cart_read_n && cart_input_dir && physical_enabled ?
                        cart_ram[physical_addr] : 8'hff;
    integer cart_writes = 0;
    always @(posedge cart_write_n) if (!reset) begin
        if (cart_input_dir || !cart_read_n) $fatal(1, "Unsafe cartridge write direction");
        if (!cart_cs_n) begin
            if (physical_enabled) begin
                cart_ram[physical_addr] = cart_data;
                if (take_bus) cart_writes = cart_writes + 1;
            end
        end else case (cart_addr[15:12])
            0,1: physical_enabled = cart_data[3:0] == 4'ha;
            2: physical_rom[7:0] = cart_data;
            3: physical_rom[8] = cart_data[0];
            4,5: physical_bank = cart_data[3:0];
        endcase
    end

    snapshot_mbc5 bridge(
        .clk(clk), .reset(reset), .enabled(1'b1), .ram_code(RAM_CODE[7:0]),
        .active(active), .abort(abort_state), .restart_core(restart),
        .core_req(raw_req), .core_read(raw_read),
        .core_addr(raw_addr), .core_out(raw_out), .core_done(raw_done), .core_in(core_in),
        .mem_req(mem_req), .mem_read(mem_read), .mem_addr(mem_addr), .mem_out(mem_out),
        .mem_done(mem_done), .mem_in(mem_in), .game_addr(game_addr), .game_out(game_data),
        .game_write_n(game_write_n), .cart_in(cart_in), .take_bus(take_bus),
        .cart_addr(state_cart_addr), .cart_out(state_cart_data), .cart_read_n(state_rd_n),
        .cart_write_n(state_wr_n), .cart_cs_n(state_cs_n), .cart_input_dir(state_input_dir)
    );

    reg command_toggle = 0;
    reg [6:0] command_addr = 0;
    reg [79:0] command_data = 0;
    wire reply_toggle, backing_toggle, backing_read;
    wire [79:0] reply;
    wire [13:0] backing_index;
    wire [63:0] backing_out;
    reg backing_ack = 0;
    reg [63:0] backing_in = 0;
    assign mem_in = backing_in;
    snapshot_control #(.STALL_BITS(14)) mailbox(
        .clk(clk), .reset(reset), .supported(supported), .identity(IDENTITY),
        .cmd_toggle(command_toggle), .cmd(command_addr), .cmd_data(command_data),
        .reply_toggle(reply_toggle), .reply(reply), .capture(capture), .restore(restore),
        .core_busy(busy), .core_req(mem_req), .core_read(mem_read), .core_addr(mem_addr),
        .core_out(mem_out), .core_done(mem_done), .mem_toggle(backing_toggle),
        .mem_index(backing_index), .mem_read(backing_read), .mem_out(backing_out),
        .mem_ack(backing_ack), .mem_in(backing_in), .core_loaded(loaded),
        .core_abort(abort_state), .restart_core(restart), .active(active), .debug_flags(16'd0)
    );

    // A separate clock and request-dependent latency catch assumptions that
    // the core, cartridge and backing-memory acknowledgements coincide.
    reg [63:0] backing [0:16383];
    reg pending = 0, pending_read, pending_toggle;
    reg [13:0] pending_index;
    reg [63:0] pending_data;
    integer latency = 0, backing_requests = 0;
    always @(posedge mem_clk) begin
        if (reset) begin
            pending <= 0;
            backing_ack <= 0;
        end else if (!pending && backing_toggle != backing_ack) begin
            pending <= 1;
            pending_read <= backing_read;
            pending_toggle <= backing_toggle;
            pending_index <= backing_index;
            pending_data <= backing_out;
            latency <= 2 + backing_index % 11;
        end else if (pending && latency != 0) latency <= latency - 1;
        else if (pending) begin
            if (pending_read) backing_in <= backing[pending_index];
            else backing[pending_index] <= pending_data;
            backing_ack <= pending_toggle;
            pending <= 0;
            backing_requests <= backing_requests + 1;
        end
    end

    function automatic [7:0] byte_pattern(input integer region, input integer offset);
        byte_pattern = (offset * 29) ^ (offset >> 8) ^ (region * 47) ^ 8'h6b;
    endfunction
    function automatic [63:0] register_pattern(input integer offset);
        register_pattern = 64'h6d32f9c18ac57e0b ^ (64'h0102040810204081 * (offset + 1));
    endfunction

    task tick; @(negedge clk); #1; endtask
    task game_write(input [15:0] a, input [7:0] d);
        tick(); game_addr = a; game_data = d; game_input_dir = 0;
        tick(); game_write_n = 0;
        repeat (8) tick(); game_write_n = 1;
        repeat (4) tick(); game_input_dir = 1;
    endtask
    task set_mapper(input [8:0] rom, input [3:0] bank, input bit enabled);
        game_write(16'h2000, rom[7:0]); game_write(16'h3000, {7'd0, rom[8]});
        game_write(16'h4000, {4'd0, bank}); game_write(16'h0000, enabled ? 8'h1a : 8'h00);
    endtask
    task command(input [6:0] address, input [79:0] data, input [79:0] expected);
        reg last;
        tick(); last = reply_toggle;
        command_addr = address; command_data = data; command_toggle = !command_toggle;
        while (reply_toggle == last) tick();
        if (reply !== expected) $fatal(1, "Mailbox %h returned %h expected %h", address, reply, expected);
    endtask
    task control(input [7:0] op, input [7:0] result);
        command(7'h20, {72'd0, op}, {16'hfff0, op, result, 48'd0});
    endtask
    task finish_operation;
        while (active || busy || take_bus) tick();
        repeat (32) tick();
    endtask
    task check_game;
        if (physical_mapper !== EXPECTED_MAPPER || bridge.current_mapper !== EXPECTED_MAPPER)
            $fatal(1, "Mapper mismatch: physical %h mirror %h", physical_mapper, bridge.current_mapper);
        for (int i = 0; i < 64; i++)
            if (i != 32 && live_regs[i] !== register_pattern(i)) $fatal(1, "Register %0d not restored", i);
        for (int i = 0; i < 32768; i++)
            if (wram[i] !== byte_pattern(0, i)) $fatal(1, "WRAM byte %0d not restored", i);
        for (int i = 0; i < 16384; i++)
            if (vram[i] !== byte_pattern(1, i)) $fatal(1, "VRAM byte %0d not restored", i);
        for (int i = 0; i < 160; i++)
            if (oam[i] !== byte_pattern(2, i)) $fatal(1, "OAM byte %0d not restored", i);
        for (int i = 0; i < 128; i++)
            if (zram[i] !== byte_pattern(3, i)) $fatal(1, "ZRAM byte %0d not restored", i);
        for (int i = 0; i < RAM_BYTES; i++)
            if (cart_ram[i] !== byte_pattern(4, i)) $fatal(1, "Physical RAM byte %0d not restored", i);
    endtask

    reg await_restore_enable = 0, commit_seen = 0;
    reg await_abort_enable = 0, abort_seen = 0;
    integer checked_resumes = 0, checked_abort_resumes = 0;
    always @(posedge clk) begin
        if (abort_state) abort_seen <= 1;
        if (loaded) begin
            commit_seen <= 1;
            if (physical_mapper !== EXPECTED_MAPPER || take_bus)
                $fatal(1, "State engine committed before mapper restoration/bus release");
        end
        if (await_restore_enable && commit_seen && ce2) begin
            check_game();
            checked_resumes <= checked_resumes + 1;
            await_restore_enable <= 0;
        end
        if (await_abort_enable && abort_seen && ce2) begin
            check_game();
            checked_abort_resumes <= checked_abort_resumes + 1;
            await_abort_enable <= 0;
        end
        if (restart) $fatal(1, "Unexpected cold restart during successful restore");
    end

    initial begin
        for (int i = 0; i < 64; i++) begin
            live_regs[i] = register_pattern(i);
            staged_regs[i] = 0;
        end
        for (int i = 0; i < 32768; i++) begin
            wram[i] = byte_pattern(0, i);
            cart_ram[i] = byte_pattern(4, i);
        end
        for (int i = 0; i < 16384; i++) vram[i] = byte_pattern(1, i);
        for (int i = 0; i < 160; i++) oam[i] = byte_pattern(2, i);
        for (int i = 0; i < 128; i++) zram[i] = byte_pattern(3, i);
        repeat (8) tick(); reset = 0; repeat (8) tick();
        for (int i = 0; i < 64; i++) live_regs[i] = register_pattern(i);
        // Capture while RAM is disabled and a non-default 9-bit bank is selected.
        set_mapper(9'h18e, 4'd3, 1'b0);
        if (physical_mapper !== EXPECTED_MAPPER || bridge.current_mapper !== EXPECTED_MAPPER)
            $fatal(1, "Guest mapper writes not tracked");
        control(1, 1); finish_operation(); control(0, 0);
        if (cart_writes != 0) $fatal(1, "Capture changed battery RAM");
        check_game();
        if (backing[0][63:32] !== 32'hb0ca || backing[33][15:0] !== EXPECTED_MAPPER)
            $fatal(1, "Header/mapper state missing from captured image");
        // CRAM input to gb_savestates is deliberately zero. These bytes must
        // have come from the physical bridge, across every supported RAM bank.
        for (int i = 0; i < RAM_BYTES; i++)
            if (backing[6245 + i/8][(i%8)*8 +: 8] !== byte_pattern(4, i))
                $fatal(1, "Capture substituted wrong physical RAM byte %0d", i);
        command(7'h21, 80'd33, {16'd33, backing[33]});
        command(7'h21, WORDS - 1, {16'(WORDS - 1), backing[WORDS - 1]});

        for (int i = 0; i < 64; i++) live_regs[i] = ~register_pattern(i);
        for (int i = 0; i < 32768; i++) begin
            wram[i] = ~byte_pattern(0, i);
            cart_ram[i] = ~byte_pattern(4, i);
        end
        for (int i = 0; i < 16384; i++) vram[i] = ~byte_pattern(1, i);
        for (int i = 0; i < 160; i++) oam[i] = ~byte_pattern(2, i);
        for (int i = 0; i < 128; i++) zram[i] = ~byte_pattern(3, i);
        set_mapper(9'h001, 4'd1, 1'b1);
        await_restore_enable = 1;
        control(2, 1); finish_operation(); control(0, 0);
        check_game();
        if (checked_resumes != 1 || cart_writes != RAM_BYTES)
            $fatal(1, "Missing resume check or wrong physical writes: %0d/%0d", checked_resumes, cart_writes);
        // A cancelled capture must drain the physical byte transaction and
        // restore the mapper before the clock generator releases the guest.
        // supported can fall on cartridge validity or I/O policy failure;
        // keeping the model present exercises the recoverable abort path.
        control(1, 1);
        while (!(take_bus && !state_rd_n && state_cart_addr[15:13] == 3'b101)) tick();
        await_abort_enable = 1;
        supported = 0;
        while (!abort_seen) tick();
        finish_operation(); supported = 1; repeat (8) tick();
        check_game();
        if (checked_abort_resumes != 1 || cart_writes != RAM_BYTES)
            $fatal(1, "Cancelled capture resumed unsafely or wrote cartridge RAM");
        if (USE_MANAGER && (manager_saves != 2 || manager_loads != 1))
            $fatal(1, "Manager did not emit exactly two captures and one restore");
        $display("PASS: joint real state engine + MBC5 + mailbox, %0d-byte physical RAM, all core memories and mapper before first CPU enable, safe capture abort (%0d backing requests, manager=%0d)", RAM_BYTES, backing_requests, USE_MANAGER);
        $finish;
    end
    initial begin #40000000; $fatal(1, "Joint MBC5 snapshot timeout"); end
endmodule
