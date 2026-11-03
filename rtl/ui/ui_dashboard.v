`timescale 1ns/1ps
// Procedural RGB565 dashboard. No full-frame FPGA RAM. Conservative single-
// pixel transactions: this is a low-refresh bring-up UI, not a video engine.
module ui_dashboard #(parameter integer CLK_HZ=50000000,parameter integer PIPELINED=0)(input wire clk,rst_n,panel_ready,pixel_ready,
    input wire [1:0] patch,input wire [7:0] volume,
    input wire [6:0] attack,decay,sustain,release_value,
    input wire [1:0] page,input wire playing,paused,looping,beat_lit,
    input wire latency_seen,latency_le_5ms,latency_le_10ms,
    input wire [31:0] latency_cycles,overrun_incidents,
    input wire signed [7:0] wave_sample,
    output wire [6:0] wave_index,output reg frame_start,output wire page_ready,
    output wire pixel_valid,output reg [8:0] pixel_x,pixel_y,
    output wire [15:0] pixel_rgb565);
    reg [2:0] render_state;
    assign pixel_valid=panel_ready && (!PIPELINED || render_state==4);
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
                if(!PIPELINED) latency_us_l<=latency_cycles/CYCLES_PER_US;
                overruns_l<=overrun_incidents;
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
    wire [39:0] us_text,xr_text;
    generate if(PIPELINED) begin: sequential_format
        ui_decimal_formatter #(.DIVISOR(CYCLES_PER_US)) us_format(
            .clk(clk),.rst_n(rst_n),.load(!panel_ready||frame_start),.value(latency_cycles),
            .text(us_text),.divided_value(),.done());
        ui_decimal_formatter xr_format(
            .clk(clk),.rst_n(rst_n),.load(!panel_ready||frame_start),.value(overrun_incidents),
            .text(xr_text),.divided_value(),.done());
    end else begin: legacy_format
        assign us_text=decimal5(latency_us_l);
        assign xr_text=decimal5(overruns_l);
    end endgenerate
    // All coordinate arithmetic is bounded; avoid signed32-bit / and % for
    // fixed80-pixel columns and25-pixel rows. The raster remains identical.
    reg [1:0] cell_index,row;
    reg [8:0] cell_x,row_y;
    reg signed [10:0] lx,ly,target_y;
    reg [6:0] bar_value;
    reg [15:0] base_color;
    reg [63:0] text_word;
    wire [16:0] volume_column=({8'd0,pixel_x}<<8)-{8'd0,pixel_x};
    wire [15:0] adsr_column=({7'd0,pixel_x}<<7)-{7'd0,pixel_x};
    wire [17:0] volume_next={10'd0,volume_l}+18'd1;
    wire [16:0] adsr_next={10'd0,bar_value}+17'd1;
    wire [17:0] volume_limit=(volume_next<<8)+(volume_next<<6)-volume_next;
    wire [16:0] adsr_limit=(adsr_next<<8)+(adsr_next<<6)-adsr_next;
    always @* begin
        base_color=16'h0841;text_word=0;lx=0;ly=0;bar_value=0;
        target_y=11'sd190-($signed(wave_sample)>>>2);
        if(pixel_x<80) begin cell_index=0;cell_x=pixel_x;end
        else if(pixel_x<160) begin cell_index=1;cell_x=pixel_x-9'd80;end
        else if(pixel_x<240) begin cell_index=2;cell_x=pixel_x-9'd160;end
        else begin cell_index=3;cell_x=pixel_x-9'd240;end
        if(pixel_y<165) begin row=0;row_y=pixel_y-9'd140;end
        else if(pixel_y<190) begin row=1;row_y=pixel_y-9'd165;end
        else if(pixel_y<215) begin row=2;row_y=pixel_y-9'd190;end
        else begin row=3;row_y=pixel_y-9'd215;end
        if(pixel_y<40) begin
            base_color=(cell_index==patch_l)?16'h0460:16'h1086;
            lx=$signed({2'b0,cell_x})-11'sd16;ly=$signed({2'b0,pixel_y})-11'sd12;
            case(cell_index)
                0:text_word="ORGN    ";1:text_word="BELL    ";
                2:text_word="PLUK    ";3:text_word="PIAN    ";
            endcase
        end else if(pixel_y<80) begin
            lx=$signed({2'b0,cell_x})-11'sd16;ly=$signed({2'b0,pixel_y})-11'sd52;
            case(cell_index)
                0:begin text_word="PLAY    ";base_color=playing_l?16'h0460:16'h1086;end
                1:begin text_word="PAUS    ";base_color=paused_l?16'hD520:16'h1086;end
                2:begin text_word="STOP    ";base_color=16'h7800;end
                3:begin text_word="LOOP    ";base_color=looping_l?16'h041F:16'h1086;end
            endcase
        end else if(pixel_y<112) begin
            // floor(x*K/319)<=v iff x*K<(v+1)*319. Exact for every
            // column/parameter; shift-add comparison removes the DSP divider.
            base_color=({1'b0,volume_column}<volume_limit)?16'h0250:16'h1082;
            text_word="VOLUME  ";lx=$signed({2'b0,pixel_x})-11'sd8;ly=$signed({2'b0,pixel_y})-11'sd88;
        end else if(pixel_y<140) begin
            text_word=(page_l==0)?"ADSR    ":((page_l==1)?"METRIC  ":"WAVE    ");
            lx=$signed({2'b0,pixel_x})-11'sd8;ly=$signed({2'b0,pixel_y})-11'sd118;
            base_color=16'h2104;
        end else if(page_l==1) begin
            lx=$signed({2'b0,pixel_x})-11'sd8;ly=$signed({2'b0,row_y})-11'sd5;
            case(row)
                0:begin text_word="A       ";bar_value=attack_l;end
                1:begin text_word="D       ";bar_value=decay_l;end
                2:begin text_word="S       ";bar_value=sustain_l;end
                3:begin text_word="R       ";bar_value=release_l;end
            endcase
            base_color=({1'b0,adsr_column}<adsr_limit)?16'h0328:16'h1082;
        end else if(page_l==2) begin
            lx=$signed({2'b0,pixel_x})-11'sd8;ly=$signed({2'b0,row_y})-11'sd5;
            case(row)
                0:begin text_word="5MS PCM ";base_color=!latency_seen_l?16'h3186:(le5_l?16'h0460:16'h7800);end
                1:begin text_word="10MS PCM";base_color=!latency_seen_l?16'h3186:(le10_l?16'h0460:16'h7800);end
                2:begin text_word=latency_seen_l?{"US ",us_text}:"NO DATA ";end
                3:begin text_word={"XR ",xr_text};end
            endcase
        end else begin
            if(pixel_y==190) base_color=16'h3186;
            if(pixel_x>=32 && pixel_x<288 && (pixel_y==target_y || pixel_y==target_y+1))
                base_color=16'h07FF;
        end
        // Beat feedback is immediate in LEDs; LCD state is frame-snapshotted.
        if(pixel_y<8) base_color=beat_l?16'hFFE0:16'h0841;
    end
    function [2:0] column;
        input [6:0] x;
        begin
            if(x<12) column=0;else if(x<24) column=1;
            else if(x<36) column=2;else if(x<48) column=3;
            else if(x<60) column=4;else if(x<72) column=5;
            else if(x<84) column=6;else column=7;
        end
    endfunction
    generate if(PIPELINED) begin: raster_pipeline
        reg [15:0] color_s;
        reg [63:0] word_s;
        reg [6:0] x_s;
        reg [3:0] y_s;
        reg text_s,ink_s;
        wire [2:0] col=column(x_s);
        wire [6:0] origin={4'd0,col}*7'd12;
        wire [6:0] glyph_x=x_s-origin;
        reg [7:0] character_s;
        reg [5:0] bit_s;
        reg [34:0] font_s;
        reg [15:0] rendered_color;
        assign pixel_rgb565=rendered_color;
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                render_state<=0;color_s<=0;word_s<=0;x_s<=0;y_s<=0;
                text_s<=0;ink_s<=0;character_s<=0;bit_s<=0;font_s<=0;rendered_color<=0;
            end else if(!panel_ready) render_state<=0;
            else case(render_state)
                0:if(!frame_start) begin
                    color_s<=base_color;word_s<=text_word;
                    x_s<=lx[6:0];y_s<=ly[3:0];
                    text_s<=lx>=0 && lx<96 && ly>=0 && ly<14;render_state<=1;
                end
                1:begin
                    character_s<=word_s[(7-col)*8+:8];
                    bit_s<=(6-y_s[3:1])*5+(4-glyph_x[6:1]);
                    ink_s<=text_s && glyph_x<10;render_state<=2;
                end
                2:begin font_s<=glyph(character_s);render_state<=3;end
                3:begin rendered_color<=(ink_s && bit_s<35 && font_s[bit_s])?16'hffff:color_s;render_state<=4;end
                4:if(pixel_ready) render_state<=0;
                default:render_state<=0;
            endcase
        end
    end else begin: direct_raster
        integer char_index,font_bit;
        reg [7:0] character;
        reg [34:0] font;
        reg [15:0] color;
        assign pixel_rgb565=color;
        always @* begin
            color=base_color;char_index=0;font_bit=0;character=0;font=0;
            if(lx>=0 && lx<96 && ly>=0 && ly<14) begin
                char_index=lx/12;character=text_word[(7-char_index)*8+:8];
                font=glyph(character);font_bit=(6-ly/2)*5+(4-(lx%12)/2);
                if(lx%12<10 && font_bit>=0 && font_bit<35 && font[font_bit]) color=16'hffff;
            end
        end
    end endgenerate
endmodule
