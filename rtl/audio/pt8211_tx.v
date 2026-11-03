// PT8211 Japanese 16-bit serial format. NOT Philips I2S.
// WS low=RIGHT, high=LEFT; data sampled on BCK rising edge.
// 50 MHz / 32 BCK / 32 bits = 48828.125 stereo frames/s.
module pt8211_tx (
    input wire clk,input wire rst_n,
    input wire signed [15:0] sample_left,sample_right,
    output wire bclk,output reg ws,output reg sdata,output reg frame_tick
);
    reg [4:0] divider,position;
    reg [15:0] left_hold,right_hold;
    wire [4:0] next_position=position+5'd1;
    assign bclk=divider[4];
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            divider<=0;position<=31;ws<=1;sdata<=0;frame_tick<=0;
            left_hold<=0;right_hold<=0;
        end else begin
            divider<=divider+5'd1;frame_tick<=0;
            if(divider==31) begin
                position<=next_position;ws<=next_position[4];
                if(next_position==0) begin
                    left_hold<=sample_left;right_hold<=sample_right;
                    sdata<=sample_right[15];frame_tick<=1;
                end else if(next_position<16) sdata<=right_hold[15-next_position];
                else sdata<=left_hold[31-next_position];
            end
        end
    end
endmodule
