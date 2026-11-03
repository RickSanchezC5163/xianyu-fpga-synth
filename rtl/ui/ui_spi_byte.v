`timescale 1ns/1ps
// Shared mode-0, MSB-first byte shifter. No CS ownership inside this module.
module ui_spi_byte(
    input wire clk, input wire rst_n, input wire start,
    input wire [7:0] tx_data, input wire [15:0] half_period,
    input wire miso,
    output reg sck, output reg mosi, output reg [7:0] rx_data,
    output reg busy, output reg done
);
    reg [15:0] divider, count;
    reg [7:0] tx_shift, rx_shift;
    reg [2:0] bit_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sck<=0; mosi<=0; rx_data<=0; busy<=0; done<=0;
            divider<=1; count<=0; tx_shift<=0; rx_shift<=0; bit_index<=0;
        end else begin
            done<=0;
            if (!busy) begin
                sck<=0;
                if(start) begin
                    busy<=1; divider <= half_period==0 ? 16'd1 : half_period;
                    count<=0; tx_shift<=tx_data; rx_shift<=0;
                    mosi<=tx_data[7]; bit_index<=7;
                end
            end else if(count==divider-1) begin
                count<=0;
                if(!sck) begin
                    sck<=1; rx_shift<={rx_shift[6:0],miso};
                end else begin
                    sck<=0;
                    if(bit_index==0) begin
                        busy<=0; done<=1; rx_data<=rx_shift; mosi<=0;
                    end else begin
                        bit_index<=bit_index-1;
                        tx_shift<={tx_shift[6:0],1'b0}; mosi<=tx_shift[6];
                    end
                end
            end else count<=count+1;
        end
    end
endmodule
