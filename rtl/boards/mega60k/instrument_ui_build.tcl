# Local synthesis / place-and-route only. No Programmer commands.
set_device -device_version B GW5AT-LV60PG484AC1/I0
foreach source [glob *.v] { add_file $source }
add_file instrument_ui.cst
add_file instrument_ui.sdc
set_option -top_module mega60k_instrument_top
set_option -output_base_name mega60k_instrument
set_option -verilog_std v2001
# Gowin1.9.12.03 has no -verilog_define option. The snapshot runner prepends
# `define INSTRUMENT_UI to copied Verilog compilation units, hashes both forms.
set_option -use_cpu_as_gpio 1
set_option -gen_text_timing_rpt 1
run all
exit
