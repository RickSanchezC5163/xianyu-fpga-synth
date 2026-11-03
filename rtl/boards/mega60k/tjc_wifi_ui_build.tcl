# Candidate build only: USB keyboard + real-time audio + TJC + Wi-Fi score loader.
# No Programmer, SRAM or Flash operation.
set_device -device_version B GW5AT-LV60PG484AC1/I0
foreach source [glob *.v] { add_file $source }
add_file tjc_wifi_ui.cst
add_file tjc_wifi_ui.sdc
set_option -top_module mega60k_tjc_wifi_top
set_option -output_base_name mega60k_tjc_wifi
set_option -verilog_std v2001
set_option -use_cpu_as_gpio 1
set_option -gen_text_timing_rpt 1
run all
exit
