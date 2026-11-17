// Keep the core in reset while fingerprinting the cartridge. MBC5 ROM banks
// are selected through the physical bus, then bank one is restored for boot.
module snapshot_cart (
    input clk, input ready, input [7:0] data,
    output [14:0] address,
    output read_n, output reg complete = 0, output supported,
    output [63:0] identity,
    output write_n, output [7:0] write_data, output write_active
);
    localparam READ = 0, BANK_LOW = 1, BANK_HIGH = 2,
               RESTORE_LOW = 3, RESTORE_HIGH = 4;
    reg [2:0] state = READ;
    reg [3:0] phase = 0;
    reg read_strobe = 0, write_strobe = 0;
    reg [14:0] read_address = 0;
    reg [8:0] bank = 1;
    reg [7:0] mapper, rom_size, ram_size, header;
    reg [31:0] crc = 32'hffffffff;
    // Complete eight polynomial steps in four idle bus clocks per byte.
    reg [2:0] crc_steps = 0;
    reg finish_crc = 0;
    reg [7:0] header_calc;
    reg header_ok;
    wire rom_only = mapper == 0 && rom_size == 0 && ram_size == 0;
    wire mbc5 = rom_size <= 8 &&
                ((mapper == 8'h19 && ram_size == 0) ||
                 ((mapper == 8'h1a || mapper == 8'h1b) &&
                  (ram_size == 2 || ram_size == 3)));
    wire [9:0] last_bank = (10'd2 << rom_size) - 1'b1;
    function [31:0] crc_two_bits(input [31:0] last);
        integer i;
        reg [31:0] next_crc;
        begin
            next_crc = last;
            for (i = 0; i < 2; i = i + 1)
                next_crc = (next_crc >> 1) ^ (next_crc[0] ? 32'hedb88320 : 0);
            crc_two_bits = next_crc;
        end
    endfunction

    assign write_active = ready && !complete && state != READ;
    // The registered strobe already includes state/complete. Avoid a second
    // decode in the physical /WR path; ready still isolates reset/ejection.
    assign write_n = !ready || !write_strobe;
    assign address = state == READ ? read_address :
                     (state == BANK_LOW || state == RESTORE_LOW) ? 15'h2000 : 15'h3000;
    assign write_data = state == BANK_LOW ? bank[7:0] :
                        state == BANK_HIGH ? {7'd0, bank[8]} :
                        state == RESTORE_LOW ? 8'd1 : 8'd0;
    assign read_n = !ready || !read_strobe;
    assign supported = ready && complete && header_ok && (rom_only || mbc5);
    assign identity = {mapper, rom_size, ram_size, header, ~crc};

    // Register the physical strobes so multi-bit counter transitions cannot
    // produce narrow /RD or /WR glitches on the cartridge connector.
    always @(posedge clk) begin
        read_strobe <= ready && !complete && !finish_crc && state == READ && phase >= 1 && phase < 13;
        write_strobe <= ready && !complete && state != READ && phase >= 3 && phase < 11;
        if (!ready) begin
            complete <= 0;
            read_address <= 0;
            phase <= 0;
            state <= READ;
            bank <= 1;
            crc <= 32'hffffffff;
            crc_steps <= 0;
            finish_crc <= 0;
            mapper <= 8'hff;
            rom_size <= 8'hff;
            ram_size <= 8'hff;
            header <= 0;
            header_calc <= 0;
            header_ok <= 0;
        end else if (!complete) begin
            if (crc_steps != 0) begin
                crc <= crc_two_bits(crc);
                crc_steps <= crc_steps - 1'b1;
            end
            // A terminal byte finishes its CRC before publishing identity.
            if (finish_crc) begin
                if (crc_steps == 0) complete <= 1;
            end else begin
                phase <= phase + 1'b1;
                if (state == READ && phase == 13) begin
                    crc <= crc ^ {24'd0, data};
                    crc_steps <= 4;
                    // Only the fixed bank contains the cartridge header.
                    if (read_address >= 'h134 && read_address <= 'h14c)
                        header_calc <= header_calc - data - 1'b1;
                    case (read_address)
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
                    case (state)
                        READ: begin
                            if (read_address == 'h14d && (!header_ok || !(rom_only || mbc5)))
                                finish_crc <= 1;
                            else if (read_address != 'h7fff)
                                read_address <= read_address + 1'b1;
                            else if (rom_only)
                                finish_crc <= 1;
                            else if ({1'b0, bank} == last_bank)
                                state <= RESTORE_LOW;
                            else begin
                                bank <= bank + 1'b1;
                                state <= BANK_LOW;
                            end
                        end
                        BANK_LOW: state <= BANK_HIGH;
                        BANK_HIGH: begin
                            read_address <= 'h4000;
                            state <= READ;
                        end
                        RESTORE_LOW: state <= RESTORE_HIGH;
                        RESTORE_HIGH: begin
                            complete <= 1;
                            state <= READ;
                        end
                    endcase
                end
            end
        end
    end
endmodule
