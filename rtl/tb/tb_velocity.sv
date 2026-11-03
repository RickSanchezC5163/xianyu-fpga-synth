`timescale 1ns/1ps
module tb_velocity;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0,tick=0,gate=0;
    wire signed [23:0] full_sample,quiet_sample,soft_sample,hard_sample;
    wire full_valid,quiet_valid,soft_valid,hard_valid;
    wire full_overrun,quiet_overrun,soft_overrun,hard_overrun;
    localparam [31:0] C4=32'd23012828;
    localparam [63:0] DEFAULT_ADSR={16'd48,16'd40000,16'd24,16'd512};
    additive_core #(.VOICES(1)) full_voice(
        clk,rst_n,tick,gate,8'd0,C4,2'd0,7'd127,DEFAULT_ADSR,
        full_sample,full_valid,full_overrun);
    additive_core #(.VOICES(1)) quiet_voice(
        clk,rst_n,tick,gate,8'd0,C4,2'd0,7'd31,DEFAULT_ADSR,
        quiet_sample,quiet_valid,quiet_overrun);
    additive_core #(.VOICES(1)) soft_voice(
        clk,rst_n,tick,gate,8'd0,C4,2'd0,7'd60,DEFAULT_ADSR,
        soft_sample,soft_valid,soft_overrun);
    additive_core #(.VOICES(1)) hard_voice(
        clk,rst_n,tick,gate,8'd0,C4,2'd0,7'd99,DEFAULT_ADSR,
        hard_sample,hard_valid,hard_overrun);
    integer frame,cycles,nonzero;
    longint unsigned soft_absolute,hard_absolute;
    longint signed soft_value,hard_value;
    initial begin
        nonzero=0;soft_absolute=0;hard_absolute=0;
        repeat(4) @(negedge clk);rst_n=1;
        for(frame=0;frame<2500;frame=frame+1) begin
            @(negedge clk);gate=frame>=4 && frame<2000;tick=1;
            @(negedge clk);tick=0;cycles=0;
            while(!full_valid || !quiet_valid || !soft_valid || !hard_valid) begin
                @(negedge clk);cycles=cycles+1;
                if(cycles>70) $fatal(1,"velocity cores missed sample deadline");
            end
            if(full_overrun || quiet_overrun || soft_overrun || hard_overrun ||
               ^full_sample===1'bx || ^quiet_sample===1'bx ||
               ^soft_sample===1'bx || ^hard_sample===1'bx)
                $fatal(1,"invalid velocity audio");
            if(full_sample!=0) nonzero=nonzero+1;
            if(frame>=500 && frame<1800) begin
                soft_value=$signed(soft_sample);
                hard_value=$signed(hard_sample);
                soft_absolute=soft_absolute+(soft_value<0 ? -soft_value : soft_value);
                hard_absolute=hard_absolute+(hard_value<0 ? -hard_value : hard_value);
            end
            // Velocity 31 gives gain 8/128.  Truncation can differ by one
            // output LSB because it happens per partial before accumulation.
            if(quiet_sample > (full_sample>>>4)+3 ||
               quiet_sample < (full_sample>>>4)-3)
                $fatal(1,"velocity did not scale sound at frame %0d: %0d %0d",
                       frame,full_sample,quiet_sample);
        end
        if(nonzero<100) $fatal(1,"test did not synthesize audible samples");
        // Same note, patch, phase and ADSR: their accumulated absolute sample
        // amplitudes should reflect the requested 16..18 dB keybed spread.
        if(soft_absolute==0 || hard_absolute*10<soft_absolute*63 ||
           hard_absolute*10>soft_absolute*79)
            $fatal(1,"velocity 60/99 amplitude ratio out of range: %0d/%0d",
                   hard_absolute,soft_absolute);
        $display("PASS velocity: note 60/99 amplitude ratio %0d:%0d",
                 hard_absolute,soft_absolute);
        $finish;
    end
    initial begin #10000000;$fatal(1,"velocity test timeout");end
endmodule
