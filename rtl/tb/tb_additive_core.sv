`timescale 1ns/1ps
module tb_additive_core;
    reg clk=0; always #10 clk=~clk;
    reg rst_n=0,tick=0,bell=0;
    reg [3:0] gates=0;
    wire signed [23:0] sample_out;
    wire valid,overrun;
    localparam [63:0] DEFAULT_ADSR={16'd48,16'd40000,16'd24,16'd512};
    reg [127:0] words={32'd43442435,32'd34480283,32'd28994347,32'd23012828};
    additive_core dut(clk,rst_n,tick,gates,32'd0,words,
       {4{1'b0,bell}},{4{7'd127}},DEFAULT_ADSR,sample_out,valid,overrun);
    integer fd,n,cycles;
    initial begin
        fd=$fopen("core_samples.csv","w");
        if(!fd) $fatal(1,"Cannot open capture");
        repeat(4) @(negedge clk); rst_n=1;
        for(n=0;n<24000;n=n+1) begin
            @(negedge clk);
            bell=(n>=12000);
            gates=((n>=10 && n<10000)||(n>=12010 && n<22000)) ? 4'b1111 : 0;
            if(n>=10 && n<2010) gates=4'b0001 << ((n-10)/500);
            if(n>=3000 && n<3200) gates=((n/40)%2) ? 15 : 0;
            tick=1;
            @(negedge clk);tick=0;cycles=0;
            while(!valid) begin
                @(negedge clk); cycles=cycles+1;
                if(cycles>220) $fatal(1,"missed sample deadline");
            end
            if(overrun || ^sample_out===1'bx) $fatal(1,"invalid core output");
            $fwrite(fd,"%0d,%0d,%0d,%0d\n",n,gates,bell,sample_out);
        end
        // All fundamentals and their partials above cutoff must be muted,
        // including products that cannot fit in a 32-bit phase increment.
        words={4{32'h80000000}};gates=15;
        repeat(300) begin
            @(negedge clk);tick=1;
            @(negedge clk);tick=0;
            while(!valid) @(negedge clk);
            if(sample_out!==0) $fatal(1,"out-of-band partial aliased into output");
        end
        // Intentionally collide transactions: sticky overrun must be observable.
        @(negedge clk);tick=1;repeat(3) @(negedge clk);tick=0;
        if(!overrun) $fatal(1,"missing overrun diagnostic");
        rst_n=0;@(negedge clk);
        if(overrun || sample_out!==0) $fatal(1,"reset failed");
        $fclose(fd);$display("PASS core: 24000 samples, independent gates, cutoff, bounded latency, overrun and reset");$finish;
    end
    initial begin #200000000; $fatal(1,"watchdog");end
endmodule
