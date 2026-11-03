`timescale 1ns/1ps
// Dedicated physical keyboard ledger. Audio gates/ADSR and UI held-display
// clearing are deliberately NOT evidence that a physical key was released.
module guide_note_match #(parameter integer PRACTICE_CHANNEL=0)(
    input wire clk,rst_n,keyboard_disconnected,clear_progress,
    input wire enabled,playing,paused,target_pulse,
    input wire [24:0] expected_keys,input wire [6:0] base_note,
    input wire note_valid,input wire [6:0] note,velocity,input wire [3:0] channel,
    output reg hit,wrong,output reg [24:0] wrong_keys
);
    reg [127:0] physical_down;
    reg [7:0] down_count;
    reg armed,previous_valid;
    reg [6:0] previous_note;
    reg [6:0] old_base;
    reg base_known;
    wire eligible=note_valid && channel==PRACTICE_CHANNEL;
    wire fresh=eligible && velocity!=0 && !physical_down[note];
    wire in_range=note>=base_note && {1'b0,note}<({1'b0,base_note}+8'd25);
    wire [6:0] relative_note=note-base_note;
    wire single_target=expected_keys!=0 && (expected_keys&(expected_keys-25'd1))==0;
    wire permitted_overlap=(down_count==0) ||
        (down_count==1 && previous_valid && physical_down[previous_note]);
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            physical_down<=0;down_count<=0;armed<=0;previous_valid<=0;previous_note<=0;
            hit<=0;wrong<=0;wrong_keys<=0;old_base<=0;base_known<=0;
        end else begin
            old_base<=base_note;base_known<=1;
            hit<=0;wrong<=0;
            // Track keys even while stopped, paused, between targets or in timed mode.
            if(keyboard_disconnected)begin physical_down<=0;down_count<=0;end
            else if(eligible)begin
                physical_down[note]<=velocity!=0;
                if(velocity!=0 && !physical_down[note])down_count<=down_count+1'b1;
                else if(velocity==0 && physical_down[note] && down_count!=0)down_count<=down_count-1'b1;
            end
            if(keyboard_disconnected || clear_progress || (base_known && old_base!=base_note) || !enabled || !playing)begin
                armed<=0;previous_valid<=0;wrong_keys<=0;
            end else if(target_pulse)begin
                // Same-cycle input is recorded but cannot count as a response.
                armed<=1;wrong_keys<=0;
            end else if(paused)wrong_keys<=0;
            else if(armed && fresh)begin
                if(single_target && in_range && expected_keys[relative_note] && permitted_overlap)begin
                    hit<=1;armed<=0;previous_note<=note;previous_valid<=1;wrong_keys<=0;
                end else begin
                    wrong<=1;wrong_keys<=in_range?(25'd1<<relative_note):25'd0;
                end
            end
        end
    end
    // synthesis translate_off
    initial if(PRACTICE_CHANNEL<0 || PRACTICE_CHANNEL>15 || PRACTICE_CHANNEL==9)
        $fatal(1,"practice channel must be one non-percussion MIDI channel");
    // synthesis translate_on
endmodule
