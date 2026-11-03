`timescale 1ns/1ps

// Exercise the real synthesis/mixer path through external I2S pins.
// No forced PCM, USB injection, or physical serial port is used.
module tb_pcm5102_path;
    parameter integer QUEUE_BSRAM=1;
    reg clk=0, rst_n=1, rx=1;
    wire tx, mclk, bclk, ws, data;
    wire dp=1'b0, dm=1'b0;
    mega60k_audio_top #(.STARTUP_CYCLES(100), .DEBOUNCE_CYCLES(8),
        .UART_CLKS_PER_BIT(16), .ENABLE_USB_HOST(0),
        .MIDI_QUEUE_BSRAM(QUEUE_BSRAM)) dut(
        .sys_clk(clk), .rst_n(rst_n), .key0_n(1'b1), .key1_n(1'b1),
        .uart_rx(rx), .uart_tx(tx), .usb_dp(dp), .usb_dm(dm),
        .ext_mclk(mclk), .ext_bck(bclk), .ext_lrclk(ws), .ext_din(data));
    always #10 clk=~clk;

    reg aligned=0, previous_ws=0;
    reg [23:0] expected_pair=0, received=0;
    integer slot_bit=0, left_count=0, right_count=0, nonzero_count=0;
    integer positive_count=0, negative_count=0;
    time last_mclk=0, last_bclk=0, last_frame=0;
    reg require_silence=0;

    // Reference is the shared final PCM presented to both serializers, sampled
    // at the externally visible stereo-frame boundary, not inside I2S RTL.
    always @(negedge ws or negedge dut.core_reset_n) begin
        if (!dut.core_reset_n) begin aligned=0; last_frame=0; end
        else begin
            if (last_frame && $time-last_frame!=20480)
                $fatal(1,"external stereo frame period is not20.48us");
            last_frame=$time;
            expected_pair={dut.dac_sample,8'b0};
            aligned=1;
        end
    end
    always @(posedge mclk or negedge dut.core_reset_n) begin
        if (!dut.core_reset_n) last_mclk=0;
        else begin
            if(last_mclk && $time-last_mclk!=80) $fatal(1,"MCLK period mismatch");
            last_mclk=$time;
        end
    end
    always @(posedge bclk or negedge dut.core_reset_n) begin
        if (!dut.core_reset_n) begin
            slot_bit=0; previous_ws=0; received=0; last_bclk=0;
        end else begin
            if(last_bclk && $time-last_bclk!=320) $fatal(1,"BCK period mismatch");
            last_bclk=$time;
            if(aligned) begin
                if(ws!=previous_ws) begin slot_bit=0; received=0; previous_ws=ws; end
                if(slot_bit==0) begin
                    if(data!==0) $fatal(1,"missing Philips I2S one-bit delay");
                end else if(slot_bit<=24) received={received[22:0],data};
                else if(data!==0) $fatal(1,"nonzero32-bit-slot padding");
                if(slot_bit==31) begin
                    if(received!==expected_pair)
                        $fatal(1,"I2S %s got%h expected%h",ws?"right":"left",received,expected_pair);
                    if(received[7:0]!==0) $fatal(1,"16-bit PCM was not left aligned in24bits");
                    if(require_silence && received!==0) $fatal(1,"STOP left nonzero I2S sample");
                    if(received!=0) begin
                        nonzero_count=nonzero_count+1;
                        if(received[23]) negative_count=negative_count+1;
                        else positive_count=positive_count+1;
                    end
                    if(ws) right_count=right_count+1; else left_count=left_count+1;
                    slot_bit=0;
                end else slot_bit=slot_bit+1;
            end
        end
    end

    reg [7:0] args[0:7];
    task clear_args;
        integer j;
        begin for(j=0;j<8;j=j+1) args[j]=0; end
    endtask
    task send_byte(input [7:0] v);
        integer b;
        begin
            rx=0; repeat(16) @(negedge clk);
            for(b=0;b<8;b=b+1) begin rx=v[b]; repeat(16) @(negedge clk); end
            rx=1; repeat(16) @(negedge clk);
        end
    endtask
    task command(input [7:0] cmd);
        integer j;
        reg [7:0] crc;
        begin
            crc=cmd; send_byte(8'ha5); send_byte(cmd);
            for(j=0;j<8;j=j+1) begin send_byte(args[j]); crc=crc^args[j]; end
            send_byte(crc);
            repeat(1900) @(negedge clk);
            if(dut.controller.reply_result!=0) $fatal(1,"command%h rejected",cmd);
        end
    endtask
    task stop_and_check;
        begin
            clear_args(); command(8'h22);
            wait(dut.gain==0);
            repeat(6) @(negedge ws);
            require_silence=1;
            repeat(8) @(negedge ws);
            require_silence=0;
            if(dut.host_playing || dut.host_queued!=0) $fatal(1,"STOP state mismatch");
        end
    endtask
    integer patch, n, baseline;
    initial begin
        clear_args(); #1 rst_n=0; repeat(8) @(negedge clk); rst_n=1;
        wait(dut.ready); stop_and_check();
        // Every existing timbre must reach the external DAC, then stop cleanly.
        for(patch=0;patch<4;patch=patch+1) begin
            clear_args(); args[0]=patch; args[1]=20; command(8'h10);
            clear_args(); args[4]=69; args[5]=127; command(8'h11);
            baseline=nonzero_count;
            clear_args(); command(8'h20);
            repeat(240) @(negedge ws);
            if(nonzero_count<baseline+100) $fatal(1,"patch%0d did not reach I2S",patch);
            if(dut.overrun) $fatal(1,"audio deadline missed");
            $display("METRIC patch=%0d nonzero_slots=%0d",patch,nonzero_count-baseline);
            stop_and_check();
        end
        // Dense mix still uses the same16-bit sample and both output channels.
        clear_args(); args[1]=20; command(8'h10);
        for(n=0;n<32;n=n+1) begin
            clear_args(); args[4]=48+n; args[5]=100; command(8'h11);
        end
        clear_args(); command(8'h20);
        repeat(240) @(negedge ws);
        if(dut.host_gates!==32'hffffffff || dut.overrun || dut.lane_overrun!=0)
            $fatal(1,"32-voice mix/deadline failed");
        stop_and_check();
        if(positive_count<50 || negative_count<50 || left_count<1000 || right_count<1000)
            $fatal(1,"insufficient decoded output coverage");
        $display("PASS pcm5102_path queue=%0d L=%0d R=%0d nonzero=%0d positive=%0d negative=%0d Fs=48828.125 BCK=3125000 MCLK=12500000",
            QUEUE_BSRAM,left_count,right_count,nonzero_count,positive_count,negative_count);
        $finish;
    end
    initial begin #100000000; $fatal(1,"PCM5102 path simulation timeout"); end
endmodule
