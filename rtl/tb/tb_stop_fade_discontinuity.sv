`timescale 1ns/1ps

// Regression for STOP clearing effect_pcm before the master gain has faded.
// This drives the real UART MIDI command path through mega60k_audio_top and
// observes the real additive_core -> echo_effect -> gain -> amplifier chain.
//
// Default build : reproduces the review's P2-1 defect (echo_effect is cleared
//                 within one clock of STOP while gain is still nonzero).
// -DEXPECT_FIXED: asserts the post-fix contract, i.e. the master gain finishes
//                 its fade before echo_effect.clear is asserted and DAC slots
//                 follow the controlled input times each frame's gain.
module tb_stop_fade_discontinuity;
    reg clk=0;
    reg rst_n=1;
    reg uart_rx=1;
    wire uart_tx,bck,ws,din,pa_en;
    wire usb_dp=1'b0,usb_dm=1'b0;
    wire [1:0] leds;

    mega60k_audio_top #(.STARTUP_CYCLES(100),.DEBOUNCE_CYCLES(8),
                         .UART_CLKS_PER_BIT(16)) dut(
        .sys_clk(clk),.rst_n(rst_n),.key0_n(1'b1),.key1_n(1'b1),
        .uart_rx(uart_rx),.uart_tx(uart_tx),.usb_dp(usb_dp),.usb_dm(usb_dm),
        .hp_bck(bck),.hp_ws(ws),.hp_din(din),.pa_en(pa_en),.status_led(leds));
    always #10 clk=~clk;

    // Controlled nonzero core output isolates STOP fade from oscillator phase.
    // The UART path, effect, gain and PT8211 transmitter remain real logic.
    // Decode both physical slots, comparing against input * frame-latched gain
    // rather than against effect_pcm (which is the signal under investigation).
    reg stop_seen = 0;
    reg expected_valid = 0;
    reg signed [15:0] expected_slot = 0;
    reg [7:0] frame_gain = 0;
    reg last_ws = 1;
    reg [15:0] received = 0;
    integer bit_index = 0;
    integer checked_slots = 0;
    integer silent_slots = 0;
    integer abrupt_slots = 0;

    always @(posedge clk) begin
        if (dut.core_reset_n && dut.dac.divider==31 && dut.dac.position==31) begin
            expected_valid = stop_seen;
            frame_gain = dut.gain;
            expected_slot = 64 * dut.gain; // 0x400000 >> 8, times gain / 256
        end
    end
    always @(posedge bck) begin
        if (ws !== last_ws) begin
            last_ws = ws;
            bit_index = 0;
            received = 0;
        end
        received = {received[14:0],din};
        if (bit_index==15) begin
            if (expected_valid) begin
                checked_slots = checked_slots + 1;
                if (frame_gain==0 && received==0) silent_slots = silent_slots + 1;
                if (frame_gain!=0 && received==0) abrupt_slots = abrupt_slots + 1;
`ifdef EXPECT_FIXED
                if (received !== expected_slot)
                    $fatal(1,"CONTRACT_FAILURE:tb_stop_fade_discontinuity: DAC slot=%0d expected=%0d at frame gain=%0d",
                           $signed(received),expected_slot,frame_gain);
