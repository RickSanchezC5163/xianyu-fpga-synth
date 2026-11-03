`timescale 1ns/1ps
module tb_echo_effect;
    reg clk=0,rst_n=0,clear=0,valid=0;
    reg signed [23:0] sample=0;
    reg [6:0] mix=0,feedback=0;
    wire signed [23:0] result;
    wire result_valid,overrun;
    echo_effect #(.DEPTH(8),.ADDR_BITS(3)) dut(
        .clk(clk),.rst_n(rst_n),.clear(clear),.sample_valid(valid),
        .sample_in(sample),.mix(mix),.feedback(feedback),
        .sample_out(result),.output_valid(result_valid),.overrun(overrun));
    always #10 clk=~clk;
    task send(input signed [23:0] value,input signed [23:0] expected);
        begin
            @(negedge clk);sample=value;valid=1;
            @(negedge clk);valid=0;
            // Synchronous RAM read, registered product/add, then saturated emit.
            repeat(3) @(negedge clk);
            if(!result_valid || result!==expected || overrun)
                $fatal(1,"delay output got %0d valid=%b expected %0d",result,result_valid,expected);
            repeat(2) @(negedge clk);
        end
    endtask
    integer n;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        mix=0;feedback=0;
        send(24'sd100000,24'sd100000);
        for(n=0;n<9;n=n+1) send(0,0);
        @(negedge clk);clear=1;
        @(negedge clk);clear=0;mix=64;feedback=64;
        send(24'sd100000,24'sd100000);
        for(n=0;n<7;n=n+1) send(0,0);
        send(0,24'sd50000);
        for(n=0;n<7;n=n+1) send(0,0);
        send(0,24'sd25000);
        @(negedge clk);clear=1;
        @(negedge clk);clear=0;
        for(n=0;n<9;n=n+1) send(0,0);
        $display("PASS: FPGA echo bypass, 8-sample delay, bounded feedback, clear");
        $finish;
    end
    initial begin #2000000;$fatal(1,"echo test timeout");end
endmodule
