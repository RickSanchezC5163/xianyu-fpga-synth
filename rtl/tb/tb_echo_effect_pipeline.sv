`timescale 1ns/1ps
// An independent sample-domain reference tracks accepted samples, saturating
// feedback and fractional signed rounding. Cycle checks also enforce latency,
// clear cancellation and the busy/completion-edge overrun contract.
module tb_echo_effect_pipeline #(
    parameter integer DEPTH=7,ADDR_BITS=3
);
    reg clk=0,rst_n=0,clear=0,sample_valid=0;
    reg signed [23:0] sample_in=0;
    reg [6:0] mix=0,feedback=0;
    wire signed [23:0] sample_out;
    wire output_valid,overrun;
    echo_effect #(.DEPTH(DEPTH),.ADDR_BITS(ADDR_BITS)) dut(.*);
    always #10 clk=~clk;
    reg signed [23:0] reference_ram [0:DEPTH-1];
    reg signed [23:0] expected_out,expected_write,delayed_reference;
    reg signed [63:0] reference_wet,reference_feedback,reference_output_sum,reference_write_sum;
    integer pointer=0,filled=0,remaining=0,saved_pointer=0;
    integer accepted=0,emitted=0,dropped=0,cancelled=0,cycles=0;
    integer positive_clip=0,negative_clip=0,positive_write_clip=0,negative_write_clip=0;
    integer feedback_reads=0,mix_zero=0,mix_full=0,feedback_zero=0,feedback_full=0;
    reg expected_valid=0,expected_overrun=0;
    reg [2:0] cleared_stages=0;
    function signed [23:0] clamp_reference(input signed [63:0] value);
        begin
            if(value>64'sd8388607)clamp_reference=24'sh7fffff;
            else if(value< -64'sd8388608)clamp_reference=24'sh800000;
            else clamp_reference=value[23:0];
        end
    endfunction
    always @(posedge clk)begin
        cycles=cycles+1;expected_valid=0;
        if(!rst_n || clear)begin
            if(rst_n && remaining!=0)begin
                cleared_stages[remaining-1]=1;cancelled=cancelled+1;
            end
            pointer=0;filled=0;remaining=0;expected_overrun=0;expected_out=0;
        end else if(remaining!=0)begin
            if(sample_valid)begin expected_overrun=1;dropped=dropped+1;end
            if(remaining==1)begin
                reference_ram[saved_pointer]=expected_write;
                expected_valid=1;emitted=emitted+1;
            end
            remaining=remaining-1;
        end else if(sample_valid)begin
            delayed_reference=filled==DEPTH?reference_ram[pointer]:24'sd0;
            reference_wet=$signed(delayed_reference)*$signed({1'b0,mix});
            reference_feedback=$signed(delayed_reference)*$signed({1'b0,feedback});
            reference_output_sum=$signed(sample_in)+(reference_wet>>>7);
            reference_write_sum=$signed(sample_in)+(reference_feedback>>>7);
            expected_out=clamp_reference(reference_output_sum);
            expected_write=clamp_reference(reference_write_sum);
            if(reference_output_sum>8388607)positive_clip=positive_clip+1;
            if(reference_output_sum< -8388608)negative_clip=negative_clip+1;
            if(reference_write_sum>8388607)positive_write_clip=positive_write_clip+1;
            if(reference_write_sum< -8388608)negative_write_clip=negative_write_clip+1;
            if(delayed_reference!=0 && feedback!=0)feedback_reads=feedback_reads+1;
            if(mix==0)mix_zero=mix_zero+1;
            if(mix==127)mix_full=mix_full+1;
            if(feedback==0)feedback_zero=feedback_zero+1;
            if(feedback==127)feedback_full=feedback_full+1;
            saved_pointer=pointer;pointer=pointer==DEPTH-1?0:pointer+1;
            if(filled<DEPTH)filled=filled+1;
            remaining=3;accepted=accepted+1;
        end
        #1;
        if(output_valid!==expected_valid)$fatal(1,"latency/flush mismatch cycle%0d valid%0b expected%0b remaining%0d",cycles,output_valid,expected_valid,remaining);
        if(expected_valid && sample_out!==expected_out)$fatal(1,"bitexact mismatch cycle%0d got%0d expected%0d",cycles,sample_out,expected_out);
        if(overrun!==expected_overrun)$fatal(1,"overrun mismatch cycle%0d",cycles);
        if((!rst_n || clear) && sample_out!==0)$fatal(1,"clear/reset output not zero");
    end
    task send(input signed [23:0] sample,input [6:0] wet,input [6:0] regen);
        begin
            @(negedge clk);sample_valid=1;sample_in=sample;mix=wet;feedback=regen;
            @(negedge clk);sample_valid=0;
            // Change controls/data while busy; accepted controls must be saved.
            sample_in=~sample;mix=~wet;feedback=~regen;
            repeat(3)@(negedge clk);
        end
    endtask
    task flush;
        begin @(negedge clk);clear=1;@(negedge clk);clear=0;end
    endtask
    task cancel_at(input integer age);
        begin
            @(negedge clk);sample_valid=1;sample_in=24'sh654321;mix=127;feedback=127;
            @(negedge clk);sample_valid=0;
            repeat(age-1)@(negedge clk);
            clear=1;sample_valid=1;
            @(negedge clk);clear=0;sample_valid=0;
            repeat(5)@(negedge clk);
            // Stale pre-clear samples must stay inaudible over a complete window.
            repeat(DEPTH+2)send(0,127,127);
        end
    endtask
    integer n;
    reg [31:0] random_state=32'h35a24f19;
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        for(n=0;n<DEPTH*4+1;n=n+1)send(24'sh7fffff,127,127);
        flush();
        for(n=0;n<DEPTH*4+1;n=n+1)send(24'sh800000,127,127);
        flush();
        send(-24'sd257,127,127);
        for(n=0;n<DEPTH*5;n=n+1)send(0,127,127);
        flush();
        for(n=0;n<DEPTH*3;n=n+1)send(n[0]?-24'sd812345:24'sd654321,0,127);
        for(n=0;n<DEPTH*3;n=n+1)send(n[0]?-24'sd812345:24'sd654321,127,0);
        for(n=1;n<=3;n=n+1)cancel_at(n);
        // Continuous input overruns every occupied pipeline phase, including emit.
        @(negedge clk);sample_valid=1;sample_in=24'sd222222;mix=63;feedback=17;
        repeat(20)@(negedge clk);sample_valid=0;repeat(5)@(negedge clk);
        flush();
        for(n=0;n<12000;n=n+1)begin
            @(negedge clk);
            random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
            sample_in=random_state[23:0];mix=random_state[30:24];feedback=random_state[22:16];
            sample_valid=random_state[2] || random_state[8];
            clear=n%197==193;
        end
        @(negedge clk);sample_valid=0;clear=0;repeat(5)@(negedge clk);
        if(positive_clip==0 || negative_clip==0 || positive_write_clip==0 || negative_write_clip==0 ||
           feedback_reads==0 || mix_zero==0 || mix_full==0 || feedback_zero==0 || feedback_full==0 ||
           dropped==0 || cleared_stages!==7 || accepted!=emitted+cancelled)
            $fatal(1,"coverage/conservation failed accepted%0d emitted%0d cancelled%0d clearstages%0b",accepted,emitted,cancelled,cleared_stages);
        $display("PASS echo_effect_pipeline depth=%0d accepted=%0d emitted=%0d cancelled=%0d dropped=%0d positive_clip=%0d negative_clip=%0d feedback_reads=%0d latency_cycles=3 cleared_stages=%0b",DEPTH,accepted,emitted,cancelled,dropped,positive_clip,negative_clip,feedback_reads,cleared_stages);
        $finish;
    end
    initial begin #50000000;$fatal(1,"echo pipeline test timeout");end
endmodule
