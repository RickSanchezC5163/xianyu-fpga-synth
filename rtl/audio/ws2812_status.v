// One-pixel GRB status display, refreshed every ~10 ms from live FPGA state.
module ws2812_status #(
    parameter integer REFRESH_CYCLES=500000,
    parameter integer RESET_CYCLES=3000
) (
    input wire clk,input wire rst_n,input wire [23:0] grb,
    output reg data_out
);
    localparam [1:0] WAIT=0,SEND=1,RESET=2;
    reg [1:0] state;
    reg [31:0] wait_count;
    reg [11:0] reset_count;
    reg [5:0] bit_count;
    reg [5:0] tick_count;
    reg [23:0] bits;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=WAIT;wait_count<=0;reset_count<=0;
            bit_count<=0;tick_count<=0;bits<=0;data_out<=0;
        end else case(state)
            WAIT: begin
                data_out<=0;
                if(wait_count==REFRESH_CYCLES-1) begin
                    wait_count<=0;bits<=grb;bit_count<=0;
                    tick_count<=0;state<=SEND;
                end else wait_count<=wait_count+1'b1;
            end
            SEND: begin
                data_out<=tick_count<(bits[23] ? 6'd35 : 6'd18);
                if(tick_count==6'd62) begin
                    tick_count<=0;bits<={bits[22:0],1'b0};
                    if(bit_count==6'd23) begin
                        reset_count<=0;state<=RESET;
                    end else bit_count<=bit_count+1'b1;
                end else tick_count<=tick_count+1'b1;
            end
            RESET: begin
                data_out<=0;
                if(reset_count==RESET_CYCLES-1) state<=WAIT;
                else reset_count<=reset_count+1'b1;
            end
            default: state<=WAIT;
        endcase
    end
endmodule
