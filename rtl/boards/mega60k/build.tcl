set_device -device_version B GW5AT-LV60PG484AC1/I0
add_file additive_core.v
add_file echo_effect.v
add_file usb_midi_packet.v
add_file usb_midi_config_parser.v
add_file usb_attach_monitor.v
add_file ws2812_status.v
add_file button_conditioner.v
add_file pt8211_tx.v
add_file i2s_tx.v
add_file uart_rx.v
add_file uart_tx.v
add_file midi_control.v
add_file mega60k_audio_top.v
add_file audio.cst
add_file audio.sdc
set_option -top_module mega60k_audio_top
set_option -output_base_name mega60k_audio
set_option -verilog_std v2001
# Release package CPU-function pins for GPIO. This does not instantiate a CPU.
set_option -use_cpu_as_gpio 1
set_option -gen_text_timing_rpt 1
run all
exit
