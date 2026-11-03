// Optional Wi-Fi score upload candidate. Compile INSTRUMENT_UI SERIAL_UI WIFI_SCORE.
// Reuses the existing USB/audio, TJC and LED engine; only a separate UART is added.
module mega60k_tjc_wifi_top #(
    parameter integer ENABLE_USB_HOST=1,
    parameter integer LOW_VELOCITY_PROFILE=0,
    parameter integer STARTUP_CYCLES=5000000,
    parameter integer WIFI_UART_CLKS_PER_BIT=434,
    parameter integer UI_SCREEN_FAST=1,
    parameter integer UI_LED_EXTERNAL_PIXELS=100,UI_LED_PREFIX_PIXELS=1,
    parameter integer UI_LED_BEAT_PIXEL=30,UI_LED_RANGE_PIXEL=31,
    parameter [199:0] UI_LED_KEY_MAP=200'h1d1b1a1918171615131211100f0d0c0b0a0908070504030201
)(
    input wire sys_clk,rst_n,key0_n,key1_n,uart_rx,
    output wire uart_tx,inout wire usb_dp,usb_dm,
    output wire hp_bck,hp_ws,hp_din,ext_mclk,ext_bck,ext_lrclk,ext_din,
    output wire pa_en,output wire [1:0] status_led,output wire rgb_din,
    input wire screen_rx,output wire screen_tx,
    input wire wifi_rx,output wire wifi_tx,
    output wire debug_control,debug_pcm
);
    mega60k_audio_top #(.ENABLE_USB_HOST(ENABLE_USB_HOST),.LOW_VELOCITY_PROFILE(LOW_VELOCITY_PROFILE),
        .STARTUP_CYCLES(STARTUP_CYCLES),.UI_ENABLE_DISPLAY(0),.MIDI_QUEUE_BSRAM(1),.UI_SCREEN_FAST(UI_SCREEN_FAST),
        .WIFI_UART_CLKS_PER_BIT(WIFI_UART_CLKS_PER_BIT),.UI_LED_EXTERNAL_PIXELS(UI_LED_EXTERNAL_PIXELS),
        .UI_LED_BEAT_PIXEL(UI_LED_BEAT_PIXEL),.UI_LED_RANGE_PIXEL(UI_LED_RANGE_PIXEL),.UI_LED_PREFIX_PIXELS(UI_LED_PREFIX_PIXELS),.UI_LED_KEY_MAP(UI_LED_KEY_MAP)) audio(
        .sys_clk(sys_clk),.rst_n(rst_n),.key0_n(key0_n),.key1_n(key1_n),
        .uart_rx(uart_rx),.uart_tx(uart_tx),.usb_dp(usb_dp),.usb_dm(usb_dm),
        .hp_bck(hp_bck),.hp_ws(hp_ws),.hp_din(hp_din),.ext_mclk(ext_mclk),
        .ext_bck(ext_bck),.ext_lrclk(ext_lrclk),.ext_din(ext_din),
        .pa_en(pa_en),.status_led(status_led),.rgb_din(rgb_din),
        .touch_irq_n(1'b1),.lcd_miso(1'b0),.screen_rx(screen_rx),.screen_tx(screen_tx),
        .wifi_rx(wifi_rx),.wifi_tx(wifi_tx),.debug_control(debug_control),.debug_pcm(debug_pcm));
endmodule
