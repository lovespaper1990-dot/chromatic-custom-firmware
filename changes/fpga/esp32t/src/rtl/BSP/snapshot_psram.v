// One outstanding 8-byte transfer. The hClk owner holds its bundled address,
// R/W and data until the acknowledge toggle crosses back from xClk.
module snapshot_psram (
    input xclk, input reset, input initialized,
    input request_toggle, input [12:0] index, input read_word,
    input [63:0] write_data, output reg [63:0] read_data = 0,
    output reg ack_toggle = 0,
    output reg ram_req = 0, output reg ram_read = 0, output reg [22:0] ram_addr,
    output [15:0] ram_din, input [15:0] ram_dout, input ram_write_next,
    input ram_valid, input ram_done
);
    reg [1:0] request_sync = 0;
    reg busy = 0;
    reg [1:0] part = 0;
    // The hClk owner holds write_data until this request's ACK returns.
    assign ram_din = write_data[part*16 +: 16];
    always @(posedge xclk) begin
        request_sync <= {request_sync[0], request_toggle};
        ram_req <= 0;
        if (reset) begin
            busy <= 0;
            part <= 0;
            // Replay an interrupted request after BIST has initialized RAM.
            // A cart-detect reset must not acknowledge an unwritten word.
        end else if (!busy && initialized && request_sync[1] != ack_toggle) begin
            // Byte address, separate from both video buffers and OSD.
            ram_addr <= 23'h40000 + {index, 3'b000};
            ram_read <= read_word;
            busy <= 1;
            part <= 0;
            ram_req <= 1;
        end else if (busy) begin
            // PSRAM always returns four beats, least-significant first.
            if (ram_valid) read_data <= {ram_dout, read_data[63:16]};
            if (ram_valid || ram_write_next) part <= part + 1'b1;
            if (ram_done) begin
                busy <= 0;
                ack_toggle <= request_sync[1];
            end
        end
    end
endmodule
