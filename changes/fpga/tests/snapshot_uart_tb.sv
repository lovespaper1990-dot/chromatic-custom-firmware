// Exercise the stock CRC-8 framing, reply arbitration under continuous telemetry,
// payload length validation, and byte order at the MCU/FPGA mailbox boundary.
module snapshot_uart_tb;
    reg clk=0,reset=1,menu_button=1,rx_valid=0,reply_toggle=0,tx_busy=0;
    reg [7:0] rx_byte;
    reg [79:0] response;
    wire [7:0] tx_byte;
    wire tx_valid, cmd_toggle, menu_closed;
    wire [6:0] cmd;
    wire [79:0] received;
    always #5 clk=~clk;

    system_monitor dut(.clk(clk),.reset(reset),.appear_off(1'b0),
        .menu_ready(1'b1),.standby_tick(1'b0),.BTN_MENU(menu_button),.BTN_A(1'b0),.BTN_B(1'b0),.BTN_SEL(1'b0),
        .BTN_START(1'b0),.BTN_DPAD_DOWN(1'b0),.BTN_DPAD_UP(1'b0),
        .BTN_DPAD_LEFT(1'b0),.BTN_DPAD_RIGHT(1'b0),.menuDisabled(menu_closed),
        .uart_rx_data(rx_byte),.uart_rx_val(rx_valid),.uart_tx_busy(tx_busy),
        .uart_tx_data(tx_byte),.uart_tx_val(tx_valid),
        .snap_cmd(cmd),.snap_cmd_toggle(cmd_toggle),.snap_cmd_data(received),
        .snap_reply_toggle(reply_toggle),.snap_reply(response));

    function automatic [7:0] crc_byte(input [7:0] prior,input [7:0] value);
        reg [7:0] crc;
        integer i;
        begin
            crc=prior^value;
            for (i=0;i<8;i=i+1) crc=(crc<<1) ^ (crc[7] ? 8'h1d : 0);
            crc_byte=crc;
        end
    endfunction
    task send_byte(input [7:0] value);
        begin
            @(negedge clk); rx_valid=1; rx_byte=value;
            @(negedge clk); rx_valid=0;
            repeat(20) @(negedge clk);
        end
    endtask
    task send_frame(input [6:0] a,input integer len,input [79:0] data,input bit corrupt);
        reg [7:0] crc,b;
        integer i;
        begin
            send_byte('h8f); send_byte(a); send_byte(len);
            crc=crc_byte(crc_byte(crc_byte(8'hff,8'h8f),a),len);
            for(i=len-1;i>=0;i=i-1) begin
                b=data[i*8 +: 8]; send_byte(b); crc=crc_byte(crc,b);
            end
            send_byte(crc^corrupt);
        end
    endtask
    integer count=0,len=0,packets=0,tx_wait=0;
    reg [7:0] addr,crc;
    reg [79:0] collected;
    always @(negedge clk) begin
        if (tx_wait>0) tx_wait=tx_wait-1;
        tx_busy = tx_wait>0;
        if (tx_valid) begin
            tx_wait=24; tx_busy=1;
            if (count==0) begin
                if (tx_byte==8'h8f) begin count=1; crc=crc_byte('hff,tx_byte); end
            end else if (count==1) begin
                addr=tx_byte; count=2; crc=crc_byte(crc,tx_byte);
            end else if (count==2) begin
                len=tx_byte; collected=0; count=3; crc=crc_byte(crc,tx_byte);
            end else if (count==len+3) begin
                if (addr==10) begin
                    if (tx_byte !== crc || len!=10 || collected!==response)
                        $fatal(1,"bad wire response %h crc=%h expected %h",collected,tx_byte,crc);
                    packets=packets+1;
                end
                count=0;
            end else begin
                collected={collected[71:0],tx_byte}; crc=crc_byte(crc,tx_byte);
                count=count+1;
            end
        end
    end
    localparam [79:0] WORD=80'h023480a55a8f0000107fff;
    initial begin
        repeat(10) @(negedge clk); reset=0;
        repeat(24) @(negedge clk); menu_button=0;
        repeat(24) @(negedge clk); menu_button=1; wait(!menu_closed);
        send_frame('h22,10,WORD,1);
        send_frame('h22,9,WORD,0);
        if (cmd_toggle!==0) $fatal(1,"invalid length/CRC was accepted");
        send_frame('h22,10,WORD,0);
        if (cmd_toggle!==1 || cmd!='h22 || received!==WORD) $fatal(1,"bad write packet");
        response=WORD; reply_toggle=1; wait(packets==1);
        send_frame('h20,1,8'h03,0);
        if (cmd_toggle!==0 || cmd!='h20 || received[7:0]!=3) $fatal(1,"bad control packet");
        response=80'hfff10000007ddd608109; reply_toggle=0; wait(packets==2);
        $display("PASS: UART/telemetry arbitration, CRC, length, control and opaque word byte order");
        $finish;
    end
    initial begin #1000000; $fatal(1,"UART timeout"); end
endmodule
