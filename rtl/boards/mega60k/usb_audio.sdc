create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]
set_false_path -from [get_ports {rst_n key0_n key1_n uart_rx usb_dp usb_dm}]
# The 60 MHz USB domain crosses to 50 MHz only in usb_midi_event_cdc:
# a two-flop toggle/connection synchronizer plus payload held for the whole
# event interval (at least four full-speed USB bytes). These paths are not
# synchronous 3.333 ns paths and must be validated by CDC simulation and
# hardware event tests, not synchronous STA.
create_generated_clock -name usb_clk -source [get_ports {sys_clk}] -master_clock sys_clk -divide_by 5 -multiply_by 6 [get_pins {audio/direct_usb.pll/PLLA_inst/CLKOUT0}]
set_false_path -from [get_clocks {usb_clk}] -to [get_clocks {sys_clk}]
set_output_delay -clock sys_clk -max 0.000 [get_ports {hp_bck hp_ws hp_din ext_mclk ext_bck ext_lrclk ext_din}]
set_output_delay -clock sys_clk -min 0.000 [get_ports {hp_bck hp_ws hp_din ext_mclk ext_bck ext_lrclk ext_din}]
set_output_delay -clock sys_clk -max 0.000 [get_ports {uart_tx}]
set_output_delay -clock sys_clk -min 0.000 [get_ports {uart_tx}]
set_false_path -to [get_ports {status_led* pa_en rgb_din}]
