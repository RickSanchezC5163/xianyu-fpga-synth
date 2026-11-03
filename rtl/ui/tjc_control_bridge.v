`timescale 1ns/1ps
// Parameter-only boundary. This module has no note, gate or audio clock output.
// Results: 0 idle,1 accepted,2 rejected,3 busy,4 backend ACK timeout.
module tjc_control_bridge #(parameter integer ACK_TIMEOUT_CYCLES=50000)(
    input wire clk,rst_n,event_valid,input wire [7:0] event_kind,event_id,
    input wire [31:0] event_value,
    input wire context_ready,urgent_stop,input wire [7:0] score_count,
    output reg param_valid,output reg [3:0] param_id,output reg [15:0] param_value,
    input wire param_ack,param_rejected,
    output reg guide_valid,output reg [2:0] guide_id,output reg [15:0] guide_value,
    output reg snapshot_request,output reg [2:0] page_id,last_result,
    output reg [31:0] rejected_count,
    output reg pending
);
    localparam integer AW=ACK_TIMEOUT_CYCLES<2?1:$clog2(ACK_TIMEOUT_CYCLES);
    reg [AW-1:0] age;
    wire param_range=(event_id==0 && event_value<=3) ||
        (event_id==1 && event_value<=255) || (event_id>=2 && event_id<=5 && event_value<=127);
    wire guide_range=(event_id<=3 && event_value==0) ||
        (event_id==4 && event_value<=1) ||
        (event_id==5 && event_value>=30 && event_value<=240) ||
        (event_id==6 && event_value<score_count) ||
        (event_id==7 && event_value<=1);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            param_valid<=0;param_id<=0;param_value<=0;guide_valid<=0;guide_id<=0;guide_value<=0;
            snapshot_request<=0;page_id<=0;last_result<=0;rejected_count<=0;pending<=0;age<=0;
        end else begin
            param_valid<=0;guide_valid<=0;snapshot_request<=0;
            if(pending) begin
                if(param_ack || param_rejected) begin
                    pending<=0;last_result<=param_rejected?3'd2:3'd1;snapshot_request<=1;
                end else if(age==ACK_TIMEOUT_CYCLES-1) begin
                    pending<=0;last_result<=4;snapshot_request<=1;
                    rejected_count<=rejected_count+1'b1;
                end else age<=age+1'b1;
            end
            if(urgent_stop) begin
                pending<=0;age<=0;
                if(event_valid) begin
                    last_result<=2;rejected_count<=rejected_count+1'b1;snapshot_request<=1;
                end
            end else if(event_valid) begin
                if(event_kind==3 && event_id<=5 && event_value==0) begin
                    page_id<=event_id[2:0];snapshot_request<=1;
                end else if(event_kind==4 && event_id==0 && event_value==0) begin
                    snapshot_request<=1;
                end else if(!context_ready) begin
                    last_result<=2;rejected_count<=rejected_count+1'b1;snapshot_request<=1;
                end else if(event_kind==1 && param_range) begin
                    if(pending) begin
                        last_result<=3;rejected_count<=rejected_count+1'b1;snapshot_request<=1;
                    end else begin
                        param_valid<=1;param_id<=event_id[3:0];param_value<=event_value[15:0];
                        pending<=1;age<=0;last_result<=0;
                    end
                end else if(event_kind==2 && guide_range) begin
                    guide_valid<=1;guide_id<=event_id[2:0];guide_value<=event_value[15:0];
                    // Guide validation/commit must be supplied by its consumer;
                    // a decoded guide command is not a backend success ACK.
                    snapshot_request<=1;
                end else begin
                    last_result<=2;rejected_count<=rejected_count+1'b1;snapshot_request<=1;
                end
            end
        end
    end
    // synthesis translate_off
    initial if(ACK_TIMEOUT_CYCLES<4) $fatal(1,"tjc_control_bridge invalid ACK timeout");
    // synthesis translate_on
endmodule
