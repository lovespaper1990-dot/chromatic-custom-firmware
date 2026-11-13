// Physical cart bus cycles in hClk (16.78 MHz). The external arbiter must
// hold the game paused throughout all commands and while restoring mapper
// registers. A byte transfer never switches direction while /WR is low.
module snapshot_mbc5_bus (
    input clk, input ready, input start, input write_byte,
    input [15:0] address, input [7:0] data_out, input [7:0] cart_in,
    output reg busy = 0, output reg done = 0, output reg [7:0] data_in,
    output reg [15:0] cart_addr, output reg [7:0] cart_out,
    output read_n, output write_n, output cs_n, output input_dir
);
    reg [3:0] phase = 0;
    reg writing;
    wire selected = ready && busy;
    wire strobe = selected && phase >= 4 && phase < 12;
    assign read_n = !(strobe && !writing);
    assign write_n = !(strobe && writing);
    assign cs_n = !(selected && cart_addr[15:13] == 3'b101 && phase >= 2 && phase < 14);
    assign input_dir = !(selected && writing && phase >= 1 && phase < 14);
    always @(posedge clk) begin
        done <= 0;
        if (!ready) begin
            busy <= 0;
            phase <= 0;
        end else if (!busy) begin
            if (start) begin
                cart_addr <= address;
                cart_out <= data_out;
                writing <= write_byte;
                busy <= 1;
                phase <= 0;
            end
        end else begin
            phase <= phase + 1'b1;
            if (!writing && phase == 11) data_in <= cart_in;
            if (phase == 15) begin
                done <= 1;
                busy <= 0;
            end
        end
    end
endmodule
