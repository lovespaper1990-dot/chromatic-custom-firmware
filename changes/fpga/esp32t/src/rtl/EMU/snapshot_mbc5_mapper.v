// Mirror physical mapper writes on /WR release. MBC5 keeps its existing
// state format; MBC1 preserves raw low-five/high-two/mode registers so both
// ROM windows and disabled/banked RAM can be restored without normalization.
module snapshot_mbc5_mapper (
    input clk, input cart_ready, input mbc1,
    input write_n, input [15:0] address, input [7:0] data,
    output [15:0] mapper_state
);
    reg [8:0] rom = 1;
    reg [3:0] ram = 0;
    reg ram_enabled = 0;
    reg mode = 0;
    reg pending = 0;
    reg [3:0] region;
    reg [7:0] value;
    // MBC1: enable[15], mode[14], secondary[10:9], raw ROM low[4:0].
    assign mapper_state = mbc1 ? {ram_enabled, mode, 3'b000, ram[1:0], 4'b0000, rom[4:0]} :
                                 {ram_enabled, 2'b00, ram, rom};
    always @(posedge clk) begin
        if (!cart_ready) begin
            // The physical scanner leaves both mapper families at low bank 1.
            // Subsequent guest/bridge writes, including MBC1 raw zero, are exact.
            rom <= 1;
            ram <= 0;
            ram_enabled <= 0;
            mode <= 0;
            pending <= 0;
        end else if (!write_n) begin
            region <= address[15:12];
            value <= data;
            pending <= 1;
        end else if (pending) begin
            if (mbc1) begin
                case (region)
                    0,1: ram_enabled <= value[3:0] == 4'ha;
                    2,3: rom <= {4'b0000, value[4:0]};
                    4,5: ram <= {2'b00, value[1:0]};
                    6,7: mode <= value[0];
                endcase
            end else begin
                case (region)
                    0,1: ram_enabled <= value[3:0] == 4'ha;
                    2: rom[7:0] <= value;
                    3: rom[8] <= value[0];
                    4,5: ram <= value[3:0];
                endcase
            end
            pending <= 0;
        end
    end
endmodule
