`timescale 1ns/1ps
module tb_ui_decimal_formatter;
    reg clk=0,rst_n=0,load=0;reg [31:0] value=0;
    wire [39:0] t1,t50;wire [31:0] q1,q50;wire d1,d50;
    ui_decimal_formatter a(clk,rst_n,load,value,t1,q1,d1);
    ui_decimal_formatter #(.DIVISOR(50)) b(clk,rst_n,load,value,t50,q50,d50);
    always #5 clk=~clk;
    function [39:0] expected(input reg [31:0] v);
        integer i;begin if(v>99999) v=99999;
            for(i=0;i<5;i=i+1) begin expected[i*8+:8]=48+v%10;v=v/10;end
        end
    endfunction
    task check(input reg [31:0] v);
        integer age;reg seen1;
        begin @(negedge clk);load=1;value=v;@(negedge clk);load=0;
            age=0;seen1=0;
            while(!d50 && age<55) begin @(negedge clk);age=age+1;
                if(d1) begin
                    if(q1!==v || t1!==expected(v)) $fatal(1,"div1 format value%0d",v);
                    seen1=1;
                end
            end
            if(!d50 || !seen1 || q50!==v/50 || t50!==expected(v/50)) $fatal(1,"div50 format value%0d q=%0d text=%s",v,q50,t50);
        end
    endtask
    integer i;reg [31:0] random_state=32'h12345678;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        check(0);check(1);check(49);check(50);check(51);check(99999);check(100000);check(32'hffffffff);
        for(i=0;i<256;i=i+1) begin random_state=random_state*32'd1664525+32'd1013904223;check(random_state);end
        // Restart a busy conversion; no stale completion may be published.
        @(negedge clk);load=1;value=100000;@(negedge clk);load=0;
        repeat(7) @(negedge clk);check(123450);
        $display("PASS tb_ui_decimal_formatter: exact32bit/50, /1, saturated5digits, 265corner/random/restart values");$finish;
    end
    initial begin #5000000;$fatal(1,"decimal formatter timeout");end
endmodule
