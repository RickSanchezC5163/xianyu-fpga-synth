`timescale 1ns/1ps
// Parameter preview, NOT a measured voice envelope. The reference is the
// ordinary linear ADSR path: A=64+16*a, D=8+4*d, S=10000+400*s, R=4+4*r.
// Bell/pluck/piano partial decays differ from that reference. Sustain hold is
// illustrative, while A/D/R widths use relative reference durations with an
// 8-pixel minimum so every stage stays visible. No absolute time axis is drawn.
// One shared 22-bit iterative divider + one shared decimal formatter; no '/' or
// dynamic combinational divider. Ordinary FF-terminated drawing commands only.
// Preserve the Figma title, card borders and native controls. Clear only the
// inner graph rectangle with picture1, then draw a 2-pixel mint polyline.
module tjc_env_plot_tx(
    input wire clk,rst_n,request,
    input wire [2:0] page_id,
    input wire [27:0] register_adsr,
    output wire busy,byte_valid,
    output wire [7:0] byte_data,
    input wire byte_ready
);
    localparam [3:0] IDLE=0,MAP=1,DIV_START=2,DIV_STEP=3,DIV_RESULT=4,
                     TOTAL=5,COORDS=6,COMMAND=7,FMT_START=8,FMT_WAIT=9,SEND=10;
    reg [3:0] state,command_index;
    reg [27:0] controls;
    reg [11:0] attack_step;
    reg [9:0] decay_step,release_step;
    reg [15:0] sustain_level,attack_time,decay_time,release_time;
    reg [16:0] total_time;
    reg [6:0] attack_width,decay_width;
    reg [7:0] attack_x,decay_x,hold_x,sustain_y;
    reg [2:0] division_kind;
    reg [21:0] dividend,denominator,quotient;
    reg [22:0] remainder;
    reg [4:0] divide_left;
    wire [22:0] trial={remainder[21:0],dividend[21]};
    wire subtract=trial>={1'b0,denominator};
    wire [21:0] quotient_next={quotient[20:0],subtract};
    wire [22:0] sustain_height=({7'd0,sustain_level}<<6)+
        ({7'd0,sustain_level}<<5)+({7'd0,sustain_level}<<3)+({7'd0,sustain_level}<<2);

    reg [7:0] x0,y0,x1,y1;
    reg [1:0] coordinate;
    reg format_load;
    reg [31:0] format_value;
    wire [39:0] formatted;
    wire format_done;
    reg [23:0] digits_x0,digits_y0,digits_x1,digits_y1;
    reg [4:0] position;
    wire [3:0] segment_index=command_index-1'b1;
    wire stroke=segment_index[0];
    ui_decimal_formatter formatter(clk,rst_n,format_load,format_value,formatted,,format_done);

    function [7:0] clear_byte;input [4:0] n;begin
        case(n)
            0:clear_byte="p";1:clear_byte="i";2:clear_byte="c";3:clear_byte="q";
            4:clear_byte=" ";5:clear_byte="1";6:clear_byte="2";7:clear_byte=",";
            8:clear_byte="6";9:clear_byte="4";10:clear_byte=",";11:clear_byte="1";
            12:clear_byte="2";13:clear_byte="3";14:clear_byte=",";15:clear_byte="1";
            16:clear_byte="2";17:clear_byte="4";18:clear_byte=",";19:clear_byte="1";
            default:clear_byte=8'hff;
        endcase
    end endfunction
    reg [7:0] line_byte;
    always @* begin
        case(position)
            0:line_byte="l";1:line_byte="i";2:line_byte="n";3:line_byte="e";4:line_byte=" ";
            5:line_byte=digits_x0[23:16];6:line_byte=digits_x0[15:8];7:line_byte=digits_x0[7:0];
            8:line_byte=",";
            9:line_byte=digits_y0[23:16];10:line_byte=digits_y0[15:8];11:line_byte=digits_y0[7:0];
            12:line_byte=",";
            13:line_byte=digits_x1[23:16];14:line_byte=digits_x1[15:8];15:line_byte=digits_x1[7:0];
            16:line_byte=",";
            17:line_byte=digits_y1[23:16];18:line_byte=digits_y1[15:8];19:line_byte=digits_y1[7:0];
            20:line_byte=",";21:line_byte="2";22:line_byte="6";23:line_byte="2";
            24:line_byte="9";25:line_byte="1";
            default:line_byte=8'hff;
        endcase
    end
    assign busy=state!=IDLE;
    assign byte_valid=state==SEND;
    assign byte_data=command_index==0?clear_byte(position):line_byte;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;command_index<=0;controls<=0;
            attack_step<=0;decay_step<=0;release_step<=0;sustain_level<=0;
            attack_time<=0;decay_time<=0;release_time<=0;total_time<=0;
            attack_width<=0;decay_width<=0;attack_x<=0;decay_x<=0;hold_x<=0;sustain_y<=0;
            division_kind<=0;dividend<=0;denominator<=0;quotient<=0;remainder<=0;divide_left<=0;
            x0<=0;y0<=0;x1<=0;y1<=0;coordinate<=0;format_load<=0;format_value<=0;
            digits_x0<=0;digits_y0<=0;digits_x1<=0;digits_y1<=0;position<=0;
        end else begin
            format_load<=0;
            // Once byte_valid is asserted, finish that command even if the
            // page changes under backpressure. All other stages may cancel.
            if(state!=IDLE && state!=SEND && page_id!=1)state<=IDLE;
            else case(state)
                IDLE:if(request && page_id==1)begin controls<=register_adsr;state<=MAP;end
                MAP:begin
                    attack_step<=12'd64+{1'b0,controls[6:0],4'b0};
                    decay_step<=10'd8+{1'b0,controls[13:7],2'b0};
                    sustain_level<=16'd10000+({9'd0,controls[20:14]}<<8)+
                        ({9'd0,controls[20:14]}<<7)+({9'd0,controls[20:14]}<<4);
                    release_step<=10'd4+{1'b0,controls[27:21],2'b0};
                    division_kind<=0;state<=DIV_START;
                end
                DIV_START:begin
                    case(division_kind)
                        0:begin dividend<=22'd65535+attack_step-1'b1;denominator<=attack_step;end
                        1:begin dividend<=22'd65535-sustain_level+decay_step-1'b1;denominator<=decay_step;end
                        2:begin dividend<={6'd0,sustain_level}+release_step-1'b1;denominator<=release_step;end
                        3:begin dividend<=({6'd0,attack_time}<<6)+({6'd0,attack_time}<<1)+attack_time;denominator<=total_time;end
                        default:begin dividend<=({6'd0,decay_time}<<6)+({6'd0,decay_time}<<1)+decay_time;denominator<=total_time;end
                    endcase
                    quotient<=0;remainder<=0;divide_left<=22;state<=DIV_STEP;
                end
                DIV_STEP:begin
                    dividend<={dividend[20:0],1'b0};quotient<=quotient_next;
                    remainder<=subtract?trial-{1'b0,denominator}:trial;
                    if(divide_left==1)state<=DIV_RESULT;else divide_left<=divide_left-1'b1;
                end
                DIV_RESULT:begin
                    case(division_kind)
                        0:attack_time<=quotient[15:0];
                        1:decay_time<=quotient[15:0];
                        2:release_time<=quotient[15:0];
                        3:attack_width<=7'd8+quotient[6:0];
                        default:decay_width<=7'd8+quotient[6:0];
                    endcase
                    if(division_kind==2)state<=TOTAL;
                    else if(division_kind==4)state<=COORDS;
                    else begin division_kind<=division_kind+1'b1;state<=DIV_START;end
                end
                TOTAL:begin total_time<={1'b0,attack_time}+{1'b0,decay_time}+{1'b0,release_time};division_kind<=3;state<=DIV_START;end
                COORDS:begin
                    attack_x<=8'd17+attack_width;
                    decay_x<=8'd17+attack_width+decay_width;
                    hold_x<=8'd37+attack_width+decay_width;
                    sustain_y<=8'd180-sustain_height[22:16];
                    command_index<=0;position<=0;state<=COMMAND;
                end
                COMMAND:begin
                    position<=0;coordinate<=0;
                    if(command_index==0)state<=SEND;
                    else begin
                        case(segment_index[2:1])
                            0:begin x0<=17;y0<=180+stroke;x1<=attack_x;y1<=72+stroke;end
                            1:begin x0<=attack_x;y0<=72+stroke;x1<=decay_x;y1<=sustain_y+stroke;end
                            2:begin x0<=decay_x;y0<=sustain_y+stroke;x1<=hold_x;y1<=sustain_y+stroke;end
                            3:begin x0<=hold_x;y0<=sustain_y+stroke;x1<=128;y1<=180+stroke;end
                        endcase
                        state<=FMT_START;
                    end
                end
                FMT_START:begin
                    case(coordinate)0:format_value<=x0;1:format_value<=y0;2:format_value<=x1;3:format_value<=y1;endcase
                    format_load<=1;state<=FMT_WAIT;
                end
                FMT_WAIT:if(format_done)begin
                    case(coordinate)0:digits_x0<=formatted[23:0];1:digits_y0<=formatted[23:0];2:digits_x1<=formatted[23:0];3:digits_y1<=formatted[23:0];endcase
                    if(coordinate==3)state<=SEND;
                    else begin coordinate<=coordinate+1'b1;state<=FMT_START;end
                end
                SEND:if(byte_ready)begin
                    if(position==(command_index==0?22:28))begin
                        if(command_index==8 || page_id!=1)state<=IDLE;
                        else begin command_index<=command_index+1'b1;state<=COMMAND;end
                    end else position<=position+1'b1;
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
