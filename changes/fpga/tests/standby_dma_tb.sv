`timescale 1ns/1ps
module standby_dma_tb;
reg clk=0, reset=1, pause=0;
always #4 clk=~clk;
wire ce,ce2, hold;
wire oam_rd, hdma_rd; wire [15:0] oa, hs, ht;
reg [7:0] waddr, wdata; reg wo=0,wh=0;
reg [1:0] mode=0;
wire ext_oam = oam_rd && (!oa[15] || oa[15:13]==3'b101);
wire ext_hdma = hdma_rd && (!hs[15] || hs[15:13]==3'b101);
speedcontrol speed(.clk_sys(clk),.pause(pause),.standby_req(pause),.cart_frozen(hold),
  .speedup(1'b0),.cart_act(ext_oam || ext_hdma),.DMA_on(1'b0),.ce(ce),.ce_2x(ce2));
video lcd(.clk(clk),.ce(ce),.ce_cpu(ce2),.reset(reset),.isGBC(1'b1),.isGBC_mode(1'b1),
  .megaduck(1'b0),.boot_rom_en(1'b0),.customPaletteEna(1'b0),.paletteBGIn(64'd0),
  .paletteOBJ0In(64'd0),.paletteOBJ1In(64'd0),.gbc_color_temp(3'd0),
  .cpu_sel_oam(1'b0),.cpu_sel_reg(wo),.cpu_wr(wo),.cpu_addr(waddr),.cpu_di(wdata),
  .vram_data(8'h61),.vram1_data(8'h79),.dma_addr(oa),.dma_rd(oam_rd),.dma_data(oa[7:0]^8'h57),
  .Savestate_OAMRAMAddr(8'd0),.Savestate_OAMRAMRWrEn(1'b0),.Savestate_OAMRAMWriteData(8'd0),
  .SaveStateBus_wren(1'b0),.SaveStateBus_rst(reset),.SaveStateBus_Adr(10'd0),.SaveStateBus_Din(64'd0));
hdma transfer(.clk(clk),.ce(ce2),.speed(1'b1),.reset(reset),.sel_reg(wh),.addr(waddr[3:0]),.wr(wh),.din(wdata),
  .lcd_mode(mode),.hdma_rd(hdma_rd),.hdma_source_addr(hs),.hdma_target_addr(ht),
  .SaveStateBus_wren(1'b0),.SaveStateBus_rst(reset),.SaveStateBus_Adr(10'd0),.SaveStateBus_Din(64'd0));
task write_reg(input bit h,input [7:0] a,input [7:0] v);
  @(negedge clk); #0.3;
  while (!ce2) begin @(negedge clk); #0.3; end
  waddr=a;wdata=v;wh=h;wo=!h;
  @(posedge clk); #0.5; wh=0;wo=0;
endtask
task test_pause(input bit must_wait, input bit expect_oam, input bit expect_hdma);
  reg [76:0] before_regs;
  integer wait_count;
  begin
   @(posedge clk); #0.4; pause=1; wait_count=0;
   while(!hold) begin @(negedge clk); #0.4; wait_count=wait_count+1; end
   if(must_wait && wait_count<=4) $fatal(1,"did not drain DMA");
   if(oam_rd!==expect_oam || hdma_rd!==expect_hdma || ext_oam || ext_hdma)
      $fatal(1,"unexpected held DMA %b/%b, at %h/%h",oam_rd,hdma_rd,oa,hs);
   before_regs={lcd.SS_Video1_BACK[10:0],transfer.SS_HDMA_BACK,transfer.hdma_state,hs};
   repeat(1999) begin @(posedge clk); #0.4;
     if({lcd.SS_Video1_BACK[10:0],transfer.SS_HDMA_BACK,transfer.hdma_state,hs}!==before_regs || ce || ce2)
       $fatal(1,"DMA changed while suspended");
   end
   pause=0; wait(!hold); @(posedge clk); #0.4;
  end
endtask
task start_hdma(input [7:0] src, input [7:0] length);
  write_reg(1,1,src);write_reg(1,2,0);write_reg(1,3,0);write_reg(1,4,0);write_reg(1,5,length);
endtask
initial begin
  repeat(10) @(negedge clk); #0.2; reset=0;
  // External CGB OAM source (ROM) must finish before granting standby.
  write_reg(0,8'h46,8'h40); wait(oam_rd); test_pause(1,0,0);
  // Internal OAM source (WRAM) may be paused mid-byte, then must finish.
  write_reg(0,8'h46,8'hc0); wait(oam_rd && oa[7:0]==8'd16); test_pause(0,1,0); wait(!oam_rd);
  // General DMA external source must drain. Internal WRAM DMA retains all
  // of its registers, including byte and sub-cycle position, while paused.
  start_hdma(8'h40,3); wait(hdma_rd); test_pause(1,0,0);
  start_hdma(8'hc0,3); wait(hdma_rd && hs[4:0]==3); test_pause(0,0,1); wait(!hdma_rd);
  // H-Blank DMA between external bursts is allowed to sleep with enable set.
  mode=3; start_hdma(8'h40,8'h83); repeat(9) @(posedge clk);
  if(!transfer.hdma_enabled) $fatal(1,"H-Blank DMA did not arm");
  test_pause(0,0,0); mode=0; wait(hdma_rd);
  $display("PASS: external OAM/GDMA drained, internal OAM/GDMA retained, external H-Blank resumed"); $finish;
end
initial begin #1200000; $fatal(1,"DMA test timeout"); end
endmodule
