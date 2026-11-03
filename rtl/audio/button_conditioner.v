module button_conditioner #(
    parameter integer DEBOUNCE_CYCLES=100000
) (
    input wire clk,input wire rst_n,input wire button_n,
    output reg pressed,output reg press_pulse
);
    reg sync1,sync2;
    reg [31:0] count;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin sync1<=1;sync2<=1;count<=0;pressed<=0;press_pulse<=0;end
        else begin
            sync1<=button_n;sync2<=sync1;press_pulse<=0;
            if((!sync2)==pressed) count<=0;
            else if(count==DEBOUNCE_CYCLES-1) begin
                pressed<=!sync2;press_pulse<=!sync2;count<=0;
            end else count<=count+32'd1;
        end
    end
endmodule
