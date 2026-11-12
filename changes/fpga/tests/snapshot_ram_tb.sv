`timescale 1ns/1ps

// Compare the shared-port RAM cycle by cycle with the original independent ports.
module snapshot_ram_tb;
    localparam ADDR_WIDTH = 15;
    localparam DEPTH = 1 << ADDR_WIDTH;
    reg clk = 0;
    always #5 clk = !clk;

    reg snapshot = 0, game_enable = 0, game_write = 0, state_write = 0;
    reg [ADDR_WIDTH-1:0] game_addr = 0, state_addr = 0;
    reg [7:0] game_data = 0, state_data = 0;
    wire [7:0] old_game_q, new_game_q, old_state_q, new_state_q;

    dpramV #(.addr_width(ADDR_WIDTH)) original (
        .clock_a(clk), .ce_a(game_enable), .address_a(game_addr),
        .data_a(game_data), .wren_a(game_write), .q_a(old_game_q),
        .clock_b(clk), .address_b(state_addr),
        .data_b(state_data), .wren_b(state_write), .q_b(old_state_q)
    );
    snapshot_ram #(.addr_width(ADDR_WIDTH)) shared (
        .clock(clk), .snapshot(snapshot), .ce_a(game_enable), .address_a(game_addr),
        .data_a(game_data), .wren_a(game_write), .q_a(new_game_q),
        .address_b(state_addr), .data_b(state_data), .wren_b(state_write), .q_b(new_state_q)
    );

    integer cycle = 0;
    task tick;
        @(posedge clk);
        #1; // sample after synchronous read outputs have updated
        if (new_game_q !== old_game_q)
            $fatal(1, "Game read/hold mismatch at cycle %0d, expected %h, got %h",
                   cycle, old_game_q, new_game_q);
        if (snapshot && !game_enable && !state_write && new_state_q !== old_state_q)
            $fatal(1, "Snapshot read at %h, expected %h, got %h",
                   state_addr, old_state_q, new_state_q);
        cycle = cycle + 1;
    endtask

    integer address, pass, seed = 32'h1cbb4405;
    initial begin
        game_enable = 1;
        game_write = 1;
        for (address = 0; address < DEPTH; address = address + 1) begin
            game_addr = address;
            game_data = (address + (address >> 5)) * 97;
            tick;
        end
        game_addr = 1;
        game_write = 0;
        tick;
        if (new_game_q !== 8'd97) $fatal(1, "Game read latency or initialization");

        for (pass = 0; pass < 3; pass = pass + 1) begin
            repeat (500) begin
                game_enable = $random(seed);
                game_write = $random(seed);
                game_addr = $random(seed);
                game_data = $random(seed);
                tick;
            end

            // The pause request can overlap the last game clock enable. The
            // state engine settles the core before it consumes any RAM byte.
            snapshot = 1;
            game_enable = 1;
            game_write = 0;
            tick;
            game_enable = 0;
            for (address = 0; address < DEPTH; address = address + 1) begin
                state_addr = address;
                tick;
            end

            state_write = 1;
            for (address = 0; address < DEPTH; address = address + 1) begin
                state_addr = address;
                state_data = $random(seed);
                tick;
            end
            state_write = 0;
            snapshot = 0;
            tick;

            // Stalls and writes after resume must leave the last game read
            // intact, including when no fresh read takes place until later.
            game_enable = 1;
            game_write = 1;
            tick;
            game_enable = 0;
            tick;
            game_enable = 1;
            game_write = 0;
            for (address = 0; address < DEPTH; address = address + 1) begin
                game_addr = address;
                tick;
            end
        end
        $display("PASS: shared snapshot RAM matches independent ports over %0d cycles", cycle);
        $finish;
    end
endmodule
