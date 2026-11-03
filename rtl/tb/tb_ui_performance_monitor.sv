`timescale 1ns/1ps
module tb_ui_performance_monitor;
    localparam integer CLK_HZ=100000, QUIET=4, WINDOW=100, TIMEOUT=2000;
    reg clk=0,rst_n=0,control=0,sample_valid=0,overrun=0;
    reg signed [15:0] pcm=0;
    reg [15:0] oscillators=0;
    wire cm,om,lv,l10,l5,to,reject,wv;
    wire [31:0] lc,lmax,missed,sw;
    wire [47:0] ow;
    integer seen_windows=0;
    integer expected_window_cycle=0;
    reg [31:0] expected_samples=0;
    reg [47:0] expected_osc=0;
    always #5 clk=~clk;
    ui_performance_monitor #(.CLK_HZ(CLK_HZ),.QUIET_SAMPLES(QUIET),
        .WINDOW_CYCLES(WINDOW),.TIMEOUT_CYCLES(TIMEOUT)) dut (
        .clk(clk),.rst_n(rst_n),.control_note_on(control),.sample_valid(sample_valid),
        .sample_pcm(pcm),.audio_overrun(overrun),.active_oscillators(oscillators),
        .control_marker(cm),.pcm_onset_marker(om),.latency_valid(lv),
        .latency_cycles(lc),.latency_max_cycles(lmax),.latency_le_10ms(l10),
        .latency_le_5ms(l5),.latency_timeout(to),.rejected_event(reject),
        .missed_deadline_count(missed),.window_valid(wv),.samples_in_window(sw),
        .oscillator_samples_in_window(ow));

    // Independent scoreboard includes every boundary sample exactly once.
    always @(posedge clk) begin
        if(!rst_n) begin
            expected_window_cycle=0; expected_samples=0; expected_osc=0;
        end else begin
            expected_window_cycle=expected_window_cycle+1;
            if(sample_valid) begin
                expected_samples=expected_samples+1;
                expected_osc=expected_osc+oscillators;
            end
            #1;
            if(cm!==control) $fatal(1,"control marker missing");
            if(expected_window_cycle==WINDOW) begin
                if(wv!==1 || sw!==expected_samples || ow!==expected_osc)
                    $fatal(1,"window integration sw%0d exp%0d ow%0d exp%0d",sw,expected_samples,ow,expected_osc);
                seen_windows=seen_windows+1;
                expected_window_cycle=0; expected_samples=0; expected_osc=0;
            end else if(wv!==0) $fatal(1,"early window boundary");
        end
    end
    task step(input bit note,input bit valid,input signed [15:0] value,input [15:0] count,input bit bad);
        begin
            @(negedge clk); control=note; sample_valid=valid; pcm=value; oscillators=count; overrun=bad;
            @(posedge clk); #2;
        end
    endtask
    task silence;
        integer n;
        begin
            for(n=0;n<QUIET;n=n+1) step(0,1,0,0,0);
        end
    endtask
    task measure(input integer delay_cycles,input bit expected5,input bit expected10,input signed [15:0] value);
        integer n;
        begin
            silence;
            step(1,delay_cycles==0,value,8,0);
            if(reject || to) $fatal(1,"qualified note rejected");
            if(delay_cycles>0) begin
                if(lv) $fatal(1,"latency early");
                for(n=1;n<delay_cycles;n=n+1) begin
                    step(0,0,0,8,0);
                    if(lv || to) $fatal(1,"premature latency result");
                end
                step(0,1,value,8,0);
            end
            if(!lv || !om || lc!==delay_cycles || l5!==expected5 || l10!==expected10)
                $fatal(1,"latency delay%0d lc%0d l5%0d l10%0d",delay_cycles,lc,l5,l10);
            step(0,0,0,0,0);
            if(lv || om || to || reject) $fatal(1,"pulse did not clear");
        end
    endtask

    integer n;
    initial begin
        #1; rst_n=1; #1; rst_n=0;
        repeat(2) @(negedge clk);
        rst_n=1;
        step(1,1,32,1,0);
        if(!reject || lv) $fatal(1,"unqualified note accepted");
        measure(0,1,1,16);
        measure(499,1,1,32);
        measure(500,1,1,32);
        measure(501,0,1,32);
        measure(750,0,1,32);
        measure(1000,0,1,32);
        measure(1001,0,0,32);
        measure(1500,0,0,-32768);
        if(lmax!==1500) $fatal(1,"maximum latency lost");

        silence;
        step(1,0,0,8,0);
        for(n=1;n<TIMEOUT;n=n+1) begin
            step(0,1,0,8,0);
            if(to || lv) $fatal(1,"timeout too early");
        end
        step(0,0,0,8,0);
        if(!to || lv) $fatal(1,"timeout cycle incorrect");
        step(1,1,32,8,0);
        if(!reject || lv || to) $fatal(1,"fresh silence required after timeout");

        silence;
        step(1,0,0,8,0);
        step(1,1,32,16,0);
        if(!reject || lv || om) $fatal(1,"poly-event did not cancel attribution");
        step(0,1,32,16,0);
        if(lv || om) $fatal(1,"cancelled note measured later");
        step(1,1,32,16,0);
        if(!reject || lv) $fatal(1,"sounding event should be rejected");

        step(0,0,0,0,1);
        if(missed!==1) $fatal(1,"overrun rising edge missed");
        repeat(4) step(0,0,0,0,1);
        if(missed!==1) $fatal(1,"overrun level double counted");
        step(0,0,0,0,0); step(0,0,0,0,1);
        if(missed!==2) $fatal(1,"second overrun missing");
        // Exercise changing oscillator counts, sparse samples and window edges.
        for(n=0;n<350;n=n+1) step(0,n%3==0,0,(n*17)%65536,0);
        if(seen_windows<50) $fatal(1,"insufficient windows");
        $display("PASS tb_ui_performance_monitor latency 0/<5/=5/5-10/=10/>10 ms, timeout, ambiguous notes, negative32768, overrun edges, exact windows=%0d",seen_windows);
        $finish;
    end
    initial begin #2000000; $fatal(1,"timeout"); end
endmodule