`endif
            end
            bit_index = 0;
        end else bit_index = bit_index + 1;
    end

    reg [7:0] params [0:7];
    integer i;

    task byte_out(input [7:0] value);
        integer bit_index;
        begin
            uart_rx=1'b0;
            repeat(16) @(negedge clk);
            for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
                uart_rx=value[bit_index];
                repeat(16) @(negedge clk);
            end
            uart_rx=1'b1;
            repeat(16) @(negedge clk);
        end
    endtask

    task command(input [7:0] cmd);
        reg [7:0] crc;
        integer index;
        begin
            crc=cmd;
            byte_out(8'ha5);
            byte_out(cmd);
            for(index=0;index<8;index=index+1) begin
                byte_out(params[index]);
                crc=crc^params[index];
            end
            byte_out(crc);
            // Let the full-duplex command reply complete before another one.
            repeat(1900) @(negedge clk);
        end
    endtask

    integer timeout;
    reg signed [23:0] sample_before_stop;
    reg [7:0] gain_before_stop;

    initial begin
        for(i=0;i<8;i=i+1) params[i]=0;
        #1 rst_n=0;
        repeat(5) @(negedge clk);
        rst_n=1;
        wait(dut.ready);

        // Enter host mode, queue one MIDI note, then start playback.
        command(8'h23);
        params[4]=8'd60;
        params[5]=8'd100;
        command(8'h11);
        for(i=0;i<8;i=i+1) params[i]=0;
        command(8'h20);
        if(!dut.host_mode || !dut.host_playing || pa_en!==1'b0)
            $fatal(1,"STOP regression setup did not enter audible host playback");

        force dut.pcm = 24'sh400000;
        // Settle the effect and master gain before measuring STOP.
        repeat(20000) @(negedge clk);
        // Wait for an actual nonzero sample after the complete audio chain.
        timeout=0;
        while((dut.effect_pcm===24'sd0 || (^dut.effect_pcm===1'bx) ||
               dut.gain===8'd0 || (^dut.gain===1'bx)) && timeout<300000) begin
            @(negedge clk);
            timeout=timeout+1;
        end
        if(timeout==300000 || dut.effect_pcm===24'sd0 || (^dut.effect_pcm===1'bx) ||
           dut.gain===8'd0 || (^dut.gain===1'bx) || pa_en!==1'b0)
            $fatal(1,"STOP regression setup never produced audible nonzero PCM");

        // At the controller's STOP state transition, capture the still-audible
        // sample, then inspect the very next clock when echo_effect sees clear.
        fork
            begin : observe_stop_edge
                wait(dut.host_playing===1'b0);
                #1;
                stop_seen=1;
                sample_before_stop=dut.effect_pcm;
                gain_before_stop=dut.gain;
                if(gain_before_stop===8'd0 || (^gain_before_stop===1'bx) || pa_en!==1'b0)
                    $fatal(1,"expected pre-clear STOP gain/amplifier to remain active: gain=%0d pa_en=%b",
                           gain_before_stop,pa_en);
`ifdef EXPECT_FIXED
                // Review P2-1 fix contract: the master gain must finish its fade
                // before echo_effect is cleared.  The clear input is driven by
                // !audio_active && !host_paused, so a compliant fix keeps it low
                // for as long as gain is nonzero.
                timeout=0;
                while(dut.gain!==8'd0 && timeout<2000000) begin
                    if(dut.echo.clear===1'b1)
                        $fatal(1,"CONTRACT_FAILURE:tb_stop_fade_discontinuity: echo cleared while gain=%0d is still fading",dut.gain);
                    if(pa_en!==1'b0)
                        $fatal(1,"CONTRACT_FAILURE:tb_stop_fade_discontinuity: amplifier disabled while gain=%0d is still fading",dut.gain);
                    @(negedge clk);
                    timeout=timeout+1;
                end
                if(timeout>=2000000)
                    $fatal(1,"gain never reached zero after STOP: gain=%0d",dut.gain);
                repeat(3072) @(negedge clk);
                if(checked_slots<2 || silent_slots<2)
                    $fatal(1,"STOP output coverage missing: checked=%0d silent=%0d",checked_slots,silent_slots);
                if(dut.echo.clear!==1'b1)
                    $fatal(1,"CONTRACT_FAILURE:tb_stop_fade_discontinuity: effect was never cleared after the fade completed");
                $display("PASS:tb_stop_fade_discontinuity: STOP faded gain %0d -> 0 before clearing the effect",
                         gain_before_stop);
`else
                if(sample_before_stop===24'sd0 || (^sample_before_stop===1'bx))
                    $fatal(1,"STOP stimulus unexpectedly zero before clear");
                @(posedge clk);
                #1;
                if(dut.effect_pcm!==24'sd0 || dut.gain==0 || pa_en!==1'b0)
                    $fatal(1,"STOP did not reproduce abrupt sample clear while gain/amplifier remained active: before=%0d after=%0d gain=%0d pa_en=%b",
                           sample_before_stop,dut.effect_pcm,dut.gain,pa_en);
                repeat(2048) @(negedge clk);
                if(abrupt_slots==0)
                    $fatal(1,"STOP internal clear did not produce a zero DAC slot at nonzero gain");
                $display("EXPECTED_BUG:tb_stop_fade_discontinuity: STOP cleared effect_pcm %0d -> %0d while gain=%0d and the amplifier stayed enabled",
                         sample_before_stop,dut.effect_pcm,dut.gain);
`endif
            end
            begin : send_stop
                command(8'h22);
            end
        join
        $finish;
    end

    initial begin
        #100000000;
        $fatal(1,"STOP fade discontinuity test timed out");
    end
endmodule
