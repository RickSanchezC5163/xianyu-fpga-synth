`timescale 1ns/1ps
// Procedural RGB565 dashboard. No full-frame FPGA RAM. Conservative single-
// pixel transactions: this is a low-refresh bring-up UI, not a video engine.
module ui_dashboard_reference #(parameter integer CLK_HZ=50000000)(input wire clk,rst_n,panel_ready,pixel_ready,
    input wire [1:0] patch,input wire [7:0] volume,
    input wire [6:0] attack,decay,sustain,release_value,
    input wire [1:0] page,input wire playing,paused,looping,beat_lit,
    input wire latency_seen,latency_le_5ms,latency_le_10ms,
    input wire [31:0] latency_cycles,overrun_incidents,
    input wire signed [7:0] wave_sample,
    output wire [6:0] wave_index,output reg frame_start,output wire page_ready,
    output wire pixel_valid,output reg [8:0] pixel_x,pixel_y,
    output reg [15:0] pixel_rgb565);
    assign pixel_valid=panel_ready;
    assign wave_index=(pixel_x>=32 && pixel_x<288)?(pixel_x-32)>>1:7'd0;
    reg [1:0] patch_l;
    reg [7:0] volume_l;
    reg [6:0] attack_l,decay_l,sustain_l,release_l;
    reg [1:0] page_l;
    reg [1:0] displayed_page;
    reg display_page_valid;
    assign page_ready=display_page_valid && displayed_page==page && page_l==page;
    reg playing_l,paused_l,looping_l,beat_l;
    reg latency_seen_l,le5_l,le10_l;
    reg [31:0] latency_us_l,overruns_l;
    localparam integer CYCLES_PER_US=(CLK_HZ>=1000000)?CLK_HZ/1000000:1;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            pixel_x<=0;pixel_y<=0;frame_start<=0;
            patch_l<=0;volume_l<=0;attack_l<=0;decay_l<=0;sustain_l<=0;release_l<=0;
            page_l<=0;playing_l<=0;paused_l<=0;looping_l<=0;beat_l<=0;
            latency_seen_l<=0;le5_l<=0;le10_l<=0;latency_us_l<=0;overruns_l<=0;
            displayed_page<=0;display_page_valid<=0;
        end else begin
            frame_start<=0;
            if(pixel_valid && pixel_ready) begin
                if(pixel_x==319) begin
                    pixel_x<=0;
                    if(pixel_y==239) begin
                        pixel_y<=0;frame_start<=1;displayed_page<=page_l;display_page_valid<=1;
                    end
                    else pixel_y<=pixel_y+1'b1;
                end else pixel_x<=pixel_x+1'b1;
            end
            if(!panel_ready || frame_start) begin
                patch_l<=patch;volume_l<=volume;attack_l<=attack;decay_l<=decay;
                sustain_l<=sustain;release_l<=release_value;page_l<=page;
                playing_l<=playing;paused_l<=paused;looping_l<=looping;beat_l<=beat_lit;
                latency_seen_l<=latency_seen;le5_l<=latency_le_5ms;le10_l<=latency_le_10ms;
                latency_us_l<=latency_cycles/CYCLES_PER_US;overruns_l<=overrun_incidents;
            end
            if(!panel_ready) display_page_valid<=0;
        end
    end
    // synthesis translate_off
    initial if(CLK_HZ<1000000 || CLK_HZ%1000000!=0)
        $fatal(1,"dashboard diagnostics require an integer MHz clock");
    // synthesis translate_on
    function [34:0] glyph;
        input [7:0] c;
        begin
            case(c)
                "A":glyph={5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "B":glyph={5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
                "C":glyph={5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111};
                "D":glyph={5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
                "E":glyph={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
                "G":glyph={5'b01110,5'b10001,5'b10000,5'b10111,5'b10001,5'b10001,5'b01110};
                "I":glyph={5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b11111};
                "K":glyph={5'b10001,5'b10010,5'b10100,5'b11000,5'b10100,5'b10010,5'b10001};
                "L":glyph={5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
                "M":glyph={5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
                "N":glyph={5'b10001,5'b11001,5'b11001,5'b10101,5'b10011,5'b10011,5'b10001};
                "O":glyph={5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "P":glyph={5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
                "R":glyph={5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
                "S":glyph={5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
                "T":glyph={5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
                "U":glyph={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "V":glyph={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100};
                "W":glyph={5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010};
                "X":glyph={5'b10001,5'b10001,5'b01010,5'b00100,5'b01010,5'b10001,5'b10001};
                "Y":glyph={5'b10001,5'b10001,5'b01010,5'b00100,5'b00100,5'b00100,5'b00100};
                "0":glyph={5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
                "1":glyph={5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                "2":glyph={5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
                "3":glyph={5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
                "4":glyph={5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
                "5":glyph={5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
                "6":glyph={5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
                "7":glyph={5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
                "8":glyph={5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
                "9":glyph={5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
                default:glyph=0;
            endcase
        end
    endfunction
    function [39:0] decimal5;
        input [31:0] value;
        integer n;
        reg [31:0] v;
        begin
            v=(value>99999)?99999:value;decimal5=0;
            for(n=0;n<5;n=n+1) begin decimal5[n*8+:8]=8'd48+v%10;v=v/10;end
        end
    endfunction
    integer cell_index,lx,ly,char_index,font_bit,target_y,bar_value,row;
    reg [63:0] text_word;
    reg [7:0] character;
    reg [34:0] font;
    always @* begin
        pixel_rgb565=16'h0841;text_word=0;lx=0;ly=0;cell_index=0;row=0;bar_value=0;
        char_index=0;font_bit=0;character=0;font=0;target_y=190-($signed(wave_sample)>>>2);
        if(pixel_y<40) begin
            cell_index=pixel_x/80;
            pixel_rgb565=(cell_index==patch_l)?16'h0460:16'h1086;
            lx=pixel_x%80-16;ly=pixel_y-12;
            case(cell_index)
                0:text_word="ORGN    ";1:text_word="BELL    ";
                2:text_word="PLUK    ";3:text_word="PIAN    ";
            endcase
        end else if(pixel_y<80) begin
            cell_index=pixel_x/80;lx=pixel_x%80-16;ly=pixel_y-52;
            case(cell_index)
                0:begin text_word="PLAY    ";pixel_rgb565=playing_l?16'h0460:16'h1086;end
                1:begin text_word="PAUS    ";pixel_rgb565=paused_l?16'hD520:16'h1086;end
                2:begin text_word="STOP    ";pixel_rgb565=16'h7800;end
                3:begin text_word="LOOP    ";pixel_rgb565=looping_l?16'h041F:16'h1086;end
            endcase
        end else if(pixel_y<112) begin
            pixel_rgb565=(pixel_x*255/319<=volume_l)?16'h0250:16'h1082;
            text_word="VOLUME  ";lx=pixel_x-8;ly=pixel_y-88;
        end else if(pixel_y<140) begin
            text_word=(page_l==0)?"ADSR    ":((page_l==1)?"METRIC  ":"WAVE    ");lx=pixel_x-8;ly=pixel_y-118;
            pixel_rgb565=16'h2104;
        end else if(page_l==1) begin
            row=(pixel_y-140)/25;lx=pixel_x-8;ly=(pixel_y-140)%25-5;
            case(row)
                0:begin text_word="A       ";bar_value=attack_l;end
                1:begin text_word="D       ";bar_value=decay_l;end
                2:begin text_word="S       ";bar_value=sustain_l;end
                3:begin text_word="R       ";bar_value=release_l;end
            endcase
            pixel_rgb565=(pixel_x*127/319<=bar_value)?16'h0328:16'h1082;
        end else if(page_l==2) begin
            row=(pixel_y-140)/25;lx=pixel_x-8;ly=(pixel_y-140)%25-5;
            case(row)
                0:begin text_word="5MS PCM ";pixel_rgb565=!latency_seen_l?16'h3186:(le5_l?16'h0460:16'h7800);end
                1:begin text_word="10MS PCM";pixel_rgb565=!latency_seen_l?16'h3186:(le10_l?16'h0460:16'h7800);end
                2:begin text_word=latency_seen_l?{"US ",decimal5(latency_us_l)}:"NO DATA ";end
                3:begin text_word={"XR ",decimal5(overruns_l)};end
            endcase
        end else begin
            if(pixel_y==190) pixel_rgb565=16'h3186;
            if(pixel_x>=32 && pixel_x<288 && (pixel_y==target_y || pixel_y==target_y+1))
                pixel_rgb565=16'h07FF;
        end
        // Beat feedback is immediate in LEDs; LCD state is frame-snapshotted.
        if(pixel_y<8) pixel_rgb565=beat_l?16'hFFE0:16'h0841;
        if(lx>=0 && lx<96 && ly>=0 && ly<14) begin
            char_index=lx/12;character=text_word[(7-char_index)*8+:8];
            font=glyph(character);font_bit=(6-ly/2)*5+(4-(lx%12)/2);
            if(lx%12<10 && font_bit>=0 && font_bit<35 && font[font_bit]) pixel_rgb565=16'hFFFF;
        end
    end
endmodule
