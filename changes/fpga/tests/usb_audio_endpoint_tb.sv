`timescale 1ns/1ps

module usb_audio_endpoint_tb;
    reg clk = 0, gclk = 0, reset = 1, sof = 0, pop = 0, active = 0;
    reg ready = 0;
    reg [31:0] sample = 0;
    wire [7:0] data;
    wire [11:0] length;
    wire cork;
    usbuac_ep dut(reset, clk, sof, gclk, sample[15:0], sample[31:16],
                  pop, active, data, length, cork);
    always #5 clk = !clk;
    always #13 gclk = !gclk;

    // Byte-order oracle: the capture window always holds the latest six
    // accepted stereo samples. The advertised packet is a private copy.
    reg [191:0] capture = 0, packet = 0;
    integer capture_bytes = 0, packet_bytes = 0;
    reg saw_ready = 0, store = 0, switch_pending = 0, publish = 0;
    reg [7:0] expected_data = 0;
    reg [11:0] expected_length = 0;
    integer full_packets = 0, short_packets = 0, underruns = 0, overlaps = 0;
    always @(posedge clk) begin
        saw_ready <= ready;
        if (ready && !saw_ready) store <= 1;
        if (sof) switch_pending <= 1;
        publish <= 0;

        if (store) begin
            if (capture_bytes < 24) begin
                capture <= {sample, capture[191:32]};
                capture_bytes <= capture_bytes + 4;
            end
            store <= 0;
        end else if (switch_pending) begin
            packet_bytes <= capture_bytes;
            capture_bytes <= 0;
            switch_pending <= 0;
            publish <= 1;
            packet <= capture_bytes == 24 ? capture : {32'b0, capture[191:32]};
            if (publish || pop) overlaps <= overlaps + 1;
        end

        // A simultaneous read consumes the prior packet, including at SOF.
        if (publish || pop) begin
            expected_data <= packet[7:0];
            packet <= {8'b0, packet[191:8]};
        end
        if (publish) begin
            expected_length <= packet_bytes >= 20 ? packet_bytes : 0;
            case (packet_bytes)
                24: full_packets <= full_packets + 1;
                20: short_packets <= short_packets + 1;
                default: underruns <= underruns + 1;
            endcase
        end
    end

    integer cycle, seed = 7768;
    initial begin
        // Inject PCM at the sampled-data boundary. The production sample
        // clock and synchronizer are unchanged by the packet storage design.
        force dut.sample = sample;
        force dut.sample_ready = ready;
        for (cycle = 0; cycle < 100000; cycle = cycle + 1) begin
            @(negedge clk);
            // Let the endpoint see complete microframes after power up.
            if (cycle >= 512 && {data, length, cork} !== {expected_data, expected_length, 1'b0})
                $fatal(1, "cycle %0d expected byte %h length %d, got byte %h length %d cork %b",
                       cycle, expected_data, expected_length, data, length, cork);
            reset = cycle % 2451 == 7;
            active = $random(seed);
            sample = $random(seed);
            if (cycle % 2000 < 1000) begin
                ready = cycle % 10 == 2;
                sof = cycle % 56 == 0;
                pop = cycle % 56 >= 4 && cycle % 56 <= 29;
            end else begin
                ready = $random(seed) % 4 == 0;
                sof = $random(seed) % 19 == 0;
                pop = $random(seed) % 3 != 0;
            end
        end
        if (full_packets < 100 || short_packets < 100 || underruns < 100 || overlaps < 100)
            $fatal(1, "missing full, short, underrun, or concurrent packet coverage");
        $display("PASS USB audio packet storage: %0d full, %0d short, %0d underrun, %0d overlapping reads",
                 full_packets, short_packets, underruns, overlaps);
        $finish;
    end
endmodule
