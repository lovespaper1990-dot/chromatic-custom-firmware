// Physical cart bus cycles in hClk (16.78 MHz). The external arbiter must
// hold the game paused throughout all commands and while restoring mapper
// registers. Register the strobes so counter transitions cannot pulse /WR.
module snapshot_mbc5_bus (
    input clk, input ready, input start, input write_byte,
    input [15:0] address, input [7:0] data_out, input [7:0] cart_in,
    output reg busy = 0, output reg done = 0, output reg [7:0] data_in,
    output reg [15:0] cart_addr, output reg [7:0] cart_out,
    output read_n, output write_n, output cs_n, output input_dir
);
    reg [3:0] phase = 0;
    reg writing;
    reg rd = 1, wr = 1, cs = 1, direction = 1;
    assign read_n = !ready || rd;
    assign write_n = !ready || wr;
    assign cs_n = !ready || cs;
    assign input_dir = !ready || direction;
    always @(posedge clk) begin
        done <= 0;
        if (!ready) begin
            busy <= 0;
            phase <= 0;
            rd <= 1;
            wr <= 1;
            cs <= 1;
            direction <= 1;
        end else if (!busy) begin
            if (start) begin
                cart_addr <= address;
                cart_out <= data_out;
                writing <= write_byte;
                busy <= 1;
                phase <= 0;
            end
        end else begin
            if (phase != 15) phase <= phase + 1'b1;
            case (phase)
                0: direction <= !writing;
                1: cs <= !(cart_addr[15:13] == 3'b101);
                3: begin rd <= writing; wr <= !writing; end
                11: begin
                    if (!writing) data_in <= cart_in;
                    rd <= 1;
                    wr <= 1;
                end
                13: begin cs <= 1; direction <= 1; end
                15: begin done <= 1; busy <= 0; end
            endcase
        end
    end
endmodule
