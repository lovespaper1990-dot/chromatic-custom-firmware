`timescale 1ns/1ps
module cart_suspend_case #(parameter SPEED=0)(output reg finished=0);
reg hclk=0, pclk=1, reset=1, request=0;
always #4 hclk=~hclk;
always #2 pclk=~pclk;
wire frozen, ce, ce2, ref_ce, ref_ce2;
// Standby boundaries are falling hclk / rising pclk; both reference clocks
// retain the exact level present at that edge until the DUT resumes.
reg ref_h=0, ref_p=1;
always @(hclk or frozen) ref_h=(frozen===1'b1) ? 1'b0 : hclk;
always @(pclk or frozen) ref_p=(frozen===1'b1) ? 1'b1 : pclk;
integer beat=0;
always @(posedge ref_h) if (!reset && (SPEED ? ref_ce2 : ref_ce)) beat<=beat+1;
wire [2:0] tstate = 1 + (beat % 4);
wire [7:0] cycle = beat / 4;
wire rd = cycle%7==1 || cycle%7==4;
wire wr = cycle%7==2 || cycle%7==6;
wire dma = cycle%7==3;
wire hdma = cycle%14==3;
wire cs = cycle[0];
wire halted = (cycle%23==13); // HALT_n is active low
wire stopped = (cycle%29==21);
wire [15:0] addr=(cycle*16'h1092) ^ (beat%4==0 ? 16'h3c11 : 16'h7a15);
wire [7:0] mem_input=(addr>>4) ^ addr;
wire [7:0] d_out=(beat*27) ^ cycle;
wire [15:0] dut_a,gold_a,free_a;
wire [7:0] dut_di,gold_di,free_di, dut_do,gold_do,free_do;
wire dut_phi,dut_cs,dut_rd,dut_wr,dut_dir;
wire gold_phi,gold_cs,gold_rd,gold_wr,gold_dir;
wire free_phi,free_cs,free_rd,free_wr,free_dir;
wire actual_busy = rd || wr || (request && (dma || !dut_wr || !dut_dir));
speedcontrol real_clock(.clk_sys(hclk),.pause(request),.standby_req(request),.cart_frozen(frozen),
 .speedup(1'b0),.cart_act(actual_busy),.DMA_on(1'b0),.ce(ce),.ce_2x(ce2));
speedcontrol reference_clock(.clk_sys(ref_h),.pause(1'b0),.standby_req(1'b0),
 .speedup(1'b0),.cart_act(rd||wr),.DMA_on(1'b0),.ce(ref_ce),.ce_2x(ref_ce2));
cart dut(.hclk(hclk),.pclk(pclk),.ce(ce),.ce_2x(ce2),.gbreset(reset),.cpu_speed(SPEED != 0),
 .cpu_halt(!halted),.cpu_stop(stopped),.DMA_on(dma),.hdma_active(hdma),
 .wr(wr),.rd(rd),.a(addr),.CART_DOUT(d_out),.nCS(cs),.TSTATEo(tstate),
 .CART_A(dut_a),.CART_CLK(dut_phi),.CART_CS(dut_cs),.CART_D_IN(mem_input),.CART_D_OUT(dut_do),
 .CART_RD(dut_rd),.CART_WR(dut_wr),.CART_DATA_DIR_E(dut_dir),.CART_DIN_r1(dut_di),.cart_frozen(frozen));
cart gold(.hclk(ref_h),.pclk(ref_p),.ce(ref_ce),.ce_2x(ref_ce2),.gbreset(reset),.cpu_speed(SPEED != 0),
 .cpu_halt(!halted),.cpu_stop(stopped),.DMA_on(dma),.hdma_active(hdma),
 .wr(wr),.rd(rd),.a(addr),.CART_DOUT(d_out),.nCS(cs),.TSTATEo(tstate),
 .CART_A(gold_a),.CART_CLK(gold_phi),.CART_CS(gold_cs),.CART_D_IN(mem_input),.CART_D_OUT(gold_do),
 .CART_RD(gold_rd),.CART_WR(gold_wr),.CART_DATA_DIR_E(gold_dir),.CART_DIN_r1(gold_di),.cart_frozen(1'b0));
cart free(.hclk(hclk),.pclk(pclk),.ce(ce),.ce_2x(ce2),.gbreset(reset),.cpu_speed(SPEED != 0),
 .cpu_halt(!halted),.cpu_stop(stopped),.DMA_on(dma),.hdma_active(hdma),
 .wr(wr),.rd(rd),.a(addr),.CART_DOUT(d_out),.nCS(cs),.TSTATEo(tstate),
 .CART_A(free_a),.CART_CLK(free_phi),.CART_CS(free_cs),.CART_D_IN(mem_input),.CART_D_OUT(free_do),
 .CART_RD(free_rd),.CART_WR(free_wr),.CART_DATA_DIR_E(free_dir),.CART_DIN_r1(free_di),.cart_frozen(1'b0));
// With capture inactive and CE stopped, the falling-edge data register holds naturally.
wire [44:0] dut_state = {dut_a,dut_di,dut_do,dut_phi,dut_cs,dut_rd,dut_wr,dut_dir,dut.counter,dut.p1,dut.p2,dut.phiCnt};
wire [44:0] gold_state = {gold_a,gold_di,gold_do,gold_phi,gold_cs,gold_rd,gold_wr,gold_dir,gold.counter,gold.p1,gold.p2,gold.phiCnt};
wire [44:0] free_state = {free_a,free_di,free_do,free_phi,free_cs,free_rd,free_wr,free_dir,free.counter,free.p1,free.p2,free.phiCnt};
integer mismatches_without_gating=0, checked=0, retained=0, samples=0, bus_busy_req=0;
always @(posedge pclk or negedge pclk) begin
 #0.4;
 if (!reset && beat>20 && !finished) begin
   checked=checked+1;
   if(frozen) begin
     retained=retained+1;
     if(rd || wr || dma || dut_wr!==1 || dut_dir!==1 || ce || ce2)
       $fatal(1,"busy bus or guest CE during sleep speed=%d beat=%d",SPEED,beat);
   end
   if(ce!==ref_ce || ce2!==ref_ce2 || dut_state!==gold_state)
     $fatal(1,"stutter mismatch t=%t speed=%d frozen=%d beat=%d dut=%h gold=%h ce=%b/%b ref=%b/%b",
            $time,SPEED,frozen,beat,dut_state,gold_state,ce,ce2,ref_ce,ref_ce2);
   if(free_state!==gold_state) mismatches_without_gating=mismatches_without_gating+1;
 end
end
initial begin
 repeat(9) @(negedge hclk); #0.7; reset=0;
 wait(beat>20);
 for(integer i=0;i<220;i=i+1) begin
   repeat(1+(i*27)%89) @(posedge hclk); #0.8;
   if(rd || wr || dma || !dut_wr || !dut_dir) bus_busy_req=bus_busy_req+1;
   request=1;
   wait(frozen===1); #0.7;
   samples=samples+1;
   repeat(1+(i*13)%121) @(posedge hclk); #0.8; request=0;
   wait(frozen===0); #0.7;
 end
 if(samples!=220 || !mismatches_without_gating || !bus_busy_req) $fatal(1,"coverage");
 $display("PASS speed=%0d: %0d standby/wake (%0d requests during bus activity), %0d half-pclk pin/state checks, %0d retained checks; ungated cart diverged %0d times", SPEED,samples,bus_busy_req,checked,retained,mismatches_without_gating);
 finished=1;
end
endmodule
module cart_standby_tb;
wire a,b;
cart_suspend_case #(0) dmg(a);
cart_suspend_case #(1) cgb(b);
initial begin wait(a&&b); $finish; end
initial begin #1000000; $fatal(1,"timeout waiting for standby/wake"); end
endmodule
