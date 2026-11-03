`timescale 1ns/1ps
// Regression for NOTE_OFF arriving while a matching NOTE_ON waits to retrigger.
// Default mode confirms the known bug; -DEXPECT_FIXED checks the desired result.
module tb_midi_retrigger_note_off;
    reg clk=0, rst_n=0, connected=0, note_valid=0, tick=0;
    reg [6:0] note=0, velocity=0;
    wire tx, host_mode, playing, paused, bell, synth_tick;
    wire [7:0] volume;
    wire [6:0] mix, feedback;
    wire [63:0] adsr;
    wire [0:0] gates;
    wire [1:0] patches;
    wire [6:0] velocities;
    wire [31:0] frequencies;
    wire [31:0] frame;
    wire [6:0] queued;

    always #10 clk=~clk;
    midi_control #(.VOICES(1), .STEAL_ON_FULL(0), .CLKS_PER_BIT(16)) dut (
        .clk(clk), .rst_n(rst_n), .rx(1'b1), .tx(tx),
        .sample_tick(tick), .audio_ready(1'b1), .audio_overrun(1'b0),
        .usb_dp_stable(1'b1), .usb_dm_stable(1'b0),
        .usb_connected(connected), .usb_note_valid(note_valid),
        .usb_note(note), .usb_velocity(velocity), .usb_channel(4'd0),
        .usb_patch_select(2'd2),
        .usb_mod_valid(1'b0), .usb_mod_depth(7'd0),
        .usb_bend_valid(1'b0), .usb_bend_word(14'd0),
        .usb_play(1'b0), .usb_stop(1'b0), .usb_record(1'b0),
        .usb_knob_a_valid(1'b0), .usb_knob_a_index(3'd0),
        .usb_knob_a_value(7'd0),
        .usb_knob_b_valid(1'b0), .usb_knob_b_index(3'd0),
        .usb_knob_b_value(7'd0),
        .usb_pad_b_valid(1'b0), .usb_pad_b_note(7'd0),
        .host_mode(host_mode), .playing(playing), .paused(paused),
        .bell(bell), .volume(volume), .effect_mix(mix),
        .effect_feedback(feedback), .adsr_values(adsr),
        .gates(gates), .voice_patches(patches),
        .voice_velocities(velocities), .frequency_words(frequencies),
        .synth_tick(synth_tick), .frame_index(frame), .queue_count(queued)
    );

    task key_event(input [6:0] event_note, input [6:0] event_velocity);
        begin
            @(negedge clk);
            note=event_note; velocity=event_velocity; note_valid=1;
            @(negedge clk); note_valid=0;
            repeat(8) @(negedge clk); // wait for event/selection/commit pipeline
        end
    endtask

    task sample_frame;
        begin
            @(negedge clk); tick=1;
            @(negedge clk); tick=0;
            repeat(3) @(negedge clk);
        end
    endtask

    initial begin
        repeat(4) @(negedge clk); rst_n=1; connected=1;
        repeat(5) @(negedge clk);
        if(!playing) $fatal(1,"precondition: USB connection did not start playback");
        key_event(7'd62,7'd100);
        sample_frame();
        if(gates[0]!==1'b1 || dut.voice_note[0]!==7'd62)
            $fatal(1,"precondition: initial note is not sounding");

        // Same-note NOTE_ON closes the gate and arms retrigger until next tick.
        key_event(7'd62,7'd100);
        if(gates[0]!==1'b0 || dut.retrigger[0]!==1'b1)
            $fatal(1,"precondition: expected pending retrigger, gate=%b retrigger=%b",
                   gates[0],dut.retrigger[0]);
        key_event(7'd62,7'd0);
        // NOTE_OFF should cancel the pending retrigger before it reopens gate.
        sample_frame();
`ifdef EXPECT_FIXED
        if(gates[0]!==1'b0 || dut.retrigger[0]!==1'b0)
            $fatal(1,"CONTRACT_FAILURE:tb_midi_retrigger_note_off: released note remained active: gate=%b retrigger=%b",
                   gates[0],dut.retrigger[0]);
        key_event(7'd62,100); sample_frame();
        key_event(7'd62,100); // pending retrigger reserves voice 0
        key_event(7'd64,100);
        if(dut.voice_note[0]!==62 || gates[0]!==0 || dut.retrigger[0]!==1)
            $fatal(1,"CONTRACT_FAILURE:tb_midi_retrigger_note_off: pending voice was reused");
        key_event(7'd62,0); sample_frame();
        if(gates[0]!==0 || dut.retrigger[0]!==0)
            $fatal(1,"CONTRACT_FAILURE:tb_midi_retrigger_note_off: release left reserved voice active");
        $display("PASS:tb_midi_retrigger_note_off: NOTE_OFF canceled pending retrigger");
`else
        if(gates[0]!==1'b1 || dut.retrigger[0]!==1'b0)
            $fatal(1,"known stuck-note bug changed: gate=%b retrigger=%b",
                   gates[0],dut.retrigger[0]);
        $display("EXPECTED_BUG:tb_midi_retrigger_note_off: NOTE_OFF during pending retrigger was ignored; gate reopened after sample tick");
`endif
        $finish;
    end
    initial begin #1000000; $fatal(1,"retrigger NOTE_OFF test timed out"); end
endmodule
