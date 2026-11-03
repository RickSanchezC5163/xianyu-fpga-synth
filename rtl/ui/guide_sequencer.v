`timescale 1ns/1ps
// ROM adapter for the same player used by uploaded RAM scores.
module guide_sequencer #(parameter integer PREVIEW_TICKS=24,ENABLE_WAIT_MODE=0)(
    input wire clk,rst_n,start,stop,playing,paused,loop_enable,
    input wire [31:0] song_tick,
    output wire [24:0] expected_keys,preview_keys,
    output wire finish,loop_restart,
    input wire wait_mode,target_hit,output wire target_pulse,unsupported
);
    wire req;wire [7:0] address;wire [31:0] at_tick;wire [24:0] next_keys;wire last;
    guide_score_rom score(address[3:0],at_tick,next_keys,last);
    reg valid;reg [63:0] event_data;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin valid<=0;event_data<=0;end
        else begin valid<=req;if(req)event_data<={7'd0,next_keys,at_tick};end
    end
    guide_event_player #(.ENABLE_WAIT_MODE(ENABLE_WAIT_MODE),.PREVIEW_TICKS(PREVIEW_TICKS)) player(
        .clk(clk),.rst_n(rst_n),.start(start),.stop(stop),.playing(playing),.paused(paused),
        .loop_enable(loop_enable),.source_changed(1'b0),.song_tick(song_tick),.source_count(9'd16),
        .read_req(req),.read_address(address),.read_valid(valid),.read_event(event_data),
        .wait_mode(wait_mode),.target_hit(target_hit),.expected_keys(expected_keys),.preview_keys(preview_keys),
        .finish(finish),.loop_restart(loop_restart),.target_pulse(target_pulse),.unsupported(unsupported));
endmodule
