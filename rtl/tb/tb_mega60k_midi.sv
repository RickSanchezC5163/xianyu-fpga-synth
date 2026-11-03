`timescale 1ns/1ps
module tb_mega60k_midi;
    reg clk=0,rst_n=1,uart_rx=1;
    wire uart_tx,bck,ws,din,pa_en;
    wire usb_dp=1'b0,usb_dm=1'b0;
    wire [1:0] leds;
    mega60k_audio_top #(.STARTUP_CYCLES(100),.DEBOUNCE_CYCLES(8),
                         .UART_CLKS_PER_BIT(16)) dut(
        .sys_clk(clk),.rst_n(rst_n),.key0_n(1'b1),.key1_n(1'b1),
        .uart_rx(uart_rx),.uart_tx(uart_tx),.usb_dp(usb_dp),.usb_dm(usb_dm),
        .hp_bck(bck),.hp_ws(ws),.hp_din(din),.pa_en(pa_en),.status_led(leds));
    always #10 clk=~clk;
    integer nonzero_bits=0;
    integer complete_samples=0;
    always @(posedge clk) if(dut.valid) complete_samples=complete_samples+1;
    always @(posedge bck) if(din) nonzero_bits=nonzero_bits+1;
    reg [7:0] p [0:7];
    task byte_out(input [7:0] value);
        integer b;
        begin
            uart_rx=0;repeat(16) @(negedge clk);
            for(b=0;b<8;b=b+1) begin
                uart_rx=value[b];repeat(16) @(negedge clk);
            end
            uart_rx=1;repeat(16) @(negedge clk);
        end
    endtask
    task command(input [7:0] cmd);
        reg [7:0] crc;
        integer i;
        begin
            crc=cmd;byte_out(8'ha5);byte_out(cmd);
            for(i=0;i<8;i=i+1) begin byte_out(p[i]);crc=crc^p[i];end
            byte_out(crc);
            // Wait for the 11-byte full-duplex reply before the next request.
            repeat(1900) @(negedge clk);
        end
    endtask
    integer baseline,timeout,i;
    initial begin
        for(i=0;i<8;i=i+1) p[i]=0;
        #1 rst_n=0;repeat(5) @(negedge clk);rst_n=1;
        wait(dut.ready);
        command(8'h23);
        if(!dut.host_mode || pa_en!==1'b1)
            $fatal(1,"idle host mode did not shut down amplifier");
        command(8'h20);
        if(!dut.host_playing || pa_en!==1'b0)
            $fatal(1,"playing with no notes did not hold amplifier on");
        command(8'h22);
        p[4]=60;p[5]=100;p[6]=0;
        command(8'h11);
        if(dut.host_queued!=1) $fatal(1,"top did not receive MIDI note");
        for(i=0;i<8;i=i+1) p[i]=0;
        command(8'h20);
        timeout=0;
        while(nonzero_bits<20 && timeout<300000) begin
            @(negedge clk);timeout=timeout+1;
        end
        if(nonzero_bits<20 || !dut.host_playing || pa_en!==1'b0)
            $fatal(1,"MIDI note did not reach PT8211 serial output");
        command(8'h21);
        wait(dut.gain==0);
        // PT8211 shifts the sample latched before the final zero-gain frame.
        repeat(2) @(posedge dut.frame_tick);
        baseline=nonzero_bits;
        repeat(4000) @(negedge clk);
        if(nonzero_bits!=baseline || !dut.host_paused || pa_en!==1'b1)
            $fatal(1,"pause did not mute DAC serial data");
        command(8'h20);
        baseline=nonzero_bits;
        repeat(4000) @(negedge clk);
        if(nonzero_bits<=baseline || pa_en!==1'b0)
            $fatal(1,"resume did not restore DAC data");
        command(8'h22);
        wait(dut.gain==0);
        repeat(2) @(posedge dut.frame_tick);
        baseline=nonzero_bits;
        repeat(4000) @(negedge clk);
        if(nonzero_bits!=baseline || dut.host_playing || dut.host_queued!=0 || pa_en!==1'b1)
            $fatal(1,"stop did not mute DAC and flush queue");
        // All 32 voices must sound before the 33rd is safely dropped.
        for(i=0;i<33;i=i+1) begin
            p[4]=8'd48+i;p[5]=8'd100;p[6]=0;
            command(8'h11);
        end
        for(i=0;i<8;i=i+1) p[i]=0;
        command(8'h20);
        timeout=0;
        while(dut.host_queued!=0 && timeout<300000) begin
            @(negedge clk);timeout=timeout+1;
        end
        repeat(5) @(negedge clk);
        if(timeout==300000 || dut.host_gates!==32'hffffffff ||
           dut.controller.voice_note[0]!=7'd48 ||
           dut.controller.voice_note[31]!=7'd79 ||
           !dut.controller.voice_dropped)
            $fatal(1,"32-voice allocation or safe overflow failed: gates=%h first=%0d last=%0d dropped=%b pending=%b/%b",
                   dut.host_gates,dut.controller.voice_note[0],
                   dut.controller.voice_note[31],dut.controller.voice_dropped,
                   dut.controller.event_pending,dut.controller.selected_pending);
        baseline=complete_samples;
        repeat(5) @(posedge dut.frame_tick);
        repeat(300) @(posedge clk);
        if(dut.overrun || dut.lane_overrun!=0 || complete_samples<baseline+5)
            $fatal(1,"32-voice synthesis missed an audio frame");
        command(8'h22);
        // Four MIDI channels must keep distinct patches in the same synth lane.
        p[0]=1;p[1]=1;command(8'h12);
        p[0]=2;p[1]=2;command(8'h12);
        p[0]=3;p[1]=3;command(8'h12);
        for(i=0;i<8;i=i+1) p[i]=0;
        p[4]=60;p[5]=100;p[6]=0;command(8'h11);
        p[4]=64;p[6]=1;command(8'h11);
        p[4]=67;p[6]=2;command(8'h11);
        p[4]=72;p[6]=3;command(8'h11);
        for(i=0;i<8;i=i+1) p[i]=0;
        command(8'h20);
        timeout=0;
        while(dut.host_queued!=0 && timeout<300000) begin
            @(negedge clk);timeout=timeout+1;
        end
        repeat(5) @(posedge dut.frame_tick);
        if(timeout==300000 || dut.host_gates[3:0]!==4'b1111 ||
           dut.selected_voice_patches[7:0]!==8'he4 ||
           dut.synthesis_lane[0].synth.patch_frame[7:0]!==8'he4)
            $fatal(1,"simultaneous MIDI channels lost four separate timbres");
        command(8'h22);
        $display("PASS: UART MIDI note reached PT8211, pause/resume/stop on DAC pins");
        $finish;
    end
    initial begin #100000000;$fatal(1,"top MIDI test timed out");end
endmodule
