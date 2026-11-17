`timescale 1ns/1ps

// Read-only shim for the parameterized VHDL register. This test holds the
// clock still and exercises live capture data; the separate palette regression
// tests register writes and complete capture/restore with the real sequencer.
module eReg_SavestateV #(
    parameter index = 0, address = 0, upper = 63, lower = 0,
    parameter [63:0] initial_value = 0
) (
    input clk, input [63:0] data, input [9:0] addr, input write_en, reset,
    output [63:0] readback, input [upper:lower] live,
    output [upper:lower] saved
);
    assign readback = addr == address + index ? (64'(live) << lower) : 0;
    assign saved = initial_value[upper:lower];
endmodule

module snapshot_palette_readback_tb;
    reg [9:0] address;
    reg [60:0] video1;
    reg [63:0] video2, video3;
    reg [7:0] palette[0:127];
    wire [63:0] readback;

    video dut(
        .clk(1'b0), .reset(1'b0), .ce(1'b0), .ce_cpu(1'b0),
        .isGBC(1'b1), .isGBC_mode(1'b1), .SaveStateBus_Adr(address),
        .SaveStateBus_Din(64'd0), .SaveStateBus_wren(1'b0), .SaveStateBus_rst(1'b0),
        .SaveStateBus_Dout(readback)
    );

    // Preserve the previous 19-source, address-masked OR implementation as
    // the reference. Palette sources are the actual video's live byte arrays.
    wire [63:0] legacy_words[0:18];
    assign legacy_words[0] = address == 9 ? {3'd0, dut.SS_Video1_BACK} : 0;
    assign legacy_words[1] = address == 10 ? dut.SS_Video2_BACK : 0;
    assign legacy_words[18] = address == 27 ? dut.SS_Video3_BACK : 0;
    genvar row;
    generate for (row = 0; row < 8; row = row + 1) begin: legacy_palette
        assign legacy_words[2+row] = address == 11+row ? dut.SS_BPAL_BACK[row] : 0;
        assign legacy_words[10+row] = address == 19+row ? dut.SS_OPAL_BACK[row] : 0;
    end endgenerate
    reg [63:0] legacy_readback;
    always @* begin
        legacy_readback = 0;
        for (integer word_index = 0; word_index < 19; word_index = word_index + 1)
            legacy_readback = legacy_readback | legacy_words[word_index];
    end

    integer cases_checked = 0;
    reg [63:0] expected;
    initial begin
        // The three live register words are arbitrary independent values.
        // Palette data still flows through the real bgpd/obpd -> BACK wiring.
        force dut.SS_Video1_BACK = video1;
        force dut.SS_Video2_BACK = video2;
        force dut.SS_Video3_BACK = video3;
        for (integer trial = 0; trial < 32; trial = trial + 1) begin
            video1 = {$random, $random};
            video2 = {$random, $random};
            video3 = {$random, $random};
            if (trial == 0) begin video1 = 0; video2 = 0; video3 = 0; end
            if (trial == 1) begin video1 = '1; video2 = '1; video3 = '1; end
            for (integer i = 0; i < 128; i = i + 1) begin
                case (trial)
                    0: palette[i] = 0;
                    1: palette[i] = 8'hff;
                    2: palette[i] = i;
                    default: palette[i] = $random;
                endcase
            end
            for (integer i = 0; i < 64; i = i + 1) begin
                dut.bgpd[i] = palette[i];
                dut.obpd[i] = palette[64+i];
            end
            for (integer a = 0; a < 1024; a = a + 1) begin
                address = a;
                expected = 0;
                case (a)
                    9: expected = {3'd0, video1};
                    10: expected = video2;
                    27: expected = video3;
                    default: if (a >= 11 && a <= 26)
                        for (integer b = 0; b < 8; b = b + 1)
                            expected[b*8+:8] = palette[(a-11)*8+b];
                endcase
                #1;
                if (legacy_readback !== expected || readback !== legacy_readback)
                    $fatal(1, "Palette readback differs trial=%0d addr=%0d old=%h actual=%h expected=%h",
                           trial, a, legacy_readback, readback, expected);
                cases_checked = cases_checked + 1;
            end
        end
        $display("PASS palette readback: %0d full-width comparisons with legacy OR, all addresses 0..1023, zero/ones/byte-order/random live states", cases_checked);
        $finish;
    end
endmodule
