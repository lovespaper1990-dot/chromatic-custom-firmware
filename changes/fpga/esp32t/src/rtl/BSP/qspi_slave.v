// QSPI_Slave.v

module QSPI_Slave(
    input               QSPI_CLK,
    input               QSPI_CS,
    input               QSPI_MOSI,
    inout               QSPI_MISO,
    input               QSPI_WP,
    input               QSPI_HD,
    input               AUD_MCLK,
    input               AUDIO_ENABLE,
    input      [6:0]    WHEEL,

    input      [15:0]   LEFT,
    input      [15:0]   RIGHT,
    
    output              qMenuInit,
    output              qDataValid,
    output      [15:0]  qData,
    output  reg [31:0]  qAddress = 'd0,
    output  reg [9:0]   qLength = 'd0,
    output  reg         qCommand = 'd0
);

    // Command 0x015 and the 44.1 kHz phase increment follow Jokippo's
    // chromatic_fpga_bt protocol. Each read returns interleaved S16_LE PCM.
    localparam CMD_AUDIO = 10'h015;
    localparam CMD_WHEEL = 10'h016;
    // The codec holds its reading between I2C polls. Require consecutive
    // synchronized samples to agree before exposing all seven bits together.
    reg [6:0] wheel_sync1 = 127, wheel_sync2 = 127, wheel_last = 127, wheel_value = 127;
    always @(posedge QSPI_CLK) begin
        wheel_sync1 <= WHEEL;
        wheel_sync2 <= wheel_sync1;
        wheel_last <= wheel_sync2;
        if (wheel_last == wheel_sync2) wheel_value <= wheel_sync2;
    end
    reg wheel_xfer = 0;
    reg [31:0] wheel_shift = 0;
    localparam AF_BITS = 11;
    reg [31:0] audio_ram [0:(1 << AF_BITS)-1];
    reg [AF_BITS:0] write_ptr = 0, read_ptr = 0;
    reg [AF_BITS:0] write_gray = 0, read_gray = 0;
    reg [AF_BITS:0] write_sync1 = 0, write_sync2 = 0;
    reg [AF_BITS:0] read_sync1 = 0, read_sync2 = 0;
    wire [AF_BITS:0] next_write = write_ptr + 1'b1;
    wire [AF_BITS:0] next_read = read_ptr + 1'b1;
    wire [AF_BITS:0] next_read_gray = (next_read >> 1) ^ next_read;
    wire fifo_full = (write_gray == {~read_sync2[AF_BITS:AF_BITS-1], read_sync2[AF_BITS-2:0]});

    // 8.388608 MHz * 22579200 / 2^32 = 44100 stereo frames per second.
    reg [31:0] phase = 0;
    wire [32:0] next_phase = {1'b0,phase} + 33'd22579200;
    // Clear both FIFO domains when switching back to the analog output.
    // Each domain releases reset only after two local clock edges.
    reg [1:0] enable_write = 0, enable_read = 0;
    always @(posedge AUD_MCLK or negedge AUDIO_ENABLE)
        if (!AUDIO_ENABLE) enable_write <= 0;
        else enable_write <= {enable_write[0], 1'b1};
    always @(posedge QSPI_CLK or negedge AUDIO_ENABLE)
        if (!AUDIO_ENABLE) enable_read <= 0;
        else enable_read <= {enable_read[0], 1'b1};

    always @(posedge AUD_MCLK) begin
        phase <= next_phase[31:0];
        if (enable_write[1] && next_phase[32] && !fifo_full)
            audio_ram[write_ptr[AF_BITS-1:0]] <= {LEFT[7:0], LEFT[15:8], RIGHT[7:0], RIGHT[15:8]};
    end
    always @(posedge AUD_MCLK or negedge enable_write[1]) begin
        if (!enable_write[1]) begin
            write_ptr <= 0;
            write_gray <= 0;
            read_sync1 <= 0;
            read_sync2 <= 0;
        end else begin
            read_sync1 <= read_gray;
            read_sync2 <= read_sync1;
            if (next_phase[32] && !fifo_full) begin
                write_ptr <= next_write;
                write_gray <= (next_write >> 1) ^ next_write;
            end
        end
    end

    reg qAddReady = 'd0;
    reg qLenReady = 'd0;

    reg [3:0] qPins_r1 = 'd0;
    reg [7:0] qDataByte = 'd0;
    reg qCyclePhase = 'd0;

    reg qValid = 'd0;
    wire [3:0] qPins = {
                    QSPI_HD,
                    QSPI_WP,
                    QSPI_MISO,
                    QSPI_MOSI};

    reg [7:0] qCycleCount = 'd0;

    reg qMenuInit1 = 1'd0;
    reg qMenuInit2 = 1'd0;
    assign qMenuInit = qMenuInit2;

    reg audio_xfer = 0;
    // Discard a transfer interrupted by mute, even if the master stops its
    // clock and continues the command after the console wakes.
    reg audio_xfer_live = 0;
    always @(posedge QSPI_CLK or negedge enable_read[1])
        if (!enable_read[1]) audio_xfer_live <= 0;
        else if (!QSPI_CS && qLenReady) audio_xfer_live <= !qCommand && qLength == CMD_AUDIO;
    reg audio_bit = 0;
    reg [4:0] bit_index = 0;
    reg [30:0] shift_audio = 0;
    reg have_sample = 0;
    reg [31:0] head_sample;
    // The last bit is launched when bit_index is 31 and sampled one edge
    // later. An interrupted frame remains at the FIFO head for a retry.
    wire pop_frame = !QSPI_CS && audio_xfer_live && audio_xfer && qCycleCount >= 18 &&
                     bit_index == 0 && have_sample;
    wire prefetch_next = !QSPI_CS && audio_xfer && bit_index == 31 && have_sample;
    wire [AF_BITS-1:0] prefetch = prefetch_next ? next_read[AF_BITS-1:0] : read_ptr[AF_BITS-1:0];
    wire fifo_empty = (pop_frame ? next_read_gray : read_gray) == write_sync2;

    // Synchronous RAM read port, independent of the audio capture clock.
    always @(posedge QSPI_CLK)
        head_sample <= audio_ram[prefetch];
    always @(posedge QSPI_CLK or negedge enable_read[1]) begin
        if (!enable_read[1]) begin
            read_ptr <= 0;
            read_gray <= 0;
            write_sync1 <= 0;
            write_sync2 <= 0;
        end else begin
            write_sync1 <= write_gray;
            write_sync2 <= write_sync1;
            if (pop_frame) begin
                read_ptr <= next_read;
                read_gray <= next_read_gray;
            end
        end
    end

    // The ESP samples on rising clocks. Launch the first bit at the end
    // of the seven dummy clocks so that it is stable at the first data clock.
    always @(posedge QSPI_CLK or posedge QSPI_CS) begin
        if (QSPI_CS) begin
            bit_index <= 0;
            audio_xfer <= 0;
            wheel_xfer <= 0;
        end else begin
            if (qLenReady && !qCommand && qLength == CMD_WHEEL) begin
                wheel_xfer <= 1;
                wheel_shift <= {8'h57, 1'b0, wheel_value, 1'b1, ~wheel_value, 8'ha6};
            end else if (wheel_xfer && qCycleCount >= 18)
                wheel_shift <= {wheel_shift[30:0], 1'b0};
            if (qLenReady && !qCommand && qLength == CMD_AUDIO)
                audio_xfer <= 1;
            if (audio_xfer && qCycleCount >= 17) begin
                if (bit_index == 0) begin
                    have_sample <= !fifo_empty;
                    audio_bit <= fifo_empty ? 1'b0 : head_sample[31];
                    shift_audio <= fifo_empty ? 31'b0 : head_sample[30:0];
                end else begin
                    audio_bit <= shift_audio[30];
                    shift_audio <= {shift_audio[29:0], 1'b0};
                end
                bit_index <= bit_index + 1'b1;
            end
        end
    end

    assign QSPI_MISO = !QSPI_CS && wheel_xfer && qCycleCount >= 18 ? wheel_shift[31] :
                       !QSPI_CS && audio_xfer && qCycleCount >= 18 ? (audio_bit & audio_xfer_live) : 1'bz;

    always@(posedge QSPI_CLK or posedge QSPI_CS)
    begin
        if(QSPI_CS)
        begin
            qCyclePhase <= 1'd0;
            qValid      <= 1'd0;
            qCycleCount <= 1'd0;
            qCommand    <= 1'd0;
            qAddReady   <= 1'd0;
            qLenReady   <= 1'd0;
        end
        else
        begin
            if(qCycleCount <= 50)
                qCycleCount   <= qCycleCount + 1'd1;
            
            // Command
            if(qCycleCount == 0)
                qCommand <= QSPI_MOSI;

            if((qCycleCount >= 1) && (qCycleCount <= 10))
                qLength <= {qLength[8:0], QSPI_MOSI};
                
            if((qCycleCount >= 11) && (qCycleCount <= 42))
                qAddress <= {qAddress[30:0], QSPI_MOSI};
                
            if(qCycleCount == 11)
                qLenReady <= 1'd1;
            else
                qLenReady <= 1'd0;

            if(qCycleCount == 43)
            begin
                qAddReady <= 1'd1;
                if(qCommand && qAddress == 0) // first display row
                begin
                    qMenuInit1  <=  1'd1;
                    if(qMenuInit1)
                        qMenuInit2 <= 1'd1;
                end
            end
            else
                qAddReady <= 1'd0;
                
            // QSPI data
            if(qCommand && qCycleCount >= 46)
            begin
                qCyclePhase      <= ~qCyclePhase;
                if(qCyclePhase)
                begin
                    qDataByte   <= {qPins_r1,qPins};
                    qValid      <= 1'd1;
                end
                else
                begin
                    qPins_r1    <= qPins;
                    qValid      <= 1'd0;
                end
            end

        end
    end

    reg [7:0] qDataByte_r1 = 'd0;
    reg QSPI_VALID_phase = 'd0;
    always@(posedge QSPI_CLK or posedge QSPI_CS)
        if(QSPI_CS)
            QSPI_VALID_phase <= 'd0;
        else
            if(qValid)
            begin
                qDataByte_r1 <= qDataByte;
                QSPI_VALID_phase <= ~QSPI_VALID_phase;
            end

    assign qDataValid = qValid&QSPI_VALID_phase;
    assign qData = {qDataByte,qDataByte_r1};

endmodule
