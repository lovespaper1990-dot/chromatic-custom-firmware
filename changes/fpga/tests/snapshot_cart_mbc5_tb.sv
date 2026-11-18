`timescale 1ns/1ps
// ROM_CODE=8 exercises all 512 ROM banks, including the ninth bank bit.
// Expected hashes were calculated independently with zlib over logical ROM
// order. No game ROM is used or retained by this test.
module snapshot_cart_mbc5_tb #(parameter ROM_CODE=3, parameter ROM_ONLY=0, parameter START_BANK=1);
    localparam ROM_BYTES = ROM_ONLY ? 32768 : 32768 << ROM_CODE;
    localparam [7:0] ROM_SIZE = ROM_ONLY ? 0 : ROM_CODE;
    localparam [31:0] EXPECTED_CRC = ROM_ONLY ? 32'h326465e6 : ROM_CODE == 8 ? 32'h85bb0839 :
                                         ROM_CODE == 3 ? 32'hc39827b4 : 32'h00d6cfee;
    localparam [7:0] HEADER = ROM_ONLY ? 8'h7d : ROM_CODE == 8 ? 8'h57 : ROM_CODE == 3 ? 8'h5c : 8'h5f;
    reg clk=0,ready=0,unsupported=0;
    always #5 clk=~clk;
    wire [14:0] address;
    wire read_n,write_n,writing,complete,supported;
    wire [7:0] write_data;
    wire [63:0] identity;
    reg [8:0] selected_bank=START_BANK;
    wire [8:0] read_bank = address[14] ? selected_bank : 9'd0;
    reg [7:0] data;
    always_comb begin
        data = address[13:0] ^ (address[13:0] >> 8) ^ (read_bank*37) ^ (read_bank>>8);
        if (read_bank==0) begin
            case (address)
                'h147: data=unsupported ? 8'h10 : ROM_ONLY ? 8'h00 : 8'h1b;
                'h148: data=ROM_SIZE;
                'h149: data=ROM_ONLY ? 0 : 3;
                'h14d: data=unsupported ? HEADER+11 : HEADER;
            endcase
        end
    end
    snapshot_cart dut(clk,ready,data,address,read_n,complete,supported,identity,
                      write_n,write_data,writing);
    integer reads=0,writes=0,bank256_reads=0;
    wire [31:0] logical_reads = !ROM_ONLY && !unsupported && reads>=334 ? reads-334 : reads;
    // Assert physical bus timing independently of the scanner's CRC pipeline.
    integer cycles=0, read_cycle=0, write_cycle=0;
    always @(posedge clk) cycles=cycles+1;
    reg [14:0] previous_address;
    reg [7:0] previous_data;
    always @(negedge read_n) if (ready) begin
        if (cycles != 2+reads*16+(!ROM_ONLY && !unsupported && reads>=334 ? 32 : 0)+
                      (logical_reads>=32768 ? (logical_reads/16384-1)*32 : 0))
            $fatal(1,"ROM read edge moved: byte %0d cycle %0d",reads,cycles);
        read_cycle=cycles;
        if (!write_n || writing) $fatal(1,"ROM bus contention");
        if (!unsupported) begin
            if (read_bank !== logical_reads/16384 || address[13:0] !== logical_reads%16384)
                $fatal(1,"Skipped/duplicate ROM byte %0d at bank %0d address %h",reads,read_bank,address);
            if (read_bank==256) bank256_reads=bank256_reads+1;
        end
    end
    always @(posedge read_n) if (ready && !writing && !complete) begin
        if (cycles-read_cycle!=12) $fatal(1,"ROM /RD width moved");
        reads=reads+1;
    end
    always @(negedge write_n) if (ready) begin
        if (!writing || !read_n || (address!='h2000 && address!='h3000))
            $fatal(1,"Unsafe bank write");
        write_cycle=cycles;
        previous_address=address;
        previous_data=write_data;
    end
    always @(posedge write_n) if (ready && writing) begin
        if (cycles-write_cycle!=8) $fatal(1,"ROM /WR width moved");
        if (address!==previous_address || write_data!==previous_data || !read_n)
            $fatal(1,"Bank write lost data/address before strobe release");
        if (address=='h2000) selected_bank[7:0]=write_data;
        else selected_bank[8]=write_data[0];
        writes=writes+1;
    end
    task restart;
        @(negedge clk); ready=0;
        repeat(3) @(negedge clk);
        selected_bank=START_BANK; reads=0; writes=0; bank256_reads=0; cycles=0; ready=1;
    endtask
    initial begin
        restart();
        wait(reads==20);
        restart(); // An incomplete identity must never survive a reset.
        if (complete || supported || !write_n || !read_n) $fatal(1,"Reset retained identity/bus activity");
        wait(complete); #1;
        if (cycles!=(ROM_BYTES+(ROM_ONLY ? 0 : 334))*16+(ROM_ONLY ? 3 : (ROM_BYTES/16384)*32))
            $fatal(1,"Scan complete cycle moved: %0d",cycles);
        if (!supported || reads!=ROM_BYTES+(ROM_ONLY ? 0 : 334) || identity!={(ROM_ONLY ? 8'h00 : 8'h1b),ROM_SIZE,(ROM_ONLY ? 8'd0 : 8'd3),HEADER,EXPECTED_CRC})
            $fatal(1,"Bad full-ROM identity %h (%0d reads)",identity,reads);
        if (selected_bank!=1 || writes!=(ROM_ONLY ? 0 : 2*(ROM_BYTES/16384)))
            $fatal(1,"Boot ROM bank not restored (%0d writes, bank %0d)",writes,selected_bank);
        if (ROM_CODE==8 && bank256_reads!=16384) $fatal(1,"Ninth ROM bank bit was not exercised");
        unsupported=1;
        restart(); wait(complete); #1;
        if (cycles!=334*16+3) $fatal(1,"Unsupported CRC tail length %0d",cycles);
        if (supported || writes || reads!=334) $fatal(1,"Unsupported cartridge scanned or banked");
        unsupported=0;
        restart();
        if (ROM_ONLY) wait(!read_n); else wait(!write_n);
        @(negedge clk); ready=0; #1;
        if (!write_n || writing || !read_n || supported) $fatal(1,"Ejected cartridge bus remained active");
        @(negedge clk);
        if (complete) $fatal(1,"Ejected identity survived reset");
        $display("PASS %s %0d-byte full ROM CRC from arbitrary initial bank, exact bus timing, bank restoration, reset/ejection and unsupported header",ROM_ONLY ? "ROM-only" : "MBC5",ROM_BYTES);
        $finish;
    end
    initial begin #(ROM_BYTES*200); $fatal(1,"Scanner timeout"); end
endmodule
