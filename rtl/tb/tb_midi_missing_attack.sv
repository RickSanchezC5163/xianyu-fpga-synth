`timescale 1ns/1ps
// Regression for NOTE_OFF(old) followed by NOTE_ON(new) between sample ticks.
// Default mode confirms the known bug; -DEXPECT_FIXED checks the desired result.
module tb_midi_missing_attack;
    reg clk=0, rst_n=0, connected=0, note_valid=0, tick=0;
    reg [6:0] note=0, velocity=0;
    wire tx, host_mode, playing, paused, bell, synth_tick;
    wire [7:0] volume;
    wire [6:0] mix, feedback;
    wire [63:0] adsr;
    wire [3:0] gates;
    wire [31:0] epochs;
    wire [7:0] patches;
    wire [27:0] velocities;
    wire [127:0] frequencies;
    wire [31:0] frame;
    wire [6:0] queued;
    wire signed [23:0] pcm;
    wire pcm_valid, overrun;

    always #10 clk=~clk;
    midi_control #(.VOICES(4), .STEAL_ON_FULL(0), .CLKS_PER_BIT(16)) dut (
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
        .gates(gates), .voice_epochs(epochs), .voice_patches(patches),
        .voice_velocities(velocities), .frequency_words(frequencies),
        .synth_tick(synth_tick), .frame_index(frame), .queue_count(queued)
    );
    additive_core #(.VOICES(4)) core (
        clk, rst_n, tick, gates, epochs, frequencies, patches, velocities,
        adsr, pcm, pcm_valid, overrun
    );

    task key_event(input [6:0] event_note, input [6:0] event_velocity);
        begin
            @(negedge clk);
            note=event_note; velocity=event_velocity; note_valid=1;
            @(negedge clk); note_valid=0;
            // USB event capture, voice selection, and gate update are pipelined.
            repeat(8) @(negedge clk);
        end
    endtask

    task sample_frame;
        begin
            @(negedge clk); tick=1;
            @(negedge clk); tick=0;
            repeat(1023) @(negedge clk); // let additive_core finish every partial
        end
    endtask

    integer i;
    initial begin
        repeat(4) @(negedge clk); rst_n=1; connected=1;
        repeat(5) @(negedge clk);
        if(!playing) $fatal(1,"precondition: USB connection did not start playback");
        key_event(7'd60,7'd100);
        if(gates[0]!==1'b1 || dut.voice_note[0]!==7'd60)
            $fatal(1,"precondition: first note did not occupy voice 0");
        for(i=0;i<300;i=i+1) sample_frame();
        if(core.env_state[0]!==3'd2)
            $fatal(1,"precondition: old note must be in DECAY, got %0d",core.env_state[0]);

        // Both events finish before the next sample tick. The control gate
        // returns to 1 before additive_core can observe the intermediate 0.
        key_event(7'd60,7'd0);
        if(gates[0]!==1'b0) $fatal(1,"precondition: NOTE_OFF did not close gate");
        key_event(7'd62,7'd100);
        if(gates[0]!==1'b1 || dut.voice_note[0]!==7'd62)
            $fatal(1,"precondition: new note did not reuse voice 0");
        sample_frame();
        if(overrun) $fatal(1,"additive_core overrun invalidates envelope check");
`ifdef EXPECT_FIXED
        if(core.env_state[0]!==3'd1)
            $fatal(1,"CONTRACT_FAILURE:tb_midi_missing_attack: new note missed ATTACK: envelope state=%0d, expected 1",core.env_state[0]);
        for(i=0;i<8;i=i+1)
            if(core.env_state[i]!==3'd1)
                $fatal(1,"CONTRACT_FAILURE:tb_midi_missing_attack: partial %0d missed ATTACK",i);
        for(i=0;i<300;i=i+1) sample_frame();
        // Two note-ons within one snapshot must not cancel as toggle bits do.
        key_event(7'd62,0); key_event(7'd62,100);
        key_event(7'd62,0); key_event(7'd62,100);
        sample_frame();
        for(i=0;i<8;i=i+1)
            if(core.env_state[i]!==3'd1)
                $fatal(1,"CONTRACT_FAILURE:tb_midi_missing_attack: same-note double reattack lost on partial %0d",i);
        $display("PASS:tb_midi_missing_attack: new note entered ATTACK after same-frame NOTE_OFF/NOTE_ON");
`else
        if(core.env_state[0]!==3'd2)
            $fatal(1,"known missing-ATTACK bug changed: envelope state=%0d",core.env_state[0]);
        $display("EXPECTED_BUG:tb_midi_missing_attack: note 62 reused voice 0, envelope stayed DECAY (state 2) instead of ATTACK (state 1)");
`endif
        $finish;
    end
    initial begin #100000000; $fatal(1,"missing-attack test timed out"); end
endmodule
