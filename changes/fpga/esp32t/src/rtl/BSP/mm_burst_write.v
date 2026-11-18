// Queue complete 1024-byte menu rows in two banks of one dual-port RAM.
// Each clock domain owns one end. Row metadata and pixels stay immutable
// from publication until the PSRAM controller finishes the entire burst.
module mm_burst_write(
    input QSPI_CLK, input QSPI_CS, input reset,
    input [31:0] qAddress, input qDataValid, input qOsdWrite, input [15:0] qData,
    input xClk, input xRdEn, input xRamReady, input xDone,
    output reg xMcuReqWrite = 0, output [15:0] xDout, output [22:0] xAddress
);
    reg write_bank = 0, read_bank = 0;
    reg [1:0] posted = 0, consumed = 0;
    reg [1:0] consumed_meta = 0, consumed_sync = 0;
    reg [1:0] posted_meta = 0, posted_sync = 0;
    reg [5:0] row [0:1];

    // A hotplug reset can be shorter than either clock. Assert it immediately
    // in both domains and release only after two local clock edges.
    reg [1:0] spi_reset_pipe = 3, ram_reset_pipe = 3;
    always @(posedge xClk or posedge reset)
        if (reset) ram_reset_pipe <= 3;
        else ram_reset_pipe <= {ram_reset_pipe[0], 1'b0};
    wire spi_reset = spi_reset_pipe[1], ram_reset = ram_reset_pipe[1];
    // A stopped SCLK must not hide a reset in the middle of a frame. Observe
    // idle CS with the free-running RAM clock before enabling the SPI domain.
    reg [1:0] idle_cs = 0;
    reg spi_allowed = 0;
    always @(posedge xClk or posedge ram_reset)
        if (ram_reset) begin
            idle_cs <= 0;
            spi_allowed <= 0;
        end else begin
            idle_cs <= {idle_cs[0], QSPI_CS};
            if (idle_cs[1]) spi_allowed <= 1;
        end
    always @(negedge QSPI_CLK or negedge spi_allowed)
        if (!spi_allowed) spi_reset_pipe <= 3;
        else spi_reset_pipe <= {spi_reset_pipe[0], 1'b0};

    always @(negedge QSPI_CLK or posedge spi_reset) begin
        if (spi_reset) begin
            consumed_meta <= 0;
            consumed_sync <= 0;
        end else begin
            consumed_meta <= consumed;
            consumed_sync <= consumed_meta;
        end
    end

    reg [8:0] write_index = 0, read_index = 0;
    reg frame_closed = 0;
    wire valid_beat = !spi_reset && !QSPI_CS && qOsdWrite && qDataValid && !frame_closed;
    wire space = posted[write_bank] == consumed_sync[write_bank];
    wire store = valid_beat && space;
    wire last = &write_index;
    wire clear_frame = QSPI_CS || spi_reset;
    always @(negedge QSPI_CLK or posedge clear_frame) begin
        if (clear_frame) begin
            write_index <= 0;
            frame_closed <= 0;
        end else if (valid_beat) begin
            // A busy bank drops this entire row. A short frame never posts
            // a descriptor and its partial bytes are overwritten on retry.
            if (!space || last) frame_closed <= 1;
            else write_index <= write_index + 1'b1;
        end
    end
    always @(negedge QSPI_CLK or posedge spi_reset) begin
        if (spi_reset) begin
            posted <= 0;
            write_bank <= 0;
        end else if (store && last) begin
            row[write_bank] <= qAddress[15:10];
            posted[write_bank] <= ~posted[write_bank];
            write_bank <= ~write_bank;
        end
    end

    // Only an OSD header with row < 45 and low ten bits zero is admitted.
    assign xAddress = {7'd0, row[read_bank], 10'd0};
    reg busy = 0;
    wire fetch = xRdEn || xMcuReqWrite;
    always @(posedge xClk or posedge ram_reset) begin
        if (ram_reset) begin
            posted_meta <= 0;
            posted_sync <= 0;
            consumed <= 0;
            read_bank <= 0;
            read_index <= 0;
            busy <= 0;
            xMcuReqWrite <= 0;
        end else begin
            posted_meta <= posted;
            posted_sync <= posted_meta;
            xMcuReqWrite <= 0;
            if (!busy && xRamReady && posted_sync[read_bank] != consumed[read_bank]) begin
                xMcuReqWrite <= 1;
                busy <= 1;
            end
            if (fetch) read_index <= read_index + 1'b1;
            if (busy && xDone) begin
                consumed[read_bank] <= posted_sync[read_bank];
                read_bank <= ~read_bank;
                read_index <= 0;
                busy <= 0;
            end
        end
    end

    // As in the original standard FIFO, fetch word zero on request and
    // advance on writeNext. Both byte lanes are enabled in 16-bit mode.
    DPB #(.BIT_WIDTH_0(16), .BIT_WIDTH_1(16)) pixels (
        .DOA(), .DOB(xDout), .DIA(qData), .DIB(16'd0),
        .BLKSELA(3'b000), .BLKSELB(3'b000),
        .ADA({write_bank, write_index, 4'b0011}), .ADB({read_bank, read_index, 4'b0011}),
        .WREA(1'b1), .WREB(1'b0), .CLKA(~QSPI_CLK), .CLKB(xClk),
        .CEA(store), .CEB(fetch), .OCEA(1'b1), .OCEB(1'b1), .RESETA(1'b0), .RESETB(1'b0)
    );
endmodule
