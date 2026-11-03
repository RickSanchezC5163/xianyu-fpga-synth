`timescale 1ns/1ps
// Atomic, non-blocking WS2812 RGB frame transmitter. Pixel 0 is frame_grb[23:0].
// At 50 MHz the defaults give 1280 ns cells, 320/640 ns highs and 350 us reset.
module ws2812_strip #(
    parameter integer PIXELS = 41,
    parameter integer BIT_CYCLES = 64,
    parameter integer ZERO_HIGH = 16,
    parameter integer ONE_HIGH = 32,
    parameter integer RESET_CYCLES = 17500
) (
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire [PIXELS*24-1:0] frame_grb,
    output reg data_out,
    output reg busy,
    output reg done
);
    localparam integer CELL_W = (BIT_CYCLES > 1) ? $clog2(BIT_CYCLES) : 1;
    localparam integer RESET_W = (RESET_CYCLES > 1) ? $clog2(RESET_CYCLES) : 1;
    localparam integer PIXEL_W = (PIXELS > 1) ? $clog2(PIXELS) : 1;
    localparam [1:0] STARTUP = 2'd0, IDLE = 2'd1, SEND = 2'd2, LATCH = 2'd3;
    reg [1:0] state;
    reg [CELL_W-1:0] cell_count;
    reg [RESET_W-1:0] reset_count;
    reg [PIXEL_W-1:0] pixel_count;
    reg [4:0] bit_index;
    reg [PIXELS*24-1:0] frame_latched;
    wire current_bit = frame_latched[bit_index];

    // synthesis translate_off
    initial begin
        if (PIXELS < 1 || BIT_CYCLES < 2 || RESET_CYCLES < 1 ||
            ZERO_HIGH < 1 || ONE_HIGH < 1 ||
            ZERO_HIGH >= BIT_CYCLES || ONE_HIGH >= BIT_CYCLES)
            $fatal(1, "Invalid WS2812 timing or pixel parameter");
    end
    // synthesis translate_on

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STARTUP;
            data_out <= 1'b0;
            busy <= 1'b1;
            done <= 1'b0;
            cell_count <= 0;
            reset_count <= 0;
            pixel_count <= 0;
            bit_index <= 23;
            frame_latched <= 0;
        end else begin
            done <= 1'b0;
            case (state)
                STARTUP: begin
                    data_out <= 1'b0;
                    if (reset_count == RESET_CYCLES-1) begin
                        reset_count <= 0;
                        busy <= 1'b0;
                        state <= IDLE;
                    end else reset_count <= reset_count + 1'b1;
                end
                IDLE: begin
                    if (start) begin
                        frame_latched <= frame_grb;
                        pixel_count <= 0;
                        bit_index <= 23;
                        cell_count <= 0;
                        data_out <= 1'b1;
                        busy <= 1'b1;
                        state <= SEND;
                    end
                end
                SEND: begin
                    if (cell_count == (current_bit ? ONE_HIGH-1 : ZERO_HIGH-1))
                        data_out <= 1'b0;
                    if (cell_count == BIT_CYCLES-1) begin
                        cell_count <= 0;
                        if (bit_index == 0 && pixel_count == PIXELS-1) begin
                            data_out <= 1'b0;
                            reset_count <= 0;
                            state <= LATCH;
                        end else begin
                            data_out <= 1'b1;
                            if (bit_index == 0) begin
                                bit_index <= 23;
                                pixel_count <= pixel_count + 1'b1;
                                frame_latched <= frame_latched >> 24;
                            end else bit_index <= bit_index - 1'b1;
                        end
                    end else cell_count <= cell_count + 1'b1;
                end
                LATCH: begin
                    data_out <= 1'b0;
                    if (reset_count == RESET_CYCLES-1) begin
                        reset_count <= 0;
                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= IDLE;
                    end else reset_count <= reset_count + 1'b1;
                end
                default: begin
                    state <= STARTUP;
                    reset_count <= 0;
                    data_out <= 1'b0;
                    busy <= 1'b1;
                end
            endcase
        end
    end
endmodule
