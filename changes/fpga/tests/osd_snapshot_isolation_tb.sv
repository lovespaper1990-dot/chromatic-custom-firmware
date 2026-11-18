`timescale 1ns/1ps
module osd_snapshot_isolation_tb;
`ifdef GOWIN_PRIMITIVES
    GSR GSR(.GSRI(1'b1));
`endif
    reg xclk=0, sclk=0, cs=1, reset=1, advance=0, done=0, ram_ready=1;
    always #7.45 xclk=~xclk;
    reg [3:0] pins=0;
    reg quad=0;
    wire miso;
    assign miso = quad ? pins[1] : 1'bz;
    wire [31:0] address;
    wire [15:0] word_in, word_out;
    wire valid, osd, request;
    wire [22:0] destination;
    QSPI_Slave spi(.QSPI_CLK(sclk), .QSPI_CS(cs), .QSPI_MOSI(pins[0]),
        .QSPI_MISO(miso), .QSPI_WP(pins[2]), .QSPI_HD(pins[3]),
        .AUD_MCLK(xclk), .AUDIO_ENABLE(1'b0), .WHEEL(7'd0), .LEFT(16'd0), .RIGHT(16'd0),
        .qAddress(address), .qDataValid(valid), .qOsdWrite(osd), .qData(word_in),
        .snapshot_miso(1'b0), .snapshot_drive(1'b0));
    mm_burst_write writer(.QSPI_CLK(sclk), .QSPI_CS(cs), .reset(reset),
        .qAddress(address), .qDataValid(valid), .qOsdWrite(osd), .qData(word_in),
        .xClk(xclk), .xRdEn(advance), .xRamReady(ram_ready), .xDone(done),
        .xMcuReqWrite(request), .xDout(word_out), .xAddress(destination));

    integer requests=0;
    always @(posedge xclk) if (request) requests<=requests+1;

    function automatic [15:0] pixel(input integer seed, input integer i);
        return 16'(seed*3037+i*8837);
    endfunction
    task tick(input [3:0] data);
        pins=data; #12.5; sclk=1; #12.5; sclk=0;
    endtask
    task header(input [10:0] command, input [31:0] arg, input bit interrupt_header=0);
        cs=0; quad=0;
        for(integer b=10;b>=0;b--) begin
            tick({3'd0,command[b]});
            if(interrupt_header && b==7) begin
                // Shorter than SCLK or xClk, with SCLK stopped and CS low.
                #64 reset=1; #7.45 reset=0; #300;
            end
        end
        for(integer b=31;b>=0;b--) tick({3'd0,arg[b]});
    endtask
    task close_frame;
        #4 cs=1;
        quad=0;
        #48;
    endtask
    task send_row(input integer row, input integer count, input integer seed, input bit interrupt_header=0);
        reg [15:0] p;
        header(11'h7ff,row*1024,interrupt_header);
        repeat(3) tick(0);
        quad=1;
        for(integer i=0;i<count;i++) begin
            p=pixel(seed,i);
            tick(p[7:4]); tick(p[3:0]); tick(p[15:12]); tick(p[11:8]);
        end
        close_frame();
    endtask
    task check_first(input integer row, input integer seed);
        if(destination !== row*1024 || word_out !== pixel(seed,0))
            $fatal(1,"first OSD beat addr=%h want row=%0d data=%h want %h",
                   destination,row,word_out,pixel(seed,0));
    endtask
    task drain(input integer row, input integer seed);
        @(negedge xclk);
        check_first(row,seed);
        for(integer i=1;i<512;i++) begin
            advance=1;
            @(negedge xclk);
            if(word_out !== pixel(seed,i) || destination !== row*1024)
                $fatal(1,"queued row %0d beat %0d got %h addr %h",row,i,word_out,destination);
        end
        advance=0; done=1;
        @(negedge xclk); done=0;
    endtask

    initial begin
        #10 cs=0; #10 cs=1; #100 reset=0;
        send_row(2,511,12);
        if(requests != 0) $fatal(1,"published truncated row");
        send_row(1,512,19);
        wait(requests==1);
        // Hold the grant off. A subsequent snapshot upload temporarily places
        // a real snapshot address in the shared receiver's command shifter.
        header(11'h018,32'h00040000);
        if(address !== 32'h40000) $fatal(1,"stimulus missed snapshot region");
        check_first(1,19);
        close_frame();
        send_row(44,512,23);
        check_first(1,19);
        if(requests != 1) $fatal(1,"second request overlapped the first");
        // Both banks are full at the start. Free one midway through this
        // third row: the suffix still must not be mistaken for a new row.
        fork
            send_row(7,512,29);
            begin #12000; drain(1,19); end
        join
        if(requests != 2) $fatal(1,"second buffered row lost");
        drain(44,23);
        repeat(10) @(negedge xclk);
        if(requests != 2) $fatal(1,"third row was admitted while full");

        // Sustain a normal refresh: service the previous bank in parallel
        // with receiving the next, covering every legal row including 0/44.
        fork
            begin
                for(integer r=0;r<45;r++) send_row(r,512,100+r);
            end
            begin
                for(integer r=0;r<45;r++) begin
                    wait(requests==3+r); drain(r,100+r);
                end
            end
        join

        // Reset midway through a partial subsequent frame with data queued.
        ram_ready=0;
        send_row(5,512,92);
        fork
            send_row(20,512,51);
            begin #8000; reset=1; #7.45; reset=0; end
        join
        ram_ready=1;
        repeat(12) @(negedge xclk);
        if(requests != 47) $fatal(1,"published pre-reset or truncated row");
        send_row(21,512,88,1);
        repeat(12) @(negedge xclk);
        if(requests != 47) $fatal(1,"published an old frame restarted after reset");
        send_row(4,512,98);
        wait(requests==48); drain(4,98);
        $display("PASS: real OSD QSPI, snapshot address isolation, two delayed rows, overflow/truncation/reset recovery and all 45 normal rows");
        $finish;
    end
    initial begin #5000000; $fatal(1,"OSD regression watchdog, requests=%0d",requests); end
endmodule
