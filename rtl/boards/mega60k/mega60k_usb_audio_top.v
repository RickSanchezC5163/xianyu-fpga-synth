// Direct SMK-25 USB-MIDI variant of the existing 32-voice audio top.
// The FPGA is the USB host and computes every sample; the PC is optional.
module mega60k_usb_audio_top (
    input wire sys_clk,input wire rst_n,input wire key0_n,input wire key1_n,
    input wire uart_rx,output wire uart_tx,
    inout wire usb_dp,inout wire usb_dm,
    output wire hp_bck,output wire hp_ws,output wire hp_din,
    output wire ext_mclk,output wire ext_bck,
    output wire ext_lrclk,output wire ext_din,
    output wire pa_en,output wire [1:0] status_led,
    output wire rgb_din
);
    mega60k_audio_top #(.ENABLE_USB_HOST(1)) audio(
        .sys_clk(sys_clk),.rst_n(rst_n),
        .key0_n(key0_n),.key1_n(key1_n),
        .uart_rx(uart_rx),.uart_tx(uart_tx),
        .usb_dp(usb_dp),.usb_dm(usb_dm),
        .hp_bck(hp_bck),.hp_ws(hp_ws),.hp_din(hp_din),
        .ext_mclk(ext_mclk),.ext_bck(ext_bck),
        .ext_lrclk(ext_lrclk),.ext_din(ext_din),
        .pa_en(pa_en),.status_led(status_led),.rgb_din(rgb_din));
endmodule
