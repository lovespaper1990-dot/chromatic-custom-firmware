// Interpose physical cartridge RAM on the core's 64-bit state stream. The
// Game Boy state engine stays paused until each byte transfer and the final
// mapper restoration have finished. No SRAM write occurs during capture.
module snapshot_mbc5 (
    input clk, input reset, input enabled, input [7:0] ram_code,
    input active, input abort, input restart_core,
    input core_req, input core_read, input [25:0] core_addr,
    input [63:0] core_out, output reg core_done = 0,
    output reg [63:0] core_in = 0,
    output reg mem_req = 0, output reg mem_read,
    output reg [25:0] mem_addr, output reg [63:0] mem_out,
    input mem_done, input [63:0] mem_in,
    input [15:0] game_addr, input [7:0] game_out, input game_write_n,
    input [7:0] cart_in,
    output reg take_bus = 0,
    output [15:0] cart_addr, output [7:0] cart_out,
    output cart_read_n, output cart_write_n, output cart_cs_n, output cart_input_dir
);
    localparam IDLE=0, MEM_WAIT=1, ENABLE_RAM=2, ENABLE_WAIT=3,
               SELECT_BANK=4, BANK_WAIT=5, BYTE_START=6, BYTE_WAIT=7,
               RESTORE_START=8, RESTORE_WAIT=9, ABORT_WAIT=10;
    localparam COMMIT=0, FINISH_LOAD=1, RECOVER=2;
    reg [3:0] state = IDLE;
    reg [1:0] finish_mode = COMMIT, restore_step = 0;
    reg [13:0] word_index;
    reg [2:0] lane = 0;
    reg [63:0] word_data;
    reg [15:0] original_mapper = 1, loaded_mapper = 1, restore_mapper;
    reg session = 0, session_loading = 0, aborting = 0, mem_pending = 0;
    wire has_ram = ram_code == 2 || ram_code == 3;
    wire [13:0] last_word = ram_code == 3 ? 14'd10340 :
                                  ram_code == 2 ? 14'd7268 : 14'd6308;
    wire [13:0] ram_word = word_index - 14'd6245;
    wire [12:0] byte_offset = {ram_word[9:0], lane};
    wire [3:0] ram_bank = {2'b00, ram_word[11:10]};
    wire [15:0] current_mapper;
    reg bus_start = 0, bus_write;
    reg [15:0] bus_addr;
    reg [7:0] bus_out;
    wire bus_busy, bus_done;
    wire [7:0] bus_in;

    snapshot_mbc5_bus bus (
        .clk(clk), .ready(!reset), .start(bus_start), .write_byte(bus_write),
        .address(bus_addr), .data_out(bus_out), .cart_in(cart_in),
        .busy(bus_busy), .done(bus_done), .data_in(bus_in),
        .cart_addr(cart_addr), .cart_out(cart_out), .read_n(cart_read_n),
        .write_n(cart_write_n), .cs_n(cart_cs_n), .input_dir(cart_input_dir)
    );
    // Include our own completed writes so the mirror describes the physical
    // mapper after a load, as well as after ordinary guest mapper writes.
    snapshot_mbc5_mapper mirror (
        .clk(clk), .cart_ready(enabled && !reset),
        .write_n(take_bus ? cart_write_n : game_write_n),
        .address(take_bus ? cart_addr : game_addr),
        .data(take_bus ? cart_out : game_out), .mapper_state(current_mapper)
    );

    always @(posedge clk) begin
        mem_req <= 0;
        core_done <= 0;
        bus_start <= 0;
        if (mem_req) mem_pending <= 1;
        if (mem_done) mem_pending <= 0;
        if (!active && !take_bus && !abort && !restart_core) begin
            session <= 0;
            session_loading <= 0;
        end
        if (reset) begin
            state <= IDLE;
            take_bus <= 0;
            mem_pending <= 0;
            session <= 0;
            session_loading <= 0;
            aborting <= 0;
        end else if (abort || restart_core || (take_bus && !active && !aborting)) begin
            // The mailbox drains its own abandoned PSRAM request and rejects
            // new operations until then. It may suppress that late ACK.
            // Finish only our physical cycle before restoring the mapper.
            state <= ABORT_WAIT;
            // A failed load cold boots the guest. Restore the physical mapper
            // to its power-on registers even if SRAM ownership has not begun.
            // restart_core also covers a load that stalled before its first request.
            // A failed capture resumes the existing guest mapper unchanged.
            if (enabled && (session_loading || restart_core)) take_bus <= 1;
            restore_mapper <= session_loading || restart_core ? 16'h0001 : original_mapper;
            mem_pending <= 0;
            aborting <= 1;
        end else case (state)
            IDLE: if (core_req && active) begin
                if (!session) begin
                    original_mapper <= current_mapper;
                    loaded_mapper <= current_mapper;
                    session <= 1;
                    session_loading <= core_read;
                end
                word_index <= core_addr[14:1];
                mem_addr <= core_addr;
                mem_read <= core_read;
                mem_out <= enabled && !core_read && core_addr[14:1] == 33 ?
                           {core_out[63:16], current_mapper} : core_out;
                lane <= 0;
                if (enabled && !core_read && core_addr[14:1] == 0 && take_bus) begin
                    restore_mapper <= original_mapper;
                    restore_step <= 0;
                    finish_mode <= COMMIT;
                    state <= RESTORE_START;
                end else if (enabled && !core_read && has_ram && core_addr[14:1] >= 6245) begin
                    take_bus <= 1;
                    state <= ENABLE_RAM;
                end else begin
                    mem_req <= 1;
                    state <= MEM_WAIT;
                end
            end
            MEM_WAIT: if (mem_done) begin
                core_in <= mem_in;
                if (enabled && mem_read && word_index == 33)
                    loaded_mapper <= mem_in[15:0];
                if (enabled && mem_read && has_ram && word_index >= 6245) begin
                    word_data <= mem_in;
                    take_bus <= 1;
                    lane <= 0;
                    state <= ENABLE_RAM;
                end else if (enabled && mem_read && word_index == last_word) begin
                    take_bus <= 1;
                    restore_mapper <= loaded_mapper;
                    restore_step <= 0;
                    finish_mode <= FINISH_LOAD;
                    state <= RESTORE_START;
                end else begin
                    core_done <= 1;
                    if (word_index == 0) take_bus <= 0;
                    state <= IDLE;
                end
            end
            ENABLE_RAM: begin
                bus_addr <= 16'h0000;
                bus_out <= 8'h0a;
                bus_write <= 1;
                bus_start <= 1;
                state <= ENABLE_WAIT;
            end
            ENABLE_WAIT: if (bus_done) state <= SELECT_BANK;
            SELECT_BANK: begin
                bus_addr <= 16'h4000;
                bus_out <= {4'b0, ram_bank};
                bus_write <= 1;
                bus_start <= 1;
                state <= BANK_WAIT;
            end
            BANK_WAIT: if (bus_done) state <= BYTE_START;
            BYTE_START: begin
                bus_addr <= {3'b101, byte_offset};
                bus_out <= word_data[lane*8 +: 8];
                bus_write <= mem_read;
                bus_start <= 1;
                state <= BYTE_WAIT;
            end
            BYTE_WAIT: if (bus_done) begin
                if (!mem_read) word_data[lane*8 +: 8] <= bus_in;
                if (lane != 7) begin
                    lane <= lane + 1'b1;
                    state <= BYTE_START;
                end else if (!mem_read) begin
                    mem_out <= {bus_in, word_data[55:0]};
                    mem_req <= 1;
                    state <= MEM_WAIT;
                end else if (word_index == last_word) begin
                    restore_mapper <= loaded_mapper;
                    restore_step <= 0;
                    finish_mode <= FINISH_LOAD;
                    state <= RESTORE_START;
                end else begin
                    core_done <= 1;
                    state <= IDLE;
                end
            end
            RESTORE_START: begin
                bus_write <= 1;
                case (restore_step)
                    0: begin bus_addr <= 16'h2000; bus_out <= restore_mapper[7:0]; end
                    1: begin bus_addr <= 16'h3000; bus_out <= {7'b0, restore_mapper[8]}; end
                    2: begin bus_addr <= 16'h4000; bus_out <= {4'b0, restore_mapper[12:9]}; end
                    3: begin bus_addr <= 16'h0000; bus_out <= restore_mapper[15] ? 8'h0a : 8'h00; end
                endcase
                bus_start <= 1;
                state <= RESTORE_WAIT;
            end
            RESTORE_WAIT: if (bus_done) begin
                if (restore_step != 3) begin
                    restore_step <= restore_step + 1'b1;
                    state <= RESTORE_START;
                end else if (finish_mode == COMMIT) begin
                    mem_req <= 1;
                    state <= MEM_WAIT;
                end else begin
                    take_bus <= 0;
                    if (finish_mode == FINISH_LOAD) core_done <= 1;
                    aborting <= 0;
                    state <= IDLE;
                end
            end
            ABORT_WAIT: if (!mem_pending && !mem_req && !bus_busy && !bus_start) begin
                if (take_bus) begin
                    restore_step <= 0;
                    finish_mode <= RECOVER;
                    state <= RESTORE_START;
                end else begin
                    aborting <= 0;
                    state <= IDLE;
                end
            end
        endcase
    end
endmodule
