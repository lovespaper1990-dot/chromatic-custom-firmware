// Copy one bounded block between the SPI mailbox and existing PSRAM word port.
// The guest uses a separate request owner and never executes from this buffer.
module snapshot_block_transfer (
    input clk, input clear,
    input prepare, input upload, input commit, input [7:0] count,
    input check_header, input check_cart_word,
    output reg done = 0, output reg good = 0,
    output reg mem_req = 0, output mem_read, output reg [6:0] offset = 0,
    output reg [63:0] word = 0, input [63:0] mem_data, input mem_done,
    input sclk, input cs, input mosi, output miso, output drive
);
    localparam IDLE = 0, READ_START = 1, READ_WAIT = 2, STORE = 3, READ_READY = 4,
               WRITE_READY = 5, PREFETCH = 6, FETCH = 7, WRITE_START = 8, WRITE_WAIT = 9;
    reg [3:0] state = IDLE;
    reg [7:0] words = 0;
    reg [8:0] address = 0;
    reg [1:0] lane = 0;
    reg ticket = 0, header_block = 0, cart_word_block = 0;
    wire upload_done;
    reg [1:0] upload_sync = 0;
    wire [15:0] buffer_data;
    wire last = {1'b0, offset} + 8'd1 == words;
    assign mem_read = state == READ_START || state == READ_WAIT;

    snapshot_spi_buffer spi (
        .clk(clk), .address(address), .write_en(state == STORE && !clear),
        .read_en((state == PREFETCH || state == FETCH) && !clear),
        .data_in(word[63:48]), .data_out(buffer_data), .words(words),
        .read_grant(state == READ_READY && !clear),
        .write_grant(state == WRITE_READY && !clear), .write_ticket(ticket),
        .cancel(clear || prepare || commit),
        .upload_done(upload_done), .sclk(sclk), .cs(cs), .mosi(mosi),
        .miso(miso), .drive(drive)
    );

    always @(posedge clk) begin
        upload_sync <= {upload_sync[0], upload_done};
        mem_req <= 0;
        done <= 0;
        if (clear) state <= IDLE;
        else if (prepare) begin
            words <= count;
            address <= 0;
            lane <= 0;
            offset <= 0;
            ticket <= ~upload_sync[1];
            header_block <= check_header;
            cart_word_block <= check_cart_word;
            state <= upload ? WRITE_READY : READ_START;
            if (upload) begin
                done <= 1;
                good <= 1;
            end
        end else if (commit) begin
            if (state == WRITE_READY && upload_sync[1] == ticket) begin
                // Synchronous RAM read. PREFETCH primes data_out at address 0
                // and advances the RAM address one cycle ahead of FETCH.
                state <= PREFETCH;
            end else begin
                state <= IDLE;
                done <= 1;
                good <= 0;
            end
        end else case (state)
            READ_START: begin
                mem_req <= 1;
                state <= READ_WAIT;
            end
            READ_WAIT: if (mem_done) begin
                word <= mem_data;
                state <= STORE;
            end
            STORE: begin
                address <= address + 1'b1;
                word <= {word[47:0], 16'd0};
                lane <= lane + 1'b1;
                if (lane == 3) begin
                    if (last) begin
                        state <= READ_READY;
                        done <= 1;
                        good <= 1;
                    end else begin
                        offset <= offset + 1'b1;
                        state <= READ_START;
                    end
                end
            end
            PREFETCH: begin
                address <= address + 1'b1;
                state <= FETCH;
            end
            FETCH: begin
                address <= address + 1'b1;
                word <= {word[47:0], buffer_data};
                lane <= lane + 1'b1;
                if (lane == 3) begin
                    // Hold the address of the next unread halfword through
                    // the PSRAM request, so PREFETCH can restart the pipe.
                    address <= address;
                    state <= WRITE_START;
                end
            end
            WRITE_START: begin
                if ((header_block && offset == 0 && word[63:32] != 32'hb0ca) ||
                    (cart_word_block && offset == 64 && word[63:48] != 16'hc507)) begin
                    done <= 1;
                    good <= 0;
                    state <= IDLE;
                end else begin
                    mem_req <= 1;
                    state <= WRITE_WAIT;
                end
            end
            WRITE_WAIT: if (mem_done) begin
                if (last) begin
                    state <= IDLE;
                    done <= 1;
                    good <= 1;
                end else begin
                    offset <= offset + 1'b1;
                    state <= PREFETCH;
                end
            end
        endcase
    end
endmodule
