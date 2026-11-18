`timescale 1ns/1ps
module snapshot_bulk_tb #(parameter RAM_CODE = 0);
`ifdef GOWIN_PRIMITIVES
    GSR GSR(.GSRI(1'b1));
`endif
    localparam WORDS = RAM_CODE == 3 ? 10341 : RAM_CODE == 2 ? 7269 : 6309;
    reg clk = 0;
    always #30 clk = ~clk;
    reg reset = 1, supported = 1, command_toggle = 0;
    reg [6:0] command;
    reg [79:0] payload;
    wire reply_toggle;
    wire [79:0] reply;
    reg core_busy = 0, core_req = 0, core_loaded = 0;
    wire capture, restore, active, core_done;
    wire mem_toggle, mem_read;
    wire [13:0] mem_index;
    wire [63:0] mem_out;
    reg ack = 0;
    reg [63:0] mem_in;
    reg [63:0] memory [0:WORDS-1];
    integer writes = 0;
    reg sclk = 0, cs = 1, mosi = 0;
    wire miso, drive, spi_pin, osd_write, osd_data;
    QSPI_Slave shared_spi(
        .QSPI_CLK(sclk), .QSPI_CS(cs), .QSPI_MOSI(mosi), .QSPI_MISO(spi_pin),
        .QSPI_WP(1'b0), .QSPI_HD(1'b0), .AUD_MCLK(clk), .AUDIO_ENABLE(1'b0),
        .WHEEL(7'd0), .LEFT(16'd0), .RIGHT(16'd0),
        .qOsdWrite(osd_write), .qDataValid(osd_data),
        .snapshot_miso(miso), .snapshot_drive(drive)
    );

    snapshot_control #(.BULK(1), .STALL_BITS(14)) dut (
        .clk(clk), .reset(reset), .supported(supported), .identity({16'h1b03,RAM_CODE[7:0],40'd0}),
        .cmd_toggle(command_toggle), .cmd(command), .cmd_data(payload),
        .reply_toggle(reply_toggle), .reply(reply), .capture(capture),
        .restore(restore), .core_busy(core_busy), .core_req(core_req),
        .core_read(1'b0), .core_addr(26'd0), .core_out(64'h0000b0ca00000001),
        .core_done(core_done), .mem_toggle(mem_toggle), .mem_index(mem_index),
        .mem_read(mem_read), .mem_out(mem_out), .mem_ack(ack), .mem_in(mem_in),
        .core_loaded(core_loaded), .active(active), .debug_flags(16'd0),
        .spi_clk(sclk), .spi_cs(cs), .spi_mosi(mosi), .spi_miso(miso), .spi_drive(drive)
    );
    always @(posedge clk) if (mem_toggle != ack) begin
        if (mem_index >= WORDS) $fatal(1, "request outside snapshot");
        if (mem_read) mem_in <= memory[mem_index];
        else begin
            writes <= writes + 1;
            memory[mem_index] <= mem_out;
        end
        ack <= mem_toggle;
    end

    task exchange(input [6:0] op, input [79:0] data, input [79:0] expected);
        reg previous_reply;
        @(negedge clk);
        previous_reply = reply_toggle;
        command = op;
        payload = data;
        command_toggle = ~command_toggle;
        wait (reply_toggle != previous_reply);
        @(negedge clk);
        if (reply !== expected)
            $fatal(1, "op=%h data=%h got %h expected %h", op,data,reply,expected);
    endtask
    task status(input [6:0] address, input [79:0] data, input [7:0] op, input [7:0] result);
        exchange(address, data, {16'hfff0,op,result,48'd0});
    endtask
    task block_cmd(input [6:0] op, input bit upload, input [15:0] start, input [7:0] result);
        status(op,{48'd0,7'd0,upload,start,8'd0},{1'b0,op},result);
    endtask

    function automatic [63:0] pattern(input integer index, input bit loaded);
        if (index == 0) pattern = {32'hb0ca,31'd0,loaded};
        else if (index == 64) pattern = {16'hc507,47'h1234abcd9876,loaded};
        else pattern = 64'h5a00eb0721678ef4 ^ (64'd879633 * 64'(index)) ^ {63'd0,loaded};
    endfunction
    // Independent byte-oriented CRC reference, tested with the canonical vector.
    function automatic [15:0] byte_crc(input [15:0] previous, input [7:0] data);
        reg [15:0] value;
        value = previous ^ {data,8'd0};
        repeat (8) value = (value << 1) ^ ((value & 16'h8000) != 0 ? 16'h1021 : 16'd0);
        return value;
    endfunction

    task spi_bit(input bit value, output logic result);
        mosi = value;
        #12;
        result = spi_pin;
        sclk = 1;
        #13 sclk = 0;
    endtask
    task spi_open(input [10:0] op);
        logic dummy;
        #1000;
        cs = 0;
        for (integer i = 10; i >= 0; i--) begin
            spi_bit(op[i], dummy);
            if (dummy !== 1'bz) $fatal(1, "snapshot drove MISO during command");
        end
        repeat (7) spi_bit(0,dummy);
    endtask
    task test_osd_header(input [10:0] op, input [31:0] addr, input bit accepted);
        logic ignored;
        cs = 0;
        for (integer i = 10; i >= 0; i--) spi_bit(op[i], ignored);
        for (integer i = 31; i >= 0; i--) spi_bit(addr[i], ignored);
        repeat (9) begin
            spi_bit(0, ignored);
            if (osd_write !== accepted || (!accepted && osd_data))
                $fatal(1, "OSD header classification op=%h addr=%h",op,addr);
        end
        cs = 1;
        #45;
    endtask
    task spi_close;
        #15 cs = 1;
        #25;
        if (drive !== 0) $fatal(1, "MISO driven outside transaction");
        if (osd_write || osd_data) $fatal(1, "snapshot received as OSD data");
    endtask
    task spi_read_block(input integer start, input integer count);
        logic value;
        reg [63:0] actual, expected;
        reg [15:0] crc, received;
        crc = 16'hffff;
        spi_open(11'h17);
        for (integer w = 0; w < count; w++) begin
            for (integer b = 63; b >= 0; b--) begin
                spi_bit(0,value);
                actual[b] = value;
            end
            expected = memory[start+w];
            if (actual !== expected) $fatal(1,"block read start=%0d offset=%0d got %h expected %h",start,w,actual,expected);
            for (integer b = 7; b >= 0; b--) crc = byte_crc(crc,expected[b*8+:8]);
        end
        for (integer b = 15; b >= 0; b--) begin
            spi_bit(0,value);
            received[b] = value;
        end
        if (received !== crc) $fatal(1,"SPI CRC read mismatch %h %h",received,crc);
        spi_close();
    endtask
    task spi_write_block(input integer start, input integer count, input logic [2:0] fault);
        logic unused;
        reg [63:0] value;
        reg [15:0] crc;
        crc = 16'hffff;
        spi_open(11'h18);
        for (integer w = 0; w < count; w++) begin
            if (fault == 4 && w == 5) begin
                // Revoke and rearm with CS low and the old SPI clock stopped.
                @(negedge clk); supported = 0;
                repeat (8) @(negedge clk);
                supported = 1;
                block_cmd('h23,1,start,0);
            end
            value = pattern(start+w,1);
            if (fault == 3 && w == 0) value[32] = ~value[32];
            for (integer b = 63; b >= 0; b--) begin
                spi_bit(value[b], unused);
                if (unused !== 1'bz) $fatal(1, "snapshot drove MISO during upload");
            end
            for (integer b = 7; b >= 0; b--) crc = byte_crc(crc,value[b*8+:8]);
        end
        if (fault != 1)
            for (integer b = 15; b >= 0; b--) spi_bit(crc[b] ^ (fault == 2 && b == 0), unused);
        spi_close();
    endtask

    integer length;
    initial begin
        logic unused;
        reg [15:0] check_crc;
        check_crc = 16'hffff;
        for (integer i = 49; i <= 57; i++) check_crc = byte_crc(check_crc,i[7:0]);
        if (check_crc !== 16'h29b1) $fatal(1,"bad CRC reference");
        for (integer i = 0; i < WORDS; i++) memory[i] = pattern(i,0);
        // Model a real inactive bus that has already seen a CS reset.
        #5 cs = 0;
        #5 cs = 1;
        repeat (4) @(negedge clk); reset = 0;
        test_osd_header(11'h417,32'h0,0); // corrupted snapshot command
        test_osd_header(11'h7ff,32'h40000,0); // outside OSD framebuffer
        test_osd_header(11'h7ff,32'd1024*44,1); // final real OSD row
        exchange('h20,5,{16'hfff3,32'h424c4b31,32'd0});
        block_cmd('h23,0,0,4);
        block_cmd('h23,1,1,3);
        block_cmd('h23,1,16'((WORDS+127)&~127),3);
        fork
            status('h20,1,1,1);
            begin
                wait(capture);
                @(negedge clk); core_busy = 1; core_req = 1;
                @(negedge clk); core_req = 0;
                wait(core_done);
                @(negedge clk); core_busy = 0;
            end
        join
        repeat (4) @(negedge clk);
        status('h20,0,0,0);

        for (integer start = 0; start < WORDS; start += 128) begin
            length = WORDS-start < 128 ? WORDS-start : 128;
            block_cmd('h23,0,start,0);
            spi_read_block(start,length);
        end
        // Uncommitted or corrupted SPI must never stage a restore.
        for (integer fault = 1; fault <= 4; fault++) begin
            block_cmd('h23,1,0,0);
            spi_write_block(0,128,fault[2:0]);
            block_cmd('h24,1,0,4);
            status('h20,2,2,4);
        end
        if (writes != 1) $fatal(1,"invalid blocks changed PSRAM");
        block_cmd('h23,1,0,0);
        spi_write_block(0,128,0);
        // A bad replay after a valid upload must leave the sealed bytes intact.
        spi_write_block(0,128,3);
        block_cmd('h24,1,0,0);
        status('h20,2,2,4);
        block_cmd('h23,1,256,4);
        for (integer start = 128; start < WORDS; start += 128) begin
            length = WORDS-start < 128 ? WORDS-start : 128;
            block_cmd('h23,1,start,0);
            spi_write_block(start,length,0);
            block_cmd('h24,1,start,0);
        end
        if (writes != WORDS+1) $fatal(1,"expected one write per word, got %0d",writes);
        for (integer i = 0; i < WORDS; i++)
            if (memory[i] !== pattern(i,1))
                $fatal(1,"upload word %0d got %h expected %h",i,memory[i],pattern(i,1));
        fork
            status('h20,2,2,1);
            begin
                wait(restore);
                @(negedge clk); core_busy = 1;
                repeat (3) @(negedge clk);
                core_loaded = 1; core_busy = 0;
                @(negedge clk); core_loaded = 0;
            end
        join
        repeat (4) @(negedge clk);
        status('h20,0,0,0);

        block_cmd('h23,1,0,0);
        spi_write_block(0,128,0);
        @(negedge clk); supported = 0;
        repeat (8) @(negedge clk);
        supported = 1;
        block_cmd('h24,1,0,4);
        status('h20,2,2,4);
        $display("PASS: SPI bulk %0d words each way, partial final block, CRC/truncation/replay/ejection protection, full restore gate",WORDS);
        $finish;
    end
    initial begin #100000000; $fatal(1,"bulk watchdog"); end
endmodule

`ifndef GOWIN_PRIMITIVES
// Behavioral DPB subset for portable regressions. The same end-to-end test
// can also run with Gowin's library by defining GOWIN_PRIMITIVES.
module DPB #(parameter BIT_WIDTH_0=16, parameter BIT_WIDTH_1=16) (
    output reg [15:0] DOA, DOB, input [15:0] DIA, DIB,
    input [2:0] BLKSELA, BLKSELB, input [13:0] ADA, ADB,
    input WREA, WREB, CLKA, CLKB, CEA, CEB, OCEA, OCEB, RESETA, RESETB
);
    reg [15:0] mem [0:1023];
    always @(posedge CLKA) if (CEA) begin
        if (WREA) begin
            if (ADA[0]) mem[ADA[13:4]][7:0] <= DIA[7:0];
            if (ADA[1]) mem[ADA[13:4]][15:8] <= DIA[15:8];
        end else DOA <= mem[ADA[13:4]];
    end
    always @(posedge CLKB) if (CEB) begin
        if (WREB) begin
            if (ADB[0]) mem[ADB[13:4]][7:0] <= DIB[7:0];
            if (ADB[1]) mem[ADB[13:4]][15:8] <= DIB[15:8];
        end else DOB <= mem[ADB[13:4]];
    end
endmodule
`endif
