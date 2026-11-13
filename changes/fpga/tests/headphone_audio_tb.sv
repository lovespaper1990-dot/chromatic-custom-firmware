// Standalone test for the FPGA side of the headset PCM transport.
`timescale 1ns/1ps
module headphone_audio_tb;
    reg enabled = 0;
    reg [6:0] wheel = 7'h7f;
    reg sclk = 0, cs = 0, mosi = 0, mclk = 0;
    wire miso, osd_valid, osd_init;
    integer partial_bits;
    reg [15:0] left = 16'h1234, right = 16'hbaad;
    QSPI_Slave dut(.QSPI_CLK(sclk), .QSPI_CS(cs), .QSPI_MOSI(mosi),
        .QSPI_MISO(miso), .QSPI_HD(1'b0), .QSPI_WP(1'b0),
        .AUDIO_ENABLE(enabled), .WHEEL(wheel), .LEFT(left), .RIGHT(right), .AUD_MCLK(mclk),
        .qMenuInit(osd_init), .qDataValid(osd_valid));

    task clocks(input integer n);
        repeat (n) begin #5 sclk = 1; #5 sclk = 0; end
    endtask

    task write_bit(input bit b);
        mosi = b;
        clocks(1);
    endtask

    task read_frame(input [31:0] expected);
        reg [31:0] data;
        integer i;
        for (i = 31; i >= 0; i--) begin
            data[i] = miso;
            clocks(1);
        end
        if (data !== expected) $fatal(1, "PCM expected %h got %h", expected, data);
    endtask

    task start_audio;
        integer i;
        reg [10:0] cmd;
        cmd = 11'h015;
        cs = 0;
        for (i = 10; i >= 0; i--) write_bit(cmd[i]);
        clocks(7);
    endtask

    task read_wheel(input [6:0] position);
        integer i;
        reg [10:0] cmd;
        wheel = position;
        cmd = 11'h016;
        cs = 0;
        for (i = 10; i >= 0; i--) write_bit(cmd[i]);
        clocks(7);
        read_frame({8'h57,1'b0,position,1'b1,~position,8'ha6});
        end_audio();
    endtask

    task end_audio;
        cs = 1;
        #2;
        if (miso !== 1'bz) $fatal(1, "MISO still driven after chip select released");
    endtask

    task capture;
        repeat (191) begin #5 mclk = 1; #5 mclk = 0; end
    endtask

    always @(posedge sclk)
        if (osd_valid || osd_init) $fatal(1, "audio traffic changed OSD state");

    initial begin
        #1 cs = 1; enabled = 1;
        #5;
        start_audio();
        read_frame(0); // underflow
        end_audio();
        capture();
        read_wheel(7'h7f); read_wheel(7'h00); read_wheel(7'h3b);
        left = 16'h5678; right = 16'hcafe; capture();
        start_audio();
        read_frame(32'h3412adba);
        read_frame(32'h7856feca);
        read_frame(0);
        end_audio();
        left = 16'h2468; right = 16'habcd;
        capture();
        for (partial_bits = 0; partial_bits < 32; partial_bits++) begin
            start_audio();
            clocks(partial_bits);
            end_audio();
        end
        start_audio();
        read_frame(32'h6824cdab);
        end_audio();
        capture();
        enabled = 0;
        #10 enabled = 1;
        start_audio();
        read_frame(0); // disconnected audio must not replay on reconnect
        end_audio();
        // If capture is suspended during a live read, discard the remainder
        // even when the master halts QSPI until after wake. A new command
        // must start at the first newly recorded sample.
        left = 16'hffff; right = 16'hffff; capture();
        start_audio(); clocks(11); enabled = 0; #20;
        if (miso !== 0) $fatal(1, "mute leaked an in-flight bit");
        enabled = 1; left = 16'h5555; right = 16'haaaa; capture();
        repeat(64) begin
            clocks(1);
            if (miso !== 0) $fatal(1, "old QSPI transfer survived standby");
        end
        end_audio();
        start_audio(); read_frame(32'h5555aaaa); end_audio();
        $display("PASS standby flush during a stalled QSPI read");
        $display("PASS stereo samples, burst framing, partial-read retry, underflow, OSD isolation and MISO release");
        $finish;
    end
endmodule
