// cart.v
//`include "header.vh"

module cart
(
    input               hclk,
    input               cart_frozen,
    input               pclk,
    input               ce,
    input               ce_2x,
    input               gbreset,
    input               cpu_speed,
    input               cpu_halt,
    input               cpu_stop,
    input               DMA_on,
    input               hdma_active,
    input               wr,
    input               rd,
    input   [15:0]      a,
    input   [7:0]       CART_DOUT,
    input               nCS,
    input   [2:0]       TSTATEo,

    output  reg [15:0]  CART_A,
    output              CART_CLK,
    output  reg         CART_CS = 1'd1,
    input   [7:0]       CART_D_IN,
    output  [7:0]       CART_D_OUT,
    output  reg         CART_RD,
    output  reg         CART_WR = 1'd1,
    output              CART_DATA_DIR_E,
    output  reg [7:0]   CART_DIN_r1,
    input               snapshot_load,
    input   [63:0]      snapshot_in,
    output  [63:0]      snapshot_out
);

    // Both clock domains restore while the speed controller holds the guest
    // frozen. One hClk-wide load covers two pClk cycles on this board.
    wire restore_snapshot = snapshot_load && snapshot_in[63:48] == 16'hc507;
    reg CART_DATA_DIR = 1'd0;
  
    assign CART_DATA_DIR_E = ~CART_DATA_DIR;

    reg phi;
    assign CART_CLK = phi; 
    
    reg [7:0]   CART_DOUT_r1;
    assign CART_D_OUT = CART_DOUT_r1;

    wire [7:0]  CART_DIN; 
    assign CART_DIN = CART_D_IN;
    // Decode the read request on the preceding positive pClk edge, giving
    // the CPU address/select logic a full pClk period before the enable FF.
    // Clear it while frozen so another timeline cannot leave a pending read.
    reg sample_cart_data = 0;
    always @(posedge pclk)
        if (cart_frozen || restore_snapshot) sample_cart_data <= 0;
        else sample_cart_data <= rd || DMA_on;
    always@(negedge pclk)
    begin
        if (restore_snapshot) CART_DIN_r1 <= snapshot_in[29:22];
        else if (!cart_frozen && sample_cart_data) CART_DIN_r1 <= CART_DIN;
    end

    // STOP is a combinational opcode decode in GBse. Only the address latch
    // needs this observation; the physical timing counter retains the direct
    // signal. HALT and external DMA keep their original address behavior.
    reg address_stop = 0;
    always @(posedge hclk)
        if (restore_snapshot) address_stop <= snapshot_in[46];
        else if (gbreset) address_stop <= 0;
        else if (!cart_frozen) address_stop <= cpu_stop;

    reg [3:0] counter;
    wire auplow = (counter == 3)&~cpu_speed;
    wire auphigh = (counter == 1)&cpu_speed;
    wire aup = auplow | auphigh;
    always@(posedge pclk)
        if (restore_snapshot) CART_A <= snapshot_in[45:30];
        else if(!cart_frozen && (aup|address_stop|~cpu_halt|DMA_on))
            CART_A <= a;
    
    reg DMA_on_r1;
    always@(posedge hclk)
        if (restore_snapshot) DMA_on_r1 <= snapshot_in[0];
        else if (!cart_frozen) DMA_on_r1 <= DMA_on;
    
    reg p1;
    reg p2;
    reg [1:0] phiCnt;
    assign snapshot_out = {16'hc507, 1'b0, address_stop, CART_A, CART_DIN_r1, CART_DOUT_r1,
                           phi, CART_CS, CART_RD, CART_WR, CART_DATA_DIR,
                           counter, p1, p2, phiCnt, DMA_on_r1};

    always@(posedge hclk)
    begin
        if (restore_snapshot) begin
            {CART_DOUT_r1, phi, CART_CS, CART_RD, CART_WR, CART_DATA_DIR,
             counter, p1, p2, phiCnt} <= snapshot_in[21:1];
        end
        else if(gbreset)
        begin
            CART_DATA_DIR <= 1'b0;
            CART_RD <= 1'd1;
            CART_WR <= 1'd1;
            CART_CS <= 1'd1;
            counter <= 'd9;
            phi     <= 'd0;
        end
        else if (!cart_frozen)
        begin
            p1 <= ce_2x&~ce;
            p2 <= ce_2x&ce;
            CART_DOUT_r1 <= CART_DOUT;
            // a is valid on first cycle of TSTATE=0, until end of TSTATE=4
            // nCS is valid on first cycle of TSTATE=0, until end of TSTATE=4
            // wr is valid on first cycle of TSTATE=0, until end of TSTATE=4
            // dout is valid on first cycle of TSTATE=2, until ?
                
            // With ~16Mhz we have 16 cycles per low speed cycle
            if(~cpu_speed)
            begin
                if(~cpu_halt | (TSTATEo == 3'd4)&p2)
                    counter <= 'd0;
                else
                    counter <= counter + 1'd1;

                case(counter)
                16'd0:
                begin
                    if(cpu_halt)
                        phi     <=   1'd1;
                    CART_RD <=   1'd0;
                    CART_CS <=   1'd1;
                end
                16'd3:
                begin
//                    CART_A <= a;
                    if(wr)
                        CART_RD        <= 1'd1;
                end
                16'd4:
                begin
                    CART_CS <= nCS;
                end
                16'd7:
                    if(wr)
                        CART_DATA_DIR   <= 1'd1;
                16'd8:
                begin
                    phi             <= 1'd0;
                    if(wr)
                    begin
                        CART_WR         <= 1'd0;
                    end
                end
                16'd14:
                begin
                    CART_WR         <= 1'd1;
                    CART_DATA_DIR   <=  1'd0;
                end
                endcase
            end
            else
            begin // 8MHz mode
                if(~cpu_halt | cpu_stop | (TSTATEo == 3'd4)&~ce_2x)
                    counter <= 'd0;
                else
                    counter <= counter + 1'd1;
                                       
                    phiCnt <= phiCnt + 1'd1;
                
                case(counter)
                16'd0:
                begin
                    if(cpu_halt & ~cpu_stop) begin
                        if (~hdma_active) begin
                           phi     <= 1'd1;
                           phiCnt  <= 2'd0;  
                        end else begin
                           if (phiCnt == 2'd3) begin
                              phi <= ~phi;
                           end
                        end
                    end
                    CART_RD <=   1'd0;
                    CART_CS <=   1'd1;
                end
                16'd1:
                begin
                    CART_CS <= nCS;
                    if(wr)
                        CART_RD        <= 1'd1;
                end
                16'd3:
                    if(wr)
                        CART_DATA_DIR   <= 1'd1;
                16'd4:
                begin
                    phi             <= 1'd0;
                    if(wr)
                    begin
                        CART_WR         <= 1'd0;
                    end
                end
                16'd7:
                begin
                    CART_WR         <= 1'd1;
                    CART_DATA_DIR   <=  1'd0;
                end
                endcase
            end
        end
    end
    
endmodule
