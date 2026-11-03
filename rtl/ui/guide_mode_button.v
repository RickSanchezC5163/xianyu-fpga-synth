`timescale 1ns/1ps
// Reuse the existing audio sample strobe for a small long-press counter.
// play_pressed itself is untouched so manual audio fallback remains intact.
module guide_mode_button #(parameter integer LONG_SAMPLES=39063)(
    input wire clk,rst_n,enable,pressed,sample_tick,
    output reg short_release,long_press
);
    localparam integer CW=(LONG_SAMPLES<2)?1:$clog2(LONG_SAMPLES);
    reg [CW-1:0] age;
    reg previous,active,long_seen,release_seen;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin previous<=0;age<=0;active<=0;long_seen<=0;release_seen<=0;short_release<=0;long_press<=0;end
        else begin
            previous<=pressed;short_release<=0;long_press<=0;
            if(!pressed)release_seen<=1;
            if(!enable)begin age<=0;active<=0;long_seen<=0;end
            else if(pressed && !previous && release_seen)begin age<=0;active<=1;long_seen<=0;end
            else if(pressed && active && !long_seen && sample_tick)begin
                if(age==LONG_SAMPLES-1)begin long_press<=1;long_seen<=1;end
                else age<=age+1'b1;
            end else if(!pressed && previous && active)begin
                short_release<=!long_seen;active<=0;age<=0;long_seen<=0;
            end
        end
    end
    // synthesis translate_off
    initial if(LONG_SAMPLES<2)$fatal(1,"guide mode long press too short");
    // synthesis translate_on
endmodule
