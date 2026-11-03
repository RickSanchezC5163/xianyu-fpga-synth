`timescale 1ns/1ps

module tb_mega60k_audio;
    reg sys_clk = 1'b0;
    reg rst_n = 1'b1;
    reg key0_n = 1'b1;
    reg key1_n = 1'b1;
    wire hp_bck, hp_ws, hp_din, pa_en;
    wire usb_dp=1'b0,usb_dm=1'b0;
    wire [1:0] status_led;

    mega60k_audio_top #(.STARTUP_CYCLES(100), .DEBOUNCE_CYCLES(8)) dut (
        .sys_clk(sys_clk), .rst_n(rst_n), .key0_n(key0_n), .key1_n(key1_n),
        .uart_rx(1'b1), .uart_tx(), .usb_dp(usb_dp), .usb_dm(usb_dm),
        .hp_bck(hp_bck), .hp_ws(hp_ws), .hp_din(hp_din),
        .pa_en(pa_en), .status_led(status_led)
    );
    always #10 sys_clk = ~sys_clk;

    integer cycles = 0;
    integer last_bclk_cycle = -1;
    integer bclk_edges = 0;
    integer bit_index = 0;
    integer right_slots = 0;
    integer left_slots = 0;
    integer decode_errors = 0;
    integer active_nonzero_slots = 0;
    integer post_release_nonzero_slots = 0;
    integer post_release_zero_slots = 0;
    integer post_reset_nonzero_slots = 0;
    reg last_ws = 1'b1;
    reg [15:0] serial_word = 16'd0;
    reg [15:0] last_right = 16'd0;
    reg have_right = 1'b0;
    reg saw_audio = 1'b0;

    always @(posedge sys_clk) cycles = cycles + 1;

    // Pin-level receiver: decode the actual PT8211 bus at BCLK rising edges.
    always @(posedge hp_bck or negedge rst_n) begin
        if (!rst_n) begin
            bit_index = 0;
            last_ws = 1'b1;
            serial_word = 16'd0;
            last_right = 16'd0;
            have_right = 1'b0;
            last_bclk_cycle = -1;
            post_reset_nonzero_slots = 0;
        end else begin
            bclk_edges = bclk_edges + 1;
            if (last_bclk_cycle >= 0 && cycles-last_bclk_cycle != 32) begin
                $display("FAIL: top BCLK edge period %0d sys_clk cycles, expected 32", cycles-last_bclk_cycle);
                decode_errors = decode_errors + 1;
            end
            last_bclk_cycle = cycles;

            if (hp_ws !== last_ws) begin
                last_ws = hp_ws;
                bit_index = 0;
                serial_word = 16'd0;
            end
            serial_word = {serial_word[14:0], hp_din};
            if (bit_index == 15) begin
                if (hp_ws == 1'b0) begin
                    last_right = serial_word;
                    have_right = 1'b1;
                    right_slots = right_slots + 1;
                end else begin
                    left_slots = left_slots + 1;
                    if (have_right && serial_word !== last_right) begin
                        $display("FAIL: mono top channels differ: R=%04h L=%04h at cycle %0d", last_right,serial_word,cycles);
                        decode_errors = decode_errors + 1;
                    end
                end
                if (serial_word !== 16'd0) begin
                    saw_audio = 1'b1;
                    post_reset_nonzero_slots = post_reset_nonzero_slots + 1;
                    if (dut.play_pressed) active_nonzero_slots = active_nonzero_slots + 1;
                    else if (saw_audio) post_release_nonzero_slots = post_release_nonzero_slots + 1;
                end else if (saw_audio && !dut.play_pressed) begin
                    post_release_zero_slots = post_release_zero_slots + 1;
                end
                bit_index = 0;
            end else bit_index = bit_index + 1;
        end
    end

    task wait_for_play_state(input reg expected);
        integer timeout;
        begin
            timeout = 0;
            while (dut.play_pressed !== expected && timeout < 100) begin
                @(negedge sys_clk); timeout = timeout + 1;
            end
            if (dut.play_pressed !== expected) $fatal(1, "FAIL: KEY1 state did not become %b", expected);
        end
    endtask

    task press_key0;
        begin
            key0_n = 1'b0;
            repeat (16) @(negedge sys_clk);
            key0_n = 1'b1;
            repeat (8) @(negedge sys_clk);
        end
    endtask

    initial begin
        // Force a real reset edge, then let the always-on 16-bit POR expire.
        #1 rst_n = 1'b0;
        repeat (5) @(negedge sys_clk);
        rst_n = 1'b1;
        wait (dut.ready === 1'b1);
        @(negedge sys_clk);
        if (pa_en !== 1'b1) $fatal(1, "FAIL: idle amplifier should stay shut down");
        repeat (2200) @(negedge sys_clk);
        if (saw_audio || status_led[1] !== 1'b0) $fatal(1, "FAIL: startup emitted audio or overrun");

        // Short low pulses are button bounce, below the configured debounce interval.
        repeat (3) begin
            key1_n = 1'b0; repeat (2) @(negedge sys_clk);
            key1_n = 1'b1; repeat (3) @(negedge sys_clk);
        end
        repeat (20) @(negedge sys_clk);
        if (dut.play_pressed !== 1'b0) $fatal(1, "FAIL: KEY1 bounce registered as a press");

        key1_n = 1'b0;
        wait_for_play_state(1'b1);
        // A mode toggle during a held note must be ignored.
        press_key0();
        if (status_led[0] !== 1'b0) $fatal(1, "FAIL: mode changed while KEY1 was held");
        while (active_nonzero_slots < 4) @(negedge sys_clk);
        if(pa_en !== 1'b0) $fatal(1,"FAIL: amplifier did not enable for manual note");
        repeat (1800) @(negedge sys_clk);
        key1_n = 1'b1;
        wait_for_play_state(1'b0);

        // A selection press during the release tail is also ignored.
        press_key0();
        if (status_led[0] !== 1'b0) $fatal(1, "FAIL: mode changed before silence");
        while (dut.quiet_count != 12'd1400) @(negedge sys_clk);
        wait(dut.gain==0);
        @(negedge sys_clk);
        if(pa_en !== 1'b1) $fatal(1,"FAIL: idle amplifier did not shut down after release");
        if (post_release_nonzero_slots == 0 || post_release_zero_slots == 0)
            $fatal(1, "FAIL: release tail was not observed through pins (nonzero=%0d zero=%0d)",
                   post_release_nonzero_slots, post_release_zero_slots);
        if (status_led[0] !== 1'b0) $fatal(1, "FAIL: bell mode changed before the 1400-frame quiet period");
        if (status_led[1] !== 1'b0) $fatal(1, "FAIL: synthesis overrun flag asserted");

        press_key0();
        if (status_led[0] !== 1'b1) $fatal(1, "FAIL: KEY0 did not toggle bell after 1400 quiet frames");

        // Reset mutes serial pins, disables the shared amplifier, and clears mode.
        rst_n = 1'b0;
        #1;
        if (pa_en !== 1'b1 || hp_bck !== 1'b0 || hp_ws !== 1'b1 || hp_din !== 1'b0)
            $fatal(1, "FAIL: reset did not mute the board outputs");
        repeat (5) @(negedge sys_clk);
        rst_n = 1'b1;
        wait (dut.ready === 1'b1);
        @(negedge sys_clk);
        repeat (2200) @(negedge sys_clk);
        if (pa_en !== 1'b1 || status_led[0] !== 1'b0 || post_reset_nonzero_slots != 0)
            $fatal(1, "FAIL: reset recovery was not muted (pa_en=%b bell=%b audio_slots=%0d)",
                   pa_en,status_led[0],post_reset_nonzero_slots);
        if (decode_errors != 0) $fatal(1, "FAIL: %0d pin-decoder or BCLK errors", decode_errors);
        if (right_slots < 10 || left_slots < 10 || bclk_edges < 300)
            $fatal(1, "FAIL: insufficient pin decode coverage slots R/L=%0d/%0d bclk=%0d",right_slots,left_slots,bclk_edges);
        $display("PASS: top decoded %0d right/%0d left slots, active audio slots=%0d, release nonzero/zero=%0d/%0d",
                 right_slots,left_slots,active_nonzero_slots,post_release_nonzero_slots,post_release_zero_slots);
        $finish;
    end

    initial begin
        #200000000;
        $fatal(1, "FAIL: audio top simulation timeout");
    end
endmodule
