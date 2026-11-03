`timescale 1ns/1ps

module i2s_tx (
    input  wire               clk,
    input  wire               rst_n,
    input  wire signed [23:0]  sample_left,
    input  wire signed [23:0]  sample_right,
    output wire               mclk,
    output wire               bclk,
    output reg                lrclk,
    output reg                sdata,
    output reg                frame_tick
);
    reg [3:0] div_count;
    reg [5:0] bit_pos;
    reg signed [23:0] held_left;
    reg signed [23:0] held_right;

    // div_count wraps every 16 core clocks: bit 1 is clk/4, bit 3 is clk/16.
    assign mclk = div_count[1];
    assign bclk = div_count[3];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_count  <= 4'd0;
            bit_pos    <= 6'd0;
            held_left  <= 24'sd0;
            held_right <= 24'sd0;
            lrclk      <= 1'b0;
            sdata      <= 1'b0;
            frame_tick <= 1'b0;
        end else begin
            div_count  <= div_count + 1'b1;
            frame_tick <= 1'b0;

            // BCLK falls when the divider wraps. Update serial outputs here,
            // leaving them stable for the following BCLK rising-edge sample.
            if (div_count == 4'hf) begin
                if (bit_pos == 6'd31) begin
                    bit_pos <= 6'd0;
                    lrclk   <= ~lrclk;
                    sdata   <= 1'b0; // I2S one-bit WS-to-MSB delay
                    if (lrclk) begin
                        held_left  <= sample_left;
                        held_right <= sample_right;
                        frame_tick <= 1'b1;
                    end
                end else begin
                    bit_pos <= bit_pos + 1'b1;
                    if (bit_pos == 6'd0) begin
                        sdata <= lrclk ? held_right[23] : held_left[23];
                    end else if (bit_pos < 6'd24) begin
                        sdata <= lrclk ? held_right[23-bit_pos] : held_left[23-bit_pos];
                    end else begin
                        sdata <= 1'b0;
                    end
                end
            end
        end
    end
endmodule
