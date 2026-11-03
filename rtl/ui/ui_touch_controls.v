`timescale 1ns/1ps
// Semantic events only. Does not drive the existing audio registers directly.
module ui_touch_controls #(parameter [7:0] DEFAULT_VOLUME=255,parameter integer PIPELINED_SCALE=0)(
    input wire clk,rst_n,touch_valid,touch_down,page_ready,
    input wire [8:0] x,y,
    output reg start,pause_toggle,stop,loop_toggle,
    output reg param_valid,output reg [3:0] param_id,output reg [15:0] param_value,
    output reg [1:0] patch,output reg [7:0] volume,
    output reg [6:0] attack,decay,sustain,release_value,
    output reg [1:0] page
);
    reg was_down;
    reg [2:0] drag_kind;
    wire [7:0] x8;
    wire [6:0] x7;
    wire event_valid,event_down;
    wire [8:0] event_x,event_y;
    wire [1:0] patch_column=event_x<80?2'd0:event_x<160?2'd1:event_x<240?2'd2:2'd3;
    generate if(PIPELINED_SCALE) begin: registered_scale
        // Mathematical coordinate table, not audio samples. One synchronous
        // lookup keeps the exact scale and removes the last touch->DSP path.
        reg [14:0] scale_rom[0:511];
        reg [14:0] scale_word;
        reg valid_r,down_r;reg [8:0] x_r,y_r;
        initial $readmemh("ui_touch_scale.hex",scale_rom);
        always @(posedge clk) if(touch_valid) scale_word<=scale_rom[x];
        always @(posedge clk or negedge rst_n)
            if(!rst_n) begin valid_r<=0;down_r<=0;x_r<=0;y_r<=0;end
            else begin
                valid_r<=touch_valid;
                if(touch_valid) begin down_r<=touch_down;x_r<=x;y_r<=y;end
            end
        assign event_valid=valid_r;assign event_down=down_r;
        assign event_x=x_r;assign event_y=y_r;
        assign x8=scale_word[14:7];assign x7=scale_word[6:0];
    end else begin: direct_scale
        assign event_valid=touch_valid;assign event_down=touch_down;
        assign event_x=x;assign event_y=y;
        assign x8=(x>=319)?8'd255:(x*255)/319;
        assign x7=(x>=319)?7'd127:(x*127)/319;
    end endgenerate
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            was_down<=0;drag_kind<=0;start<=0;pause_toggle<=0;stop<=0;loop_toggle<=0;
            param_valid<=0;param_id<=0;param_value<=0;patch<=0;volume<=DEFAULT_VOLUME;
            attack<=8;decay<=40;sustain<=96;release_value<=40;page<=0;
        end else begin
            start<=0;pause_toggle<=0;stop<=0;loop_toggle<=0;param_valid<=0;
            if(event_valid) begin
                was_down<=event_down;
                if(!event_down) drag_kind<=0;
                else if(event_x<320 && event_y<240) begin
                    if(!was_down) begin
                        drag_kind<=0;
                        if(event_y<40) begin
                            patch<=patch_column;param_valid<=1;param_id<=0;param_value<={14'd0,patch_column};
                        end else if(event_y<80) begin
                            if(event_x<80) start<=1;
                            else if(event_x<160) pause_toggle<=1;
                            else if(event_x<240) stop<=1;
                            else loop_toggle<=1;
                        end else if(event_y<112) begin
                            drag_kind<=1;volume<=x8;param_valid<=1;param_id<=1;param_value<={8'd0,x8};
                        end else if(event_y<140) page<=(page==2)?0:page+1'b1;
                        else if(page==1 && page_ready) begin
                            param_valid<=1;param_value<={9'd0,x7};
                            if(event_y<165) begin drag_kind<=2;attack<=x7;param_id<=2;end
                            else if(event_y<190) begin drag_kind<=3;decay<=x7;param_id<=3;end
                            else if(event_y<215) begin drag_kind<=4;sustain<=x7;param_id<=4;end
                            else begin drag_kind<=5;release_value<=x7;param_id<=5;end
                        end
                    end else if(drag_kind!=0 && (drag_kind==1 || page_ready)) begin
                        param_valid<=1;
                        if(drag_kind==1) begin volume<=x8;param_id<=1;param_value<={8'd0,x8};end
                        else begin
                            param_id<=drag_kind;param_value<={9'd0,x7};
                            case(drag_kind)
                                2:attack<=x7;3:decay<=x7;4:sustain<=x7;5:release_value<=x7;
                            endcase
                        end
                    end
                end
            end
        end
    end
endmodule
