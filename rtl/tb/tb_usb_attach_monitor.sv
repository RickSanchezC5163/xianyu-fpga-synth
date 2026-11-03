`timescale 1ns/1ps
module tb_usb_attach_monitor;
    reg clk=0,rst_n=0,dp=0,dm=0;
    wire stable_dp,stable_dm;
    usb_attach_monitor #(.STABLE_CYCLES(8)) dut(
        clk,rst_n,dp,dm,stable_dp,stable_dm);
    always #10 clk=~clk;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        dp=1;repeat(5) @(negedge clk);
        if(stable_dp || stable_dm) $fatal(1,"short pulse reported as attach");
        dp=0;repeat(14) @(negedge clk);
        dp=1;repeat(15) @(negedge clk);
        if(!stable_dp || stable_dm) $fatal(1,"full-speed J state not detected");
        dp=0;repeat(15) @(negedge clk);
        if(stable_dp || stable_dm) $fatal(1,"disconnect not detected");
        dm=1;repeat(15) @(negedge clk);
        if(stable_dp || !stable_dm) $fatal(1,"low-speed state not detected");
        $display("PASS: passive USB-A2 attach debounce and disconnect");
        $finish;
    end
    initial begin #100000;$fatal(1,"USB attach timeout");end
endmodule
