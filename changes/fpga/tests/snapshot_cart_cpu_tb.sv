`timescale 1ns/1ps

// Execute a small counter program through the physical cartridge timing RTL.
// The reference is a continuation of the captured machine, not a second CPU
// implementation. After perturbing the machine, restoring must reproduce that
// continuation at every guest enable, including the instruction-fetch bytes.
module snapshot_cart_cpu_case #(parameter SPEED = 0)(output reg passed = 0);
    localparam TRACE_LENGTH = 256;
    localparam TRIALS = 32;
    reg hclk = 0, pclk = 1;
    always #5 hclk = ~hclk;
    always #2.5 pclk = ~pclk;

    reg cold_reset = 1, cpu_restore = 0, request = 0, boot_overlay = 1;
    wire ce, ce2, frozen;
    wire cpu_enable = SPEED ? ce2 : ce;
    wire [15:0] cpu_addr;
    wire [7:0] cpu_out, cpu_in;
    wire cpu_rd_n, cpu_wr_n, cpu_halt_n, cpu_stop, write_cycle;
    wire [2:0] tstate;
    wire cart_read = !cpu_rd_n && !cpu_addr[15];
    wire cart_write = write_cycle && !cpu_addr[15];
    wire [15:0] cart_addr;
    wire [7:0] cart_out, cart_latched;
    wire cart_phi, cart_cs_n, cart_rd_n, cart_wr_n, cart_input_dir;
    wire bus_active = cart_read || cart_write ||
                      (request && (!cart_wr_n || !cart_input_dir));
    speedcontrol clocks(
        .clk_sys(hclk), .pause(request), .standby_req(request), .cart_frozen(frozen),
        .speedup(1'b0), .cart_act(bus_active), .DMA_on(1'b0), .ce(ce), .ce_2x(ce2)
    );

    reg [9:0] ss_addr = 0;
    reg [63:0] ss_data = 0;
    reg ss_write = 0;
    wire [63:0] ss_readback;
    GBse cpu(
        .RESET_n(!(cold_reset || cpu_restore)), .CLK_n(hclk), .CLKEN(cpu_enable),
        .WAIT_n(1'b1), .INT_n(1'b1), .NMI_n(1'b1), .BUSRQ_n(1'b1),
        .RD_n(cpu_rd_n), .WR_n(cpu_wr_n), .HALT_n(cpu_halt_n), .STOP(cpu_stop),
        .WRITE_CYCLE(write_cycle), .TSTATEo(tstate), .A(cpu_addr), .DI(cpu_in), .DO(cpu_out),
        .isGBC(1'b1), .SaveStateBus_Din(ss_data), .SaveStateBus_Adr(ss_addr),
        .SaveStateBus_wren(ss_write), .SaveStateBus_rst(cold_reset), .SaveStateBus_Dout(ss_readback)
    );

    function automatic [7:0] rom(input [15:0] address);
        // LD HL,$C000; INC (HL); LD A,(HL); XOR $A5;
        // LD ($C001),A; JR back to INC (HL).
        case (address)
            0: rom = 8'h21; 1: rom = 8'h00; 2: rom = 8'hc0;
            3: rom = 8'h34; 4: rom = 8'h7e; 5: rom = 8'hee; 6: rom = 8'ha5;
            7: rom = 8'hea; 8: rom = 8'h01; 9: rom = 8'hc0;
            10: rom = 8'h18; 11: rom = 8'hf7;
            default: rom = 8'h00;
        endcase
    endfunction
    wire [7:0] physical_data = !cart_rd_n && cart_input_dir && !cart_addr[15] ?
                               rom(cart_addr) : 8'hff;
    reg cart_load = 0;
    reg [63:0] cart_saved = 0;
    wire [63:0] cart_state;
    cart cartridge(
        .hclk(hclk), .pclk(pclk), .cart_frozen(frozen), .ce(ce), .ce_2x(ce2),
        .gbreset(cold_reset), .cpu_speed(SPEED != 0), .cpu_halt(cpu_halt_n), .cpu_stop(cpu_stop),
        .DMA_on(1'b0), .hdma_active(1'b0), .wr(cart_write), .rd(cart_read), .a(cpu_addr),
        .CART_DOUT(cpu_out), .nCS(!cpu_addr[15]), .TSTATEo(tstate),
        .CART_A(cart_addr), .CART_CLK(cart_phi), .CART_CS(cart_cs_n),
        .CART_D_IN(physical_data), .CART_D_OUT(cart_out), .CART_RD(cart_rd_n),
        .CART_WR(cart_wr_n), .CART_DATA_DIR_E(cart_input_dir), .CART_DIN_r1(cart_latched),
        .snapshot_load(cart_load), .snapshot_in(cart_saved), .snapshot_out(cart_state)
    );

    reg [7:0] counter = 0, marker = 0;
    assign cpu_in = cpu_addr == 16'hc000 ? counter : cpu_addr == 16'hc001 ? marker :
                    !cpu_addr[15] ? (boot_overlay ? rom(cpu_addr) : cart_latched) : 8'hff;
    always @(posedge hclk) if (!cold_reset && !cpu_restore && cpu_enable && !cpu_wr_n) begin
        if (cpu_addr == 16'hc000) counter <= cpu_out;
        if (cpu_addr == 16'hc001) marker <= cpu_out;
    end

    // Keep all physical timing fields in the comparison. Unused single-speed
    // phiCnt bits can be X in the original core and are compared with !==.
    wire [116:0] execution_trace = {cart_state, cpu_addr, cpu_in, cpu_out,
                                    cpu_rd_n, cpu_wr_n, tstate, counter, marker};
    reg [116:0] reference [0:TRACE_LENGTH-1];
    reg [63:0] cpu_saved [0:63];
    reg [7:0] saved_counter, saved_marker;
    integer fetches = 0, compared = 0, request_during_read = 0;
    integer trial;
    reg [15:0] requested_phases = 0;
    reg [4:0] requested_tstates = 0;

    task tick; @(negedge hclk); #0.7; endtask
    task pause_machine;
        request = 1;
        while (!frozen) tick();
        repeat (3) tick();
        if (ce || ce2 || cart_write || cart_read || !cart_wr_n || !cart_input_dir)
            $fatal(1, "CPU/cart not idle when frozen speed=%0d", SPEED);
    endtask
    task resume_machine;
        request = 0;
        while (frozen) tick();
    endtask
    task capture_machine;
        saved_counter = counter; saved_marker = marker; cart_saved = cart_state;
        for (int i = 0; i < 64; i++) begin
            ss_addr = i; tick(); cpu_saved[i] = ss_readback;
        end
    endtask
    task restore_machine;
        for (int i = 0; i < 64; i++) begin
            ss_addr = i; ss_data = cpu_saved[i]; ss_write = 1; tick();
        end
        ss_write = 0;
        // CPU restore is an explicit commit of the staged state. Physical
        // timing restore spans hClk and both pClk edges while CE stays off.
        cpu_restore = 1; cart_load = 1;
        repeat (3) tick();
        cpu_restore = 0; cart_load = 0;
        counter = saved_counter; marker = saved_marker;
        repeat (3) tick();
        if (cart_state !== cart_saved)
            $fatal(1, "Physical timing restore differs speed=%0d got=%h expected=%h", SPEED, cart_state, cart_saved);
        for (int i = 0; i < 64; i++) begin
            ss_addr = i; tick();
            if (ss_readback !== cpu_saved[i])
                $fatal(1, "CPU state word %0d not restored speed=%0d got=%h expected=%h", i, SPEED, ss_readback, cpu_saved[i]);
        end
    endtask
    task continue_machine(input bit checking);
        integer step;
        step = 0;
        request = 0;
        while (step < TRACE_LENGTH) begin
            @(posedge hclk);
            if (cpu_enable) begin
                #0.7;
                if (checking) begin
                    if (execution_trace !== reference[step])
                        $fatal(1, "Wrong continuation speed=%0d trial=%0d step=%0d got=%h expected=%h PC=%h", SPEED, trial, step, execution_trace, reference[step], cpu_addr);
                    compared = compared + 1;
                end else reference[step] = execution_trace;
                if (!cpu_rd_n && !cpu_addr[15]) fetches = fetches + 1;
                step = step + 1;
            end
        end
        // Return between clock edges so the next pause cannot race the CPU.
        tick();
    endtask

    reg [7:0] continuation_counter;
    initial begin
        repeat (20) tick(); cold_reset = 0;
        while (counter != 8'd5) tick();
        // Real hardware first runs an internal boot ROM, allowing the physical
        // cartridge timing generator to settle before the first external fetch.
        // Remove this small overlay before all snapshot/reference trials.
        pause_machine(); boot_overlay = 0; resume_machine();
        for (trial = 0; trial < TRIALS; trial = trial + 1) begin
            // The requests span every hClk phase and many CPU microstates.
            repeat (1 + ((trial * 37) % 91)) tick();
            #0.3;
            requested_phases[cartridge.counter] = 1;
            if (tstate <= 4) requested_tstates[tstate] = 1;
            if (cart_read) request_during_read = request_during_read + 1;
            pause_machine(); capture_machine();
            continue_machine(0);
            continuation_counter = counter;
            if (counter == saved_counter) $fatal(1, "Reference failed to execute counter program");
            // Advance past the reference and stop at a different physical
            // phase. Reloading the CPU alone must not pass this comparison.
            repeat (67 + ((trial * 19) % 101)) tick();
            pause_machine(); restore_machine();
            continue_machine(1);
            if (counter !== continuation_counter)
                $fatal(1, "Counter continuation differs speed=%0d", SPEED);
        end
        if (compared != TRIALS * TRACE_LENGTH || !fetches || !request_during_read ||
            $countones(requested_phases) < 4 || $countones(requested_tstates) < 3)
            $fatal(1, "Insufficient phase coverage speed=%0d phases=%h T=%b reads=%0d", SPEED, requested_phases, requested_tstates, request_during_read);
        $display("PASS real GBse/cart snapshot speed=%0d: %0d restores, %0d exact enable traces, request phases=%h Tstates=%b, %0d instruction reads", SPEED, TRIALS, compared, requested_phases, requested_tstates, fetches);
        passed = 1;
    end
endmodule

module snapshot_cart_cpu_tb;
    wire slow, fast;
    snapshot_cart_cpu_case #(0) single_speed(slow);
    snapshot_cart_cpu_case #(1) double_speed(fast);
    initial begin wait (slow && fast); $finish; end
    initial begin #20000000; $fatal(1, "Real CPU/cart snapshot test timeout"); end
endmodule
