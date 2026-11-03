`timescale 1ns/1ps
// Bounded committed score identity -> existing TJC components. No screen reflash.
// Byte 0 of title is in low bits, and title is validated GB2312 upstream.
// Navigation cancels only between complete ordinary ASCII commands.
module tjc_score_meta_tx #(parameter integer NATIVE_SLOTS_ENABLE=0)(
    input wire clk,rst_n,request,input wire [2:0] page_id,
    input wire active_present,input wire [191:0] title,input wire [4:0] title_len,
    input wire [9:0] part,parts,input wire [7:0] bpm,
    input wire playing,paused,context_ready,
    output wire busy,byte_valid,output wire [7:0] byte_data,input wire byte_ready,
    input wire [3:0] resident_valid,input wire [767:0] resident_titles,input wire [19:0] resident_title_lens
);
    localparam IDLE=0,FMT_LOAD=1,FMT_WAIT=2,BOUNDARY=3,SEND=4;
    reg [2:0] state,saved_page,command;
    reg [5:0] position;
    reg [191:0] saved_title;
    reg [4:0] saved_len;
    reg saved_active,saved_ready,saved_playing,saved_paused,saved_named;
    reg [7:0] saved_bpm;
    reg [9:0] saved_part,saved_parts;
    reg [1:0] format_item;
    reg format_load;
    reg [31:0] format_value;
    wire [39:0] formatted;
    wire format_done;
    reg [23:0] bpm_digits,part_digits,parts_digits;
    wire [1:0] slot_index=command-3'd1;
    wire [191:0] selected_slot_title=resident_titles[slot_index*192+:192];
    wire [4:0] selected_slot_len=resident_title_lens[slot_index*5+:5];
    ui_decimal_formatter formatter(clk,rst_n,format_load,format_value,formatted,,format_done);
    function [4:0] fit_length;
        input [191:0] text;input [4:0] count,limit;
        integer j;reg continuation;reg [4:0] n;
        begin
            n=count>limit?limit:count;continuation=0;
            for(j=0;j<24;j=j+1)if(j<n)begin
                if(continuation)continuation=0;
                else if(text[j*8+7])continuation=1;
            end
            fit_length=continuation && n!=0?n-1'b1:n;
        end
    endfunction
    function [7:0] header_byte;
        input [2:0] item;input [5:0] n;input is_songs;
        reg [87:0] suffix;integer size;
        begin
            case(item)
                0:begin suffix=NATIVE_SLOTS_ENABLE?"poll.en=1":"poll.en=0";size=9;end
                1:begin suffix=is_songs?"rslot.txt=\"":"rsong.txt=\"";size=11;end
                2:begin suffix="rlink.txt=\"";size=11;end
                3:begin suffix="rbpm.txt=\"";size=10;end
                4:begin suffix="rplay.txt=\"";size=11;end
                default:begin suffix="rlink.txt=\"";size=11;end
            endcase
            if(NATIVE_SLOTS_ENABLE && is_songs && item>=1 && item<=4)begin
                case(n)
                    0:header_byte="s";1:header_byte="o";2:header_byte="n";3:header_byte="g";
                    4:header_byte="s";5:header_byte=".";6:header_byte="c";7:header_byte="1"+item;
                    8:header_byte=".";9:header_byte="t";10:header_byte="x";11:header_byte="t";
                    12:header_byte="=";default:header_byte=8'h22;
                endcase
            end else
            case(n)
                0:header_byte=is_songs?"s":"g";
                1:header_byte=is_songs?"o":"u";
                2:header_byte=is_songs?"n":"i";
                3:header_byte=is_songs?"g":"d";
                4:header_byte=is_songs?"s":"e";
                5:header_byte=".";
                default:header_byte=suffix>>((size-1-(n-6))*8);
            endcase
        end
    endfunction
    wire native_slot=NATIVE_SLOTS_ENABLE && saved_page==5 && command>=1 && command<=4;
    wire [5:0] header_length=native_slot?6'd14:command==0?6'd15:command==3?6'd16:6'd17;
    wire [5:0] content_length=command==0?6'd0:native_slot?
        (6'd3+(!saved_ready?6'd2:!saved_named?6'd4:{1'b0,saved_len})):
        (NATIVE_SLOTS_ENABLE && saved_page==5 && command==5)?(saved_ready?6'd8:6'd4):
        command==1?(!saved_ready?6'd2:saved_active?(saved_named?{1'b0,saved_len}:6'd10):6'd10):
        command==2?(!saved_ready?6'd4:saved_active?6'd8:6'd3):
        command==3?6'd3:!saved_ready?6'd4:6'd8;
    wire [6:0] body_length={1'b0,header_length}+{1'b0,content_length}+(command!=0);
    wire [5:0] content_position=position-header_length;
    function [7:0] content_byte;
        input [2:0] item;input [5:0] n;
        begin
            content_byte=8'd32;
            if(NATIVE_SLOTS_ENABLE && saved_page==5 && item>=1 && item<=4)begin
                if(n==0)content_byte="0";
                else if(n==1)content_byte="0"+item;
                else if(n==2)content_byte=" ";
                else if(!saved_ready)content_byte="-";
                else if(!saved_named)content_byte=32'hbfd5b2db>>((6-n)*8);
                else content_byte=saved_title>>((n-3)*8);
            end else if(NATIVE_SLOTS_ENABLE && saved_page==5 && item==5)
                content_byte=saved_ready?(64'h5333204341434845>>((7-n)*8)):(32'h57414954>>((3-n)*8));
            else case(item)
                1:if(!saved_ready)content_byte="-";
                  else if(!saved_active)content_byte=80'h524f4d204d454c4f4459>>((9-n)*8);
                  else if(saved_named)content_byte=saved_title>>(n*8);
                  else content_byte=80'h574946492053434f5245>>((9-n)*8);
                2:if(!saved_ready)content_byte=32'h57414954>>((3-n)*8);
                  else if(saved_active)content_byte=64'h574946492052414d>>((7-n)*8);
                  else content_byte=24'h524f4d>>((2-n)*8);
                3:content_byte=saved_ready?(bpm_digits>>((2-n)*8)):"-";
                4:if(!saved_ready)content_byte=32'h57414954>>((3-n)*8);
                  else if(n==0)content_byte=saved_paused?"H":saved_playing?"P":"S";
                  else if(n==4)content_byte="/";
                  else if(n<4)content_byte=(saved_active && !saved_named)?"-":part_digits>>((3-n)*8);
                  else content_byte=(saved_active && !saved_named)?"-":parts_digits>>((7-n)*8);
            endcase
        end
    endfunction
    assign busy=state!=IDLE;
    assign byte_valid=state==SEND;
    assign byte_data=position<header_length?header_byte(command,position,saved_page==5):
        position<header_length+content_length?content_byte(command,content_position):
        command!=0 && position==header_length+content_length?8'h22:8'hff;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=IDLE;saved_page<=0;command<=0;position<=0;saved_title<=0;saved_len<=0;
            saved_active<=0;saved_ready<=0;saved_playing<=0;saved_paused<=0;saved_named<=0;
            saved_bpm<=0;saved_part<=0;saved_parts<=0;format_item<=0;format_load<=0;format_value<=0;
            bpm_digits<=0;part_digits<=0;parts_digits<=0;
        end else begin
            format_load<=0;
            case(state)
                IDLE:if(request && (page_id==2 || page_id==5))begin
                    saved_page<=page_id;saved_title<=title;
                    saved_len<=fit_length(title,title_len>24?5'd24:title_len,page_id==5?5'd20:5'd24);
                    saved_active<=active_present;saved_ready<=context_ready;
                    saved_named<=title_len!=0;saved_playing<=playing;saved_paused<=paused;
                    saved_bpm<=bpm;saved_part<=active_present?part:10'd1;
                    saved_parts<=active_present?parts:10'd1;
                    format_item<=0;command<=0;position<=0;state<=FMT_LOAD;
                end
                FMT_LOAD:begin
                    format_value<=format_item==0?{24'd0,saved_bpm}:format_item==1?{22'd0,saved_part}:{22'd0,saved_parts};
                    format_load<=1;state<=FMT_WAIT;
                end
                FMT_WAIT:if(format_done)begin
                    case(format_item)0:bpm_digits<=formatted[23:0];1:part_digits<=formatted[23:0];2:parts_digits<=formatted[23:0];endcase
                    if(format_item==2)state<=BOUNDARY;
                    else begin format_item<=format_item+1'b1;state<=FMT_LOAD;end
                end
                BOUNDARY:if(page_id!=saved_page)state<=IDLE;
                         else begin
                            if(NATIVE_SLOTS_ENABLE && saved_page==5 && command>=1 && command<=4)begin
                                saved_title<=selected_slot_title;
                                saved_named<=resident_valid[slot_index];
                                saved_len<=fit_length(selected_slot_title,selected_slot_len>24?5'd24:selected_slot_len,5'd20);
                            end
                            position<=0;state<=SEND;
                         end
                SEND:if(byte_ready)begin
                    if({1'b0,position}==body_length+2)begin
                        if(command==(saved_page==5?(NATIVE_SLOTS_ENABLE?3'd5:3'd2):3'd4))state<=IDLE;
                        else begin command<=command+1'b1;state<=BOUNDARY;end
                    end else position<=position+1'b1;
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
