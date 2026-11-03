`timescale 1ns/1ps
module tb_usb_direct_control;
    reg clk=0,rst_n=0,connected=0,note_valid=0;
    reg [6:0] note=0,velocity=0;
    reg usb_play=0,usb_stop=0,usb_record=0;
    reg knob_a_valid=0,knob_b_valid=0,pad_b_valid=0;
    reg [2:0] knob_a_index=0,knob_b_index=0;
    reg [6:0] knob_a_value=0,knob_b_value=0,pad_b_note=0;
    wire host_mode,playing,paused,bell,synth_tick,tx;
    wire [7:0] volume;
    wire [6:0] mix,feedback;
    wire [63:0] adsr;
    wire [31:0] gates;
    wire [63:0] patches;
    wire [223:0] velocities;
    wire [1023:0] frequencies;
    wire [31:0] frame;
    wire [6:0] queued;
    always #10 clk=~clk;
    midi_control #(.VOICES(32),.STEAL_ON_FULL(0),.CLKS_PER_BIT(16)) dut(
        .clk(clk),.rst_n(rst_n),.rx(1'b1),.tx(tx),.sample_tick(1'b0),
        .audio_ready(1'b1),.audio_overrun(1'b0),
        .usb_dp_stable(1'b1),.usb_dm_stable(1'b0),
        .usb_connected(connected),.usb_note_valid(note_valid),
        .usb_note(note),.usb_velocity(velocity),.usb_channel(4'd0),
        .usb_patch_select(2'd2),.usb_mod_valid(1'b0),
        .usb_mod_depth(7'd0),.usb_bend_valid(1'b0),
        .usb_bend_word(14'd0),.host_mode(host_mode),.playing(playing),
        .usb_play(usb_play),.usb_stop(usb_stop),.usb_record(usb_record),
        .usb_knob_a_valid(knob_a_valid),.usb_knob_a_index(knob_a_index),
        .usb_knob_a_value(knob_a_value),
        .usb_knob_b_valid(knob_b_valid),.usb_knob_b_index(knob_b_index),
        .usb_knob_b_value(knob_b_value),
        .usb_pad_b_valid(pad_b_valid),.usb_pad_b_note(pad_b_note),
        .paused(paused),.bell(bell),.volume(volume),
        .effect_mix(mix),.effect_feedback(feedback),.adsr_values(adsr),
        .gates(gates),.voice_patches(patches),
        .voice_velocities(velocities),.frequency_words(frequencies),
        .synth_tick(synth_tick),.frame_index(frame),.queue_count(queued));
    task key_event(input [6:0] n,input [6:0] v);
        begin
            @(negedge clk);note=n;velocity=v;note_valid=1;
            @(negedge clk);note_valid=0;
            repeat(6) @(negedge clk);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst_n=1;connected=1;
        repeat(5) @(negedge clk);
        if(!playing || !host_mode || volume!=8'd255)
            $fatal(1,"USB direct session did not start at configured gain");
        key_event(7'd53,7'd104);
        key_event(7'd54,7'd122);
        if(gates[1:0]!=2'b11 || patches[3:0]!=4'b1010 ||
           velocities[6:0]!=7'd104 || velocities[13:7]!=7'd122 ||
           frequencies[31:0]==0 || frequencies[63:32]==0)
            $fatal(1,"direct polyphonic notes failed");
        key_event(7'd53,7'd0);
        if(gates[1:0]!=2'b10) $fatal(1,"note off failed");
        @(negedge clk);usb_record=1;
        @(negedge clk);usb_record=0;
        if(dut.velocity_response_enabled!==1'b0)
            $fatal(1,"REC failed to disable touch response");
        key_event(7'd57,7'd12);
        if(velocities[6:0]!=7'd96)
            $fatal(1,"fixed velocity did not ignore a light USB strike");
        key_event(7'd57,7'd0);
        if(gates[0]!==1'b0) $fatal(1,"fixed mode swallowed note off");
        @(negedge clk);usb_stop=1;
        @(negedge clk);usb_stop=0;
        @(negedge clk);usb_play=1;
        @(negedge clk);usb_play=0;
        if(dut.velocity_response_enabled!==1'b0 || !playing)
            $fatal(1,"STOP/PLAY lost fixed-velocity preference");
        @(negedge clk);usb_record=1;
        @(negedge clk);usb_record=0;
        if(dut.velocity_response_enabled!==1'b1)
            $fatal(1,"second REC failed to restore touch response");
        key_event(7'd57,7'd12);
        if(velocities[6:0]!=7'd12)
            $fatal(1,"touch response did not restore measured velocity");
        key_event(7'd57,7'd0);
        @(negedge clk);knob_a_valid=1;knob_a_index=3'd1;knob_a_value=7'd100;
        @(negedge clk);knob_a_valid=0;
        key_event(7'd60,7'd80);
        if(dut.voice_pitch_note[0]!=7'd72)
            $fatal(1,"A OCT did not transpose a newly played note");
        @(negedge clk);knob_b_valid=1;knob_b_index=3'd4;knob_b_value=7'd64;
        @(negedge clk);knob_b_valid=0;
        if(mix!=7'd32) $fatal(1,"B echo mix mapping failed");
        @(negedge clk);pad_b_valid=1;pad_b_note=7'd96;
        @(negedge clk);pad_b_valid=0;
        if(mix!=0) $fatal(1,"PAD-B echo toggle failed");
        @(negedge clk);knob_b_valid=1;knob_b_index=3'd6;knob_b_value=7'd124;
        @(negedge clk);knob_b_valid=0;
        if(volume!=8'd248) $fatal(1,"USB B volume mapping failed");
        @(negedge clk);knob_b_valid=1;knob_b_value=7'd127;
        @(negedge clk);knob_b_valid=0;
        if(volume!=8'd255) $fatal(1,"USB B volume maximum failed");
        @(negedge clk);usb_stop=1;
        @(negedge clk);usb_stop=0;
        if(playing || gates!=0) $fatal(1,"USB STOP failed");
        @(negedge clk);usb_play=1;
        @(negedge clk);usb_play=0;
        if(!playing) $fatal(1,"USB PLAY failed");
        @(negedge clk);usb_record=1;
        @(negedge clk);usb_record=0;
        if(dut.velocity_response_enabled!==1'b0)
            $fatal(1,"REC failed before disconnect reset");
        connected=0;repeat(4) @(negedge clk);
        if(gates!=0 || playing || dut.velocity_response_enabled!==1'b1)
            $fatal(1,"USB disconnect left held notes or fixed velocity");
        $display("PASS direct USB note allocation, REC touch toggle, patch and disconnect");
        $finish;
    end
endmodule
