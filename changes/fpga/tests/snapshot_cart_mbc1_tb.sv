`timescale 1ns/1ps
// Synthetic ROMs only. Expected CRCs were independently calculated with zlib.
// MBC1M compares the complete raw low register against zero before discarding
// bit 4: writing $10 selects physical bank zero rather than bank one.
module snapshot_cart_mbc1_tb #(parameter ROM_CODE=6, RAM_CODE=2, MAPPER=3,
                                        MBC1M=0, ALIAS_LOGO=0);
    localparam ROM_BANKS = 2 << ROM_CODE;
    localparam REJECT_ALIAS = MBC1M || ALIAS_LOGO;
    localparam TOTAL_READS = REJECT_ALIAS ? 16*16384+'h134 : ROM_BANKS*16384;
    localparam LAST_TARGET = REJECT_ALIAS ? 16 : ROM_BANKS-1;
    function [31:0] expected_crc;
        begin
            expected_crc=0;
            if (MAPPER==1 && ROM_CODE==0 && RAM_CODE==0 && !REJECT_ALIAS) expected_crc=32'he56351ff;
            if (MAPPER==1 && ROM_CODE==1 && RAM_CODE==0 && !REJECT_ALIAS) expected_crc=32'hfd0c3aff;
            if (MAPPER==1 && ROM_CODE==3 && RAM_CODE==0 && !REJECT_ALIAS) expected_crc=32'h22533760;
            if (MAPPER==2 && ROM_CODE==3 && RAM_CODE==0 && !REJECT_ALIAS) expected_crc=32'h91fb7241;
            if (MAPPER==3 && ROM_CODE==4 && RAM_CODE==3 && !REJECT_ALIAS) expected_crc=32'hd9b14941;
            if (MAPPER==3 && ROM_CODE==5 && RAM_CODE==2 && !REJECT_ALIAS) expected_crc=32'h5c561d83;
            if (MAPPER==3 && ROM_CODE==6 && RAM_CODE==2 && !REJECT_ALIAS) expected_crc=32'hbcdbf49c;
            if (MAPPER==3 && ROM_CODE==5 && RAM_CODE==2 && MBC1M && !ALIAS_LOGO) expected_crc=32'h6f78b032;
            if (MAPPER==3 && ROM_CODE==5 && RAM_CODE==2 && !MBC1M && ALIAS_LOGO) expected_crc=32'h835c357f;
        end
    endfunction
    localparam [31:0] EXPECTED_CRC = expected_crc();
    reg clk=0, ready=0;
    always #5 clk=~clk;
    reg [4:0] low_bank=0;
    reg [1:0] high_bank=0;
    reg mode=0;
    reg physical_mbc1m=MBC1M, physical_alias_logo=ALIAS_LOGO;
    integer negative_mode=0;
    wire [14:0] address;
    wire read_n,write_n,writing,complete,supported;
    wire [7:0] write_data;
    wire [63:0] identity;
    wire [4:0] translated_low = low_bank==0 ? 5'd1 : low_bank;
    wire [6:0] upper_bank = physical_mbc1m ? {1'b0,high_bank,translated_low[3:0]} :
                                                  {high_bank,translated_low};
    wire [6:0] lower_bank = !mode ? 7'd0 : physical_mbc1m ? {1'b0,high_bank,4'd0} :
                                                               {high_bank,5'd0};
    wire [7:0] test_last_target = physical_mbc1m || physical_alias_logo ? 16 : ROM_BANKS-1;
    wire [6:0] read_bank = (address[14] ? upper_bank : lower_bank) & (ROM_BANKS-1);
    wire [7:0] header_mapper = negative_mode==2 || negative_mode==4 ? 1 :
                              negative_mode==6 ? 8'h10 : MAPPER;
    wire [7:0] header_rom = negative_mode==1 ? 6 : negative_mode==3 ? 4 :
                           negative_mode==4 ? 7 : ROM_CODE;
    wire [7:0] header_ram = negative_mode==1 ? 3 : negative_mode==2 ? 2 :
                           negative_mode==3 ? 1 : negative_mode==4 ? 0 : RAM_CODE;
    wire [7:0] header = 8'h7d-header_mapper-header_rom-header_ram+(negative_mode==5);
    function [7:0] rom_byte(input integer bank, input integer offset);
        integer source_bank;
        begin
            source_bank = physical_alias_logo && bank==16 && offset>='h104 && offset<='h133 ? 0 : bank;
            rom_byte = offset ^ (offset>>8) ^ (source_bank*37) ^
                       (source_bank>>8) ^ ((offset*source_bank)>>3);
            if (source_bank==0) case(offset)
                'h147: rom_byte=header_mapper;
                'h148: rom_byte=header_rom;
                'h149: rom_byte=header_ram;
                'h14d: rom_byte=header;
            endcase
        end
    endfunction
    wire [7:0] data = rom_byte(read_bank,address[13:0]);
    snapshot_cart dut(clk,ready,data,address,read_n,complete,supported,identity,
                      write_n,write_data,writing);
    integer cycles=0,reads=0,writes=0,read_cycle,write_cycle;
    integer target,part,expected_bank;
    integer bank20_reads=0,bank40_reads=0,bank60_reads=0;
    reg [14:0] held_address;
    reg [7:0] held_data;
    always @(posedge clk) cycles=cycles+1;
    always @(negedge read_n) if(ready) begin
        if (complete || !write_n || writing) $fatal(1,"Unsafe MBC1 ROM read");
        if (cycles!=2+reads*16+(reads>=32768 ? (reads/16384-1)*48 : 0))
            $fatal(1,"MBC1 read timing changed at byte %0d",reads);
        read_cycle=cycles;
        if (!negative_mode) begin
            target=reads/16384;
            expected_bank=physical_mbc1m && target==16 ? 0 : target;
            if (read_bank!==expected_bank || address[13:0]!==reads%16384)
                $fatal(1,"MBC1 skipped/aliased byte %0d: physical bank %0d address %h",reads,read_bank,address);
            if (target>=2) begin
                if (target==16 && physical_mbc1m && (low_bank!=5'h10 || high_bank || mode || read_bank!=0))
                    $fatal(1,"MBC1M raw $10 must map bank zero, not bank one");
                if (target%32==0) begin
                    if (address[14] || !mode || high_bank!=target/32)
                        $fatal(1,"Forbidden upper-window bank %h was not read through mode1",target);
                end else if (!address[14] || mode)
                    $fatal(1,"Ordinary MBC1 bank was not read in mode0 upper window");
            end
            if (target=='h20) bank20_reads=bank20_reads+1;
            if (target=='h40) bank40_reads=bank40_reads+1;
            if (target=='h60) bank60_reads=bank60_reads+1;
        end
    end
    always @(posedge read_n) if(ready && !writing && !complete) begin
        if(cycles-read_cycle!=12) $fatal(1,"MBC1 /RD width changed");
        reads=reads+1;
    end
    always @(negedge write_n) if(ready) begin
        if (negative_mode || !writing || !read_n || complete) $fatal(1,"Unsafe MBC1 register write");
        part=writes%3;
        target=writes/3 < test_last_target-1 ? writes/3+2 : 1;
        if(address!=(part==0 ? 'h2000 : part==1 ? 'h4000 : 'h6000))
            $fatal(1,"MBC1 register order changed");
        if(write_data!=(part==0 ? target%32 : part==1 ? target/32 : target%32==0))
            $fatal(1,"Incorrect MBC1 bank register data for target %h",target);
        write_cycle=cycles; held_address=address; held_data=write_data;
    end
    always @(posedge write_n) if(ready && writing) begin
        if(cycles-write_cycle!=8 || address!==held_address || write_data!==held_data || !read_n)
            $fatal(1,"MBC1 register bus changed before write release");
        case(address)
            'h2000: low_bank=write_data[4:0];
            'h4000: high_bank=write_data[1:0];
            'h6000: mode=write_data[0];
            default: $fatal(1,"MBC1 probe wrote outside mapper registers");
        endcase
        writes=writes+1;
    end
    task restart;
        @(negedge clk); ready=0;
        repeat(3) @(negedge clk);
        low_bank=0;high_bank=0;mode=0;reads=0;writes=0;cycles=0;
        bank20_reads=0;bank40_reads=0;bank60_reads=0;ready=1;
        if(complete || supported || !read_n || !write_n) $fatal(1,"Stale hotplug identity or bus activity");
    endtask
    initial begin
        if(!EXPECTED_CRC) $fatal(1,"No independent zlib fixture for this parameter set");
        restart(); wait(reads==20); restart();
        if(ROM_CODE>=5 && !REJECT_ALIAS) begin
            // Eject while bank $20 is visible in the low ROM window. A new
            // cartridge must not inherit mode1, a partial CRC or its identity.
            wait(reads==32*16384+20);
            @(negedge clk);ready=0;#1;
            if(!read_n || !write_n || writing || supported)
                $fatal(1,"Mode1 hotplug left the cartridge bus active");
            restart();
        end
        wait(complete); #1;
        if(supported!==!REJECT_ALIAS || reads!=TOTAL_READS || writes!=3*LAST_TARGET ||
           identity!=={MAPPER[7:0],ROM_CODE[7:0],RAM_CODE[7:0],header,EXPECTED_CRC})
            $fatal(1,"Bad MBC1 identity %h reads=%0d writes=%0d supported=%b",identity,reads,writes,supported);
        if(cycles!=TOTAL_READS*16+LAST_TARGET*48 || low_bank!=1 || high_bank || mode)
            $fatal(1,"MBC1 completion did not restore bank1/high0/mode0");
        if(!REJECT_ALIAS && ROM_CODE>=5 && bank20_reads!=16384) $fatal(1,"Missing physical bank $20");
        if(!REJECT_ALIAS && ROM_CODE==6 && (bank40_reads!=16384 || bank60_reads!=16384))
            $fatal(1,"Missing physical banks $40/$60");
        repeat(8) @(negedge clk);
        if(!read_n || !write_n) $fatal(1,"Ghost bus access after completion");
        if(REJECT_ALIAS) begin
            // Swap the rejected cartridge for a standard MBC1 with the same
            // header geometry. No rejection flag, hash or CRC may survive.
            physical_mbc1m=0;physical_alias_logo=0;restart();wait(complete);#1;
            if(!supported || reads!=ROM_BANKS*16384 || writes!=3*(ROM_BANKS-1) ||
               identity[31:0]!==32'h5c561d83 || low_bank!=1 || high_bank || mode)
                $fatal(1,"Rejected MBC1M poisoned the next standard cartridge");
        end
        // Every rejected header must finish quickly without touching mapper
        // registers, even after a previously completed or rejected cartridge.
        for(negative_mode=1;negative_mode<=6;negative_mode=negative_mode+1) begin
            restart(); wait(complete); #1;
            if(supported || reads!=334 || writes || cycles!=334*16+3)
                $fatal(1,"Invalid MBC1 geometry/header was admitted (%0d)",negative_mode);
        end
        negative_mode=0;restart();wait(!write_n);@(negedge clk);ready=0;#1;
        if(!read_n || !write_n || writing || supported) $fatal(1,"MBC1 ejection left bus active");
        @(negedge clk);if(complete) $fatal(1,"MBC1 ejection retained identity");
        $display("PASS MBC1 ROM=%0d RAM=%0d mapper=%0d MBC1M=%0d alias=%0d: zlib CRC, raw-zero translation, $20/$40/$60 windows, exact bus timing, safe rejection/hotplug",ROM_CODE,RAM_CODE,MAPPER,MBC1M,ALIAS_LOGO);
        $finish;
    end
    // The final ejection test starts another 32 KiB pass before its first
    // register write, including for a cartridge whose entire ROM is 32 KiB.
    initial begin #(ROM_BANKS*16384*300+10000000);$fatal(1,"MBC1 scanner timeout");end
endmodule
