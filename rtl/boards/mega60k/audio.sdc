create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]
# Buttons are asynchronous; synchronizers/qualification are verified separately.
set_false_path -from [get_ports {rst_n key0_n key1_n uart_rx usb_dp usb_dm}]
# All three DAC pins are registered DATA outputs of sys_clk, not internal clocks.
# Budget each output path to finish within one 20ns sys_clk period.
# The serializer proves DIN/WS only change on falling BCK, 16 sys_clk cycles
# (320ns) before the next sampling rise. Thus pin delay spread <=20ns leaves
# >=300ns nominal setup/hold before additional PCB skew (to be measured).
# This synthetic 50MHz endpoint is a conservative output-delay budget, NOT
# a claim that the PT8211 samples at 50MHz or a guessed datasheet setup time.
set_output_delay -clock sys_clk -max 0.000 [get_ports {hp_bck hp_ws hp_din ext_mclk ext_bck ext_lrclk ext_din}]
set_output_delay -clock sys_clk -min 0.000 [get_ports {hp_bck hp_ws hp_din ext_mclk ext_bck ext_lrclk ext_din}]
# UART TX is registered at sys_clk; the PC samples in the middle of each bit.
set_output_delay -clock sys_clk -max 0.000 [get_ports {uart_tx}]
set_output_delay -clock sys_clk -min 0.000 [get_ports {uart_tx}]
set_false_path -to [get_ports {status_led* pa_en rgb_din}]
