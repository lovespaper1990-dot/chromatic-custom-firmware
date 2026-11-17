`timescale 1ns/1ps

// Real GBse execution across HALT, interrupt wake, STOP and an external DMA
// reader. The same frozen CPU/cart/RAM image must reproduce the continuation.
module snapshot_cart_sleep_cpu_case #(parameter SPEED = 0)(output reg passed = 0);
    localparam STEPS = 192, TRIALS = 16;
    reg hclk = 0, pclk = 1;
    always #5 hclk = ~hclk;
    always #2.5 pclk = ~pclk;
    reg reset = 1, restore_cpu = 0, pause = 0, boot_overlay = 1, irq_n = 1;
    reg dma = 0;
    reg [15:0] dma_addr = 16'h4000;
    wire ce, ce2, frozen;
    wire enable = (SPEED ? ce2 : ce) && !dma;
    wire [15:0] address;
    wire [7:0] data_out, data_in;
    wire rd_n, wr_n, halt_n, stop, write_cycle;
    wire [2:0] tstate;
    wire [15:0] external_addr = dma ? dma_addr : address;
    wire external_read = dma || (!rd_n && !address[15]);
    wire external_write = write_cycle && !address[15] && !dma;
    wire [15:0] cart_addr;
    wire [7:0] cart_data, latched;
    wire cart_rd_n, cart_wr_n, cart_dir;
    speedcontrol clocks(
        .clk_sys(hclk), .pause(pause), .standby_req(pause), .cart_frozen(frozen),
        .speedup(1'b0), .cart_act(external_read || external_write ||
            (pause && (dma || !cart_wr_n || !cart_dir))),
        .DMA_on(1'b0), .ce(ce), .ce_2x(ce2)
    );
    reg [9:0] state_addr = 0;
    reg [63:0] state_data = 0;
    reg state_write = 0;
    wire [63:0] cpu_state;
    GBse cpu(
        .RESET_n(!(reset || restore_cpu)), .CLK_n(hclk), .CLKEN(enable),
        .WAIT_n(1'b1), .INT_n(irq_n), .NMI_n(1'b1), .BUSRQ_n(1'b1),
        .RD_n(rd_n), .WR_n(wr_n), .HALT_n(halt_n), .STOP(stop),
        .WRITE_CYCLE(write_cycle), .TSTATEo(tstate), .A(address), .DI(data_in), .DO(data_out),
        .isGBC(1'b1), .SaveStateBus_Din(state_data), .SaveStateBus_Adr(state_addr),
        .SaveStateBus_wren(state_write), .SaveStateBus_rst(reset), .SaveStateBus_Dout(cpu_state)
    );
    function automatic [7:0] rom(input [15:0] a);
        if (a >= 16'h4000 && a < 16'h4020) rom = 8'he3 ^ a[7:0];
        else case (a)
            // Counter + marker; HALT; STOP/padding; JR back to INC (HL).
            0:rom=8'h21; 1:rom=8'h00; 2:rom=8'hc0; 3:rom=8'h34;
            4:rom=8'h7e; 5:rom=8'hee; 6:rom=8'ha5;
            7:rom=8'hea; 8:rom=8'h01; 9:rom=8'hc0;
            10:rom=8'h76; 11:rom=8'h10; 12:rom=8'h00;
            13:rom=8'h18; 14:rom=8'hf4;
            default:rom=8'h00;
        endcase
    endfunction
    wire [7:0] cartridge_input = !cart_rd_n && cart_dir ? rom(cart_addr) : 8'hff;
    reg load_cart = 0;
    reg [63:0] saved_cart;
    wire [63:0] cart_state;
    cart cartridge(
        .hclk(hclk), .pclk(pclk), .cart_frozen(frozen), .ce(ce), .ce_2x(ce2),
        .gbreset(reset), .cpu_speed(SPEED != 0), .cpu_halt(halt_n), .cpu_stop(stop),
        .DMA_on(dma), .hdma_active(dma), .wr(external_write), .rd(external_read),
        .a(external_addr), .CART_DOUT(data_out), .nCS(!external_addr[15]), .TSTATEo(tstate),
        .CART_A(cart_addr), .CART_D_IN(cartridge_input), .CART_D_OUT(cart_data),
        .CART_RD(cart_rd_n), .CART_WR(cart_wr_n), .CART_DATA_DIR_E(cart_dir),
        .CART_DIN_r1(latched), .snapshot_load(load_cart), .snapshot_in(saved_cart),
        .snapshot_out(cart_state)
    );
    reg [7:0] counter = 0, marker = 0;
    assign data_in = address == 16'hc000 ? counter : address == 16'hc001 ? marker :
                     !address[15] ? (boot_overlay ? rom(address) : latched) : 8'hff;
    always @(posedge hclk) if (!reset && !restore_cpu && enable && !wr_n) begin
        if (address == 16'hc000) counter <= data_out;
        if (address == 16'hc001) marker <= data_out;
    end

    reg [63:0] saved_cpu [0:63];
    reg [7:0] saved_counter, saved_marker;
    wire [119:0] trace_word = {cart_state, address, data_in, data_out, rd_n, wr_n,
                              halt_n, stop, irq_n, tstate, counter, marker};
    reg [119:0] reference [0:STEPS-1];
    integer mode = 0, trace_step = 0, trial, checks = 0, dma_checks = 0, stop_edges = 0;
    reg old_stop = 0;
    always @(posedge hclk) begin
        if (!reset && stop && !old_stop) stop_edges = stop_edges + 1;
        old_stop <= stop;
        if (!reset && enable && mode != 0 && trace_step < STEPS) begin
            #0.7;
            if (mode == 1) reference[trace_step] = trace_word;
            else begin
                if (trace_word !== reference[trace_step])
                    $fatal(1, "HALT/STOP continuation differs speed=%0d trial=%0d step=%0d address=%h got=%h expected=%h", SPEED, trial, trace_step, address, trace_word, reference[trace_step]);
                checks = checks + 1;
            end
            trace_step = trace_step + 1;
        end
    end

    task tick; @(negedge hclk); #0.8; endtask
    task freeze_machine;
        pause = 1;
        while (!frozen) tick();
        repeat (4) tick();
        if (ce || ce2 || !cart_wr_n || !cart_dir)
            $fatal(1, "Unsafe HALT freeze speed=%0d", SPEED);
    endtask
    task capture_machine;
        saved_cart = cart_state; saved_counter = counter; saved_marker = marker;
        for (int i = 0; i < 64; i++) begin state_addr = i; tick(); saved_cpu[i] = cpu_state; end
    endtask
    task restore_machine;
        for (int i = 0; i < 64; i++) begin
            state_addr = i; state_data = saved_cpu[i]; state_write = 1; tick();
        end
        state_write = 0; restore_cpu = 1; load_cart = 1;
        repeat (3) tick();
        restore_cpu = 0; load_cart = 0;
        counter = saved_counter; marker = saved_marker;
        repeat (4) tick();
        if (cart_state !== saved_cart || halt_n !== 0)
            $fatal(1, "HALT/cart state not restored speed=%0d", SPEED);
    endtask
    task exercise(input bit compare_trace);
        trace_step = 0; mode = compare_trace ? 2 : 1;
        // Keep the halted CPU disabled while an external DMA reader takes the
        // real address/data bus. This also tests the pClk read-enable pipeline.
        dma = 1; dma_addr = 16'h4000; pause = 0;
        while (frozen) tick();
        for (int i = 0; i < 32; i++) begin
            dma_addr = 16'h4000 + i;
            repeat (8) tick();
            if (latched !== rom(dma_addr) || cart_addr !== dma_addr)
                $fatal(1, "External DMA byte wrong speed=%0d byte=%0d got=%h address=%h", SPEED, i, latched, cart_addr);
            dma_checks = dma_checks + 1;
        end
        dma = 0;
        // With IME disabled, a pending interrupt wakes HALT without entering a
        // handler. The next executed opcode is STOP, followed by its padding.
        repeat (4) tick(); irq_n = 0;
        while (!halt_n) tick();
        irq_n = 1;
        while (trace_step < STEPS) tick();
        mode = 0;
        if (counter !== saved_counter + 8'd1 || marker !== (counter ^ 8'ha5) || halt_n !== 0)
            $fatal(1, "HALT interrupt/STOP program failed speed=%0d count=%h expected=%h PC=%h", SPEED, counter, saved_counter + 8'd1, address);
    endtask

    initial begin
        repeat (20) tick(); reset = 0;
        // Warm the physical timing generator through an internal boot overlay.
        while (halt_n) tick();
        repeat (20) tick(); freeze_machine(); boot_overlay = 0;
        for (trial = 0; trial < TRIALS; trial = trial + 1) begin
            capture_machine();
            exercise(0);
            repeat (1 + trial * 7 % 53) tick();
            freeze_machine(); restore_machine();
            exercise(1);
            repeat (1 + trial * 11 % 31) tick();
            freeze_machine();
        end
        if (checks != TRIALS * STEPS || dma_checks != TRIALS * 64 || stop_edges < TRIALS * 2)
            $fatal(1, "Missing HALT/STOP/DMA coverage speed=%0d", SPEED);
        $display("PASS real GBse HALT/INT/STOP/cart speed=%0d: %0d restores, %0d continuation steps, %0d external DMA bytes, %0d STOP edges", SPEED, TRIALS, checks, dma_checks, stop_edges);
        passed = 1;
    end
endmodule

module snapshot_cart_sleep_cpu_tb;
    wire slow, fast;
    snapshot_cart_sleep_cpu_case #(0) single_speed(slow);
    snapshot_cart_sleep_cpu_case #(1) double_speed(fast);
    initial begin wait (slow && fast); $finish; end
    initial begin #3000000; $fatal(1, "HALT/STOP CPU snapshot timeout"); end
endmodule
