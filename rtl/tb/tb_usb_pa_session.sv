`timescale 1ns/1ps
module tb_usb_pa_session;
    reg clk=0,rst_n=1;
    wire dp=1'b0,dm=1'b0;
    wire pa_en;
    always #10 clk=~clk;
    mega60k_audio_top #(.STARTUP_CYCLES(10),.DEBOUNCE_CYCLES(8)) dut(
        .sys_clk(clk),.rst_n(rst_n),.key0_n(1'b1),.key1_n(1'b1),
        .uart_rx(1'b1),.uart_tx(),.usb_dp(dp),.usb_dm(dm),
        .hp_bck(),.hp_ws(),.hp_din(),.ext_mclk(),.ext_bck(),
        .ext_lrclk(),.ext_din(),.pa_en(pa_en),.status_led(),.rgb_din());
    initial begin
        repeat(5) @(negedge clk);rst_n=0;
        repeat(5) @(negedge clk);rst_n=1;
        force dut.por=16'hffff;
        force dut.usb_audio_connected=1'b1;
        repeat(25) @(negedge clk);
        if(dut.host_gates!=0 || !dut.host_playing || pa_en!=0)
            $fatal(1,"USB amplifier must be enabled before first note: gates=%h playing=%b pa=%b ready=%b connected=%b",dut.host_gates,dut.host_playing,pa_en,dut.ready,dut.usb_audio_connected);
        repeat(3000) @(negedge clk);
        if(pa_en!=0) $fatal(1,"USB amplifier must stay enabled during rests");
        force dut.usb_audio_connected=1'b0;
        repeat(3000) @(negedge clk);
        if(pa_en!=1) $fatal(1,"USB amplifier must disable on disconnect");
        $display("PASS amplifier stays on between direct USB notes");$finish;
    end
endmodule
