`timescale 1ns/1ps
module tb_adsr;
    reg clk=0,rst_n=0,tick=0,gate=0;
    wire signed [23:0] fast_sample,slow_sample;
    wire fast_valid,slow_valid,fast_overrun,slow_overrun;
    localparam [63:0] FAST={16'd512,16'd40000,16'd24,16'd2096};
    localparam [63:0] SLOW={16'd4,16'd40000,16'd24,16'd64};
    additive_core #(.VOICES(1)) fast(clk,rst_n,tick,gate,8'd0,32'd23012828,
        2'd0,7'd127,FAST,fast_sample,fast_valid,fast_overrun);
    additive_core #(.VOICES(1)) slow(clk,rst_n,tick,gate,8'd0,32'd23012828,
        2'd0,7'd127,SLOW,slow_sample,slow_valid,slow_overrun);
    always #10 clk=~clk;
    task frame;
        integer cycles;
        begin
            @(negedge clk);tick=1;
            @(negedge clk);tick=0;cycles=0;
            while(!fast_valid || !slow_valid) begin
                @(negedge clk);cycles=cycles+1;
                if(cycles>80) $fatal(1,"ADSR missed sample deadline");
            end
            if(fast_overrun || slow_overrun) $fatal(1,"ADSR overrun");
        end
    endtask
    integer n,fast_before,slow_before;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;gate=1;
        for(n=0;n<120;n=n+1) frame();
        fast_before=fast.envelope[0];slow_before=slow.envelope[0];
        if(fast_before<50000 || slow_before>10000)
            $fatal(1,"ADSR attack controls ineffective %0d/%0d",fast_before,slow_before);
        gate=0;
        for(n=0;n<30;n=n+1) frame();
        if(fast_before-fast.envelope[0]<14000 ||
           slow_before-slow.envelope[0]>200)
            $fatal(1,"ADSR release controls ineffective");
        $display("PASS: FPGA ADSR controls change attack and release envelopes");
        $finish;
    end
    initial begin #10000000;$fatal(1,"ADSR test timeout");end
endmodule
