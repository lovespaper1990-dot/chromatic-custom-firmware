`timescale 1ns/1ps
module standby_tb;
    reg g=0, h=1, p=0, lock=0, power_off=0, menu_n=1, physical_a=0;
    reg tick=0, menu_ready=1, core_reset=1, snapshot_active=0, read_cycle=0;
    reg [8:0] injected=0;
    always #8 g=~g;
    always #4 h=~h;
    always #2 p=~p;
    top board(.POWER_ON_FPGA(power_off), .BTN_MENU(menu_n), .BTN_A(physical_a),
              .BTN_B(1'b0), .BTN_DPAD_UP(1'b0), .BTN_DPAD_DOWN(1'b0),
              .BTN_DPAD_LEFT(1'b0), .BTN_DPAD_RIGHT(1'b0), .BTN_SEL(1'b0), .BTN_START(1'b0));
    // Shorten only the physical debouncer. Exercise the normal 150 tick
    // threshold, actual system monitor, cart sequencer and VHDL clock control.
    defparam board.debouncer_MENU.HIGHBIT=2;
    defparam board.debouncer_A.HIGHBIT=2;
    integer progress=0;
    always @(posedge h)
        if (board.u_emu_system_top.ce) progress<=progress+1;

    task clocks(input integer n);
        repeat(n) @(negedge g);
    endtask
    task timer_ticks(input integer n);
        repeat(n) begin tick=1; clocks(1); tick=0; clocks(1); end
    endtask
    task press_menu; menu_n=0; clocks(32); endtask
    task release_menu; menu_n=1; clocks(32); endtask
    task check_outputs(input bit asleep);
        if (board.LCD_PWM !== !asleep ||
            board.left !== (asleep ? 16'd0 : 16'h3456) ||
            board.right !== (asleep ? 16'd0 : 16'h789a) ||
            board.u_mem_system_top.AUDIO_ENABLE !== !asleep ||
            board.u_usb_top.video_pixel !== (asleep ? 18'd0 : 18'h21fab) ||
            board.u_usb_top.standby !== asleep ||
            {board.u_usb_top.video_valid,board.u_usb_top.video_frame_start,board.u_usb_top.video_line_end} !== 3'b101)
            $fatal(1,"standby output mismatch, expected asleep=%b",asleep);
    endtask
    integer saved;
    initial begin
        force board.hClk=h; force board.gClk=g; force board.pClk=p; force board.lock_o=lock;
        force board.u_emu_system_top.gbreset=core_reset;
        force board.cartridge_ready=1; force board.scan_complete=1;
        force board.u_emu_system_top.ss_active=snapshot_active;
        force board.u_emu_system_top.sleep_savestate=0;
        force board.u_emu_system_top.rd=read_cycle; force board.u_emu_system_top.wr=0;
        force board.u_emu_system_top.DMA_on=0; force board.u_emu_system_top.cpu_speed=0;
        force board.u_emu_system_top.cpu_halt=1; force board.u_emu_system_top.cpu_stop=0;
        force board.u_emu_system_top.TSTATEo=3'd2;
        force board.percentEna=tick; force board.menu_ready=menu_ready;
        force board.capture_valid=1; force board.capture_frame_start=0;
        force board.capture_line_end=1; force board.capture_pixel=18'h21fab;
        force board.game_left=16'h3456; force board.game_right=16'h789a;
        force board.system_control=16'h8000;
        force board.u_system_monitor.MCU_buttons=injected;
        force board.u_system_monitor.LCD_INIT_DONE=1;
        force board.u_system_monitor.LCD_BACKLIGHT_INIT=1;
        force board.u_system_monitor.lcdcount=0;
        force board.BTN_B_filtered=0; force board.BTN_DPAD_UP_filtered=0;
        force board.BTN_DPAD_DOWN_filtered=0; force board.BTN_DPAD_LEFT_filtered=0;
        force board.BTN_DPAD_RIGHT_filtered=0; force board.BTN_SEL_filtered=0;
        force board.BTN_START_filtered=0;
        board.debouncer_MENU.filtered=0; board.debouncer_A.filtered=0;
        clocks(8); core_reset=0; lock=1; clocks(32);
        check_outputs(0);
        press_menu(); release_menu();
        if(board.menuDisabled !== 0) $fatal(1,"short menu did not open");
        press_menu(); timer_ticks(160);
        if(board.standby !== 0) $fatal(1,"standby during OSD operation");
        release_menu();
        if(board.menuDisabled !== 1) $fatal(1,"menu did not close");

        // An injected chord consumes the long press and its release.
        press_menu(); timer_ticks(100); injected[3]=1; clocks(8);
        injected=0; timer_ticks(100); release_menu();
        if (!board.menuDisabled || board.standby) $fatal(1,"chord entered standby or menu");

        // A running game can sleep before the OSD handshake or a supported
        // snapshot cartridge. An already running snapshot wins arbitration.
        menu_ready=0; snapshot_active=1; read_cycle=1;
        press_menu(); timer_ticks(149);
        if (board.standby) $fatal(1,"early threshold");
        timer_ticks(1); clocks(6);
        if (!board.standby || board.u_emu_system_top.cart_frozen) $fatal(1,"standby request or transfer arbitration");
        check_outputs(1);
        saved=progress; clocks(40);
        if(progress==saved) $fatal(1,"standby blocked active snapshot");
        snapshot_active=0; clocks(12);
        if (board.u_emu_system_top.cart_frozen) $fatal(1,"paused an active ROM read");
        read_cycle=0; wait(board.u_emu_system_top.cart_frozen); clocks(2);
        saved=progress;
        release_menu(); timer_ticks(200);
        if(!board.standby || saved!=progress || !board.menuDisabled) $fatal(1,"entry release woke console");
        physical_a=1; injected[2]=1; clocks(40);
        if(!board.standby || board.u_emu_system_top.BTN_A_filtered || board.u_emu_system_top.BTN_B_filtered)
            $fatal(1,"keys leaked while asleep");
        press_menu(); release_menu();
        if(!board.standby) $fatal(1,"woke with held keys");
        physical_a=0; clocks(40);
        if(!board.standby) $fatal(1,"ignored injected key");
        injected=0; clocks(40);
        if(board.standby || !board.menuDisabled || progress<=saved) $fatal(1,"failed to resume");
        check_outputs(0);
        if(board.u_emu_system_top.BTN_A_filtered || board.u_emu_system_top.BTN_B_filtered)
            $fatal(1,"wake keys reached game");
        // A real power switch/reset always clears the volatile session.
        press_menu(); timer_ticks(150); release_menu(); power_off=1; clocks(3);
        if(board.standby || !board.menuDisabled) $fatal(1,"power switch kept stale state");
        $display("PASS MENU short/long/chord, sleep at 150 ticks, held-key consumption, snapshot and cartridge arbitration, retained CPU enables, LCD/PCM/USB and switch reset");
        $finish;
    end
    initial begin #1000000; $fatal(1,"standby timeout"); end
endmodule
