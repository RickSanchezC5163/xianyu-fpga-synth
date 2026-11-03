`timescale 1ns/1ps
// ILI9341 RGB565 pixel writer, shared SPI byte-client interface.
// STREAM_ROW=1 retains a bounded row window for contiguous pixels; default0
// preserves independent13-byte pixel sessions for conservative bring-up.
// Default orientation: landscape (MADCTL MV|BGR=0x28), 320x240.
// Power settings are a common breakout profile, not a guarantee for every panel.
// See output/research/20261015_ui_rtl/orchestra/lcd.md for provenance/limits.
module ili9341_panel #(
    parameter integer CLK_HZ = 50000000,
    parameter integer SPI_HALF_PERIOD = 2,
    parameter integer RESET_LOW_CYCLES = 500000,
    parameter integer RESET_WAIT_CYCLES = 6000000,
    parameter integer SLEEP_OUT_CYCLES = 6000000,
    parameter integer WIDTH = 320,
    parameter integer HEIGHT = 240,
    parameter integer STREAM_ROW = 0
)(
    input wire clk, input wire rst_n,
    output wire request, input wire grant,
    output reg tx_start, output reg [7:0] tx_data,
    output wire [15:0] tx_half_period,
    input wire tx_busy, input wire tx_done,
    output reg cs_n, output reg dc, output reg lcd_reset_n,
    output reg ready,
    input wire pixel_valid, output wire pixel_ready,
    input wire [8:0] pixel_x, input wire [8:0] pixel_y,
    input wire [15:0] pixel_rgb565
);
    localparam [3:0] RESET_LOW=0, RESET_WAIT=1, ACQUIRE=2,
                     ISSUE=3, BYTE_WAIT=4, SLEEP_WAIT=5, IDLE=6, YIELD=7,
                     WAIT_NEXT=8;
    localparam integer INIT_LAST = 53;
    localparam integer INIT_SLEEP = 52;
    localparam [8:0] ROW_END = WIDTH-1;
    reg [3:0] state;
    reg [31:0] timer;
    reg [6:0] init_index;
    reg [3:0] pixel_index;
    reg pixel_mode;
    reg [8:0] latched_x, latched_y;
    reg [15:0] latched_color;
    wire [9:0] current_init = init_word(init_index);
    wire [9:0] next_init = init_word(init_index + 7'd1);
    wire [8:0] next_pixel = pixel_word(pixel_index + 4'd1,
                                     latched_x,latched_y,latched_color);

    wire contiguous = pixel_x==latched_x+9'd1 && pixel_y==latched_y;
    assign request = state==ACQUIRE || state==ISSUE || state==BYTE_WAIT || state==WAIT_NEXT;
    assign pixel_ready = ready && (state==IDLE || (state==WAIT_NEXT && contiguous));
    assign tx_half_period = SPI_HALF_PERIOD;

    // synthesis translate_off
    initial begin
        if(CLK_HZ<=0 || RESET_LOW_CYCLES<=0 || RESET_WAIT_CYCLES<=0 ||
           SLEEP_OUT_CYCLES<=0)
            $fatal(1,"ili9341_panel requires positive clock and wait parameters");
        if(SPI_HALF_PERIOD<1 || SPI_HALF_PERIOD>65535)
            $fatal(1,"ili9341_panel SPI_HALF_PERIOD must fit a nonzero 16-bit divider");
        if(WIDTH<1 || WIDTH>512 || HEIGHT<1 || HEIGHT>512)
            $fatal(1,"ili9341_panel dimensions must fit the 9-bit coordinate interface");
    end
    // synthesis translate_on

    // {end_of_command, data_not_command, byte}. Reset restores controller gamma
    // defaults; this profile intentionally does not copy panel-specific gamma LUTs.
    function [9:0] init_word;
        input [6:0] index;
        begin
            case(index)
            7'd0: init_word = 10'h0ef;
            7'd1: init_word = 10'h103;
            7'd2: init_word = 10'h180;
            7'd3: init_word = 10'h302;
            7'd4: init_word = 10'h0cf;
            7'd5: init_word = 10'h100;
            7'd6: init_word = 10'h1c1;
            7'd7: init_word = 10'h330;
            7'd8: init_word = 10'h0ed;
            7'd9: init_word = 10'h164;
            7'd10: init_word = 10'h103;
            7'd11: init_word = 10'h112;
            7'd12: init_word = 10'h381;
            7'd13: init_word = 10'h0e8;
            7'd14: init_word = 10'h185;
            7'd15: init_word = 10'h100;
            7'd16: init_word = 10'h378;
            7'd17: init_word = 10'h0cb;
            7'd18: init_word = 10'h139;
            7'd19: init_word = 10'h12c;
            7'd20: init_word = 10'h100;
            7'd21: init_word = 10'h134;
            7'd22: init_word = 10'h302;
            7'd23: init_word = 10'h0f7;
            7'd24: init_word = 10'h320;
            7'd25: init_word = 10'h0ea;
            7'd26: init_word = 10'h100;
            7'd27: init_word = 10'h300;
            7'd28: init_word = 10'h0c0;
            7'd29: init_word = 10'h323;
            7'd30: init_word = 10'h0c1;
            7'd31: init_word = 10'h310;
            7'd32: init_word = 10'h0c5;
            7'd33: init_word = 10'h13e;
            7'd34: init_word = 10'h328;
            7'd35: init_word = 10'h0c7;
            7'd36: init_word = 10'h386;
            7'd37: init_word = 10'h036;
            7'd38: init_word = 10'h328;
            7'd39: init_word = 10'h03a;
            7'd40: init_word = 10'h355;
            7'd41: init_word = 10'h0b1;
            7'd42: init_word = 10'h100;
            7'd43: init_word = 10'h318;
            7'd44: init_word = 10'h0b6;
            7'd45: init_word = 10'h108;
            7'd46: init_word = 10'h182;
            7'd47: init_word = 10'h327;
            7'd48: init_word = 10'h0f2;
            7'd49: init_word = 10'h300;
            7'd50: init_word = 10'h026;
            7'd51: init_word = 10'h301;
            7'd52: init_word = 10'h211;
            7'd53: init_word = 10'h229;
            default: init_word = 10'h229;
            endcase
        end
    endfunction

    // {data_not_command, byte}; streaming window extends to the row end.
    function [8:0] pixel_word;
        input [3:0] index;
        input [8:0] x,y;
        input [15:0] color;
        begin
            case(index)
            0: pixel_word = {1'b0,8'h2a};
            1: pixel_word = {1'b1,7'b0,x[8]};
            2: pixel_word = {1'b1,x[7:0]};
            3: pixel_word = {1'b1,7'b0,STREAM_ROW ? ROW_END[8] : x[8]};
            4: pixel_word = {1'b1,STREAM_ROW ? ROW_END[7:0] : x[7:0]};
            5: pixel_word = {1'b0,8'h2b};
            6,8: pixel_word = {1'b1,7'b0,y[8]};
            7,9: pixel_word = {1'b1,y[7:0]};
            10: pixel_word = {1'b0,8'h2c};
            11: pixel_word = {1'b1,color[15:8]};
            12: pixel_word = {1'b1,color[7:0]};
            default: pixel_word = 9'h100;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=RESET_LOW; timer<=0; init_index<=0; pixel_index<=0;
            pixel_mode<=0; latched_x<=0; latched_y<=0; latched_color<=0;
            tx_start<=0; tx_data<=0; cs_n<=1; dc<=0;
            lcd_reset_n<=0; ready<=0;
        end else begin
            tx_start<=0;
            case(state)
            RESET_LOW: begin
                if(timer >= RESET_LOW_CYCLES-1) begin
                    timer<=0; lcd_reset_n<=1; state<=RESET_WAIT;
                end else timer<=timer+1'b1;
            end
            RESET_WAIT: begin
                if(timer >= RESET_WAIT_CYCLES-1) begin
                    timer<=0; state<=ACQUIRE;
                end else timer<=timer+1'b1;
            end
            ACQUIRE: if(grant && !tx_busy) begin
                cs_n<=0;
                if(pixel_mode) begin dc<=0; tx_data<=8'h2a; end
                else begin dc<=current_init[8]; tx_data<=current_init[7:0]; end
                state<=ISSUE;
            end
            ISSUE: if(grant && !tx_busy) begin
                tx_start<=1; state<=BYTE_WAIT;
            end
            BYTE_WAIT: if(tx_done) begin
                if(pixel_mode) begin
                    if(pixel_index==12) begin
                        if(STREAM_ROW && latched_x<WIDTH-1) state<=WAIT_NEXT;
                        else begin cs_n<=1; pixel_mode<=0; state<=IDLE; end
                    end else begin
                        pixel_index<=pixel_index+1'b1;
                        dc<=next_pixel[8]; tx_data<=next_pixel[7:0]; state<=ISSUE;
                    end
                end else if(current_init[9]) begin
                    cs_n<=1;
                    init_index<=init_index+1'b1;
                    if(init_index==INIT_LAST) begin ready<=1; state<=IDLE; end
                    else if(init_index==INIT_SLEEP) begin timer<=0; state<=SLEEP_WAIT; end
                    else state<=YIELD;
                end else begin
                    init_index<=init_index+1'b1;
                    dc<=next_init[8]; tx_data<=next_init[7:0]; state<=ISSUE;
                end
            end
            SLEEP_WAIT: begin
                if(timer >= SLEEP_OUT_CYCLES-1) begin timer<=0; state<=ACQUIRE; end
                else timer<=timer+1'b1;
            end
            // A real request-low cycle lets the shared arbiter rotate ownership.
            YIELD: state<=ACQUIRE;
            WAIT_NEXT: begin
                if(pixel_valid && contiguous) begin
                    latched_x<=pixel_x; latched_color<=pixel_rgb565;
                    pixel_index<=11; dc<=1; tx_data<=pixel_rgb565[15:8];
                    state<=ISSUE;
                end else begin
                    // Do not consume a mismatching pending pixel. Return ready
                    // from IDLE and send a new address window for that request.
                    cs_n<=1; pixel_mode<=0; state<=IDLE;
                end
            end
            IDLE: if(pixel_valid) begin
                // Invalid coordinates are consumed and dropped, never wrapped.
                if(pixel_x<WIDTH && pixel_y<HEIGHT) begin
                    latched_x<=pixel_x; latched_y<=pixel_y;
                    latched_color<=pixel_rgb565; pixel_index<=0;
                    pixel_mode<=1; state<=ACQUIRE;
                end
            end
            default: begin state<=RESET_LOW; timer<=0; ready<=0;
                cs_n<=1; lcd_reset_n<=0; end
            endcase
        end
    end
endmodule

