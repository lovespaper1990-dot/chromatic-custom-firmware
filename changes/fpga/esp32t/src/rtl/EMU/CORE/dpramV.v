// dpramV.v

module dpramV #(
    parameter   addr_width  =   8,
    parameter   data_width  =   8
    )(  
    input   clock_a,
    input   ce_a,
    input   [addr_width-1:0]    address_a,
    input   [data_width-1:0]    data_a,
    input                       wren_a,
    output  reg [data_width-1:0]    q_a,
    
    input   clock_b,
    input   [addr_width-1:0]    address_b,
    input   [data_width-1:0]    data_b,
    input                       wren_b,
    output  reg [data_width-1:0]    q_b
);

    reg [data_width-1:0]    dpram [2**addr_width-1:0];
    
    always@(posedge clock_a)
        if(wren_a&ce_a)
            dpram[address_a]    <=  data_a;
            
    always@(posedge clock_a)
        if((~wren_a) & ce_a)
            q_a <=  dpram[address_a];
            

    always@(posedge clock_b)
        if(wren_b && !(wren_a && ce_a))
            dpram[address_b]    <=  data_b;
            
    always@(posedge clock_b)
        if(~wren_b)
            q_b <=  dpram[address_b];





endmodule

// A paused core and the state engine share one synchronous RAM port.
module snapshot_ram #(
    parameter addr_width = 8,
    parameter data_width = 8
)(
    input clock, input snapshot,
    input ce_a, input [addr_width-1:0] address_a,
    input wren_a, input [data_width-1:0] data_a,
    output [data_width-1:0] q_a,
    input [addr_width-1:0] address_b,
    input wren_b, input [data_width-1:0] data_b,
    output [data_width-1:0] q_b
);
    wire select_b = snapshot && !ce_a;
    wire [addr_width-1:0] address = select_b ? address_b : address_a;
    wire [data_width-1:0] data = select_b ? data_b : data_a;
    wire enabled = select_b || ce_a;
    wire write_en = select_b ? wren_b : wren_a;

    reg [data_width-1:0] ram [0:(1<<addr_width)-1];
    reg [data_width-1:0] ram_q;
    always @(posedge clock) begin
        if (enabled) begin
            if (write_en)
                ram[address] <= data;
            else
                ram_q <= ram[address];
        end
    end

    // Preserve the last game read across every snapshot read and write.
    reg last_read_game;
    reg [data_width-1:0] game_q;
    always @(posedge clock) begin
        if (enabled && !write_en) begin
            if (select_b && last_read_game)
                game_q <= ram_q;
            last_read_game <= !select_b;
        end
    end
    assign q_a = last_read_game ? ram_q : game_q;
    assign q_b = ram_q;
endmodule
