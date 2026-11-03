`timescale 1ns/1ps
// Two 128-byte banks; completed snapshots wait for display frame boundary.
// Samples may be dropped while pending. No ready/backpressure to audio source.
module ui_waveform_buffer #(parameter integer DECIMATE=64)(
    input wire clk,rst_n,sample_valid,input wire signed [15:0] sample_pcm,
    input wire frame_start,input wire [6:0] read_index,
    output wire signed [7:0] read_sample,output reg display_valid
);
    localparam integer CW=(DECIMATE<=1)?1:$clog2(DECIMATE);
    reg [CW-1:0] count;
    reg [7:0] samples[0:255];
    reg [6:0] write_index;
    reg read_bank,pending;
    assign read_sample=display_valid?samples[{read_bank,read_index}]:8'd0;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin count<=0;write_index<=0;read_bank<=0;pending<=0;display_valid<=0;end
        else if(frame_start && pending) begin
            read_bank<=!read_bank;display_valid<=1;pending<=0;write_index<=0;count<=0;
        end else if(sample_valid && !pending) begin
            if(count==DECIMATE-1) begin
                count<=0;samples[{!read_bank,write_index}]<=sample_pcm[15:8];
                if(write_index==127) pending<=1;
                else write_index<=write_index+1'b1;
            end else count<=count+1'b1;
        end
    end
    // synthesis translate_off
    initial if(DECIMATE<1) $fatal(1,"DECIMATE must be positive");
    // synthesis translate_on
endmodule
