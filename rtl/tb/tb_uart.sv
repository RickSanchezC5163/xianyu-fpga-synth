`timescale 1ns/1ps

module tb_uart;
    localparam integer CPB = 8;
    reg clk = 0;
    reg rst_n = 0;
    reg manual_rx = 1;
    reg use_tx = 1;
    reg [7:0] tx_data = 0;
    reg tx_valid = 0;
    wire tx_pin, tx_ready, rx_pin;
    wire [7:0] rx_data;
    wire rx_valid, framing_error;
    integer good_count = 0;
    integer bad_count = 0;

    assign rx_pin = use_tx ? tx_pin : manual_rx;
    uart_tx #(.CLKS_PER_BIT(CPB)) tx0
        (.clk(clk), .rst_n(rst_n), .data(tx_data), .valid(tx_valid), .tx(tx_pin), .ready(tx_ready));
    uart_rx #(.CLKS_PER_BIT(CPB)) rx0
        (.clk(clk), .rst_n(rst_n), .rx(rx_pin), .data(rx_data), .valid(rx_valid), .framing_error(framing_error));
    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (rst_n && rx_valid) begin
            if (good_count == 0 && rx_data !== 8'hA5) $fatal(1, "first byte mismatch %02x", rx_data);
            if (good_count == 1 && rx_data !== 8'h3C) $fatal(1, "second byte mismatch %02x", rx_data);
            good_count = good_count + 1;
        end
        if (rst_n && framing_error) bad_count = bad_count + 1;
    end

    task automatic send_byte(input [7:0] b);
        begin
            @(negedge clk);
            while (!tx_ready) @(negedge clk);
            tx_data = b;
            tx_valid = 1;
            @(negedge clk);
            tx_valid = 0;
        end
    endtask

    task automatic manual_bit(input bit v);
        begin
            manual_rx = v;
            repeat (CPB) @(negedge clk);
        end
    endtask

    integer i;
    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        send_byte(8'hA5);
        send_byte(8'h3C);
        wait (good_count == 2);

        // Inject a complete frame with a low stop bit.
        use_tx = 0;
        repeat (4) @(negedge clk);
        manual_bit(0);
        for (i = 0; i < 8; i = i + 1) manual_bit((8'h69 >> i) & 1'b1);
        manual_bit(0);
        repeat (CPB) @(negedge clk);
        if (bad_count != 1) $fatal(1, "expected one framing error, got %0d", bad_count);
        if (good_count != 2) $fatal(1, "bad frame incorrectly produced valid data");

        // Reset in the middle of a frame and ensure the partial byte is discarded.
        manual_bit(0);
        manual_bit(1);
        manual_bit(1);
        rst_n = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;
        manual_rx = 1;
        repeat (CPB * 12) @(negedge clk);
        if (good_count != 2 || bad_count != 1) $fatal(1, "reset mid-frame emitted an event");
        $display("PASS tb_uart");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "timeout");
    end
endmodule
