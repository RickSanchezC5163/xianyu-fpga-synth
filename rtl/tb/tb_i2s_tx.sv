`timescale 1ns/1ps

module tb_i2s_tx;
    reg clk = 1'b0;
    reg rst_n = 1'b1;
    reg signed [23:0] sample_left = 24'sd0;
    reg signed [23:0] sample_right = 24'sd0;
    wire mclk, bclk;
    wire lrclk, sdata, frame_tick;

    i2s_tx dut (
        .clk(clk), .rst_n(rst_n),
        .sample_left(sample_left), .sample_right(sample_right),
        .mclk(mclk), .bclk(bclk), .lrclk(lrclk), .sdata(sdata), .frame_tick(frame_tick)
    );

    always #10 clk = ~clk;

    integer core_cycles = 0;
    integer ticks = 0;
    integer last_tick_cycle = -1;
    integer left_slots = 0;
    integer right_slots = 0;
    integer slot_bit = 0;
    reg prev_ws = 1'b0;
    reg signed [23:0] expect_left = 24'sd0;
    reg signed [23:0] expect_right = 24'sd0;
    reg [23:0] captured = 24'd0;
    reg [23:0] slot_expected;
    integer mclk_edges = 0;
    integer bclk_edges = 0;
    integer frame_errors = 0;
    integer last_mclk_cycle = -1;
    integer last_bclk_cycle = -1;

    always @(posedge clk) begin
        core_cycles = core_cycles + 1;
    end

    // Independent rate checks from observed output edges.
    always @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            last_mclk_cycle = -1;
        end else begin
            mclk_edges = mclk_edges + 1;
            if (last_mclk_cycle >= 0 && core_cycles - last_mclk_cycle != 4) begin
                $display("FAIL: mclk rising-edge period %0d core cycles, expected 4", core_cycles-last_mclk_cycle);
                frame_errors = frame_errors + 1;
            end
            last_mclk_cycle = core_cycles;
        end
    end
    always @(posedge bclk or negedge rst_n) begin
        if (!rst_n) begin
            last_bclk_cycle = -1;
        end else begin
            bclk_edges = bclk_edges + 1;
            if (last_bclk_cycle >= 0 && core_cycles - last_bclk_cycle != 16) begin
                $display("FAIL: bclk rising-edge period %0d core cycles, expected 16", core_cycles-last_bclk_cycle);
                frame_errors = frame_errors + 1;
            end
            last_bclk_cycle = core_cycles;
        end
    end

    // External serial receiver: sample only on BCLK rising edges and decode
    // I2S slot layout, including WS delay and all zero padding bits.
    always @(posedge bclk or negedge rst_n) begin
        if (!rst_n) begin
            slot_bit = 0;
            prev_ws = 1'b0;
            captured = 24'd0;
            expect_left = 24'sd0;
            expect_right = 24'sd0;
            last_tick_cycle = -1;
        end else begin
            if (lrclk !== prev_ws) begin
                prev_ws = lrclk;
                slot_bit = 0;
                captured = 24'd0;
            end

            if (slot_bit == 0) begin
                if (sdata !== 1'b0) begin
                    $display("FAIL: I2S delay bit was not zero at cycle %0d", core_cycles);
                    frame_errors = frame_errors + 1;
                end
            end else if (slot_bit <= 24) begin
                captured = {captured[22:0], sdata};
            end else if (sdata !== 1'b0) begin
                $display("FAIL: nonzero padding bit in %s slot bit %0d at cycle %0d",
                         lrclk ? "right" : "left", slot_bit, core_cycles);
                frame_errors = frame_errors + 1;
            end

            if (slot_bit == 31) begin
                slot_expected = lrclk ? expect_right : expect_left;
                if (captured !== slot_expected) begin
                    $display("FAIL: %s sample got %06h expected %06h at cycle %0d",
                             lrclk ? "right" : "left", captured, slot_expected, core_cycles);
                    frame_errors = frame_errors + 1;
                end
                if (lrclk) right_slots = right_slots + 1;
                else left_slots = left_slots + 1;
                slot_bit = 0;
            end else begin
                slot_bit = slot_bit + 1;
            end
        end
    end

    // frame_tick is observed outside the DUT and its period is measured in clk cycles.
    always @(negedge clk) begin
        if (rst_n && frame_tick) begin
            ticks = ticks + 1;
            if (last_tick_cycle >= 0 && core_cycles - last_tick_cycle != 1024) begin
                $display("FAIL: frame_tick period %0d core cycles, expected 1024",
                         core_cycles - last_tick_cycle);
                frame_errors = frame_errors + 1;
            end
            last_tick_cycle = core_cycles;
            expect_left = sample_left;
            expect_right = sample_right;
        end
    end

    task wait_ticks;
        input integer target;
        begin
            while (ticks < target) @(negedge clk);
        end
    endtask

    initial begin
        #1 rst_n = 1'b0;
        #1;
        if (mclk !== 1'b0 || bclk !== 1'b0 || lrclk !== 1'b0 || sdata !== 1'b0 || frame_tick !== 1'b0)
            $fatal(1, "FAIL: reset outputs are not at the defined zero phase");
        repeat (7) @(negedge clk);
        rst_n = 1'b1;

        // Distinct signed patterns exercise MSB/sign handling and changing frames.
        sample_left = -24'sd1193046;
        sample_right = 24'sd6636321;
        wait_ticks(ticks + 2);
        @(negedge clk);
        sample_left = 24'sd5592405;
        sample_right = -24'sd5592406;
        wait_ticks(ticks + 3);

        // Reset partway through a slot; receiver and serializer must restart cleanly.
        repeat (173) @(negedge clk);
        rst_n = 1'b0;
        sample_left = -24'sd74565;
        sample_right = 24'sd11259375;
        repeat (9) @(negedge clk);
        rst_n = 1'b1;
        wait_ticks(ticks + 2);
        @(negedge clk);
        sample_left = 24'sd32767;
        sample_right = -24'sd32768;
        wait_ticks(ticks + 3);

        if (mclk_edges < 100 || bclk_edges < 20) begin
            $display("FAIL: output clocks did not run (mclk=%0d bclk=%0d)", mclk_edges, bclk_edges);
            frame_errors = frame_errors + 1;
        end
        if (left_slots < 8 || right_slots < 8) begin
            $display("FAIL: insufficient externally decoded slots (left=%0d right=%0d)", left_slots, right_slots);
            frame_errors = frame_errors + 1;
        end
        if (frame_errors != 0) begin
            $display("FAIL: %0d errors; ticks=%0d slots L/R=%0d/%0d", frame_errors, ticks, left_slots, right_slots);
            $fatal(1);
        end
        $display("PASS: ticks=%0d, decoded slots L/R=%0d/%0d, mclk edges=%0d, bclk edges=%0d",
                 ticks, left_slots, right_slots, mclk_edges, bclk_edges);
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "FAIL: simulation timeout");
    end
endmodule
