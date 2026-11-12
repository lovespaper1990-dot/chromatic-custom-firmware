// ROM-only save-state mailbox. Commands are one-at-a-time; the MCU holds the
// command bus until the reply. Both toggle handshakes include two sync stages.
module snapshot_control #(parameter STALL_BITS = 22) (
    input clk, input reset, input supported, input [63:0] identity,
    input cmd_toggle, input [6:0] cmd, input [79:0] cmd_data,
    output reg reply_toggle = 0, output reg [79:0] reply = 0,
    output reg capture = 0, output reg restore = 0,
    input core_busy, input core_req, input core_read, input [25:0] core_addr,
    input [63:0] core_out, output reg core_done = 0,
    output reg mem_toggle = 0, output reg [12:0] mem_index,
    output reg mem_read, output reg [63:0] mem_out,
    input mem_ack, input [63:0] mem_in, input core_loaded,
    output reg core_abort = 0, output reg restart_core = 0, output active
);
    localparam WORDS = 6309;
    localparam IDLE=0, SAVING=1, LOADING=2;
    localparam NONE=0, CORE=1, READ=2, WRITE=3, DRAIN=4;
    reg [1:0] operation = IDLE;
    reg [2:0] owner = NONE;
    reg [1:0] cmd_sync = 0, ack_sync = 0;
    reg cmd_seen = 0;
    reg busy_seen = 0, staged = 0, loaded = 0, header_committed = 0;
    reg [7:0] last_result = 0;
    reg [STALL_BITS-1:0] stall_count = 0;
    wire memory_pending = owner != NONE && ack_sync[1] != mem_toggle;
    wire work_pending = operation != IDLE || owner == READ || owner == WRITE;
    wire failed = work_pending && (!supported || (&stall_count));
    assign active = operation != IDLE;
    reg [12:0] next_word = 0;
    wire [15:0] index = cmd == 7'h22 ? cmd_data[79:64] : cmd_data[15:0];

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
        end else if (failed) begin
            // A missing VBlank, clock pause or memory completion cannot leave
            // the guest frozen. Ignore a late RAM acknowledgement after abort.
            core_abort <= operation != IDLE;
            restart_core <= operation == LOADING;
            if (owner == READ || owner == WRITE)
                respond_status(owner == READ ? 8'h21 : 8'h22, supported ? 3 : 2);
            owner <= memory_pending ? DRAIN : NONE;
            staged <= 0;
            next_word <= 0;
            last_result <= supported ? 3 : 2;
            operation <= IDLE;
            busy_seen <= 0;
            stall_count <= 0;
        end else begin
            if (!work_pending || core_req || (owner != NONE && !memory_pending))
                stall_count <= 0;
            else stall_count <= stall_count + 1'b1;
            if (!supported) begin
                staged <= 0;
                next_word <= 0;
            end
            if (operation != IDLE) begin
                if (core_busy) busy_seen <= 1;
                if (core_loaded) loaded <= 1;
                if (busy_seen && !core_busy) begin
                    if (operation == SAVING) begin
                        staged <= supported && header_committed;
                        if (!header_committed) last_result <= 3;
                    end
                    if (operation == LOADING && !(loaded || core_loaded)) begin
                        last_result <= 3;
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
                        reply <= {3'b000, mem_index, mem_in};
                        reply_toggle <= ~reply_toggle;
                    end
                    WRITE: begin
                        next_word <= mem_index + 1'b1;
                        staged <= mem_index == WORDS - 1 && supported;
                        // The request index and payload remain held until this ACK.
                        reply <= {3'b000, mem_index, mem_out};
                        reply_toggle <= ~reply_toggle;
                    end
                endcase
                owner <= NONE;
            end
            if (core_req && owner == NONE && operation != IDLE) begin
                owner <= CORE;
                // Slot zero is 64K-DWORD aligned; the core addresses DWORDs.
                mem_index <= core_addr[13:1];
                mem_read <= core_read;
                mem_out <= core_out;
                mem_toggle <= ~mem_toggle;
            end
            if (cmd_sync[1] != cmd_seen && owner != READ && owner != WRITE) begin
                cmd_seen <= cmd_sync[1];
                if (cmd == 7'h20) begin
                    case (cmd_data[7:0])
                        0: respond_status(0, operation != IDLE ? 1 : supported ? last_result : 2);
                        1,2: begin
                            if (operation != IDLE || owner == DRAIN) respond_status(cmd_data[7:0], 5);
                            else if (!supported) respond_status(cmd_data[7:0], 2);
                            else if (cmd_data[7:0] == 2 && !staged) respond_status(2, 4);
                            else begin
                                if (cmd_data[7:0] == 1) begin
                                    operation <= SAVING;
                                    capture <= 1;
                                    staged <= 0;
                                    next_word <= 0;
                                end else begin
                                    operation <= LOADING;
                                    restore <= 1;
                                end
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
                        default: respond_status(cmd_data[7:0], 3);
                    endcase
                end else if (operation != IDLE || owner == DRAIN)
                    respond_status({1'b0,cmd}, 5);
                else if (!supported)
                    respond_status({1'b0,cmd}, 2);
                else if (index >= WORDS)
                    respond_status({1'b0,cmd}, 3);
                else if (cmd == 7'h21 && !staged)
                    respond_status(8'h21, 4);
                else if (cmd == 7'h22 && ((index != 0 && index != next_word &&
                          index + 1 != next_word) || (index == 0 && cmd_data[63:32] != 32'hb0ca)))
                    respond_status(8'h22, 3);
                else if (cmd == 7'h21 || cmd == 7'h22) begin
                    owner <= cmd == 7'h21 ? READ : WRITE;
                    if (cmd == 7'h22) staged <= 0;
                    mem_index <= index[12:0];
                    mem_read <= cmd == 7'h21;
                    mem_out <= cmd_data[63:0];
                    mem_toggle <= ~mem_toggle;
                end else respond_status({1'b0,cmd}, 3);
            end
        end
    end
endmodule
