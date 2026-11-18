`timescale 1ns/1ps
// Standard physical MBC1 model. The ROM masks address lines only after the
// full low-five zero->one rule; SRAM has independent mode-controlled banks.
// MBC1M has different wiring and is deliberately excluded by the scanner.
module snapshot_mbc1_tb #(parameter RAM_CODE = 3, parameter ROM_BITS = 5);
    localparam RAM_BYTES = RAM_CODE == 3 ? 32768 : RAM_CODE == 2 ? 8192 : 0;
    localparam LAST_WORD = RAM_CODE == 3 ? 10340 : RAM_CODE == 2 ? 7268 : 6308;
    localparam ROM_MASK = (1 << ROM_BITS) - 1;
    reg clk=0, reset=1, enabled=1, active=0, abort_state=0, restart_core=0;
    always #5 clk=~clk;
    reg core_req=0, core_read=0;
    reg [25:0] core_addr=0;
    reg [63:0] core_out=0;
    wire core_done;
    wire [63:0] core_in;
    wire mem_req,mem_read;
    wire [25:0] mem_addr;
    wire [63:0] mem_out;
    reg mem_done=0;
    reg [63:0] mem_in=0;
    reg [15:0] game_addr=0;
    reg [7:0] game_out=0;
    reg game_write_n=1,game_read_n=1,game_input_dir=1;
    wire take_bus;
    wire [15:0] bus_addr;
    wire [7:0] bus_out;
    wire bus_rd,bus_wr,bus_cs,bus_dir;
    wire [15:0] physical_addr=take_bus ? bus_addr : game_addr;
    wire [7:0] physical_out=take_bus ? bus_out : game_out;
    wire physical_wr=take_bus ? bus_wr : game_write_n;
    wire physical_rd=take_bus ? bus_rd : game_read_n;
    wire physical_cs=take_bus ? bus_cs : !(game_addr[15:13]==3'b101);
    wire physical_dir=take_bus ? bus_dir : game_input_dir;
    // Match the scanner's explicit exit registers, not chip power-on raw zero.
    reg [4:0] rom_low=1;
    reg [1:0] secondary=0;
    reg mode=0,ram_enabled=0;
    wire [15:0] physical_mapper={ram_enabled,mode,3'b0,secondary,4'b0,rom_low};
    wire [6:0] high_window=({secondary,(rom_low==0 ? 5'd1 : rom_low)}) & ROM_MASK;
    wire [6:0] low_window=(mode ? {secondary,5'b0} : 7'd0) & ROM_MASK;
    wire [6:0] rom_window=physical_addr[14] ? high_window : low_window;
    wire [14:0] ram_address={((RAM_CODE==3 && mode) ? secondary : 2'b00),physical_addr[12:0]};
    reg [7:0] ram[0:32767];
    reg [63:0] slot[0:10340];
    wire [7:0] cart_in=physical_rd || !physical_dir ? 8'hff :
        !physical_addr[15] ? (8'ha5 ^ {1'b0,rom_window} ^ physical_addr[7:0]) :
        !physical_cs && ram_enabled && RAM_BYTES!=0 ? ram[ram_address] : 8'hff;
    integer ram_writes=0,control_writes=0;
    snapshot_mbc5 dut(.clk(clk),.reset(reset),.enabled(enabled),.mbc1(1'b1),.ram_code(RAM_CODE[7:0]),
        .active(active),.abort(abort_state),.restart_core(restart_core),
        .core_req(core_req),.core_read(core_read),.core_addr(core_addr),.core_out(core_out),
        .core_done(core_done),.core_in(core_in),.mem_req(mem_req),.mem_read(mem_read),
        .mem_addr(mem_addr),.mem_out(mem_out),.mem_done(mem_done),.mem_in(mem_in),
        .game_addr(game_addr),.game_out(game_out),.game_write_n(game_write_n),.cart_in(cart_in),
        .take_bus(take_bus),.cart_addr(bus_addr),.cart_out(bus_out),.cart_read_n(bus_rd),
        .cart_write_n(bus_wr),.cart_cs_n(bus_cs),.cart_input_dir(bus_dir));
    always @(posedge physical_wr) if (!reset) begin
        if (physical_dir || !physical_rd) $fatal(1,"Unsafe physical mapper/SRAM write");
        case(physical_addr[15:13])
            0:begin ram_enabled=physical_out[3:0]==4'ha;control_writes=control_writes+1;end
            1:begin rom_low=physical_out[4:0];control_writes=control_writes+1;end
            2:begin secondary=physical_out[1:0];control_writes=control_writes+1;end
            3:begin mode=physical_out[0];control_writes=control_writes+1;end
            5:begin
                if (!take_bus || physical_cs || !ram_enabled || !mode || RAM_BYTES==0 || !dut.mem_read)
                    $fatal(1,"Snapshot SRAM write without RAM mode/enable or during capture");
                ram[ram_address]=physical_out;ram_writes=ram_writes+1;
            end
        endcase
    end
    reg pending=0,suppress_ack=0,delayed_read;
    reg [63:0] delayed_data;
    integer delay_left,delayed_index;
    always @(posedge clk) begin
        mem_done<=0;
        if(mem_req)begin
            if(pending)$fatal(1,"Overlapping backing memory request");
            if(mem_addr<26'h3800000 || mem_addr>=26'h3800000+2*(LAST_WORD+1) || mem_addr[0])
                $fatal(1,"Invalid backing address");
            pending=1;delayed_index=(mem_addr-26'h3800000)/2;
            delayed_read=mem_read;delayed_data=mem_out;delay_left=2+delayed_index%9;
        end else if(pending)begin
            if(delay_left!=0)delay_left=delay_left-1;
            else begin
                if(delayed_read)mem_in<=slot[delayed_index];else slot[delayed_index]<=delayed_data;
                if(!suppress_ack)mem_done<=1;
                pending=0;
            end
        end
    end
    function automatic [15:0] pack(input bit e,input bit m,input [1:0] h,input [4:0] l);
        pack={e,m,3'b0,h,4'b0,l};
    endfunction
    function automatic [7:0] pattern(input integer address);
        pattern=address^(address>>8)^((address>>13)*101);
    endfunction
    task tick;@(negedge clk);#0.1;endtask
    task mapper_write(input [15:0] address,input [7:0] value);
        tick();game_addr=address;game_out=value;game_input_dir=0;game_write_n=0;
        repeat(8)tick();game_write_n=1;repeat(3)tick();game_input_dir=1;
    endtask
    task set_mapper(input bit e,input bit m,input [1:0] h,input [4:0] l);
        mapper_write(16'h3fff,{3'b111,l});mapper_write(16'h5abc,{6'b111111,h});
        mapper_write(16'h7fff,{7'b1111111,m});mapper_write(16'h1fff,e ? 8'hfa : 8'hf0);
    endtask
    task expect_mapper(input [15:0] expected);
        if(physical_mapper!==expected || dut.current_mapper!==expected)
            $fatal(1,"MBC1 physical/mirror %h/%h expected %h",physical_mapper,dut.current_mapper,expected);
    endtask
    task read_window(input [15:0] address,input [6:0] bank);
        tick();game_addr=address;game_read_n=0;repeat(2)tick();
        if(cart_in!==(8'ha5 ^ {1'b0,bank} ^ address[7:0]))$fatal(1,"Wrong restored MBC1 ROM window at %h",address);
        game_read_n=1;
    endtask
    task begin_session;
        active=0;repeat(3)tick();active=1;repeat(3)tick();
    endtask
    task transfer(input integer index,input bit read_op,input [63:0] value);
        tick();core_addr=26'h3800000+index*2;core_read=read_op;core_out=value;core_req=1;
        tick();core_req=0;wait(core_done);tick();
        if(read_op && core_in!==slot[index])$fatal(1,"Wrong restore word %0d",index);
    endtask
    task abort_operation(input bit restart);
        tick();abort_state=1;restart_core=restart;active=0;
        tick();abort_state=0;restart_core=0;wait(!take_bus);repeat(6)tick();
        if(core_done || !bus_wr || !bus_rd || !bus_cs || !bus_dir)$fatal(1,"Aborted MBC1 left active bus/ACK");
    endtask
    integer i,j,h,m,l,old_writes;
    reg [15:0] advanced;
    initial begin
        for(i=0;i<32768;i=i+1)ram[i]=pattern(i);
        repeat(4)tick();reset=0;repeat(3)tick();expect_mapper(16'h0001);
        // Full five-bit zero test occurs before ROM-address masking. Preserve
        // ignored data bits, both write aliases, and all mode/high combinations.
        for(l=0;l<32;l=l+1)for(h=0;h<4;h=h+1)for(m=0;m<2;m=m+1)begin
            set_mapper(l[0],m[0],h[1:0],l[4:0]);expect_mapper(pack(l[0],m[0],h[1:0],l[4:0]));
            read_window(16'h0123,(m ? h*32 : 0)&ROM_MASK);
            read_window(16'h4123,(h*32+(l==0 ? 1 : l))&ROM_MASK);
        end
        set_mapper(0,0,3,0);expect_mapper(16'h0600);
        begin_session();if(take_bus)$fatal(1,"MBC1 bus taken before first request");
        transfer(33,0,64'h1234000000000000);
        if(slot[33]!==64'h1234000000000600)$fatal(1,"MBC1 raw-zero mapper encoding not serialized");
        for(i=6245;i<=LAST_WORD;i=i+1)begin
            transfer(i,0,RAM_BYTES==0 ? 64'h1234567800000000+i : 0);
            if(RAM_BYTES!=0)for(j=0;j<8;j=j+1)
                if(slot[i][j*8+:8]!==pattern((i-6245)*8+j))$fatal(1,"MBC1 RAM capture bank/byte missing");
        end
        transfer(0,0,64'h0000b0ca00000001);expect_mapper(16'h0600);
        if(take_bus || ram_writes)$fatal(1,"Capture wrote SRAM or retained bus");
        for(i=0;i<RAM_BYTES;i=i+1)ram[i]=~pattern(i);
        set_mapper(1,1,1,7);begin_session();transfer(33,1,0);
        for(i=6245;i<=LAST_WORD;i=i+1)transfer(i,1,0);
        expect_mapper(16'h0600);
        if(take_bus || ram_writes!=RAM_BYTES)$fatal(1,"Wrong RAM restore size or held ownership");
        for(i=0;i<RAM_BYTES;i=i+1)if(ram[i]!==pattern(i))$fatal(1,"MBC1 SRAM restore mismatch");
        read_window(16'h0123,0);read_window(16'h4123,(3*32+1)&ROM_MASK);

        // Advanced mode must restore the lower ROM window as well as RAM bank.
        // Raw $10 can map bank zero on a small ROM and must not become $01.
        advanced=pack(1,1,2,16);slot[33]={48'd0,advanced};
        set_mapper(0,0,0,1);begin_session();transfer(33,1,0);transfer(LAST_WORD,1,0);
        expect_mapper(advanced);
        if(take_bus)$fatal(1,"Advanced MBC1 mapper not committed before ACK");
        read_window(16'h0123,(2*32)&ROM_MASK);read_window(16'h4123,(2*32+16)&ROM_MASK);
        if(RAM_BYTES!=0)begin
            tick();game_addr=16'ha123;game_read_n=0;repeat(2)tick();
            if(cart_in!==pattern((RAM_CODE==3 ? 2*8192 : 0)+16'h123))$fatal(1,"Restored MBC1 RAM mode/bank wrong");
            game_read_n=1;
            begin_session();transfer(33,0,0);
            tick();core_req=1;core_read=0;core_addr=26'h3800000+6245*2;tick();core_req=0;
            wait(!bus_rd);abort_operation(0);expect_mapper(advanced);
            // A missing downstream ACK cannot prevent mapper recovery.
            begin_session();transfer(33,0,0);
            tick();core_req=1;core_read=0;core_addr=26'h3800000+6245*2;tick();core_req=0;
            wait(mem_req);suppress_ack=1;abort_operation(0);expect_mapper(advanced);suppress_ack=0;
            old_writes=ram_writes;
            begin_session();transfer(33,1,0);
            tick();core_req=1;core_read=1;core_addr=26'h3800000+6245*2;tick();core_req=0;
            wait(!bus_wr && bus_addr==16'ha000);abort_operation(0);expect_mapper(16'h0000);
            if(ram_writes!=old_writes+1)$fatal(1,"MBC1 load abort wrote beyond active byte");
        end
        // No-RAM and early load failures must cold-boot raw low=0/high=0/mode0,
        // even when no physical CRAM transaction or first core request occurred.
        set_mapper(1,1,3,0);begin_session();transfer(33,1,0);
        if(take_bus)$fatal(1,"Early register load owns cartridge");
        abort_operation(0);expect_mapper(16'h0000);
        set_mapper(1,1,3,16);begin_session();abort_operation(1);expect_mapper(16'h0000);
        begin_session();transfer(33,0,0);
        if(slot[33][15:0]!==0)$fatal(1,"Cold-boot raw-zero mapper lost on next capture");
        active=0;enabled=0;repeat(3)tick();begin_session();
        transfer(33,0,64'h1122334455667788);
        if(slot[33]!==64'h1122334455667788 || take_bus)$fatal(1,"Disabled mapper bypass changed stream");
        $display("PASS MBC1 snapshot: ROM address bits=%0d RAM=%0d, raw low5/high2/mode/enable, both ROM windows, full SRAM, disabled RAM, delayed ACK/abort/no-RAM recovery",ROM_BITS,RAM_BYTES);
        $finish;
    end
    initial begin #100000000;$fatal(1,"MBC1 snapshot timeout");end
endmodule
