`timescale 1ns/1ps
module tb_ui_spi_byte;
    reg clk=0,rst_n=0,start=0,miso=0;
    reg [7:0] tx_data=0;
    reg [15:0] half_period=0;
    wire sck,mosi,busy,done;
    wire [7:0] rx_data;
    ui_spi_byte dut(.*);
    always #5 clk=~clk;
    integer checks=0,done_count=0;
    always @(posedge clk) if(done) done_count=done_count+1;
    task exchange(input [7:0] outgoing,input [7:0] incoming,input integer divisor);
        integer i;
        time edge_time;
        begin
            @(negedge clk);tx_data=outgoing;half_period=divisor;start=1;miso=incoming[7];
            @(negedge clk);start=0;
            if(!busy || sck) $fatal(1,"start not accepted / wrong CPOL");
            // Divider changes and starts during a transfer must not disturb it.
            half_period=12;tx_data=~outgoing;
            for(i=7;i>=0;i=i-1) begin
                @(posedge sck);edge_time=$time;
                if(mosi!==outgoing[i]) $fatal(1,"MOSI order bit %0d",i);
                if(i==5) start=1;
                @(negedge sck);
                if($time-edge_time != (divisor<1 ? 1 : divisor)*10)
                    $fatal(1,"half-period not latched");
                start=0;
                if(i>0) miso=incoming[i-1];
            end
            #1;
            if(busy || !done || rx_data!==incoming || sck)
                $fatal(1,"byte completion / RX mismatch rx=%h want=%h",rx_data,incoming);
            @(negedge clk);@(negedge clk);
            if(done || busy || sck) $fatal(1,"done must pulse, idle SCK must be zero");
            checks=checks+1;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        exchange(8'hA5,8'h3C,0);
        exchange(8'h96,8'hD3,1);
        exchange(8'hFF,8'h00,3);
        exchange(8'h00,8'hFF,7);
        @(negedge clk);tx_data=8'h99;half_period=2;start=1;
        @(negedge clk);start=0;
        repeat(3) @(negedge clk);rst_n=0;#1;
        if(busy || sck || done) $fatal(1,"reset mid-byte");
        @(negedge clk);rst_n=1;
        exchange(8'h81,8'h7E,2);
        if(done_count!=checks) $fatal(1,"unexpected done count");
        $display("PASS: shared SPI mode0 bytes, divider latch, busy-start rejection, RX, reset");
        $finish;
    end
    initial begin #1000000;$fatal(1,"SPI timeout");end
endmodule
