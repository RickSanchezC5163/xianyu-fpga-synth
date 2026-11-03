`timescale 1ns/1ps
// Illustrative 18mm white-key geometry only; replace KEY_MAP after measuring.
// Indicator positions are configurable; low24bits is stream pixel0.
module guide_led_frame #(
    parameter integer EXTERNAL_PIXELS=40,
    parameter integer PREFIX_PIXELS=1,MODE_FEEDBACK=0,
    parameter integer BEAT_PIXEL=0,RANGE_PIXEL=EXTERNAL_PIXELS-1,
    parameter [199:0] KEY_MAP={8'd38,8'd35,8'd34,8'd32,8'd31,8'd30,8'd29,
        8'd27,8'd25,8'd23,8'd22,8'd21,8'd19,8'd17,8'd16,8'd14,8'd13,
        8'd12,8'd10,8'd9,8'd6,8'd5,8'd4,8'd3,8'd1}
)(input wire [24:0] expected_keys,preview_keys,held_keys,
    input wire playing,paused,beat_lit,strong_beat,range_warning,
    output reg [(EXTERNAL_PIXELS+PREFIX_PIXELS)*24-1:0] frame_grb,
    input wire wait_mode,input wire [24:0] wrong_keys);
    integer k,p;
    always @* begin
        frame_grb=0;
        // Prefix is kept dark; indicator positions must not overlap keys.
        if(MODE_FEEDBACK && !playing)
            frame_grb[(PREFIX_PIXELS+BEAT_PIXEL)*24+:24]=wait_mode?24'h080800:24'h000008;
        if(playing && beat_lit)
            frame_grb[(PREFIX_PIXELS+BEAT_PIXEL)*24+:24]=strong_beat?24'h101010:24'h000010;
        if(range_warning) frame_grb[(PREFIX_PIXELS+RANGE_PIXEL)*24+:24]=24'h001000;
        for(k=0;k<25;k=k+1) begin
            p=KEY_MAP[k*8+:8];
            if(p<EXTERNAL_PIXELS && p!=BEAT_PIXEL && p!=RANGE_PIXEL) begin
                if(preview_keys[k]) frame_grb[(PREFIX_PIXELS+p)*24+:24]=24'h000008;
                if(expected_keys[k] && playing)
                    frame_grb[(PREFIX_PIXELS+p)*24+:24]=paused?24'h080800:24'h100000;
                if(held_keys[k]) frame_grb[(PREFIX_PIXELS+p)*24+:24]=24'h001010;
                if(MODE_FEEDBACK && playing && !paused && wait_mode && wrong_keys[k] && held_keys[k])
                    frame_grb[(PREFIX_PIXELS+p)*24+:24]=24'h001000;
            end
        end
    end
    // synthesis translate_off
    integer a,b;
    initial begin
        if(EXTERNAL_PIXELS<27 || EXTERNAL_PIXELS>256 || PREFIX_PIXELS<0 || PREFIX_PIXELS>1)
            $fatal(1,"guide_led_frame invalid pixel count");
        if(BEAT_PIXEL<0 || RANGE_PIXEL<0 || BEAT_PIXEL>=EXTERNAL_PIXELS || RANGE_PIXEL>=EXTERNAL_PIXELS || BEAT_PIXEL==RANGE_PIXEL)
            $fatal(1,"invalid indicator pixels");
        for(a=0;a<25;a=a+1) begin
            if(KEY_MAP[a*8+:8]==BEAT_PIXEL || KEY_MAP[a*8+:8]==RANGE_PIXEL || KEY_MAP[a*8+:8]>=EXTERNAL_PIXELS)
                $fatal(1,"key pixel overlaps reserved pixel or is out of range");
            for(b=0;b<a;b=b+1)
                if(KEY_MAP[a*8+:8]==KEY_MAP[b*8+:8]) $fatal(1,"key pixel collision");
        end
    end
    // synthesis translate_on
endmodule
