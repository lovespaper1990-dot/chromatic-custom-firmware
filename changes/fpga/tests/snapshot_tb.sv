// Run with snapshot_control.v, snapshot_psram.v and snapshot_cart.v. Simulates
// independent clocks and the burst timing of MultiPortRamCtrl, without Gowin IP.
module snapshot_tb #(parameter RAM_CODE = 0);
    localparam WORDS = RAM_CODE == 3 ? 10341 : RAM_CODE == 2 ? 7269 : 6309;
    localparam [15:0] LAST = WORDS - 1;
    reg hclk=0, xclk=0, reset=1, ready=0, initialized=1;
    always #5 hclk=~hclk;
    always #2 xclk=~xclk;
    wire [14:0] address;
    wire rd_n, complete, supported;
    wire diagnostics_off_passed;
    snapshot_diagnostics_off_case check_diagnostics_off(hclk, diagnostics_off_passed);
    wire [63:0] identity;
    reg wrong_mapper=0;
    reg [7:0] rom_byte;
    always_comb begin
        rom_byte = address ^ (address >> 8);
        if (address == 'h147) rom_byte = wrong_mapper ? 8'h10 : 8'h00;
        if (address == 'h148 || address == 'h149) rom_byte = 0;
        if (address == 'h14d) rom_byte = wrong_mapper ? 8'h6d : 8'h7d;
    end
    snapshot_cart cart(hclk,ready,rom_byte,address,rd_n,complete,supported,identity);
    reg core_loaded=0;
    reg [15:0] debug_flags=0;
    reg [63:0] expected_debug;
    wire core_abort, restart_core, active;
    reg command_toggle=0, busy=0, core_req=0, core_read=0;
    reg [6:0] cmd;
    reg [79:0] payload;
    reg [25:0] core_addr;
    reg [63:0] core_out;
    wire reply_toggle, capture, restore, core_done, req_toggle, read_word, ack;
    wire [79:0] reply;
    wire [13:0] index;
    wire [63:0] word_out, word_in;
    // Separate transport geometry from probe admission; physical MBC5 support
    // remains disabled until bank switching and SRAM are wired and tested.
    wire [63:0] mailbox_id = RAM_CODE == 0 ? identity :
                             {16'h1b03, RAM_CODE[7:0], identity[39:0]};
    snapshot_control #(.STALL_BITS(9), .DIAGNOSTICS(1)) ctl(hclk,reset,supported,mailbox_id,command_toggle,cmd,payload,
        reply_toggle,reply,capture,restore,busy,core_req,core_read,core_addr,
        core_out,core_done,req_toggle,index,read_word,word_out,ack,word_in,core_loaded,core_abort,restart_core,active,debug_flags,
        1'b0,1'b1,1'b0, , );
    reg memory_reset=0;
    wire ram_req, ram_read;
    wire [22:0] ram_addr;
    wire [15:0] ram_din;
    reg [15:0] ram_dout=0;
    reg ram_next=0, ram_valid=0, ram_done=0;
    snapshot_psram ram(xclk,reset || memory_reset,initialized,req_toggle,index,read_word,
        word_out,word_in,ack,ram_req,ram_read,ram_addr,ram_din,ram_dout,
        ram_next,ram_valid,ram_done);

    reg [15:0] memory[0:65535];
    integer base, part;
    initial forever begin
        @(negedge xclk);
        if (ram_req) begin
            if (ram_addr < 'h40000 || ram_addr >= 'h60000 || ram_addr[2:0])
                $fatal(1,"outside staging area");
            base = (ram_addr - 'h40000)/2;
            repeat (5) @(negedge xclk);
            for (part=0;part<4;part=part+1) begin
                ram_valid = ram_read;
                ram_next = !ram_read && part != 3;
                ram_done = part == 3;
                if (ram_read) ram_dout=memory[base+part];
                else memory[base+part]=ram_din;
                @(negedge xclk);
            end
            ram_valid=0; ram_next=0; ram_done=0;
        end
    end
    task command(input [6:0] addr, input [79:0] data, input [79:0] expected);
        reg last;
        begin
            @(negedge hclk);
            last=reply_toggle;
            cmd=addr; payload=data; command_toggle=~command_toggle;
            wait (reply_toggle!=last);
            if(reply!==expected) $fatal(1,"command %h payload %h got %h expected %h",addr,data,reply,expected);
        end
    endtask
    function [63:0] pattern(input integer i);
        pattern = (i==0) ? 64'h0000b0ca00000001 : (64'h95bc2468d036753a ^ i);
    endfunction
    task transfer(input integer i,input reading);
        begin
            @(negedge hclk);
            core_addr=26'h3800000+i*2;
            core_read=reading;
            core_out=pattern(i);
            core_req=1;
            @(negedge hclk); core_req=0;
            wait(core_done);
            if(reading && word_in!==pattern(i)) $fatal(1,"core restore mismatch at %d",i);
            @(negedge hclk);
        end
    endtask
    task control(input [7:0] op,input [7:0] result);
        command('h20,op,{16'hfff0,op,result,48'd0});
    endtask

    integer i;
    initial begin
        repeat(4) @(negedge hclk); reset=0;
        control(1,2);
        command('h20,4,{16'hfff2,64'd0});
        ready=1; wait(complete); @(negedge hclk);
        if(identity !== 64'h0000007ddd608109 || !supported) $fatal(1,"identity %h",identity);
        command('h20,3,{16'hfff1,mailbox_id});
        control(2,4);
        control(1,1);
        wait(capture);
        @(negedge hclk); busy=1;
        control(0,1);
        control(2,5);
        for(i=1;i<WORDS;i=i+1) transfer(i,0);
        transfer(0,0);
        @(negedge hclk); busy=0; repeat(3) @(negedge hclk);
        control(0,0);
        for(i=0;i<WORDS;i=i+1) command('h21,i,{i[15:0],pattern(i)});
        // Reboot the memory controller after queuing a read. It must replay
        // the pending request rather than return an unwritten or stale value.
        initialized=0;
        fork
            command('h21,16'd123,{16'd123,pattern(123)});
            begin
                wait(ctl.owner==2);
                repeat (5) @(negedge xclk);
                memory_reset=1;
                repeat (8) @(negedge xclk);
                memory_reset=0; initialized=1;
            end
        join
        // A failed/partial upload must leave the game running and refuse restore.
        command('h22,0,{16'hfff0,8'h22,8'd3,48'd0});
        command('h22,{16'd0,pattern(0)},{16'd0,pattern(0)});
        control(2,4);
        command('h22,{16'd9,pattern(9)},{16'hfff0,8'h22,8'd3,48'd0});
        for(i=1;i<WORDS;i=i+1)
            command('h22,{i[15:0],pattern(i)},{i[15:0],pattern(i)});
        command('h22,{LAST,pattern(LAST)},{LAST,pattern(LAST)});
        control(2,1); wait(restore);
        @(negedge hclk); busy=1;
        for(i=0;i<WORDS;i=i+1) transfer(i,1);
        @(negedge hclk); core_loaded=1; busy=0;
        @(negedge hclk); core_loaded=0;
        control(0,0);
        // A core that rejects a staged header never asserts load_done.
        control(2,1); @(negedge hclk); busy=1;
        repeat (3) @(negedge hclk); busy=0;
        control(0,3); control(2,4);
        // Freeze diagnostic flags at an incomplete capture, while retaining
        // the existing zero-padded status reply. A prior real capture must not
        // leave req_seen set in this new operation.
        debug_flags=16'h0001;
        control(1,1); @(negedge hclk); busy=1;
        repeat (3) @(negedge hclk); debug_flags=16'h0002;
        repeat (3) @(negedge hclk);
        expected_debug={16'h0002,16'h0003,index,2'd1,3'd0,
            1'b1,1'b0,1'b0,1'b0,1'b0,1'b0,core_read,core_loaded,
            req_toggle,ack,3'b000};
        busy=0;
        control(0,3); control(2,4);
        debug_flags=16'h8000;
        command('h20,4,{16'hfff2,expected_debug});
        // Core never reaches VBlank/settle: watchdog releases the engine.
        control(1,1); @(negedge hclk); busy=1;
        wait(core_abort); if(restart_core) $fatal(1,"failed capture rebooted core");
        @(negedge hclk); busy=0;
        control(0,3); control(2,4);
        // Stall a PSRAM request so diagnostics distinguish a core that never
        // requested memory from an unacknowledged physical-memory transfer.
        debug_flags=16'h0010; initialized=0;
        control(1,1); @(negedge hclk); busy=1;
        command('h20,4,{16'hfff2,64'd0});
        @(negedge hclk); core_addr=26'h3800000+17*2; core_out=pattern(17);
        core_read=0; core_req=1;
        @(negedge hclk); core_req=0;
        wait(ctl.owner==1); @(negedge hclk); debug_flags=16'h0020;
        repeat (3) @(negedge hclk); debug_flags=16'h0040;
        expected_debug={16'h0040,16'h0070,14'd17,2'd1,3'd1,
            1'b1,1'b1,1'b1,1'b0,1'b1,1'b0,1'b0,1'b0,
            req_toggle,ack,3'b000};
        wait(core_abort);
        if(restart_core) $fatal(1,"capture memory timeout rebooted core");
        @(negedge hclk); busy=0; debug_flags=16'h8000;
        command('h20,4,{16'hfff2,expected_debug});
        initialized=1;
        wait(ctl.owner==0); repeat(3) @(negedge hclk);
        control(0,3);
        command('h20,4,{16'hfff2,expected_debug});
        debug_flags=0;
        // During an interrupted load the processor must cold boot rather than
        // resume a partially restored register file or memory image.
        control(1,1); @(negedge hclk); busy=1;
        transfer(0,0); @(negedge hclk); busy=0;
        repeat(4) @(negedge hclk);
        control(2,1); @(negedge hclk); busy=1;
        ready=0; wait(core_abort);
        if(!restart_core) $fatal(1,"interrupted load did not reset the core");
        @(negedge hclk); busy=0;
        control(0,2);
        ready=0; repeat (5) @(negedge hclk); wrong_mapper=1; ready=1; wait(complete); @(negedge hclk);
        if(supported) $fatal(1,"mapper was accepted");
        control(2,2);
        if (!diagnostics_off_passed) $fatal(1,"default-off diagnostics case did not complete");
        $display("PASS: %0d capture/read/upload/restore words, partial upload and wrong mapper", WORDS);
        $finish;
    end
    initial begin #20000000; $fatal(1,"timeout"); end
endmodule

// Production's default parameter must remove storage without changing op4's
// response framing. Exercise a real capture timeout with every flag set.
module snapshot_diagnostics_off_case(input clk, output reg passed = 0);
    reg reset = 1, command_toggle = 0;
    reg [79:0] command_data = 0;
    wire reply_toggle, active;
    wire [79:0] reply;
    snapshot_control #(.STALL_BITS(4)) ctl(
        .clk(clk), .reset(reset), .supported(1'b1), .identity(64'd0),
        .cmd_toggle(command_toggle), .cmd(7'h20), .cmd_data(command_data),
        .reply_toggle(reply_toggle), .reply(reply), .active(active),
        .core_busy(1'b0), .core_req(1'b0), .core_read(1'b0),
        .core_addr(26'd0), .core_out(64'd0), .core_loaded(1'b0),
        .mem_ack(1'b0), .mem_in(64'd0), .debug_flags(16'hffff)
    );
    task command(input [7:0] operation, input [79:0] expected);
        reg previous_reply;
        begin
            @(negedge clk);
            previous_reply = reply_toggle;
            command_data = operation;
            command_toggle = ~command_toggle;
            wait (reply_toggle != previous_reply);
            @(negedge clk);
            if (reply !== expected)
                $fatal(1,"default-off diagnostics response %h, expected %h",reply,expected);
        end
    endtask
    initial begin
        repeat (4) @(negedge clk); reset = 0;
        command(1, {16'hfff0,8'd1,8'd1,48'd0});
        repeat (30) @(negedge clk);
        if (active) $fatal(1,"default-off capture watchdog did not finish");
        command(4, {16'hfff2,64'd0});
        $display("PASS diagnostics default-off: timeout and nonzero flags return fff2/zero");
        passed = 1;
    end
    initial begin
        repeat (1000) @(posedge clk);
        if (!passed) $fatal(1,"default-off diagnostics timeout");
    end
endmodule
