// Reuses the existing USB/audio engine and shared FPGA guide/measurement logic.
// Compile with INSTRUMENT_UI and SERIAL_UI. SPI raster/touch path is absent.
module mega60k_tjc_top #(
    parameter integer ENABLE_USB_HOST=1,
    parameter integer LOW_VELOCITY_PROFILE=0,
    parameter integer STARTUP_CYCLES=5000000
)(
    input wire sys_clk,rst_n,key0_n,key1_n,uart_rx,
    output wire uart_tx,inout wire usb_dp,usb_dm,
    output wire hp_bck,hp_ws,hp_din,ext_mclk,ext_bck,ext_lrclk,ext_din,
    output wire pa_en,output wire [1:0] status_led,output wire rgb_din,
    input wire screen_rx,output wire screen_tx,
    output wire debug_control,debug_pcm
);
    mega60k_audio_top #(.ENABLE_USB_HOST(ENABLE_USB_HOST),.LOW_VELOCITY_PROFILE(LOW_VELOCITY_PROFILE),
        .STARTUP_CYCLES(STARTUP_CYCLES),.UI_ENABLE_DISPLAY(0),.MIDI_QUEUE_BSRAM(1)) audio(
        .sys_clk(sys_clk),.rst_n(rst_n),.key0_n(key0_n),.key1_n(key1_n),
        .uart_rx(uart_rx),.uart_tx(uart_tx),.usb_dp(usb_dp),.usb_dm(usb_dm),
        .hp_bck(hp_bck),.hp_ws(hp_ws),.hp_din(hp_din),.ext_mclk(ext_mclk),
        .ext_bck(ext_bck),.ext_lrclk(ext_lrclk),.ext_din(ext_din),
        .pa_en(pa_en),.status_led(status_led),.rgb_din(rgb_din),
        .touch_irq_n(1'b1),.lcd_miso(1'b0),.screen_rx(screen_rx),.screen_tx(screen_tx),
        .debug_control(debug_control),.debug_pcm(debug_pcm));
endmodule
