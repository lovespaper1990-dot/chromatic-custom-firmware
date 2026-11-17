`timescale 1ns/1ps
// Capture a real cart sequencer, run to a different phase, then restore it.
// The independent reference remains frozen at the captured phase. Compare
// every subsequent half-pClk edge, including all physical bus outputs.
module cart_snapshot_case #(parameter SPEED=0)(output reg finished=0);
    reg hclk=0,pclk=1,reset=1,load=0,restore_reset=0;
    always #4 hclk=~hclk;
    always #2 pclk=~pclk;
    reg frozen=0,reference_frozen=0,write_enabled=0,read_enabled=1,dma_enabled=0;
    reg halted=0,stopped=0;
    integer cycle=0;
    always @(posedge hclk) cycle<=cycle+1;
    wire ce=cycle%4==3,ce2=cycle%2==1;
    wire [2:0] tstate=1+(cycle/4)%4;
    wire [15:0] address=16'ha000 ^ (cycle*17);
    wire [7:0] data_in=cycle*29;
    wire [7:0] data_out=cycle*53;
    wire [63:0] current,reference;
    reg [63:0] saved;
    wire physical_wr,physical_dir,physical_rd;
    cart dut(.hclk(hclk),.pclk(pclk),.ce(ce && !frozen),.ce_2x(ce2 && !frozen),
        .gbreset(reset || restore_reset),.cpu_speed(SPEED!=0),.cpu_halt(!halted),.cpu_stop(stopped),
        .DMA_on(dma_enabled),.hdma_active(1'b0),.wr(write_enabled),.rd(read_enabled),
        .a(address),.CART_DOUT(data_out),.nCS(1'b0),.TSTATEo(tstate),
        .CART_D_IN(data_in),.CART_WR(physical_wr),.CART_RD(physical_rd),
        .CART_DATA_DIR_E(physical_dir),.cart_frozen(frozen),
        .snapshot_load(load),.snapshot_in(saved),.snapshot_out(current));
    cart reference_cart(.hclk(hclk),.pclk(pclk),.ce(ce && !reference_frozen),
        .ce_2x(ce2 && !reference_frozen),.gbreset(reset),.cpu_speed(SPEED!=0),
        .cpu_halt(!halted),.cpu_stop(stopped),.DMA_on(dma_enabled),.hdma_active(1'b0),
        .wr(write_enabled),.rd(read_enabled),.a(address),.CART_DOUT(data_out),
        .nCS(1'b0),.TSTATEo(tstate),.CART_D_IN(data_in),.cart_frozen(reference_frozen),
        .snapshot_load(1'b0),.snapshot_in(64'd0),.snapshot_out(reference));
    task tick(input integer count);
        repeat(count) begin @(negedge hclk); #0.5; end
    endtask
    integer trial,checks=0,diverged=0;
    reg compare=0;
    always @(posedge pclk or negedge pclk) begin
        #0.8;
        if(compare) begin
            if(current!==reference) $fatal(1,"Restored physical cart diverged speed=%0d DUT=%h reference=%h",SPEED,current,reference);
            checks=checks+1;
        end
    end
    initial begin
        tick(8); reset=0; tick(24);
        for(trial=0;trial<32;trial=trial+1) begin
            halted=trial%5==0; stopped=trial%7==0;
            write_enabled=trial%3==0; read_enabled=!write_enabled; dma_enabled=trial%4==0;
            tick(9+(trial*17)%39);
            write_enabled=0; dma_enabled=0; tick(20);
            if(!physical_wr || !physical_dir) $fatal(1,"Capture attempted during a write");
            frozen=1; reference_frozen=1; tick(1); saved=reference;
            if(saved[63:48]!==16'hc507 || saved[47]!==0) $fatal(1,"Invalid state framing");
            // Cart inputs keep changing while frozen, including a DMA request.
            dma_enabled=1; tick(4);
            if(current!==saved || reference!==saved) $fatal(1,"Frozen bus sampled another timeline");
            stopped=!stopped;
            frozen=0; tick(31+trial); frozen=1; tick(2);
            if(current!==saved) diverged=diverged+1;
            // A legacy/malformed slot must not overwrite the sequencer.
            saved[63:48]=0; load=1; tick(2); load=0;
            if(current===reference) $fatal(1,"Invalid frame unexpectedly restored state");
            stopped=trial%7==0;
            saved=reference; load=1; restore_reset=trial==31; tick(2);
            restore_reset=0; load=0; tick(1);
            if(current!==saved) $fatal(1,"Incomplete physical state restoration");
            dma_enabled=0; frozen=0; reference_frozen=0; compare=1;
            tick(32); compare=0;
        end
        if(checks<4000 || diverged!=32) $fatal(1,"Insufficient state/phase coverage");
        $display("PASS cart snapshot speed=%0d: %0d cross-phase restores and %0d half-clock physical bus/state checks",SPEED,diverged,checks);
        finished=1;
    end
endmodule
module cart_snapshot_tb;
    wire dmg,cgb;
    cart_snapshot_case #(0) normal_speed(dmg);
    cart_snapshot_case #(1) double_speed(cgb);
    initial begin wait(dmg&&cgb); $finish; end
    initial begin #1000000; $fatal(1,"Cart snapshot timeout"); end
endmodule
