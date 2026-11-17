`timescale 1ns/1ps
module snapshot_mbc5_tb;
    reg clk=0, reset=1, enabled=1, active=0, abort_state=0, restart_core=0;
    reg [7:0] ram_code=3;
    reg core_req=0, core_read=0;
    reg [25:0] core_addr;
    reg [63:0] core_out;
    wire core_done;
    wire [63:0] core_in;
    wire mem_req, mem_read;
    wire [25:0] mem_addr;
    wire [63:0] mem_out;
    reg mem_done=0;
    reg [63:0] mem_in;
    reg [15:0] game_addr=0;
    reg [7:0] game_out=0;
    reg game_write_n=1;
    wire take_bus;
    wire [15:0] bus_addr;
    wire [7:0] bus_out;
    wire bus_read_n,bus_write_n,bus_cs_n,bus_input_dir;
    wire [15:0] physical_addr=take_bus ? bus_addr : game_addr;
    wire [7:0] physical_out=take_bus ? bus_out : game_out;
    wire physical_write_n=take_bus ? bus_write_n : game_write_n;
    reg [8:0] rom_bank=1;
    reg [3:0] ram_bank=0;
    reg ram_enable=0;
    reg [7:0] ram[0:32767];
    reg [63:0] slot[0:10340];
    wire [14:0] ram_address={ram_bank[1:0],bus_addr[12:0]};
    wire [7:0] cart_in=!bus_read_n && !bus_cs_n && ram_enable && bus_input_dir ? ram[ram_address] : 8'hxx;
    integer writes=0, mapper_writes=0;
    always #5 clk=~clk;
    snapshot_mbc5 dut(.clk(clk),.reset(reset),.enabled(enabled),.ram_code(ram_code),
        .active(active),.abort(abort_state),.restart_core(restart_core),.core_req(core_req),.core_read(core_read),
        .core_addr(core_addr),.core_out(core_out),.core_done(core_done),.core_in(core_in),
        .mem_req(mem_req),.mem_read(mem_read),.mem_addr(mem_addr),.mem_out(mem_out),
        .mem_done(mem_done),.mem_in(mem_in),.game_addr(game_addr),.game_out(game_out),
        .game_write_n(game_write_n),.cart_in(cart_in),.take_bus(take_bus),
        .cart_addr(bus_addr),.cart_out(bus_out),.cart_read_n(bus_read_n),
        .cart_write_n(bus_write_n),.cart_cs_n(bus_cs_n),.cart_input_dir(bus_input_dir));

    always @(posedge physical_write_n) if (!reset) begin
        if (physical_addr<16'h2000) ram_enable=physical_out[3:0]==10;
        else if (physical_addr<16'h3000) rom_bank[7:0]=physical_out;
        else if (physical_addr<16'h4000) rom_bank[8]=physical_out[0];
        else if (physical_addr<16'h6000) ram_bank=physical_out[3:0];
        if (physical_addr<16'h6000) mapper_writes=mapper_writes+1;
        if (physical_addr>=16'ha000 && physical_addr<16'hc000) begin
            if (!take_bus || bus_input_dir || !bus_read_n || bus_cs_n || !ram_enable)
                $fatal(1,"invalid physical RAM write at %h ownership=%b dir=%b rd=%b cs=%b en=%b phase=%d",physical_addr,take_bus,bus_input_dir,bus_read_n,bus_cs_n,ram_enable,dut.bus.phase);
            ram[ram_address]=physical_out;
            writes=writes+1;
        end
    end
    reg pending=0, delayed_read, suppress_ack=0;
    reg [63:0] delayed_data;
    integer delayed_index, delay_cycles;
    always @(posedge clk) begin
        mem_done<=0;
        if (mem_req) begin
            if (pending) $fatal(1,"overlapping memory request");
            if (mem_addr<26'h3800000 || mem_addr>=26'h3800000+2*10341 || mem_addr[0])
                $fatal(1,"invalid snapshot word address");
            delayed_index=(mem_addr-26'h3800000)/2;
            delayed_read=mem_read;
            delayed_data=mem_out;
            delay_cycles=delayed_index%7+2;
            pending=1;
        end else if (pending) begin
            if (delay_cycles>0) delay_cycles=delay_cycles-1;
            else begin
                if (delayed_read) mem_in<=slot[delayed_index];
                else slot[delayed_index]<=delayed_data;
                if (!suppress_ack) mem_done<=1;
                pending=0;
            end
        end
    end
    function [7:0] pattern(input integer i);
        pattern=i^(i>>8)^((i>>13)*37);
    endfunction
    task mapper_write(input [15:0] a,input [7:0] value);
        @(negedge clk); game_addr=a; game_out=value; game_write_n=0;
        repeat(8) @(negedge clk); game_write_n=1;
        repeat(3) @(negedge clk);
    endtask
    task transfer(input integer index,input bit read_op,input [63:0] value);
        @(negedge clk); core_addr=26'h3800000+index*2;
        core_read=read_op; core_out=value; core_req=1;
        @(negedge clk); core_req=0;
        wait(core_done); @(negedge clk);
        if(read_op && core_in!==slot[index]) $fatal(1,"wrong restore word %0d",index);
    endtask
    task begin_session;
        @(negedge clk); active=0; repeat(3) @(negedge clk);
        active=1; repeat(3) @(negedge clk);
    endtask
    task expect_mapper(input [15:0] expected);
        if({ram_enable,2'b0,ram_bank,rom_bank}!==expected || dut.current_mapper!==expected)
            $fatal(1,"physical/mirrored mapper %h/%h expected %h",{ram_enable,2'b0,ram_bank,rom_bank},dut.current_mapper,expected);
    endtask
    integer i,j,old_writes;
    initial begin
        for(i=0;i<32768;i=i+1) ram[i]=pattern(i);
        repeat(4) @(negedge clk); reset=0;
        mapper_write(16'h2000,8'h8e); mapper_write(16'h3000,1);
        mapper_write(16'h4000,3); mapper_write(16'h0000,0);
        expect_mapper(16'h078e);
        begin_session();
        if(take_bus) $fatal(1,"cart stolen while waiting for VBlank");
        transfer(33,0,64'h1234000000000000);
        if(slot[33]!==64'h123400000000078e) $fatal(1,"mapper state absent from capture");
        for(i=6245;i<10341;i=i+1) begin
            transfer(i,0,0);
            for(j=0;j<8;j=j+1)
                if(slot[i][j*8+:8]!==pattern((i-6245)*8+j)) $fatal(1,"capture omitted RAM bank or byte");
        end
        if(writes) $fatal(1,"capture wrote cartridge SRAM");
        transfer(0,0,64'h0000b0ca00000001);
        if(take_bus) $fatal(1,"capture retained bus after commit");
        expect_mapper(16'h078e);
        for(i=0;i<32768;i=i+1) ram[i]=~pattern(i);
        mapper_write(16'h2000,5); mapper_write(16'h3000,0);
        mapper_write(16'h4000,1); mapper_write(16'h0000,10);
        begin_session(); transfer(33,1,0);
        for(i=6245;i<10341;i=i+1) transfer(i,1,0);
        if(take_bus || writes!=32768) $fatal(1,"incomplete SRAM restore");
        expect_mapper(16'h078e);
        for(i=0;i<32768;i=i+1)
            if(ram[i]!==pattern(i)) $fatal(1,"restored SRAM mismatch");

        // Abort a capture in the middle of a real /RD cycle. Restore the
        // mapper while the caller holds the CPU paused, then release the bus.
        begin_session(); transfer(33,0,0);
        @(negedge clk); core_req=1; core_read=0; core_addr=26'h3800000+6245*2;
        @(negedge clk); core_req=0;
        wait(!bus_read_n); @(negedge clk); abort_state=1; active=0;
        @(negedge clk); abort_state=0;
        wait(!take_bus); repeat(4) @(negedge clk);
        if(core_done || writes!=32768) $fatal(1,"aborted capture committed");
        expect_mapper(16'h078e);

        // Abort after the captured RAM word was issued to delayed memory.
        // The mailbox suppresses its ACK while draining the abandoned request.
        begin_session(); transfer(33,0,0);
        @(negedge clk); core_req=1; core_read=0; core_addr=26'h3800000+6245*2;
        @(negedge clk); core_req=0; wait(mem_req);
        suppress_ack=1;
        @(negedge clk); abort_state=1; active=0;
        @(negedge clk); abort_state=0;
        wait(!take_bus); repeat(4) @(negedge clk);
        expect_mapper(16'h078e);
        if(core_done || pending) $fatal(1,"late ACK survived abort");
        suppress_ack=0;
        begin_session(); transfer(33,0,0);
        if(slot[33][15:0]!==16'h078e) $fatal(1,"recovery changed next capture mapper");

        // An interrupted restore can have written part of SRAM. The caller
        // resets the guest, and mapper recovery must still finish without an
        // upstream acknowledgement or a stuck /WR. The guest cold boots.
        begin_session(); slot[33]=64'h0000000000008134;
        transfer(33,1,0); old_writes=writes;
        @(negedge clk); core_req=1; core_read=1; core_addr=26'h3800000+6245*2;
        @(negedge clk); core_req=0;
        wait(!bus_write_n && bus_addr==16'ha000);
        @(negedge clk); abort_state=1; active=0;
        @(negedge clk); abort_state=0;
        wait(!take_bus); repeat(4) @(negedge clk);
        expect_mapper(16'h0001);
        if(core_done || !bus_write_n || writes!=old_writes+1)
            $fatal(1,"interrupted SRAM restore was not bounded to the active byte");
        old_writes=writes;

        // The ROM-only MBC5 format contains placeholder bytes. Loading it
        // still restores the saved nine-bit ROM and RAM-enable registers.
        active=0; ram_code=0; repeat(3) @(negedge clk);
        slot[33]=64'h0000000000008134;
        slot[6308]=64'h123456789abcdef0;
        begin_session(); transfer(33,1,0); transfer(6308,1,0);
        expect_mapper(16'h8134);
        if(take_bus || writes!=old_writes) $fatal(1,"placeholder wrote SRAM");

        // A load can abort after restoring core registers but before touching
        // CRAM. The ensuing cold boot still needs the power-on mapper.
        begin_session(); transfer(33,1,0);
        if (take_bus) $fatal(1,"early register restore stole cartridge bus");
        @(negedge clk); abort_state=1; active=0;
        @(negedge clk); abort_state=0;
        wait(!take_bus); repeat(8) @(negedge clk);
        expect_mapper(16'h0001);
        if(core_done) $fatal(1,"early aborted load acknowledged core state");
        // Starting another capture must serialize the recovered power-on bank.
        begin_session(); transfer(33,0,0);
        if(slot[33][15:0]!==16'h0001) $fatal(1,"cold boot mapper not reflected in next capture");
        mapper_write(16'h2000,8'h34); mapper_write(16'h3000,1);
        mapper_write(16'h4000,0); mapper_write(16'h0000,10);
        active=0;

        // Smaller real SRAM geometries finish at word 7268 and never touch
        // bytes beyond the advertised 8 KiB bank.
        active=0; ram_code=2; repeat(3) @(negedge clk);
        for(i=0;i<8192;i=i+1) ram[i]=pattern(i);
        begin_session(); transfer(33,0,0);
        for(i=6245;i<7269;i=i+1) transfer(i,0,0);
        transfer(0,0,64'h0000b0ca00000001);
        expect_mapper(16'h8134);
        for(i=0;i<8192;i=i+1) ram[i]=~pattern(i);
        begin_session(); transfer(33,1,0);
        for(i=6245;i<7269;i=i+1) transfer(i,1,0);
        expect_mapper(16'h8134);
        if(take_bus || writes!=old_writes+8192) $fatal(1,"8 KiB restore length mismatch");
        for(i=0;i<8192;i=i+1)
            if(ram[i]!==pattern(i)) $fatal(1,"8 KiB SRAM mismatch");
        // The state engine can time out during its initial clock-settle wait.
        // No core request has identified a load yet, so the explicit restart
        // signal must still prepare bank 1 with RAM disabled for the boot ROM.
        begin_session(); repeat(12) @(negedge clk);
        if(take_bus || dut.session) $fatal(1,"pre-request setup already owns bus");
        @(negedge clk); abort_state=1; restart_core=1; active=0;
        @(negedge clk); abort_state=0; restart_core=0;
        wait(!take_bus); repeat(8) @(negedge clk);
        expect_mapper(16'h0001);
        if(core_done) $fatal(1,"pre-request aborted load acknowledged core");
        active=0; enabled=0; repeat(3) @(negedge clk);
        begin_session(); transfer(33,0,64'h1122334455667788);
        if(slot[33]!==64'h1122334455667788 || take_bus) $fatal(1,"ROM-only bypass modified core state");
        $display("PASS MBC5 snapshot: four SRAM banks, 9-bit ROM/disabled RAM state, capture immutability, delayed ACK/abort recovery and no-RAM restore");
        $finish;
    end
    initial begin #50000000; $fatal(1,"snapshot MBC5 timeout"); end
endmodule
