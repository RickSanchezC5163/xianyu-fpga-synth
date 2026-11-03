`timescale 1ns/1ps
module tb_tjc_uart;
    reg clk=0,rst_n=0,rx=1,ack=0;wire tx,pv,gv;wire [3:0] pid;wire [15:0] pval,gval;
    reg [7:0] volume=20;wire [2:0] gid,page_id,result;
    wire [31:0] crc_errors,format_errors,timeouts,rejects;
    wire [31:0] rx_counts;
    tjc_uart_panel #(.CLKS_PER_BIT(16),.REFRESH_CYCLES(200000),.GAP_CYCLES(2000)) dut(
        clk,rst_n,rx,tx,1'b1,1'b0,8'd1,pv,pid,pval,ack,1'b0,2'd3,volume,
        {7'd11,7'd75,7'd4,7'd28},gv,gid,gval,1'b0,1'b0,1'b1,8'd120,
        page_id,result,crc_errors,format_errors,timeouts,rejects,
        1'b0,16'sd0,1'b0,1'b0,1'b0,1'b0,32'd0,32'd0,32'd0,1'b0,32'd0,rx_counts,,
        1'b0,192'd0,5'd0,10'd0,10'd0,4'd0,768'd0,20'd0,3'd0,2'd0);
    always #10 clk=~clk;
    always @(posedge clk) begin ack<=pv;if(pv) begin
        if(pid!=1 || pval!=128) $fatal(1,"UART payload mismatch");volume<=pval[7:0];end end
    wire [7:0] txdata;wire txvalid,txerror;
    uart_rx #(.CLKS_PER_BIT(16)) monitor(clk,rst_n,tx,txdata,txvalid,txerror);
    integer fd,bytes=0;
    always @(negedge clk) begin
        if(txerror) $fatal(1,"invalid TX UART stop bit");
        if(txvalid) begin $fwrite(fd,"%02x",txdata);bytes=bytes+1;end
    end
    reg [87:0] vectors[0:273];integer i,j;
    task send_byte(input [7:0] data);
        begin
            @(negedge clk);rx=0;repeat(16) @(negedge clk);
            for(j=0;j<8;j=j+1) begin rx=data[j];repeat(16) @(negedge clk);end
            rx=1;repeat(17) @(negedge clk);
        end
    endtask
    initial begin
        $readmemh("tjc_vectors.hex",vectors);fd=$fopen("tjc_uart_tx.hex","w");
        repeat(4) @(negedge clk);rst_n=1;
        for(i=10;i>=0;i=i-1) send_byte(vectors[128][i*8+:8]);
        repeat(20) @(negedge clk);
        if(volume!=128 || result!=1 || crc_errors || format_errors || rejects) $fatal(1,"UART event failed");
        if(rx_counts!==32'h000b0001) $fatal(1,"screen UART byte/event counters failed");
        // Two complete snapshots, the first taken before the event and the
        // second after the controller ACK. End after transmitter drains.
        wait(dut.snapshot.revision==2);wait(!dut.snapshot_busy);
        @(negedge clk);wait(dut.fast_ready); // drain the accepted final FF, after NBA/ready propagation
        repeat(32) @(negedge clk);$fclose(fd);
        $display("PASS tjc_uart: 8N1 RX, accepted parameter, coherent ASCII TX, no framing errors");$finish;
    end
    initial begin #10000000;$fatal(1,"tjc uart bench timeout");end
endmodule
