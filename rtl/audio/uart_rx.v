`timescale 1ns/1ps

// 8N1 UART receiver. CLKS_PER_BIT is the number of clk cycles per serial bit.
module uart_rx #(
    parameter integer CLKS_PER_BIT = 434
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    output reg [7:0]  data,
    output reg        valid,
    output reg        framing_error
);
    localparam [1:0] IDLE = 2'd0, START = 2'd1, DATA = 2'd2, STOP = 2'd3;
    reg [1:0] state;
    reg [15:0] count;
    reg [2:0] bit_index;
    reg [7:0] shift;
    reg rx_meta, rx_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            count <= 0;
            bit_index <= 0;
            shift <= 0;
            data <= 0;
            valid <= 0;
            framing_error <= 0;
        end else begin
            valid <= 1'b0;
            framing_error <= 1'b0;
            case (state)
                IDLE: if (!rx_sync) begin
                    // Confirm the start bit at its midpoint.
                    count <= (CLKS_PER_BIT / 2) - 1;
                    state <= START;
                end
                START: if (count == 0) begin
                    if (!rx_sync) begin
                        count <= CLKS_PER_BIT - 1;
                        bit_index <= 0;
                        state <= DATA;
                    end else state <= IDLE;
                end else count <= count - 1'b1;
                DATA: if (count == 0) begin
                    shift[bit_index] <= rx_sync;
                    count <= CLKS_PER_BIT - 1;
                    if (bit_index == 3'd7) state <= STOP;
                    else bit_index <= bit_index + 1'b1;
                end else count <= count - 1'b1;
                STOP: if (count == 0) begin
                    if (rx_sync) begin
                        data <= shift;
                        valid <= 1'b1;
                    end else framing_error <= 1'b1;
                    state <= IDLE;
                end else count <= count - 1'b1;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
