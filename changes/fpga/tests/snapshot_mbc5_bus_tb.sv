module snapshot_mbc5_bus_tb;
    reg clk=0, ready=0, start=0, wr=0;
    reg [15:0] addr;
    reg [7:0] out;
    wire [15:0] cart_a;
    wire [7:0] cart_d, result;
    wire rd_n, wr_n, cs_n, input_dir, busy, done;
    reg [3:0] bank=0;
    reg [7:0] ram[0:32767];
    wire [14:0] ram_addr={bank[1:0],cart_a[12:0]};
    wire [7:0] cart_in=!cs_n && !rd_n && input_dir ? ram[ram_addr] : 8'hxx;
    snapshot_mbc5_bus dut(clk,ready,start,wr,addr,out,cart_in,busy,done,result,
                          cart_a,cart_d,rd_n,wr_n,cs_n,input_dir);
    wire [15:0] mapper_state;
    snapshot_mbc5_mapper mirror(clk,ready,wr_n,cart_a,cart_d,mapper_state);
    always #5 clk=~clk;
    always @(posedge wr_n) if (ready && busy) begin
        if (input_dir || !rd_n) $fatal(1,"unstable data on cartridge write");
        if (!cs_n) ram[ram_addr]=cart_d;
        else if (cart_a==16'h4000) bank=cart_d[3:0];
    end
    task transfer(input bit write_op, input [15:0] a, input [7:0] d);
        begin
            @(negedge clk); start=1; wr=write_op; addr=a; out=d;
            @(negedge clk); start=0;
            wait(done); @(negedge clk);
            if (!write_op && result!==d) $fatal(1,"wrong bank or data at %h",a);
        end
    endtask
    integer pass,b,i;
    initial begin
        @(negedge clk); ready=1;
        transfer(1,16'h0000,8'h0a);
        transfer(1,16'h2fff,8'h8e);
        transfer(1,16'h3fff,8'h01);
        for(pass=0;pass<2;pass=pass+1)
            for(b=0;b<4;b=b+1) begin
                transfer(1,16'h4000,b);
                if (mapper_state !== {1'b1,2'b0,b[3:0],9'h18e})
                    $fatal(1,"mapper mirror lost RAM enable or high ROM bank");
                for(i=0;i<8192;i=i+1)
                    transfer(!pass,16'ha000+i,i^(i>>8)^(b*37));
            end
        transfer(1,16'h0000,8'h00);
        if (mapper_state !== 16'h078e) $fatal(1,"disabled RAM state lost bank");
        @(negedge clk); start=1; wr=1; addr=16'ha000; out=8'hff;
        @(negedge clk); start=0; wait(!wr_n); @(negedge clk); ready=0; #1;
        if (!wr_n || !cs_n || !rd_n || !input_dir) $fatal(1,"bus not isolated on eject");
        @(negedge clk); if (done || busy) $fatal(1,"aborted transfer committed");
        $display("PASS physical MBC5 bus model: 32 KiB, four RAM banks, read/write sequencing and removal");
        $finish;
    end
endmodule
