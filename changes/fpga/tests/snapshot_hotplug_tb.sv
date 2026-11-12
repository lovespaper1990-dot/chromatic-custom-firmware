`timescale 1ns/1ps
module snapshot_hotplug_tb;
   reg h=0, f=0, lock=0, present=0, finished=1, failed=0, alternate=0;
   always #30 h=~h;
   reg fast_run=1;
   always #3.75 begin if (fast_run) f=~f; end
   top board(.CART_DET(present));
   wire [14:0] address=board.scan_address;
   reg [7:0] data;
   always_comb begin
      data=address ^ (address >>8);
      if (address=='h147 || address=='h148 || address=='h149) data=0;
      if (address=='h14d) data='h7d;
      if (address=='h42 && alternate) data=8'hdd;
   end
   wire valid=board.scan_supported && board.snapshot_ram_ready_sync[1];
   task hclock; @(posedge h); #1; endtask
   task tickcheck(input [1:0] expect_phase);
      hclock();
      if (board.scan_run_sync !== expect_phase)
         $fatal(1, "release state is %b, expected %b", board.scan_run_sync, expect_phase);
   endtask
   task scan(input [31:0] expected_crc);
      wait(board.scan_complete); #1;
      if (!valid || board.snap_identity[31:0]!==expected_crc)
         $fatal(1, "bad identity got %h expected CRC %h", board.snap_identity,expected_crc);
   endtask
   integer fast_events=0;
   always @(posedge board.memrst) if (lock && fast_run) fast_events=fast_events+1;
   initial begin
      force board.hClk=h; force board.fClk=f; force board.lock_o=lock;
      force board.cartridge_ready=1'b1; force board.latched_cart_rst_n=1'b1;
      force board.BIST_finished=finished; force board.BIST_failed=failed;
      force board.core_cart_d_in=data;
      repeat(24) @(posedge f); lock=1; present=1;
      repeat(32) @(posedge f); hclock();hclock();hclock();
      if (!board.scan_ready) $fatal(1,"first insertion failed");
      fast_run=0;
      scan(32'hdd608109);
      // Each narrow pulse is shorter than a high half-cycle. Choose ten
      // offsets, including pulses before, after, and across a falling edge.
      for(int n=0;n<10;n++) begin
         @(posedge h); #(1+n*5); force board.memrst=1'b1; #1;
         if (board.scan_run_sync!==0 || board.scan_ready || valid)
             $fatal(1,"asynchronous assertion missed at offset %0d",1+n*5);
         #6.5; release board.memrst;
         // memrst is itself a register. Resume ordinary native value after
         // releasing the temporary force before the next h clock.
         board.memrst=0;
         tickcheck(2'b01);
         if (board.scan_complete || board.scan_address!==0 || board.scan_ready || valid)
            $fatal(1,"scanner did not forget old cartridge");
         tickcheck(2'b11);
         if (!board.scan_ready || board.scan_complete || valid)
            $fatal(1,"early assertion after synchronizer release");
      end
      // Stock f-clock hotplug debounce generates a one-period memrst pulse
      // on each genuine edge. Do not force either pulse here.
      fast_run=1; @(negedge h); #3; present=0;
      repeat(32) @(posedge f); hclock();hclock();hclock();
      if (board.scan_ready!==0 || valid!==0 || board.scan_complete!==0)
         $fatal(1,"stale identity after ejection");
      alternate=1; @(negedge h); #6; present=1;
      repeat(32) @(posedge f); hclock();hclock();hclock();
      if (fast_events!==3 || !board.scan_ready || valid)
         $fatal(1,"missed real edge: pulses %0d",fast_events);
      fast_run=0;
      scan(32'hf81b4138);
      @(negedge h); failed=1; finished=0;
      hclock(); if (!valid) $fatal(1,"BIST status skipped stage");
      hclock(); if (valid || !board.scan_supported) $fatal(1,"BIST fail did not mask");
      @(negedge h); failed=0;finished=1;
      hclock(); if(valid) $fatal(1,"early BIST recovery");
      hclock(); if(!valid) $fatal(1,"missing BIST recovery");
      $display("PASS 10 narrow asynchronous pulses, 3 real hotplug pulses, two full ROM CRC identities, synchronous BIST gating");
      $finish;
   end
   initial begin #100000000; $fatal(1,"watchdog"); end
endmodule
