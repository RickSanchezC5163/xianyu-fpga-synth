`timescale 1ns/1ps
// Coherent register snapshot -> ordinary TJC ASCII assignments + FF FF FF.
// All home.v0..v8 and home.g0..g3 must be global numeric HMI variables.
// home.v8 commits the global fields. Optional env text mirrors follow it.
module tjc_snapshot_tx #(parameter integer ENV_READOUT_ENABLE=0,NATIVE_SLOTS_ENABLE=0)(
    input wire clk,rst_n,request,
    input wire [1:0] patch,input wire [7:0] volume,input wire [27:0] adsr,
    input wire link_ready,input wire [2:0] result,
    input wire guide_playing,guide_paused,guide_loop,input wire [7:0] guide_bpm,
    output wire busy,output wire byte_valid,output wire [7:0] byte_data,input wire byte_ready,
    input wire [2:0] page_id,
    input wire [3:0] resident_valid,input wire [2:0] active_slot,input wire [1:0] guide_beat_index
);
    reg [2:0] state;
    reg env_mirror;
    reg [255:0] snapshot;
    reg [15:0] revision;
    reg [3:0] field;
    reg [4:0] position;
    reg format_load;
    reg [31:0] format_value;
    wire [39:0] formatted;
    wire format_done;
    reg [39:0] digits;
    reg [2:0] skip,digit_count;
    wire [15:0] selected_value=snapshot[field*16+:16];
    ui_decimal_formatter formatter(clk,rst_n,format_load,format_value,formatted,,format_done);
    function [7:0] prefix;
        input [4:0] index;input [3:0] item;
        begin
            case(index)
                0:prefix="h";1:prefix="o";2:prefix="m";3:prefix="e";4:prefix=".";
                5:prefix=(item>=8 && item<=(NATIVE_SLOTS_ENABLE?14:11))?"g":"v";
                6:prefix=8'd48+((item>=8 && item<=(NATIVE_SLOTS_ENABLE?14:11))?item-8:
                    ((item==(NATIVE_SLOTS_ENABLE?15:12))?8:item));
                7:prefix=".";8:prefix="v";9:prefix="a";10:prefix="l";default:prefix="=";
            endcase
        end
    endfunction
    wire [4:0] digit_position=position-12+skip;
    function [7:0] env_letter;input [3:0] item;begin
        case(item) 2:env_letter="a";3:env_letter="d";4:env_letter="s";default:env_letter="r";endcase
    end endfunction
    function [7:0] env_prefix;input [4:0] index;input [3:0] item;begin
        case(index) 0:env_prefix="r";1:env_prefix=env_letter(item);2:env_prefix=".";
        3:env_prefix="t";4:env_prefix="x";5:env_prefix="t";6:env_prefix="=";default:env_prefix=8'h22;endcase
    end endfunction
    function [7:0] ref_prefix;input [4:0] index;input [3:0] item;begin
        case(index) 0:ref_prefix="r";1:ref_prefix="e";2:ref_prefix="f";3:ref_prefix=" ";
        4:ref_prefix="r";5:ref_prefix=env_letter(item);default:ref_prefix=8'hff;endcase
    end endfunction
    wire [4:0] env_digit_position=position-8+skip;
    assign byte_data=state==5 ? (position<8 ? env_prefix(position,field) :
        (position<8+digit_count ? (digits>>((4-env_digit_position)*8)) :
         position==8+digit_count ? 8'h22 : 8'hff)) :
        state==7 ? ref_prefix(position,field) :
        position<12?prefix(position,field):
        (position<12+digit_count ? (digits>>((4-digit_position)*8)) : 8'hff);
    assign byte_valid=state==3 || state==5 || state==7;
    assign busy=state!=0;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=0;env_mirror<=0;snapshot<=0;revision<=0;field<=0;position<=0;
            format_load<=0;format_value<=0;digits<=0;skip<=0;digit_count<=1;
        end else begin
            format_load<=0;
            case(state)
                0: if(request) begin
                    if(NATIVE_SLOTS_ENABLE)
                    snapshot<={revision+16'd1,{14'd0,guide_beat_index},{13'd0,active_slot},{12'd0,resident_valid},
                        {8'd0,guide_bpm},{15'd0,guide_loop},{15'd0,guide_paused},
                        {15'd0,guide_playing},{13'd0,result},{15'd0,link_ready},
                        {9'd0,adsr[27:21]},{9'd0,adsr[20:14]},{9'd0,adsr[13:7]},{9'd0,adsr[6:0]},
                        {8'd0,volume},{14'd0,patch}};
                    else snapshot<={revision+16'd1,{8'd0,guide_bpm},{15'd0,guide_loop},{15'd0,guide_paused},
                        {15'd0,guide_playing},{13'd0,result},{15'd0,link_ready},
                        {9'd0,adsr[27:21]},{9'd0,adsr[20:14]},{9'd0,adsr[13:7]},{9'd0,adsr[6:0]},
                        {8'd0,volume},{14'd0,patch}};
                    revision<=revision+1'b1;field<=0;state<=1;env_mirror<=0;
                end
                1: begin format_value<={16'd0,selected_value};format_load<=1;state<=2;end
                2: if(format_done) begin
                    if(env_mirror && page_id!=1) state<=0;
                    else begin
                    digits<=formatted;
                    if(selected_value>=10000) begin skip<=0;digit_count<=5;end
                    else if(selected_value>=1000) begin skip<=1;digit_count<=4;end
                    else if(selected_value>=100) begin skip<=2;digit_count<=3;end
                    else if(selected_value>=10) begin skip<=3;digit_count<=2;end
                    else begin skip<=4;digit_count<=1;end
                    position<=0;state<=env_mirror ? 5 : 3;
                    end
                end
                3: if(byte_ready) begin
                    if(position==14+digit_count) begin
                        if(field==(NATIVE_SLOTS_ENABLE?15:12)) begin
                            if(ENV_READOUT_ENABLE && page_id==1 && snapshot[96]) begin
                                env_mirror<=1;field<=2;state<=4;
                            end else state<=0;
                        end
                        else begin field<=field+1'b1;state<=1;end
                    end else position<=position+1'b1;
                end
                // Page checks happen before a command, never midway through it.
                4:if(page_id!=1) state<=0;else state<=1;
                5:if(byte_ready) begin
                    if(position==11+digit_count) state<=6;
                    else position<=position+1'b1;
                end
                6:if(page_id!=1) state<=0;else begin position<=0;state<=7;end
                7:if(byte_ready) begin
                    if(position==8) begin
                        if(field==5)state<=0;else begin field<=field+1'b1;state<=4;end
                    end else position<=position+1'b1;
                end
            endcase
        end
    end
endmodule
