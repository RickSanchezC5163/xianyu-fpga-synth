`timescale 1ns/1ps

module tb_pt8211_tx;
    reg clk = 1'b0;
    reg rst_n = 1'b1;
    reg signed [15:0] sample_left = -16'sd11317;
    reg signed [15:0] sample_right = 16'sd9321;
    wire bclk, ws, sdata, frame_tick;

    pt8211_tx dut (clk, rst_n, sample_left, sample_right, bclk, ws, sdata, frame_tick);
    always #10 clk = ~clk;

    integer cycles = 0;
    integer ticks = 0;
    integer last_tick_cycle = -1;
    integer right_slots = 0;
    integer left_slots = 0;
    integer bit_index = 0;
    integer errors = 0;
    integer last_bclk_posedge_cycle = -1;
    integer bclk_edges = 0;
    reg last_ws = 1'b1;
    reg signed [15:0] expected_right = 16'sd0;
    reg signed [15:0] expected_left = 16'sd0;
    reg [15:0] received = 16'd0;
    reg signed [15:0] slot_expected;
    reg pin_prev_bck=0,pin_prev_ws=1,pin_prev_data=0;
    integer last_fall_cycle=-1;

    // Check the timing argument used by audio.sdc, independently of DUT state.
    always @(negedge clk) begin
        if(!rst_n) begin
            pin_prev_bck=0;pin_prev_ws=1;pin_prev_data=0;last_fall_cycle=-1;
        end else begin
            if(pin_prev_bck && !bclk) last_fall_cycle=cycles;
            if((ws!==pin_prev_ws || sdata!==pin_prev_data) && !(pin_prev_bck && !bclk))
                $fatal(1,"DIN/WS changed outside falling BCK");
            if(!pin_prev_bck && bclk && last_fall_cycle>=0 && cycles-last_fall_cycle!=16)
                $fatal(1,"Incorrect 320ns data setup window");
            pin_prev_bck=bclk;pin_prev_ws=ws;pin_prev_data=sdata;
        end
    end

    always @(posedge clk) cycles = cycles + 1;

    // Observe pins as a stand-alone PT8211 receiver: WS low is right, high is left,
    // MSB first with no I2S delay; every data bit is sampled on BCLK rising.
    always @(posedge bclk or negedge rst_n) begin
        if (!rst_n) begin
            bit_index = 0;
            last_ws = 1'b1;
            received = 16'd0;
            expected_left = 16'sd0;
            expected_right = 16'sd0;
            last_bclk_posedge_cycle = -1;
            last_tick_cycle = -1;
        end else begin
            bclk_edges = bclk_edges + 1;
            if (last_bclk_posedge_cycle >= 0 && cycles-last_bclk_posedge_cycle != 32) begin
                $display("FAIL: BCLK rising-edge period %0d core clocks, expected 32", cycles-last_bclk_posedge_cycle);
                errors = errors + 1;
            end
            last_bclk_posedge_cycle = cycles;

            if (ws !== last_ws) begin
                last_ws = ws;
                bit_index = 0;
                received = 16'd0;
            end
            received = {received[14:0], sdata};
            if (bit_index == 15) begin
                slot_expected = ws ? expected_left : expected_right;
                if (received !== slot_expected) begin
                    $display("FAIL: WS=%b slot decoded %04h expected %04h at core cycle %0d", ws, received, slot_expected, cycles);
                    errors = errors + 1;
                end
                if (ws) left_slots = left_slots + 1;
                else right_slots = right_slots + 1;
                bit_index = 0;
            end else bit_index = bit_index + 1;
        end
    end

    always @(negedge clk) begin
        if (rst_n && frame_tick) begin
            ticks = ticks + 1;
            if (last_tick_cycle >= 0 && cycles-last_tick_cycle != 1024) begin
                $display("FAIL: frame_tick period %0d core clocks, expected 1024", cycles-last_tick_cycle);
                errors = errors + 1;
            end
            last_tick_cycle = cycles;
            expected_left = sample_left;
            expected_right = sample_right;
        end
    end

    task wait_ticks(input integer target);
        begin while (ticks < target) @(negedge clk); end
    endtask

    initial begin
        #1 rst_n = 1'b0;
        #1;
        if (bclk !== 1'b0 || ws !== 1'b1 || sdata !== 1'b0 || frame_tick !== 1'b0)
            $fatal(1, "FAIL: reset pins do not have deterministic mute phase");
        repeat (9) @(negedge clk);
        rst_n = 1'b1;

        wait_ticks(ticks + 3);
        // Change both inputs in the middle of a frame. The active pair must remain intact.
        repeat (211) @(negedge clk);
        sample_left = 16'sh6A5C;
        sample_right = -16'sh35A7;
        wait_ticks(ticks + 2);
        sample_left = -16'sh1234;
        sample_right = 16'sh5678;
        wait_ticks(ticks + 3);

        // Assert reset in the middle of a slot and verify asynchronous muting/restart.
        repeat (287) @(negedge clk);
        rst_n = 1'b0;
        #1;
        if (bclk !== 1'b0 || ws !== 1'b1 || sdata !== 1'b0 || frame_tick !== 1'b0)
            $fatal(1, "FAIL: reset did not asynchronously mute PT8211 pins");
        repeat (11) @(negedge clk);
        rst_n = 1'b1;
        wait_ticks(ticks + 4);

        if (ticks < 8 || left_slots < 6 || right_slots < 6 || bclk_edges < 100)
            $fatal(1, "FAIL: coverage too low ticks=%0d slots L/R=%0d/%0d bclk=%0d", ticks,left_slots,right_slots,bclk_edges);
        if (errors != 0) $fatal(1, "FAIL: %0d PT8211 protocol errors", errors);
        $display("PASS: PT8211 decoded %0d right/%0d left slots, %0d frame ticks", right_slots,left_slots,ticks);
        $finish;
    end

    initial begin
        #300000;
        $fatal(1, "FAIL: PT8211 simulation timeout");
    end
endmodule
