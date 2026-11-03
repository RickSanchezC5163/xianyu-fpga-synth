create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]
set_false_path -from [get_ports {rst_n key0_n key1_n uart_rx usb_dp usb_dm}]
create_generated_clock -name usb_clk -source [get_ports {sys_clk}] -master_clock sys_clk -divide_by 5 -multiply_by 6 [get_pins {audio/direct_usb.pll/PLLA_inst/CLKOUT0}]
set_false_path -from [get_clocks {usb_clk}] -to [get_clocks {sys_clk}]
# Only the asynchronous input to the UART's first synchronizer stage is exempt.
set_false_path -from [get_ports {screen_rx}] -to [get_pins {audio/screen/receiver/rx_meta_s0/D}]
set_output_delay -clock sys_clk -max 0.000 [get_ports {hp_bck hp_ws hp_din ext_mclk ext_bck ext_lrclk ext_din uart_tx screen_tx debug_control debug_pcm rgb_din}]
set_output_delay -clock sys_clk -min 0.000 [get_ports {hp_bck hp_ws hp_din ext_mclk ext_bck ext_lrclk ext_din uart_tx screen_tx debug_control debug_pcm rgb_din}]
set_false_path -to [get_ports {status_led* pa_en}]
