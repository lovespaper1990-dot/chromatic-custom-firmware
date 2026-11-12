
module system_monitor_arbiter
#(
    parameter   NUM_CH = 8,
    parameter   REPLY_CH = 0
)
(
    input                            clk,
    input                            reset,
    input       [NUM_CH-1:0]         channelsNewDataValid,
    input                            menuDisabled,
    input                            uart_tx_busy,
    input                            write_done,
    output                           uartDisabled,
    output      [$clog2(NUM_CH)-1:0] tx_channel,
    output  reg [6:0]                tx_address = 'd0,
    output  reg                      write
);

    reg [NUM_CH-1:0] channelsDataRefreshRequest = '0;
    reg [$clog2(NUM_CH)-1:0]    active_channel = 'd0;
    reg [$clog2(NUM_CH)-1:0]    next_channel = 'd0;
    reg                         write_active;
    reg                         arbiter_active;
    reg                         button_next = 1'b0;
    
    
    assign tx_channel = active_channel;
    
    genvar g;
    generate
        for(g = 0; g < NUM_CH; g++)
        begin : channels
            always@(posedge clk)
            begin
                if(channelsNewDataValid[g])
                begin
                    channelsDataRefreshRequest[g] <= 1'd1;
                end
                else
                    if((active_channel == g)&&(write_done))
                        channelsDataRefreshRequest[g] <= 1'd0;
            end
        end
    endgenerate
    
    assign  uartDisabled = ~arbiter_active;
    always@(posedge clk or posedge reset)
    begin
        if(reset)
        begin
            active_channel <= 'd0;
            write          <= 'd0;
            write_active   <= 'd0;
            arbiter_active <= 'd0;
        end
        else
        begin
            arbiter_active <= 1'd1;
                
            // Service an explicit MCU request between telemetry frames. The
            // stop-and-wait client permits only one outstanding response.
            if (!write_active && REPLY_CH != 0 && channelsDataRefreshRequest[REPLY_CH] &&
                active_channel != REPLY_CH) begin
                active_channel <= REPLY_CH;
                write <= 1'b0;
            end else if((channelsDataRefreshRequest[active_channel] == 'd0) & arbiter_active)
            begin
                if(active_channel < NUM_CH - 1)
                    active_channel <= active_channel + 1'd1;
                else
                    active_channel <= 'd0;
            end
            else
            begin
                if(~write_active & arbiter_active)
                begin
                    if(~uart_tx_busy)
                    begin
                        write_active    <= 1'd1;
                        write           <= 1'd1;
                        tx_address      <= active_channel;
                    end
                end
                else
                begin
                    write   <=  1'd0;
                    if(write_done)
                    begin
                        if(menuDisabled)
                            arbiter_active <= 1'd0;
                        
                        write_active    <= 1'd0;

                        button_next <= ~button_next;
                        if (button_next) begin
                            active_channel <= 'd2;
                        end else begin
                            if(next_channel < NUM_CH - 1) begin
                                next_channel   <= next_channel + 1'd1;
                                active_channel <= next_channel + 1'd1;
                            end else begin
                                next_channel   <= 'd0;
                                active_channel <= 'd0;
                            end
                        end
                    end
                end
            end
        end
    end

endmodule
