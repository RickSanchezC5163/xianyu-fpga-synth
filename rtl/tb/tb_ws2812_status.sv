`timescale 1ns/1ps
module tb_ws2812_status;
    reg clk=0,rst_n=0;
    wire out;
    ws2812_status #(.REFRESH_CYCLES(4),.RESET_CYCLES(8)) dut(
        clk,rst_n,24'h800000,out);
    always #10 clk=~clk;
    integer i,high_count;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        @(posedge out);
        high_count=0;
        for(i=0;i<63;i=i+1) begin
            @(negedge clk);if(out) high_count=high_count+1;
        end
        if(high_count!=35) $fatal(1,"WS2812 one high length %0d",high_count);
        @(posedge out);
        high_count=0;
        for(i=0;i<63;i=i+1) begin
            @(negedge clk);if(out) high_count=high_count+1;
        end
        if(high_count!=18) $fatal(1,"WS2812 zero high length %0d",high_count);
        $display("PASS: FPGA WS2812 status one/zero bit timing");
        $finish;
    end
    initial begin #500000;$fatal(1,"WS2812 timeout");end
endmodule
