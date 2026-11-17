`timescale 1ns/1ps
// Exercise the board's actual USB DTR/RTS -> ESP32 reset/strap logic. Only
// unrelated PLL/USB blocks are black boxes. Shorten the 4096-cycle prescaler,
// retaining all 255 strap-hold ticks and the real delayed-EN shift register.
module esp32_sd_strap_tb;
    reg gclk=0, usbclk=0, usb_locked=0;
    reg dtr=0, rts=0, sd_pull_low=0;
    always #5 gclk=~gclk;
    always #3 usbclk=~usbclk;
    tri io0;
    wire en;
    assign io0=sd_pull_low ? 1'b0 : 1'bz;
    top board(.ESP32_IO0(io0),.ESP32_EN(en),.POWER_ON_FPGA(1'b0));

    task tick;
        @(posedge gclk); #1;
    endtask
    task usb_settle;
        repeat(3) @(posedge usbclk);
        repeat(3) tick();
    endtask
    task check_normal_window;
        integer n;
        begin
            wait(en===1'b1); #1;
            if(io0!==1'b1 || board.ESP32_IO0_STRAP_HOLD!==0)
                $fatal(1,"normal boot did not start with an active high strap");
            for(n=1;n<=254;n=n+1) begin
                tick();
                if(io0!==1'b1 || board.ESP32_IO0_STRAP_HOLD!==n)
                    $fatal(1,"strap released before tick 255, tick=%0d hold=%0d IO0=%b",n,board.ESP32_IO0_STRAP_HOLD,io0);
            end
            tick();
            if(io0!==1'bz || board.ESP32_IO0_STRAP_HOLD!==255)
                $fatal(1,"normal boot retained push-pull high after tick 255");
        end
    endtask
    task check_sd_release;
        begin
            // No simulated pullup is attached so Z proves the FPGA released
            // its output. A real card can then pull the shared DAT0 low.
            sd_pull_low=1; #1;
            if(io0!==1'b0) $fatal(1,"SD DAT0 low contends with FPGA output");
            repeat(20) tick();
            if(io0!==1'b0 || board.ESP32_IO0_STRAP_HOLD!==255)
                $fatal(1,"released strap counter wrapped or resumed driving");
            sd_pull_low=0; #1;
            if(io0!==1'bz) $fatal(1,"FPGA output did not remain high impedance");
        end
    endtask

    initial begin
        force board.gClk=gclk;
        force board.PHY_CLKOUT=usbclk;
        force board.usblocked=usb_locked;
        force board.UART_DTR=dtr;
        force board.UART_RTS=rts;
        force board.ESP_BOOT_DELAY_COUNTER=12'd0;
        // No unrelated clock domain or emulator output participates in the
        // boot handshake, and all work remains in this simulated board.
        force board.lock_o=1'b0;
        repeat(3) @(posedge usbclk); usb_locked=1;
        check_normal_window();
        check_sd_release();

        // DTR requests download mode and must pull IO0 low even after the
        // normal startup hold has finished. Releasing it restores Z directly.
        @(negedge gclk); dtr=1;
        usb_settle();
        if(en!==1'b1 || io0!==1'b0 || board.ESP32_IO0_STRAP_HOLD!==255)
            $fatal(1,"DTR did not override high-impedance normal mode");
        @(negedge gclk); dtr=0;
        usb_settle();
        if(io0!==1'bz) $fatal(1,"releasing DTR did not restore high impedance");

        // RTS reset clears the full hold window. Normal boot must again hold
        // high for exactly 255 prescaler ticks after delayed EN rises.
        @(negedge gclk); rts=1;
        usb_settle();
        if(en!==1'b0 || io0!==1'b0 || board.ESP32_IO0_STRAP_HOLD!==0)
            $fatal(1,"RTS reset failed to clear strap-hold counter");
        @(negedge gclk); rts=0;
        check_normal_window();
        check_sd_release();

        // The esptool reset sequence keeps DTR asserted while releasing RTS.
        // Its low strap must survive the entire normal release timeout.
        @(negedge gclk); dtr=1; rts=1;
        usb_settle();
        if(en!==1'b0 || io0!==1'b0) $fatal(1,"download reset did not assert EN/IO0 low");
        @(negedge gclk); rts=0;
        wait(en===1'b1); #1;
        repeat(270) begin
            tick();
            if(io0!==1'b0) $fatal(1,"download strap released while DTR remained asserted");
        end
        if(board.ESP32_IO0_STRAP_HOLD!==255) $fatal(1,"download hold counter did not saturate");
        @(negedge gclk); dtr=0;
        usb_settle();
        if(io0!==1'bz) $fatal(1,"finished download did not release shared DAT0");
        check_sd_release();
        $display("PASS ESP32/SD shared strap: startup high, 255-tick release, DAT0 low without contention, DTR download priority and RTS restart");
        $finish;
    end
    initial begin #100000; $fatal(1,"ESP32 strap test timed out"); end
endmodule
