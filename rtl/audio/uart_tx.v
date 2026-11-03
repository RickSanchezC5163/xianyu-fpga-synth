`timescale 1ns/1ps

// 8N1 UART transmitter. A byte is accepted on valid && ready at a clk edge.
module uart_tx #(
    parameter integer CLKS_PER_BIT = 434
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,
    input  wire       valid,
    output reg        tx,
    output wire       ready
);
    localparam [1:0] IDLE = 2'd0, START = 2'd1, DATA = 2'd2, STOP = 2'd3;
    reg [1:0] state;
    reg [15:0] count;
    reg [2:0] bit_index;
    reg [7:0] shift;

    assign ready = (state == IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            count <= 0;
            bit_index <= 0;
            shift <= 0;
            tx <= 1'b1;
        end else begin
            case (state)
                IDLE: begin
                    tx <= 1'b1;
                    if (valid) begin
                        shift <= data;
                        count <= CLKS_PER_BIT - 1;
                        bit_index <= 0;
                        tx <= 1'b0;
                        state <= START;
                    end
                end
                START: if (count == 0) begin
                    tx <= shift[0];
                    count <= CLKS_PER_BIT - 1;
                    state <= DATA;
                end else count <= count - 1'b1;
                DATA: if (count == 0) begin
                    if (bit_index == 3'd7) begin
                        tx <= 1'b1;
                        count <= CLKS_PER_BIT - 1;
                        state <= STOP;
                    end else begin
                        bit_index <= bit_index + 1'b1;
                        tx <= shift[bit_index + 1'b1];
                        count <= CLKS_PER_BIT - 1;
                    end
                end else count <= count - 1'b1;
                STOP: if (count == 0) state <= IDLE;
                     else count <= count - 1'b1;
                default: begin state <= IDLE; tx <= 1'b1; end
            endcase
        end
    end
endmodule
