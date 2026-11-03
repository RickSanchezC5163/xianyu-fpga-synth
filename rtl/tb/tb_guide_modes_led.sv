`timescale 1ns/1ps
module tb_guide_modes_led;
    reg [24:0] expected_keys=0,preview_keys=0,held_keys=0,wrong_keys=0;
    reg playing=0,paused=0,beat_lit=0,strong_beat=0,range_warning=0,wait_mode=0;
    wire [791:0] frame_grb;
    localparam [199:0] MAP={8'd25,8'd24,8'd23,8'd22,8'd21,8'd20,8'd19,8'd18,
        8'd17,8'd16,8'd15,8'd14,8'd13,8'd12,8'd11,8'd10,8'd9,8'd8,8'd7,
        8'd6,8'd5,8'd4,8'd3,8'd2,8'd1};
    guide_led_frame #(.EXTERNAL_PIXELS(32),.PREFIX_PIXELS(1),.MODE_FEEDBACK(1),.KEY_MAP(MAP)) dut(.*);
    task check(input integer external_pixel,input [23:0] color);
        begin #1;if(frame_grb[23:0]!==0 || frame_grb[(external_pixel+1)*24+:24]!==color)
            $fatal(1,"mode/color prefix mismatch pixel%0d wanted%h got%h",external_pixel,color,frame_grb[(external_pixel+1)*24+:24]);end
    endtask
    initial begin
        // Drive a real input transition after time0 (Verilog2001 always @*).
        #1;wait_mode=1;#1;wait_mode=0;
        check(0,24'h000008);wait_mode=1;check(0,24'h080800);
        playing=1;check(0,0);expected_keys=1;check(1,24'h100000);
        held_keys=1;check(1,24'h001010);wrong_keys=1;check(1,24'h001000);
        wait_mode=0;check(1,24'h001010);wait_mode=1;paused=1;check(1,24'h001010);
        held_keys=0;check(1,24'h080800);paused=0;check(1,24'h100000);
        beat_lit=1;strong_beat=1;check(0,24'h101010);strong_beat=0;check(0,24'h000010);
        range_warning=1;check(31,24'h001000);
        $display("PASS guide mode LEDs: idle modes, target/held/wrong/paused, reference beat, range and dark prefix");$finish;
    end
endmodule
