`timescale 1ns/1ps
// Physical held-key feedback, not synthesizer voice/gate accounting.
// One bit per channel/key prevents one channel's Note Off clearing another.
module ui_key_state(input wire clk,rst_n,clear,input wire [6:0] base_note,
    input wire note_valid,input wire [6:0] note,velocity,input wire [3:0] channel,
    output reg [24:0] held_keys,output reg out_of_range);
    reg [15:0] channels[0:24];
    reg [6:0] old_base;
    reg base_known;
    integer i;
    always @* begin
        for(i=0;i<25;i=i+1) held_keys[i]=|channels[i];
    end
    integer j;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            // Asynchronous reset must select a constant, never an input value.
            // Capture the initial base synchronously without losing a first note.
            old_base<=0;base_known<=0;out_of_range<=0;
            for(j=0;j<25;j=j+1) channels[j]<=0;
        end else begin
            old_base<=base_note;base_known<=1;out_of_range<=0;
            if(clear || (base_known && base_note!=old_base)) begin
                for(j=0;j<25;j=j+1) channels[j]<=0;
            end else if(note_valid) begin
                if(note>=base_note && {1'b0,note}<({1'b0,base_note}+8'd25))
                    channels[note-base_note][channel]<=velocity!=0;
                else out_of_range<=1;
            end
        end
    end
endmodule
