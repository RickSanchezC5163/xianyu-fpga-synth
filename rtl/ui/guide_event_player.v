`timescale 1ns/1ps
// One synchronous event reader for both timed and fresh-key practice modes.
// Waiting never stalls the musical reference clock or any audio calculation.
module guide_event_player #(
    parameter integer ENABLE_WAIT_MODE=0,PREVIEW_TICKS=24
)(
    input wire clk,rst_n,start,stop,playing,paused,loop_enable,source_changed,
    input wire [31:0] song_tick,input wire [8:0] source_count,
    output reg read_req,output reg [7:0] read_address,
    input wire read_valid,input wire [63:0] read_event,
    input wire wait_mode,target_hit,
    output reg [24:0] expected_keys,output wire [24:0] preview_keys,
    output reg finish,loop_restart,target_pulse,unsupported
);
    localparam [1:0] FETCH_HEAD=0,FETCH_NEXT=1,RUN=2,ENDED=3;
    reg [1:0] state;
    reg pending,head_valid,waiting_for_hit,nonzero_seen;
    reg [8:0] head_index;
    reg [63:0] head_event,next_event;
    wire stepping=(ENABLE_WAIT_MODE!=0) && wait_mode;
    wire [24:0] mask=head_event[56:32];
    wire single_target=(mask!=0) && ((mask&(mask-25'd1))==0);
    assign preview_keys=playing && !paused && !stepping && head_valid &&
        head_event[31:0]>song_tick && head_event[31:0]-song_tick<=PREVIEW_TICKS ? mask:25'd0;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=FETCH_HEAD;pending<=0;head_valid<=0;head_index<=0;head_event<=0;next_event<=0;
            read_req<=0;read_address<=0;expected_keys<=0;finish<=0;loop_restart<=0;
            target_pulse<=0;unsupported<=0;waiting_for_hit<=0;nonzero_seen<=0;
        end else begin
            read_req<=0;finish<=0;loop_restart<=0;target_pulse<=0;unsupported<=0;
            if(start || stop || !playing || source_changed)begin
                state<=FETCH_HEAD;pending<=0;head_valid<=0;head_index<=0;expected_keys<=0;
                waiting_for_hit<=0;nonzero_seen<=0;
            end else case(state)
                FETCH_HEAD:begin
                    if(source_count==0)begin unsupported<=1;finish<=1;state<=ENDED;end
                    else if(!pending)begin read_req<=1;read_address<=0;pending<=1;end
                    else if(read_valid)begin head_event<=read_event;head_valid<=1;pending<=0;state<=FETCH_NEXT;end
                end
                FETCH_NEXT:begin
                    if(head_index+9'd1>=source_count)begin pending<=0;state<=RUN;end
                    else if(!pending)begin read_req<=1;read_address<=head_index[7:0]+8'd1;pending<=1;end
                    else if(read_valid)begin next_event<=read_event;pending<=0;state<=RUN;end
                end
                RUN:if(!paused && head_valid)begin
                    if(stepping && mask!=0 && !single_target)begin
                        // A single-note lesson cannot quietly reinterpret a chord.
                        expected_keys<=0;unsupported<=1;finish<=1;head_valid<=0;state<=ENDED;
                    end else if(stepping && mask!=0 && !waiting_for_hit)begin
                        expected_keys<=mask;target_pulse<=1;waiting_for_hit<=1;nonzero_seen<=1;
                    end else if((!stepping && head_event[31:0]<=song_tick) ||
                                (stepping && (mask==0 || (waiting_for_hit && target_hit))))begin
                        expected_keys<=stepping?25'd0:mask;waiting_for_hit<=0;
                        if(!stepping && mask!=0)begin target_pulse<=1;nonzero_seen<=1;end
                        if(head_index==source_count-1'b1)begin
                            head_valid<=0;state<=ENDED;
                            // Empty step-mode scores terminate even with looping on.
                            if(loop_enable && (!stepping || nonzero_seen))loop_restart<=1;
                            else finish<=1;
                        end else begin
                            head_index<=head_index+1'b1;head_event<=next_event;state<=FETCH_NEXT;
                        end
                    end
                end
                ENDED:begin end
                default:state<=FETCH_HEAD;
            endcase
        end
    end
endmodule
