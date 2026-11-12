// Hold the core in reset while reading a ROM fingerprint. All cartridge cycles
// are reads in the normal ROM window. Banking and cartridge RAM are unsupported.
module snapshot_cart (
    input clk, input ready, input [7:0] data,
    output reg [14:0] address = 0,
    output read_n, output reg complete = 0, output supported,
    output [63:0] identity
);
    reg [3:0] phase = 0;
    reg [7:0] mapper, rom_size, ram_size, header;
    reg [31:0] crc = 32'hffffffff;
    reg [7:0] header_calc;
    reg header_ok;
    function [31:0] crc_byte(input [31:0] last, input [7:0] value);
        integer i;
        reg [31:0] next_crc;
        begin
            next_crc = last ^ value;
            for (i = 0; i < 8; i = i + 1)
                next_crc = (next_crc >> 1) ^ (next_crc[0] ? 32'hedb88320 : 0);
            crc_byte = next_crc;
        end
    endfunction

    assign read_n = phase < 2 || phase >= 14;
    assign supported = ready && complete && header_ok &&
                       mapper == 0 && rom_size == 0 && ram_size == 0;
    assign identity = {mapper, rom_size, ram_size, header, ~crc};

    always @(posedge clk) begin
        if (!ready) begin
            complete <= 0;
            address <= 0;
            phase <= 0;
            crc <= 32'hffffffff;
            mapper <= 8'hff;
            rom_size <= 8'hff;
            ram_size <= 8'hff;
            header <= 0;
            header_calc <= 0;
            header_ok <= 0;
        end else if (!complete) begin
            phase <= phase + 1'b1;
            if (phase == 13) begin
                crc <= crc_byte(crc, data);
                if (address >= 'h134 && address <= 'h14c)
                    header_calc <= header_calc - data - 1'b1;
                case (address)
                    'h147: mapper <= data;
                    'h148: rom_size <= data;
                    'h149: ram_size <= data;
                    'h14d: begin
                        header <= data;
                        header_ok <= data == header_calc;
                    end
                endcase
            end
            if (phase == 15) begin
                if (address == 'h7fff || (address == 'h14d &&
                    (mapper != 0 || rom_size != 0 || ram_size != 0 || !header_ok)))
                    complete <= 1;
                else address <= address + 1'b1;
            end
        end
    end
endmodule
