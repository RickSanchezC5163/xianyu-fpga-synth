// Full USB host + 32-voice audio + local LCD/touch/guide build.
// INSTRUMENT_UI is enabled by the dedicated build snapshot, never by a board
// programming command. Existing UART and USB audio tops retain their pinouts.
module mega60k_instrument_top #(
    parameter integer ENABLE_USB_HOST=1,
    parameter integer LOW_VELOCITY_PROFILE=0,
    parameter integer STARTUP_CYCLES=5000000,
    parameter integer UI_LCD_RESET_LOW_CYCLES=500000,
    parameter integer UI_LCD_RESET_WAIT_CYCLES=6000000,
    parameter integer UI_LCD_SLEEP_OUT_CYCLES=6000000,
    parameter integer UI_TOUCH_POLL_HZ=100,
    parameter integer UI_TOUCH_SPI_HALF_PERIOD=25
)(
    input wire sys_clk,rst_n,key0_n,key1_n,uart_rx,
    output wire uart_tx,inout wire usb_dp,usb_dm,
    output wire hp_bck,hp_ws,hp_din,ext_mclk,ext_bck,ext_lrclk,ext_din,
    output wire pa_en,output wire [1:0] status_led,output wire rgb_din,
    input wire touch_irq_n,lcd_miso,
    output wire lcd_sck,lcd_mosi,lcd_cs_n,lcd_dc,lcd_reset_n,touch_cs_n,
    output wire debug_control,debug_pcm
);
    mega60k_audio_top #(.ENABLE_USB_HOST(ENABLE_USB_HOST),.LOW_VELOCITY_PROFILE(LOW_VELOCITY_PROFILE),
        .STARTUP_CYCLES(STARTUP_CYCLES),
        .UI_LCD_RESET_LOW_CYCLES(UI_LCD_RESET_LOW_CYCLES),
        .UI_LCD_RESET_WAIT_CYCLES(UI_LCD_RESET_WAIT_CYCLES),
        .UI_LCD_SLEEP_OUT_CYCLES(UI_LCD_SLEEP_OUT_CYCLES),
        .UI_TOUCH_POLL_HZ(UI_TOUCH_POLL_HZ),.UI_TOUCH_SPI_HALF_PERIOD(UI_TOUCH_SPI_HALF_PERIOD)) audio(
        .sys_clk(sys_clk),.rst_n(rst_n),.key0_n(key0_n),.key1_n(key1_n),
        .uart_rx(uart_rx),.uart_tx(uart_tx),.usb_dp(usb_dp),.usb_dm(usb_dm),
        .hp_bck(hp_bck),.hp_ws(hp_ws),.hp_din(hp_din),.ext_mclk(ext_mclk),
        .ext_bck(ext_bck),.ext_lrclk(ext_lrclk),.ext_din(ext_din),
        .pa_en(pa_en),.status_led(status_led),.rgb_din(rgb_din),
        .touch_irq_n(touch_irq_n),.lcd_miso(lcd_miso),.lcd_sck(lcd_sck),.lcd_mosi(lcd_mosi),
        .lcd_cs_n(lcd_cs_n),.lcd_dc(lcd_dc),.lcd_reset_n(lcd_reset_n),.touch_cs_n(touch_cs_n),
        .debug_control(debug_control),.debug_pcm(debug_pcm));
endmodule
