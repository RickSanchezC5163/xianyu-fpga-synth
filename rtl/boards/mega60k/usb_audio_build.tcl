set_device -device_version B GW5AT-LV60PG484AC1/I0
foreach source {
    additive_core.v echo_effect.v usb_midi_packet.v usb_midi_config_parser.v
    smk25_event_decoder.v
    usb_attach_monitor.v ws2812_status.v button_conditioner.v
    pt8211_tx.v i2s_tx.v uart_rx.v uart_tx.v midi_control.v
    usb_hid_host.v usb_hid_host_rom.v pll_60.v usb_midi_event_cdc.v
    mega60k_audio_top.v mega60k_usb_audio_top.v audio.cst usb_audio.sdc
} { add_file $source }
set_option -top_module mega60k_usb_audio_top
set_option -output_base_name mega60k_usb_audio
set_option -verilog_std v2001
set_option -use_cpu_as_gpio 1
set_option -gen_text_timing_rpt 1
run all
exit
