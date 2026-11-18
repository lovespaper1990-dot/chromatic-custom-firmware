// A single block shared by the snapshot mailbox and the board SPI master.
// The mailbox holds the grant and length from before CS goes low until the
// transaction finishes. Only the granted side writes RAM at a given time.
module snapshot_spi_buffer (
    input clk, input [8:0] address, input read_en, input write_en, input [15:0] data_in,
    output [15:0] data_out,
    input read_grant, input write_grant, input write_ticket, input [7:0] words, input cancel,
    output reg upload_done = 0,
    input sclk, input cs, input mosi, output miso, output drive
);
    // The grant has two local clock edges to settle well before command decode.
    // The bundled length is held stable for the whole transaction.
    reg [1:0] read_sync = 0, write_sync = 0;
    always @(posedge sclk) begin
        read_sync <= {read_sync[0], read_grant};
        write_sync <= {write_sync[0], write_grant};
    end

    // Kill an abandoned SPI frame even if its clock is stopped. Discard
    // pre-cancel samples, then require an observed idle CS before rearming.
    // The MCU leaves CS idle for 1 us after acquiring the shared bus.
    reg [1:0] idle_cs = 0;
    reg frame_allowed = 0;
    always @(posedge clk or posedge cancel)
        if (cancel) begin
            idle_cs <= 0;
            frame_allowed <= 0;
        end else begin
            idle_cs <= {idle_cs[0], cs};
            if (idle_cs[1]) frame_allowed <= 1;
        end

    reg [4:0] header_bit = 0;
    reg [9:0] command = 0;
    reg reading = 0, writing = 0;
    reg ticket;
    reg [9:0] halfwords;
    reg [8:0] halfword_index = 0;
    reg [3:0] serial_bit = 0;
    reg crc_phase = 0, finished = 0;
    reg [15:0] crc = 16'hffff, serial_shift;
    wire [15:0] read_word;
    wire data_phase = header_bit == 18 && !finished;
    wire last_word = {1'b0, halfword_index} + 10'd1 == halfwords;
    wire [15:0] received = {serial_shift[14:0], mosi};
    wire bit_out = serial_shift[15];
    wire crc_feedback = crc[15] ^ (reading ? bit_out : mosi);
    wire [15:0] crc_next = {crc[14:0], 1'b0} ^ (crc_feedback ? 16'h1021 : 16'h0000);
    wire [8:0] read_address = halfword_index + {8'd0, reading && serial_bit[3]};
    wire put_word = !cs && frame_allowed && writing && data_phase && !crc_phase && serial_bit == 15;
    wire [8:0] spi_address = put_word ? halfword_index : read_address;
    // One true dual-port GW5A block RAM. In 16-bit mode address bits [1:0]
    // enable the two byte lanes. Each port is enabled only while it owns
    // the buffer and reads have the standard single-clock latency.
    DPB #(.BIT_WIDTH_0(16), .BIT_WIDTH_1(16)) data_ram (
        .DOA(data_out), .DOB(read_word), .DIA(data_in), .DIB(received),
        .BLKSELA(3'b000), .BLKSELB(3'b000),
        .ADA({1'b0, address, 4'b0011}), .ADB({1'b0, spi_address, 4'b0011}),
        .WREA(write_en), .WREB(put_word), .CLKA(clk), .CLKB(sclk),
        .CEA(read_en || write_en), .CEB(!cs && frame_allowed && (reading || put_word)),
        .OCEA(1'b1), .OCEB(1'b1), .RESETA(1'b0), .RESETB(1'b0)
    );

    // Shift out on the preceding rising edge, leaving one SPI period of
    // setup at the master. Read prefetch starts eight bits before use.
    assign miso = bit_out;
    assign drive = !cs && frame_allowed && reading && header_bit == 18;
    always @(posedge sclk or posedge cs) begin
        if (cs) begin
            header_bit <= 0;
            command <= 0;
            reading <= 0;
            writing <= 0;
            halfwords <= 0;
            halfword_index <= 0;
            serial_bit <= 0;
            crc_phase <= 0;
            finished <= 0;
            crc <= 16'hffff;
            serial_shift <= 0;
        end else if (header_bit < 18) begin
            header_bit <= header_bit + 1'b1;
            if (header_bit <= 10) command <= {command[8:0], mosi};
            if (header_bit == 10) begin
                reading <= read_sync[1] && {command, mosi} == 11'h017;
                writing <= write_sync[1] && upload_done != write_ticket && {command, mosi} == 11'h018;
                ticket <= write_ticket;
                halfwords <= {words, 2'b00};
            end
            if (header_bit == 17 && reading) serial_shift <= read_word;
        end else if ((reading || writing) && !finished) begin
            serial_bit <= serial_bit + 1'b1;
            serial_shift <= received;
            if (!crc_phase) crc <= crc_next;
            if (serial_bit == 15) begin
                if (crc_phase) finished <= 1;
                else if (last_word) begin
                    crc_phase <= 1;
                    if (reading) serial_shift <= crc_next;
                end else begin
                    halfword_index <= halfword_index + 1'b1;
                    if (reading) serial_shift <= read_word;
                end
            end
        end
    end
    // Keep this toggle through chip select. A partial frame or invalid CRC
    // leaves it unchanged and cannot authorize a PSRAM write.
    always @(posedge sclk)
        if (!cs && frame_allowed && writing && data_phase && crc_phase && serial_bit == 15 && received == crc)
            upload_done <= ticket;

endmodule
