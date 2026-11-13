// Mirror physical mapper writes on /WR release. Serializing the register
// layout used by the upstream MBC5 core also preserves a disabled RAM window.
module snapshot_mbc5_mapper (
    input clk, input cart_ready,
    input write_n, input [15:0] address, input [7:0] data,
    output [15:0] mapper_state
);
    reg [8:0] rom = 1;
    reg [3:0] ram = 0;
    reg ram_enabled = 0;
    reg pending = 0;
    reg [3:0] region;
    reg [7:0] value;
    assign mapper_state = {ram_enabled, 2'b00, ram, rom};
    always @(posedge clk) begin
        if (!cart_ready) begin
            rom <= 1;
            ram <= 0;
            ram_enabled <= 0;
            pending <= 0;
        end else if (!write_n) begin
            region <= address[15:12];
            value <= data;
            pending <= 1;
        end else if (pending) begin
            case (region)
                0,1: ram_enabled <= value[3:0] == 4'ha;
                2: rom[7:0] <= value;
                3: rom[8] <= value[0];
                4,5: ram <= value[3:0];
            endcase
            pending <= 0;
        end
    end
endmodule
