// Save-state mailbox. Commands are one-at-a-time; the MCU holds the
// command bus until the reply. Both toggle handshakes include two sync stages.
module snapshot_control #(parameter STALL_BITS = 22, parameter DIAGNOSTICS = 0, parameter BULK = 0) (
    input clk, input reset, input supported, input [63:0] identity,
    input cmd_toggle, input [6:0] cmd, input [79:0] cmd_data,
    output reg reply_toggle = 0, output reg [79:0] reply = 0,
    output reg capture = 0, output reg restore = 0,
    input core_busy, input core_req, input core_read, input [25:0] core_addr,
    input [63:0] core_out, output reg core_done = 0,
    output reg mem_toggle = 0, output reg [13:0] mem_index = 0,
    output reg mem_read, output reg [63:0] mem_out,
    input mem_ack, input [63:0] mem_in, input core_loaded,
    output reg core_abort = 0, output reg restart_core = 0, output active,
    input [15:0] debug_flags,
    input spi_clk, input spi_cs, input spi_mosi, output spi_miso, output spi_drive
);
    // The cartridge probe gates supported mapper geometries before this mailbox.
    wire [13:0] words = identity[47:40] == 3 ? 14'd10341 :
                        identity[47:40] == 2 ? 14'd7269 : 14'd6309;
    localparam IDLE=0, SAVING=1, LOADING=2;
    localparam NONE=0, CORE=1, READ=2, WRITE=3, DRAIN=4, BLOCK=5;
    reg [1:0] operation = IDLE;
    reg [2:0] owner = NONE;
    reg [1:0] cmd_sync = 0, ack_sync = 0;
    reg cmd_seen = 0;
    reg busy_seen = 0, staged = 0, loaded = 0, header_committed = 0;
    reg [7:0] last_result = 0;
    reg [15:0] debug_seen = 0;
    reg req_seen = 0;
    reg [63:0] frozen_debug = 0;
    reg [STALL_BITS-1:0] stall_count = 0;
    wire memory_pending = owner != NONE && ack_sync[1] != mem_toggle;
    reg block_pending = 0, block_armed = 0;
    reg [7:0] block_command, block_count;
    reg [13:0] block_index;
    reg block_prepare = 0, block_commit = 0, block_clear = 0, block_upload = 0;
    reg block_mem_done = 0;
    wire block_done, block_good, block_mem_req, block_mem_read;
    wire [6:0] block_offset;
    wire [63:0] block_word;
    wire work_pending = operation != IDLE || owner == READ || owner == WRITE || block_pending;
    wire failed = work_pending && (!supported || (&stall_count));
    assign active = operation != IDLE;
    wire [63:0] debug_payload = {debug_flags, debug_seen | debug_flags,
        mem_index, operation, owner, busy_seen, core_busy, memory_pending,
        header_committed, req_seen | core_req, core_req, core_read,
        core_loaded, mem_toggle, ack_sync[1], 3'b000};
    reg [13:0] next_word = 0;
    wire [15:0] index = cmd == 7'h22 ? cmd_data[79:64] : cmd_data[15:0];
    wire [15:0] block_start = cmd_data[23:8];
    wire [13:0] block_remaining = words - block_start[13:0];

    generate if (BULK) begin : bulk_port
        snapshot_block_transfer transfer (
            .clk(clk), .clear(reset || !supported || failed || block_clear),
            .prepare(block_prepare), .upload(block_upload), .commit(block_commit),
            .count(block_count), .check_header(block_index == 0),
            .check_cart_word(block_index == 0),
            .done(block_done), .good(block_good), .mem_req(block_mem_req),
            .mem_read(block_mem_read), .offset(block_offset), .word(block_word),
            .mem_data(mem_in), .mem_done(block_mem_done), .sclk(spi_clk),
            .cs(spi_cs), .mosi(spi_mosi), .miso(spi_miso), .drive(spi_drive)
        );
    end else begin : no_bulk_port
        assign {block_done, block_good, block_mem_req, block_mem_read,
                block_offset, block_word, spi_miso, spi_drive} = 0;
    end endgenerate

    task respond_status(input [7:0] op, input [7:0] result);
        begin
            reply <= {16'hfff0, op, result, 48'd0};
            reply_toggle <= ~reply_toggle;
        end
    endtask

    always @(posedge clk) begin
        cmd_sync <= {cmd_sync[0], cmd_toggle};
        ack_sync <= {ack_sync[0], mem_ack};
        capture <= 0;
        restore <= 0;
        core_done <= 0;
        core_abort <= 0;
        restart_core <= 0;
        block_prepare <= 0;
        block_commit <= 0;
        block_clear <= 0;
        block_mem_done <= 0;
        if (operation != IDLE) begin
            if (DIAGNOSTICS) debug_seen <= debug_seen | debug_flags;
            if (DIAGNOSTICS) req_seen <= req_seen | core_req;
        end
        if (reset) begin
            owner <= NONE;
            operation <= IDLE;
            staged <= 0;
            next_word <= 0;
            busy_seen <= 0;
            cmd_seen <= cmd_sync[1];
            mem_toggle <= ack_sync[1];
            loaded <= 0;
            stall_count <= 0;
            last_result <= 0;
            block_pending <= 0;
            block_armed <= 0;
            mem_index <= 0;
            if (DIAGNOSTICS) debug_seen <= 0;
            if (DIAGNOSTICS) req_seen <= 0;
            if (DIAGNOSTICS) frozen_debug <= 0;
        end else if (failed) begin
            // A missing VBlank, clock pause or memory completion cannot leave
            // the guest frozen. Ignore a late RAM acknowledgement after abort.
            if (DIAGNOSTICS) frozen_debug <= debug_payload;
            core_abort <= operation != IDLE;
            restart_core <= operation == LOADING;
            if (owner == READ || owner == WRITE)
                respond_status(owner == READ ? 8'h21 : 8'h22, supported ? 3 : 2);
            if (block_pending) respond_status(block_command, supported ? 3 : 2);
            block_pending <= 0;
            block_armed <= 0;
            owner <= memory_pending ? DRAIN : NONE;
            staged <= 0;
            next_word <= 0;
            last_result <= supported ? 3 : 2;
            operation <= IDLE;
            busy_seen <= 0;
            stall_count <= 0;
        end else begin
            if (!work_pending || core_req || block_mem_req || (owner != NONE && !memory_pending))
                stall_count <= 0;
            else stall_count <= stall_count + 1'b1;
            if (!supported) begin
                staged <= 0;
                next_word <= 0;
                block_armed <= 0;
            end
            if (block_pending && block_done) begin
                block_pending <= 0;
                respond_status(block_command, block_good ? 0 : 4);
                if (block_command == 8'h24 && block_good) begin
                    next_word <= block_index + {6'd0, block_count};
                    staged <= block_index + {6'd0, block_count} == words;
                end
            end
            if (operation != IDLE) begin
                if (core_busy) busy_seen <= 1;
                if (core_loaded) loaded <= 1;
                if (busy_seen && !core_busy) begin
                    if (operation == SAVING) begin
                        staged <= supported && header_committed;
                        if (!header_committed) begin
                            last_result <= 3;
                            if (DIAGNOSTICS) frozen_debug <= debug_payload;
                        end
                    end
                    if (operation == LOADING && !(loaded || core_loaded)) begin
                        last_result <= 3;
                        if (DIAGNOSTICS) frozen_debug <= debug_payload;
                        staged <= 0;
                    end
                    operation <= IDLE;
                    busy_seen <= 0;
                end
            end
            if (owner != NONE && ack_sync[1] == mem_toggle) begin
                case (owner)
                    CORE: begin
                        core_done <= 1;
                        if (operation == SAVING && !mem_read && mem_index == 0 &&
                            mem_out[63:32] == 32'hb0ca) header_committed <= 1;
                    end
                    READ: begin
                        reply <= {2'b00, mem_index, mem_in};
                        reply_toggle <= ~reply_toggle;
                    end
                    WRITE: begin
                        next_word <= mem_index + 1'b1;
                        staged <= mem_index == words - 1 && supported;
                        // The request index and payload remain held until this ACK.
                        reply <= {2'b00, mem_index, mem_out};
                        reply_toggle <= ~reply_toggle;
                    end
                    BLOCK: block_mem_done <= 1;
                endcase
                owner <= NONE;
            end
            if (core_req && owner == NONE && operation != IDLE) begin
                owner <= CORE;
                // Slot zero is 64K-DWORD aligned; the core addresses DWORDs.
                mem_index <= core_addr[14:1];
                mem_read <= core_read;
                mem_out <= core_out;
                mem_toggle <= ~mem_toggle;
            end
            if (block_pending && block_mem_req && owner == NONE) begin
                owner <= BLOCK;
                mem_index <= {block_index[13:7], block_offset};
                mem_read <= block_mem_read;
                mem_out <= block_word;
                mem_toggle <= ~mem_toggle;
            end
            if (cmd_sync[1] != cmd_seen && owner != READ && owner != WRITE && !block_pending) begin
                cmd_seen <= cmd_sync[1];
                if (cmd == 7'h20) begin
                    case (cmd_data[7:0])
                        0: respond_status(0, operation != IDLE ? 1 : supported ? last_result : 2);
                        1,2: begin
                            if (operation != IDLE || owner == DRAIN) respond_status(cmd_data[7:0], 5);
                            else if (!supported) respond_status(cmd_data[7:0], 2);
                            else if (cmd_data[7:0] == 2 && !staged) respond_status(2, 4);
                            else begin
                                block_clear <= 1;
                                block_armed <= 0;
                                if (cmd_data[7:0] == 1) begin
                                    operation <= SAVING;
                                    capture <= 1;
                                    staged <= 0;
                                    next_word <= 0;
                                end else begin
                                    operation <= LOADING;
                                    restore <= 1;
                                end
                                if (DIAGNOSTICS) debug_seen <= 0;
                                if (DIAGNOSTICS) req_seen <= 0;
                                if (DIAGNOSTICS) frozen_debug <= 0;
                                busy_seen <= 0;
                                loaded <= 0;
                                header_committed <= 0;
                                last_result <= 0;
                                respond_status(cmd_data[7:0], 1);
                            end
                        end
                        3: begin
                            if (!supported) respond_status(3, 2);
                            else begin
                                reply <= {16'hfff1, identity};
                                reply_toggle <= ~reply_toggle;
                            end
                        end
                        4: begin
                            reply <= {16'hfff2, DIAGNOSTICS ? frozen_debug : 64'd0};
                            reply_toggle <= ~reply_toggle;
                        end
                        5: begin
                            if (BULK) begin
                                reply <= {16'hfff3, 32'h424c4b31, 32'd0};
                                reply_toggle <= ~reply_toggle;
                            end else respond_status(5, 3);
                        end
                        default: respond_status(cmd_data[7:0], 3);
                    endcase
                end else if (operation != IDLE || owner == DRAIN)
                    respond_status({1'b0,cmd}, 5);
                else if (!supported)
                    respond_status({1'b0,cmd}, 2);
                else if (BULK && (cmd == 7'h23 || cmd == 7'h24)) begin
                    // Direction byte, aligned word index and one reserved byte.
                    if (cmd_data[31:24] > 1 || cmd_data[7:0] != 0 ||
                        block_start >= {2'd0, words} || block_start[6:0] != 0)
                        respond_status({1'b0,cmd}, 3);
                    else if (cmd == 7'h24) begin
                        if (!block_armed || !cmd_data[24] || block_start[13:0] != block_index)
                            respond_status(8'h24, 4);
                        else begin
                            block_commit <= 1;
                            block_pending <= 1;
                            block_command <= 8'h24;
                            block_armed <= 0;
                        end
                    end else if ((!cmd_data[24] && !staged) ||
                                 (cmd_data[24] && block_start != 0 && block_start[13:0] != next_word))
                        respond_status(8'h23, 4);
                    else begin
                        block_prepare <= 1;
                        block_pending <= 1;
                        block_command <= 8'h23;
                        block_index <= block_start[13:0];
                        block_count <= block_remaining > 14'd128 ? 8'd128 : block_remaining[7:0];
                        block_upload <= cmd_data[24];
                        block_armed <= cmd_data[24];
                        if (cmd_data[24]) begin
                            staged <= 0;
                            if (block_start == 0) next_word <= 0;
                        end
                    end
                end
                else if (index >= words)
                    respond_status({1'b0,cmd}, 3);
                else if (cmd == 7'h21 && !staged)
                    respond_status(8'h21, 4);
                else if (cmd == 7'h22 && ((index != 0 && index != next_word &&
                          index + 1 != next_word) || (index == 0 && cmd_data[63:32] != 32'hb0ca)))
                    respond_status(8'h22, 3);
                else if (cmd == 7'h21 || cmd == 7'h22) begin
                    block_clear <= 1;
                    block_armed <= 0;
                    owner <= cmd == 7'h21 ? READ : WRITE;
                    if (cmd == 7'h22) staged <= 0;
                    mem_index <= index[13:0];
                    mem_read <= cmd == 7'h21;
                    mem_out <= cmd_data[63:0];
                    mem_toggle <= ~mem_toggle;
                end else respond_status({1'b0,cmd}, 3);
            end
        end
    end
endmodule
