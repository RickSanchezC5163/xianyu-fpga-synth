`timescale 1ns/1ps
// Independent stimulus/output harness. Python owns the numerical oracle.
module tb_tjc_wave_preview #(parameter integer TRIGGER_TEST_ENABLE=1, parameter integer DECIMATE_TEST=1, parameter integer SCROLL_TEST=0, parameter integer SECOND_FRAME=0);
    reg clk=0,rst_n=0,request=0,sample_valid=0;
    reg signed [15:0] pcm=0;
    reg [2:0] page=3;
    reg ready=0;
    wire busy,bvalid;
    wire [7:0] data;
    tjc_telemetry_tx #(.CAPTURE_TIMEOUT_CYCLES(8192),.TRIGGER_ENABLE(TRIGGER_TEST_ENABLE),.WAVE_DECIMATE(DECIMATE_TEST),.WAVE_SCROLL_ENABLE(SCROLL_TEST)) dut(
        .clk(clk),.rst_n(rst_n),.request(request),.page_id(page),
        .sample_valid(sample_valid),.sample_pcm(pcm),
        .control_note_on(1'b0),.latency_valid(1'b0),.latency_timeout(1'b0),.latency_rejected(1'b0),
        .latency_cycles(32'd0),.latency_max_cycles(32'd0),.missed_deadline_count(32'd0),
        .window_valid(1'b0),.samples_in_window(32'd0),
        .busy(busy),.byte_valid(bvalid),.byte_data(data),.byte_ready(ready),.raw_rx_valid(1'b0),.raw_rx_error(1'b0),.raw_rx_data(8'd0),.transfer_fault());
    reg [15:0] stimulus[0:1023];
    integer mode=0,cut=0,backpressure=1,feed_count=1024,fd,cycle=0,accepted=0;
    integer canceled=0,cancel_pending=0,frame=0,rawfd,rawindex;
    reg previous_stall=0;
    reg [7:0] previous_byte;
    always #10 clk=~clk;
    always @(negedge clk) begin
        cycle=cycle+1;
        ready=backpressure ? (cycle%11!=0 && cycle%11!=1 && cycle%11!=4) : 1;
        if(cancel_pending) begin
            page=0;cancel_pending=0;canceled=1;
        end
    end
    always @(posedge clk) begin
        if(!rst_n) previous_stall<=0;
        else begin
            if(previous_stall && (!bvalid || data!==previous_byte))
                $fatal(1,"byte changed while backpressured");
            previous_stall<=bvalid && !ready;
            previous_byte<=data;
            if(bvalid && ready) begin
                $fwrite(fd,"%02x",data);
                accepted=accepted+1;
                if(mode==1 && frame==0 && !canceled && accepted==cut)
                    cancel_pending=1;
            end
            if(dut.capture_count>420) $fatal(1,"capture exceeded420 samples");
        end
    end
    task admit;
        begin
            @(negedge clk);request=1;
            @(negedge clk);request=0;
        end
    endtask
    task feed(input integer amount);
        integer i;
        begin
            for(i=0;i<amount;i=i+1) begin
                @(negedge clk);sample_valid=1;pcm=stimulus[i];
                @(negedge clk);sample_valid=0;
            end
        end
    endtask
    task drain;
        integer ticks;
        begin
            ticks=0;
            while(busy && ticks<100000) begin @(negedge clk);ticks=ticks+1;end
            if(busy) $fatal(1,"sender did not finish");
            repeat(5) @(negedge clk);
        end
    endtask
    initial begin
        if($value$plusargs("MODE=%d",mode)) begin end
        if($value$plusargs("CUT=%d",cut)) begin end
        if($value$plusargs("BACKPRESSURE=%d",backpressure)) begin end
        if($value$plusargs("FEED_COUNT=%d",feed_count)) begin end
        $readmemh("stimulus.hex",stimulus,0,1023);
        fd=$fopen("frame0.hex","w");
        repeat(5) @(negedge clk);rst_n=1;
        admit();
        if(mode==2) begin
            fork
                feed(1024);
                begin
                    wait(bvalid && dut.state==5);
                    @(negedge clk);rst_n=0;
                    #1;
                    if(busy || bvalid) $fatal(1,"reset failed to idle sender");
                    repeat(3) @(negedge clk);
                    if(dut.capture_count || dut.capture_enabled || dut.capture_raw_peak)
                        $fatal(1,"reset did not clear capture state");
                end
            join
            if(rst_n!==0) $fatal(1,"reset test did not actually assert reset");
            $fclose(fd);
            $display("PASS wave_preview RESET");$finish;
        end
        feed(feed_count);
        // Different later PCM must not overwrite a completed display capture.
        if(mode==0) begin
            repeat(33) begin
                @(negedge clk);sample_valid=1;pcm=16'sd32123;
                @(negedge clk);sample_valid=0;
            end
        end
        drain();$fclose(fd);
        if(mode==0)begin
            rawfd=$fopen("capture.hex","w");
            for(rawindex=0;rawindex<420;rawindex=rawindex+1)$fwrite(rawfd,"%04x\n",dut.capture[rawindex]);
            $fclose(rawfd);
        end
        $display("CAPTURE samples=%0d peak=%0d rawpeak=%0d gain=%0d failed=%0d wait=%0d",
            dut.capture_count,dut.capture_peak,dut.capture_raw_peak,dut.gain_shift,dut.capture_failed,dut.trigger_wait_count);
        if(mode==3 && !dut.capture_failed) $fatal(1,"missing sample was not timed out");
        if(mode==1 || SECOND_FRAME) begin
            if(mode==1 && !canceled) $fatal(1,"requested cancellation point never reached");
            frame=1;accepted=0;page=3;
            fd=$fopen("frame1.hex","w");
            admit();feed(1024);drain();$fclose(fd);
        end
        $display("PASS wave_preview mode=%0d cut=%0d backpressure=%0d",mode,cut,backpressure);
        $finish;
    end
    initial begin #20000000;$fatal(1,"wave preview timeout");end
endmodule
