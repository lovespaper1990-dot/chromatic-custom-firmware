// emu_system_top.v

module emu_system_top
(
    input snapshot_power_reset, input snap_supported, input [63:0] snap_identity,
    output snap_request, output [12:0] snap_index, output snap_read,
    output [63:0] snap_out, input [63:0] snap_in, input snap_ack,
    input snap_cmd_toggle, input [6:0] snap_cmd, input [79:0] snap_cmd_data,
    output snap_reply_toggle, output [79:0] snap_reply,
    input               hclk,
    input               pclk,
    input               fclk, 
    input               xclk,
    input               reset_n,
    input               POWER_GOOD,
    
    input               customPaletteEna,
    input [63:0]        paletteBGIn,
    input [63:0]        paletteOBJ0In,
    input [63:0]        paletteOBJ1In,
    input [2:0]         gbc_color_temp,
    input               paletteOff,
    output              gbc_mode,
    output [63:0]       gpd,
    
    input               BTN_NODIAGONAL,
    input               BTN_A,
    input               BTN_B,
    input               BTN_DPAD_DOWN,
    input               BTN_DPAD_LEFT,
    input               BTN_DPAD_RIGHT,
    input               BTN_DPAD_UP,
    input               BTN_MENU,
    input               BTN_SEL,
    input               BTN_START,
    input               MENU_CLOSED,
    input               standby, // synchronized to hclk
    output              boot_rom_enabled,
    output  [15:0]      CART_A,
    output              CART_CLK,
    output              CART_CS,
    input   [7:0]       CART_D_IN,
    output  [7:0]       CART_D_OUT,
    output              CART_RD,
    output              CART_WR,
    output              CART_DATA_DIR_E,

    input               IR_RX,
    output              IR_LED,

    inout               LINK_CLK,
    output              LINK_CLK_DIR_LV,
    input               LINK_IN,
    output              LINK_OUT,

    output [15:0]       left,
    output [15:0]       right,

    output lcd_on_int,
    output lcd_off_overwrite,
    
    input               LCD_INIT_DONE,
    output              gb_lcd_clkena,
    output [14:0]       gb_lcd_data,
    output [1:0]        gb_lcd_mode,
    output              gb_lcd_on,
    output              gb_lcd_vsync,

    input               latched_cart_rst_n,
    output  wire        o_emulator_reset    // core reset should be used to paint black screen

);


    parameter SRSIZE = 15;

    reg [SRSIZE-1:0] BTN_DPAD_DOWN_sr;
    reg [SRSIZE-1:0] BTN_DPAD_UP_sr;
    reg [SRSIZE-1:0] BTN_DPAD_LEFT_sr;
    reg [SRSIZE-1:0] BTN_DPAD_RIGHT_sr;

    reg [SRSIZE-1:0] BTN_START_sr;
    reg [SRSIZE-1:0] BTN_SEL_sr;
    reg [SRSIZE-1:0] BTN_B_sr;
    reg [SRSIZE-1:0] BTN_A_sr;

    reg BTN_DPAD_DOWN_filtered;
    reg BTN_DPAD_UP_filtered;
    reg BTN_DPAD_LEFT_filtered;
    reg BTN_DPAD_RIGHT_filtered;
    reg BTN_START_filtered;
    reg BTN_SEL_filtered;
    reg BTN_B_filtered;
    reg BTN_A_filtered;
    
    reg BTN_DPAD_DOWN_filtered_dir;
    reg BTN_DPAD_UP_filtered_dir;
    reg BTN_DPAD_LEFT_filtered_dir;
    reg BTN_DPAD_RIGHT_filtered_dir;

    always@(posedge pclk)
    begin
        BTN_DPAD_DOWN_sr <= {BTN_DPAD_DOWN_sr[SRSIZE-2:0], BTN_DPAD_DOWN&~BTN_MENU&MENU_CLOSED};
        BTN_DPAD_UP_sr <= {BTN_DPAD_UP_sr[SRSIZE-2:0], BTN_DPAD_UP&~BTN_MENU&MENU_CLOSED};
        BTN_DPAD_LEFT_sr <= {BTN_DPAD_LEFT_sr[SRSIZE-2:0], BTN_DPAD_LEFT&~BTN_MENU&MENU_CLOSED};
        BTN_DPAD_RIGHT_sr <= {BTN_DPAD_RIGHT_sr[SRSIZE-2:0], BTN_DPAD_RIGHT&~BTN_MENU&MENU_CLOSED};
        BTN_START_sr <= {BTN_START_sr [SRSIZE-2:0], BTN_START&~BTN_MENU&MENU_CLOSED};
        BTN_SEL_sr <= {BTN_SEL_sr [SRSIZE-2:0], BTN_SEL&~BTN_MENU&MENU_CLOSED};
        BTN_A_sr <= {BTN_A_sr [SRSIZE-2:0], BTN_A&~BTN_MENU&MENU_CLOSED};
        BTN_B_sr <= {BTN_B_sr [SRSIZE-2:0], BTN_B&~BTN_MENU&MENU_CLOSED};

        BTN_DPAD_DOWN_filtered <= &BTN_DPAD_DOWN_sr[SRSIZE-1:1];
        BTN_DPAD_UP_filtered <= &BTN_DPAD_UP_sr[SRSIZE-1:1];
        BTN_DPAD_LEFT_filtered <= &BTN_DPAD_LEFT_sr[SRSIZE-1:1];
        BTN_DPAD_RIGHT_filtered <= &BTN_DPAD_RIGHT_sr[SRSIZE-1:1];
        BTN_START_filtered <= &BTN_START_sr[SRSIZE-1:1];
        BTN_SEL_filtered <= &BTN_SEL_sr[SRSIZE-1:1];
        BTN_A_filtered <= &BTN_A_sr[SRSIZE-1:1];
        BTN_B_filtered <= &BTN_B_sr[SRSIZE-1:1];
        
        if (BTN_NODIAGONAL) begin
            BTN_DPAD_DOWN_filtered_dir  <= BTN_DPAD_DOWN_filtered  & ~BTN_DPAD_UP_filtered & ~BTN_DPAD_LEFT_filtered_dir & ~BTN_DPAD_RIGHT_filtered_dir;
            BTN_DPAD_UP_filtered_dir    <= BTN_DPAD_UP_filtered    & ~BTN_DPAD_DOWN_filtered & ~BTN_DPAD_LEFT_filtered_dir & ~BTN_DPAD_RIGHT_filtered_dir;
            BTN_DPAD_LEFT_filtered_dir  <= BTN_DPAD_LEFT_filtered  & ~BTN_DPAD_RIGHT_filtered & ~BTN_DPAD_UP_filtered_dir & ~BTN_DPAD_DOWN_filtered_dir;
            BTN_DPAD_RIGHT_filtered_dir <= BTN_DPAD_RIGHT_filtered & ~BTN_DPAD_LEFT_filtered & ~BTN_DPAD_UP_filtered_dir & ~BTN_DPAD_DOWN_filtered_dir;
        end else begin
            BTN_DPAD_DOWN_filtered_dir  <= BTN_DPAD_DOWN_filtered  & ~BTN_DPAD_UP_filtered;
            BTN_DPAD_UP_filtered_dir    <= BTN_DPAD_UP_filtered    & ~BTN_DPAD_DOWN_filtered;
            BTN_DPAD_LEFT_filtered_dir  <= BTN_DPAD_LEFT_filtered  & ~BTN_DPAD_RIGHT_filtered;
            BTN_DPAD_RIGHT_filtered_dir <= BTN_DPAD_RIGHT_filtered & ~BTN_DPAD_LEFT_filtered;
        end
        
    end

    wire [3:0] btn_key = {
        BTN_DPAD_DOWN_filtered_dir, 
        BTN_DPAD_UP_filtered_dir,
        BTN_DPAD_LEFT_filtered_dir, 
        BTN_DPAD_RIGHT_filtered_dir
    }; 
     
    wire [3:0] dpad_key = {
        BTN_START_filtered,
        BTN_SEL_filtered,
        BTN_B_filtered,
        BTN_A_filtered
    };

    reg [3:0] joy_din;
    wire [1:0] joy_p54;
    always@(posedge hclk)
    begin
        case(joy_p54)
            2'b00: joy_din <= (~btn_key) & (~dpad_key); 
            2'b01: joy_din <= ~dpad_key;
            2'b10: joy_din <= ~btn_key; 
            2'b11: joy_din <= 4'hF;
        endcase
    end

    wire wr;
    wire rd;
    wire [7:0] CART_DOUT;
    wire nCS;

    wire [7:0]  CART_DIN; 
    assign CART_DIN = CART_D_IN;

    wire cpu_speed;
    wire cpu_halt;
    wire cpu_stop;
    
    wire [7:0] CART_DIN_r1;
    wire [15:0] a;
    wire [2:0] TSTATEo;
    wire sleep_savestate;

    wire ss_save, ss_load, ss_busy, ss_loaded, ss_abort, ss_active, ss_restart;
    reg gbreset;
    wire DMA_on;
    wire cart_frozen;
    // A core transfer waiting for VBlank must finish before entering standby.
    wire standby_pause = standby && POWER_GOOD && !gbreset && !ss_active;
    speedcontrol u_speedcontrol
    (
        .clk_sys     (hclk),
        .pause       (sleep_savestate | standby_pause),
        .speedup     (1'b0),
        .cart_act    (rd | wr | (standby_pause && (DMA_on || !CART_WR || !CART_DATA_DIR_E))),
        .DMA_on      (1'b0),
        .ce          (ce),
        .ce_2x       (ce_2x),
        .standby_req (standby_pause),
        .cart_frozen (cart_frozen),
        .refresh     (),
        .ff_on       ()
    );

    wire sel_cram = a[15:13] == 3'b101;           // 8k cart ram at $a000
    wire cart_oe = (rd & ~a[15]) | (sel_cram & rd);



    // Let the state engine reset its register bank before resuming a partially
    // restored game. Keep the boot reset asserted across multiple CPU enables.
    reg [5:0] restart_count = 0;
    always @(posedge hclk) begin
        if (ss_restart) restart_count <= 6'd63;
        else if (restart_count != 0) restart_count <= restart_count - 1'b1;
    end
    // If a cartridge is removed during an in-flight operation, hold the next
    // cartridge in reset until the old core transfer has finished draining.
    reg drain_on_remove = 0;
    always @(posedge hclk) begin
        if (!POWER_GOOD && ss_busy) drain_on_remove <= 1;
        else if (!ss_busy) drain_on_remove <= 0;
    end
    reg gbreset_ungated;
    reg CART_RST_r1;
    reg CART_RST_r2;
    reg ce_2x_r1;
    always@(posedge hclk)
        ce_2x_r1 <= ce_2x;


    // bring out the manufactured reset, will be used to generate black pixels
    assign o_emulator_reset = gbreset;

    always@(posedge hclk or negedge reset_n)
    begin
        if(~reset_n)
        begin
            gbreset <= 1'd1;
            gbreset_ungated <= 1'd1;
        end
        else
        begin
            // latched_cart_rst_n in "xClk" 75 MHz clock domain and was stretched
            // to 256 clock cycles.  This is sufficient to be detected in ~16MHz hclk
            // domain.  Use synchronization registers to avoid metastability. 
            //
            // CART_RST is pulled high ordinarily, pulled low by cartridge under certain 
            // circumstances. 
            ///
            // => using 3-state synchronizer = > safe to false path
            CART_RST_r1 <= latched_cart_rst_n;  
            CART_RST_r2 <= CART_RST_r1;
            gbreset_ungated <= ~LCD_INIT_DONE ? 1'b1 : ~CART_RST_r2;
            if(~ce_2x_r1 & ce_2x & ce)
                gbreset <= gbreset_ungated;
                
            if (MENU_CLOSED & BTN_MENU & BTN_A & BTN_B & BTN_START & BTN_SEL) gbreset <= 1'd1;
            
            if (~POWER_GOOD || drain_on_remove || restart_count != 0 || ss_restart) gbreset <= 1'b1;
        end
    end




    
    wire hdma_active;
    cart u_cart
    (
       .hclk            (hclk           ),
       .pclk            (pclk           ),
       .cart_frozen     (cart_frozen    ),
       .ce              (ce             ),
       .ce_2x           (ce_2x          ),
       .gbreset         (gbreset        ), 
       .cpu_speed       (cpu_speed      ),
       .cpu_halt        (cpu_halt       ),
       .cpu_stop        (cpu_stop       ),
       .wr              (wr             ),
       .rd              (rd             ),
       .a               (a              ),
       .CART_DOUT       (CART_DOUT      ),
       .nCS             (nCS            ),
       .TSTATEo         (TSTATEo        ),
       .DMA_on          (DMA_on         ),
       .hdma_active     (hdma_active    ),
                                        
       .CART_A          (CART_A         ),
       .CART_CLK        (CART_CLK       ),
       .CART_CS         (CART_CS        ),
       .CART_D_IN       (CART_D_IN      ),
       .CART_D_OUT      (CART_D_OUT     ),
       .CART_RD         (CART_RD        ),
       .CART_WR         (CART_WR        ),
       .CART_DATA_DIR_E (CART_DATA_DIR_E),
       .CART_DIN_r1     (CART_DIN_r1    )
    );

    wire sc_int_clock2;
    wire serial_clk_in;
    wire serial_clk_out;
    wire serial_data_out;
    
    reg LINK_IN_r1;
    reg LINK_CLK_r1;
    reg serial_clk_out_r1;
    reg sc_int_clock2_r1;
    reg serial_data_out_r1;
    always@(posedge hclk)
    begin
        LINK_IN_r1         <= LINK_IN;
        LINK_CLK_r1        <= LINK_CLK;
        serial_clk_out_r1  <= serial_clk_out;
        sc_int_clock2_r1   <= sc_int_clock2;
        serial_data_out_r1 <= serial_data_out;
    end


    // when sc_int_clock2_r1 == 1'b1 , output => A->B
    assign LINK_CLK_DIR_LV = sc_int_clock2_r1; 

    assign LINK_CLK = sc_int_clock2_r1 ? serial_clk_out_r1 : 1'bZ;
    assign serial_clk_in = LINK_CLK_r1;

    wire serial_data_in = LINK_IN_r1;
    assign LINK_OUT = serial_data_out_r1;

    wire [63:0] SAVE_out_Din  ;
    wire [63:0] SAVE_out_Dout ;
    wire [25:0] SAVE_out_Adr  ;
    wire SAVE_out_rnw  ;                    
    wire SAVE_out_ena  ;                                    
    wire SAVE_out_done ; 
    
    snapshot_control u_snapshot_control (
        .clk(hclk), .reset(snapshot_power_reset), .supported(snap_supported && !gbreset && !boot_rom_enabled),
        .identity(snap_identity), .cmd_toggle(snap_cmd_toggle), .cmd(snap_cmd),
        .cmd_data(snap_cmd_data), .reply_toggle(snap_reply_toggle), .reply(snap_reply),
        .capture(ss_save), .restore(ss_load), .core_busy(ss_busy),
        .core_loaded(ss_loaded), .core_abort(ss_abort), .active(ss_active), .restart_core(ss_restart),
        .core_req(SAVE_out_ena), .core_read(SAVE_out_rnw), .core_addr(SAVE_out_Adr),
        .core_out(SAVE_out_Din), .core_done(SAVE_out_done), .mem_toggle(snap_request),
        .mem_index(snap_index), .mem_read(snap_read), .mem_out(snap_out),
        .mem_ack(snap_ack), .mem_in(snap_in)
    );
    assign SAVE_out_Dout = snap_in;

    wire [15:0] snd_l;  
    wire [15:0] snd_r;  



    gb u_gb(
        .reset(gbreset),

        .clk_sys(hclk),
        .ce(ce),
        .ce_2x(ce_2x),

        .isGBC(1'd1),
        .real_cgb_boot(1'd0),
        .customPaletteEna(customPaletteEna),
        .paletteBGIn(paletteBGIn),
        .paletteOBJ0In(paletteOBJ0In),
        .paletteOBJ1In(paletteOBJ1In),
        .gbc_color_temp(gbc_color_temp),

        .paletteOff(paletteOff),
        .gbc_mode(gbc_mode),
        .gpd(gpd),

        // cartridge interface
        // can adress up to 1MB ROM
        .ext_bus_addr(a[14:0]),
        .ext_bus_a15(a[15]),
        .cart_rd(rd),
        .cart_wr(wr),
        .cart_do(CART_DIN_r1),
        .cart_di(CART_DOUT),
        .cart_oe(cart_oe),
        .TSTATEo(TSTATEo),
        .TSTATE1(TSTATE1),
        .TSTATE2(TSTATE2),
        .TSTATE3(TSTATE3),
        .TSTATE4(TSTATE4),
        // WRAM or Cart RAM CS
        .nCS(nCS),

        .cgb_boot_download(1'd0),
        .dmg_boot_download(1'd0),
        .ioctl_wr(1'd0),
        .ioctl_addr(25'd0),
        .ioctl_dout(16'd0),

        // Bootrom features
        .boot_rom_enabled(boot_rom_enabled),

        .boot_gba_en(1'd0),
        .fast_boot_en(1'd0),
        // audio
        .audio_l(snd_l),
        .audio_r(snd_r),

        // Megaduck?
        .megaduck(1'd0),

        .IR_RX(IR_RX),
        .IR_LED(IR_LED),

        // lcd interface
        .lcd_clkena(gb_lcd_clkena),
        .lcd_data(gb_lcd_data),
        //      .lcd_data_gb(),
        .lcd_mode(gb_lcd_mode),
        .lcd_on(gb_lcd_on),
        .lcd_vsync(gb_lcd_vsync),

        .joy_p54(joy_p54),
        .joy_din(joy_din),

        .lcd_on_int(lcd_on_int),
        .lcd_off_overwrite(lcd_off_overwrite),

        .speed(cpu_speed),   //GBC
        .cpu_stop(cpu_stop),
        .cpu_halt(cpu_halt),
        .DMA_on(DMA_on),
        .hdma_active(hdma_active),
        .gg_reset(1'd0),
        .gg_en(1'd0),
        .gg_code(129'd0),
        .gg_available(),

        //serial port
        .sc_int_clock2(sc_int_clock2),
        .serial_clk_in(serial_clk_in),
        .serial_clk_out(serial_clk_out),
        .serial_data_in(serial_data_in),
        .serial_data_out(serial_data_out),

        // savestates
        .increaseSSHeaderCount(1'd0),
        .cart_ram_size(8'd0),
        .save_state(ss_save),
        .snapshot_busy(ss_busy), .snapshot_abort(ss_abort), .snapshot_active(ss_active),
        .load_state(ss_load),
        .savestate_number(2'd0),
        .sleep_savestate(sleep_savestate),

        .SaveStateExt_Din(), 
        .SaveStateExt_Adr(), 
        .SaveStateExt_wren(),
        .SaveStateExt_rst(), 
        .SaveStateExt_Dout(64'd0),
        .SaveStateExt_load(ss_loaded),

        .Savestate_CRAMAddr(),     
        .Savestate_CRAMRWrEn(),    
        .Savestate_CRAMWriteData(),
        .Savestate_CRAMReadData(8'd0),

        .SAVE_out_Din  (SAVE_out_Din ),    // data read from savestate
        .SAVE_out_Dout (SAVE_out_Dout),  // data written to savestate
        .SAVE_out_Adr  (SAVE_out_Adr ),    // all addresses are DWORD addresses!
        .SAVE_out_rnw  (SAVE_out_rnw ),     // read = 1, write = 0
        .SAVE_out_ena  (SAVE_out_ena ),     // one cycle high for each action
        .SAVE_out_done (SAVE_out_done),    // should be one cycle high when write is done or read value is valid

        .rewind_on(1'd0),
        .rewind_active(1'd0)

    );
    
    audio_filter u_audio_filter
    (
       .reset    (~reset_n),
       .clk      (hclk),

       .core_l   (snd_l),
       .core_r   (snd_r),

       .filter_l (left),
       .filter_r (right)
    );
    
endmodule
