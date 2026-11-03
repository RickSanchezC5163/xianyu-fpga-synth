`timescale 1ns/1ps
// Local musical clock. Never waits for LEDs, LCD, touch or audio consumers.
module guide_transport #(
    parameter integer CLK_HZ=50000000,
    parameter integer PPQN=96,
    parameter integer BEATS_PER_BAR=4,
    parameter integer FLASH_MS=80
)(
    input wire clk,rst_n,start,pause_toggle,stop,finish,
    input wire [7:0] bpm,
    output reg playing,paused,
    output reg [31:0] song_tick,
    output reg beat_pulse,strong_beat,beat_lit
);
    localparam integer MS_CYCLES=CLK_HZ/1000;
    localparam integer CW=(MS_CYCLES<=1)?1:$clog2(MS_CYCLES);
    reg [CW-1:0] divider;
    reg [31:0] phase;
    reg [15:0] subbeat,beat_index,flash_left;
    wire [7:0] tempo=(bpm<30)?8'd30:((bpm>240)?8'd240:bpm);
    wire [31:0] phase_next=phase+tempo*PPQN;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            divider<=0;phase<=0;subbeat<=0;beat_index<=0;flash_left<=0;
            playing<=0;paused<=0;song_tick<=0;beat_pulse<=0;strong_beat<=0;beat_lit<=0;
        end else begin
            beat_pulse<=0;
            if(stop || finish) begin
                playing<=0;paused<=0;song_tick<=0;phase<=0;divider<=0;
                subbeat<=0;beat_index<=0;flash_left<=0;beat_lit<=0;strong_beat<=0;
            end else if(start) begin
                playing<=1;paused<=0;song_tick<=0;phase<=0;divider<=0;
                subbeat<=0;beat_index<=0;flash_left<=FLASH_MS;
                beat_pulse<=1;strong_beat<=1;beat_lit<=1;
            end else if(pause_toggle && playing) begin
                paused<=!paused;
            end else if(playing && !paused) begin
                if(divider==MS_CYCLES-1) begin
                    divider<=0;
                    if(flash_left!=0) begin flash_left<=flash_left-1'b1;if(flash_left==1) beat_lit<=0;end
                    if(phase_next>=60000) begin
                        phase<=phase_next-60000;song_tick<=song_tick+1'b1;
                        if(subbeat==PPQN-1) begin
                            subbeat<=0;beat_pulse<=1;flash_left<=FLASH_MS;beat_lit<=1;
                            if(beat_index==BEATS_PER_BAR-1) begin beat_index<=0;strong_beat<=1;end
                            else begin beat_index<=beat_index+1'b1;strong_beat<=0;end
                        end else subbeat<=subbeat+1'b1;
                    end else phase<=phase_next;
                end else divider<=divider+1'b1;
            end
        end
    end
    // synthesis translate_off
    initial begin
        if(CLK_HZ<1000 || CLK_HZ%1000!=0 || PPQN<1 || PPQN>250 ||
           BEATS_PER_BAR<1 || FLASH_MS<1 || FLASH_MS>65535)
            $fatal(1,"guide_transport invalid parameters");
    end
    // synthesis translate_on
endmodule
