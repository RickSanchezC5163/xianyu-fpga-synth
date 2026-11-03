// NEO Dock: manual KEY0/KEY1 fallback, or timestamped UART MIDI control.
// All audio samples are generated in FPGA logic and sent to the PT8211 DAC.
module mega60k_audio_top #(
    parameter integer STARTUP_CYCLES=5000000,
    parameter integer DEBOUNCE_CYCLES=100000,
    parameter integer UART_CLKS_PER_BIT=434,
    parameter integer ENABLE_USB_HOST=0,
    parameter integer LOW_VELOCITY_PROFILE=0,
    parameter integer UI_LCD_RESET_LOW_CYCLES=500000,
    parameter integer UI_LCD_RESET_WAIT_CYCLES=6000000,
    parameter integer UI_LCD_SLEEP_OUT_CYCLES=6000000,
    parameter integer UI_TOUCH_POLL_HZ=100,
    parameter integer UI_TOUCH_SPI_HALF_PERIOD=25,
    parameter integer UI_ENABLE_DISPLAY=1,
    parameter integer MIDI_QUEUE_BSRAM=0,
    parameter integer UI_SCREEN_FAST=0,
    parameter integer GUIDE_KEY_LONG_SAMPLES=39063,PRACTICE_CHANNEL=0,
    parameter integer UI_LED_EXTERNAL_PIXELS=40,UI_LED_PREFIX_PIXELS=1,
    parameter integer UI_LED_BEAT_PIXEL=0,UI_LED_RANGE_PIXEL=UI_LED_EXTERNAL_PIXELS-1,
    parameter [199:0] UI_LED_KEY_MAP={8'd38,8'd35,8'd34,8'd32,8'd31,8'd30,8'd29,
        8'd27,8'd25,8'd23,8'd22,8'd21,8'd19,8'd17,8'd16,8'd14,8'd13,
        8'd12,8'd10,8'd9,8'd6,8'd5,8'd4,8'd3,8'd1}
`ifdef WIFI_SCORE
    ,parameter integer WIFI_UART_CLKS_PER_BIT=434
`endif
) (
    input wire sys_clk,input wire rst_n,input wire key0_n,input wire key1_n,
    input wire uart_rx,output wire uart_tx,
    inout wire usb_dp,inout wire usb_dm,
    output wire hp_bck,output wire hp_ws,output wire hp_din,
    output wire ext_mclk,output wire ext_bck,
    output wire ext_lrclk,output wire ext_din,
    output wire pa_en,output wire [1:0] status_led,
    output wire rgb_din
`ifdef INSTRUMENT_UI
    ,input wire touch_irq_n,input wire lcd_miso,
    output wire lcd_sck,output wire lcd_mosi,
    output wire lcd_cs_n,output wire lcd_dc,output wire lcd_reset_n,
    output wire touch_cs_n,output wire debug_control,output wire debug_pcm
`endif
`ifdef SERIAL_UI
    ,input wire screen_rx,output wire screen_tx
`endif
`ifdef WIFI_SCORE
    ,input wire wifi_rx,output wire wifi_tx
`endif
);
    // FPGA power-up initialization plus asynchronously asserted/synchronously released reset.
    reg [15:0] por=0;
    always @(posedge sys_clk) if(!(&por)) por<=por+16'd1;
    wire reset_request_n=rst_n && (&por);
    reg [1:0] reset_sync=0;
    always @(posedge sys_clk or negedge reset_request_n)
        if(!reset_request_n) reset_sync<=0; else reset_sync<={reset_sync[0],1'b1};
    wire core_reset_n=reset_sync[1];
    wire select_pressed,select_pulse,play_pressed,play_pulse;
    button_conditioner #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)) select_key
        (sys_clk,core_reset_n,key0_n,select_pressed,select_pulse);
    button_conditioner #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)) play_key
        (sys_clk,core_reset_n,key1_n,play_pressed,play_pulse);
    reg bell=0;
    reg [31:0] startup_count=0;
    reg ready=0;
    reg [11:0] quiet_count=0;
    reg manual_seen_play=0;
    wire frame_tick;
    // Mode changes wait until the maximum release tail is finished (1366 frames).
    always @(posedge sys_clk or negedge core_reset_n) begin
        if(!core_reset_n) begin bell<=0;startup_count<=0;ready<=0;quiet_count<=0;manual_seen_play<=0;end
        else begin
            if(!ready) begin
                if(startup_count==STARTUP_CYCLES-1) ready<=1;
                else startup_count<=startup_count+32'd1;
            end
            if(play_pressed) begin quiet_count<=0;manual_seen_play<=1;end
            else if(frame_tick && quiet_count<12'd1400) quiet_count<=quiet_count+12'd1;
            if(select_pulse && !play_pressed && quiet_count==12'd1400) bell<=!bell;
        end
    end
    wire host_mode,host_playing,host_paused,host_bell,host_tick;
    wire usb_audio_connected,usb_note_valid,usb_mod_valid,usb_bend_valid;
    wire [6:0] usb_note,usb_velocity,usb_mod_depth;
    wire [3:0] usb_channel;
    wire [13:0] usb_bend_word;
    wire knob_a_valid,knob_b_valid,pad_b_valid;
    wire [2:0] knob_a_index,knob_b_index;
    wire [6:0] knob_a_value,knob_b_value,pad_b_note;
    wire usb_play,usb_stop,usb_record;
    wire ui_param_valid,ui_param_ack,ui_param_rejected;
    wire [3:0] ui_param_id;
    wire [15:0] ui_param_value;
    wire [27:0] register_adsr;
    wire [1:0] configured_patch;
    wire note_on_accepted;
    wire direct_packet_valid;
    wire [31:0] direct_packet;
    wire [31:0] screen_rx_counts,screen_crc_errors,screen_format_errors;
    wire screen_transfer_fault;
    reg [15:0] usb_packet_count;
    reg [14:0] usb_note_count;
    reg [31:0] last_usb_packet;
    always @(posedge sys_clk or negedge core_reset_n)
        if(!core_reset_n) begin usb_packet_count<=0;usb_note_count<=0;last_usb_packet<=0;end
        else begin
            if(direct_packet_valid) begin
                usb_packet_count<=usb_packet_count+1'b1;
                last_usb_packet<=direct_packet;
            end
            if(usb_note_valid) usb_note_count<=usb_note_count+1'b1;
        end
`ifndef SERIAL_UI
    assign screen_rx_counts=0;
    assign screen_crc_errors=0;
    assign screen_format_errors=0;
    assign screen_transfer_fault=0;
`endif
    reg usb_connected_prev;
    always @(posedge sys_clk or negedge core_reset_n)
        if(!core_reset_n) usb_connected_prev<=0;
        else usb_connected_prev<=usb_audio_connected;
    wire ui_patch_write=ui_param_valid && ui_param_id==0 && ui_param_value<=3 &&
        ready && host_mode && !(usb_connected_prev && !usb_audio_connected);
    reg [1:0] usb_patch=0;
    always @(posedge sys_clk or negedge core_reset_n)
        if(!core_reset_n) usb_patch<=0;
        else if(usb_audio_connected) begin
            if(select_pulse) usb_patch<=usb_patch+2'd1;
            if(knob_a_valid && knob_a_index==0) usb_patch<=knob_a_value[6:5];
            if(knob_b_valid && knob_b_index==7) usb_patch<=knob_b_value[6:5];
            if(pad_b_valid) begin
                if(pad_b_note<=7'd3) usb_patch<=pad_b_note[1:0];
                else if(pad_b_note==7'd91) usb_patch<=usb_patch-2'd1;
                else if(pad_b_note==7'd92) usb_patch<=usb_patch+2'd1;
            end
            if(ui_patch_write) usb_patch<=ui_param_value[1:0];
        end
    generate if(ENABLE_USB_HOST) begin: direct_usb
        wire usb_clk,pll_lock;
        pll_60 pll(.clkout0(usb_clk),.lock(pll_lock),.clkin(sys_clk));
        reg [2:0] usb_reset_sync=0;
        always @(posedge usb_clk or negedge core_reset_n)
            if(!core_reset_n) usb_reset_sync<=0;
            else usb_reset_sync<={usb_reset_sync[1:0],pll_lock};
        wire usb_reset=!usb_reset_sync[2];
        wire dp_out,dm_out,output_enable;
        assign usb_dp=output_enable ? dp_out : 1'bz;
        assign usb_dm=output_enable ? dm_out : 1'bz;
        wire connected,packet_start,byte_valid;
        wire [7:0] usb_byte;
        wire [9:0] rom_address;
        wire [3:0] rom_data;
        wire rom_enable;
        usb_hid_host #(.FULL_SPEED(1),.KEYBOARD_SUPPORT(0),
                       .MOUSE_SUPPORT(0),.GAME_SUPPORT(1)) host(
            .clk(usb_clk),.reset(usb_reset),.cs(1'b1),
            .usb_dm_i(usb_dm),.usb_dp_i(usb_dp),
            .usb_dm_o(dm_out),.usb_dp_o(dp_out),.usb_oe(output_enable),
            .midi_connected(connected),.midi_packet_start(packet_start),
            .midi_byte_valid(byte_valid),.midi_byte(usb_byte),
            .rom_addr(rom_address),.rom_dout(rom_data),.rom_en(rom_enable));
        usb_hid_host_rom rom(usb_clk,rom_address,rom_data,rom_enable);
        usb_midi_event_cdc bridge(
            .usb_clk(usb_clk),.usb_rst_n(!usb_reset),
            .audio_clk(sys_clk),.audio_rst_n(core_reset_n),
            .connected(connected),.packet_start(packet_start),
            .byte_valid(byte_valid),.byte_data(usb_byte),
            .audio_connected(usb_audio_connected),
            .packet_valid(direct_packet_valid),.packet(direct_packet));
        smk25_event_decoder decoder(
            .clk(sys_clk),.rst_n(core_reset_n),
            .packet_valid(direct_packet_valid),.packet(direct_packet),
            .note_valid(usb_note_valid),
            .note(usb_note),.velocity(usb_velocity),
            .channel(usb_channel),.mod_valid(usb_mod_valid),
            .mod_depth(usb_mod_depth),.bend_valid(usb_bend_valid),
            .bend_word(usb_bend_word),
            .knob_a_valid(knob_a_valid),.knob_a_index(knob_a_index),
            .knob_a_value(knob_a_value),
            .knob_b_valid(knob_b_valid),.knob_b_index(knob_b_index),
            .knob_b_value(knob_b_value),
            .pad_b_valid(pad_b_valid),.pad_b_note(pad_b_note),
            .transport_play(usb_play),.transport_stop(usb_stop),
            .transport_record(usb_record));
    end else begin: no_direct_usb
        assign direct_packet_valid=0;assign direct_packet=0;
        assign usb_audio_connected=1'b0;
        assign usb_note_valid=1'b0;assign usb_note=0;
        assign usb_velocity=0;assign usb_channel=0;
        assign usb_mod_valid=0;assign usb_mod_depth=0;
        assign usb_bend_valid=0;assign usb_bend_word=0;
        assign knob_a_valid=0;assign knob_a_index=0;assign knob_a_value=0;
        assign knob_b_valid=0;assign knob_b_index=0;assign knob_b_value=0;
        assign pad_b_valid=0;assign pad_b_note=0;
        assign usb_play=0;assign usb_stop=0;assign usb_record=0;
    end endgenerate
    wire [7:0] host_volume;
    wire [6:0] host_effect_mix,host_effect_feedback;
    wire [63:0] host_adsr;
    wire [31:0] host_gates;
    wire [255:0] host_epochs;
    wire [255:0] selected_epochs=host_mode ? host_epochs : 256'd0;
    wire [63:0] host_voice_patches;
    wire [223:0] host_velocities;
    wire [1023:0] host_frequencies;
    wire [31:0] host_frame;
    wire [6:0] host_queued;
    wire usb_dp_stable,usb_dm_stable;
    usb_attach_monitor usb_monitor(sys_clk,core_reset_n,usb_dp,usb_dm,
                                    usb_dp_stable,usb_dm_stable);
    wire valid,overrun;
    midi_control #(.CLKS_PER_BIT(UART_CLKS_PER_BIT),
               .VOICES(32),.STEAL_ON_FULL(0),.QUEUE_BSRAM(MIDI_QUEUE_BSRAM)
`ifdef SERIAL_UI
               ,.ENABLE_DIAGNOSTICS(1)
`endif
               ) controller(
        .clk(sys_clk),.rst_n(core_reset_n),.rx(uart_rx),.tx(uart_tx),
        .sample_tick(frame_tick),.audio_ready(ready),.audio_overrun(overrun),
        .usb_dp_stable(usb_dp_stable),.usb_dm_stable(usb_dm_stable),
        .usb_connected(usb_audio_connected),
        .usb_note_valid(usb_note_valid),.usb_note(usb_note),
        .usb_velocity(usb_velocity),.usb_channel(usb_channel),
        .usb_patch_select(usb_patch),.usb_mod_valid(usb_mod_valid),
        .usb_mod_depth(usb_mod_depth),.usb_bend_valid(usb_bend_valid),
        .usb_bend_word(usb_bend_word),
        .usb_play(usb_play),.usb_stop(usb_stop),.usb_record(usb_record),
        .usb_knob_a_valid(knob_a_valid),.usb_knob_a_index(knob_a_index),
        .usb_knob_a_value(knob_a_value),
        .usb_knob_b_valid(knob_b_valid),.usb_knob_b_index(knob_b_index),
        .usb_knob_b_value(knob_b_value),
        .usb_pad_b_valid(pad_b_valid),.usb_pad_b_note(pad_b_note),
        .host_mode(host_mode),.playing(host_playing),.paused(host_paused),
        .bell(host_bell),.volume(host_volume),
        .effect_mix(host_effect_mix),.effect_feedback(host_effect_feedback),
        .adsr_values(host_adsr),
        .gates(host_gates),.voice_epochs(host_epochs),
        .voice_patches(host_voice_patches),
        .voice_velocities(host_velocities),
        .frequency_words(host_frequencies),.synth_tick(host_tick),
        .frame_index(host_frame),.queue_count(host_queued),
        .ui_param_valid(ui_param_valid),.ui_param_id(ui_param_id),.ui_param_value(ui_param_value),
        .ui_param_ack(ui_param_ack),.ui_param_rejected(ui_param_rejected),
        .adsr_controls(register_adsr),.configured_patch(configured_patch),
        .note_on_accepted(note_on_accepted),
        // CONTROL_STATUS selector8: bit31 sticky binary-transfer timeout;
        // bits30:16 format-error low15 bits, bits15:0 CRC-error low16 bits.
        .hardware_diagnostics({screen_transfer_fault,screen_format_errors[14:0],screen_crc_errors[15:0],
            screen_rx_counts,last_usb_packet,usb_audio_connected,usb_note_count,usb_packet_count}));
    wire [31:0] gates=host_mode ? host_gates :
        {28'd0,{4{ready && play_pressed}}};
    wire [1023:0] frequencies=host_mode ? host_frequencies :
        {896'd0,32'd43442435,32'd34480283,32'd28994347,32'd23012828};
    wire selected_bell=host_mode ? host_bell : bell;
    wire [63:0] selected_voice_patches=host_mode ? host_voice_patches : {32{1'b0,bell}};
    wire [223:0] selected_velocities=host_mode ? host_velocities : {32{7'd127}};
    wire [63:0] selected_adsr=host_mode ? host_adsr :
        {16'd48,16'd40000,16'd24,16'd512};
    wire signed [23:0] lane_pcm [0:3];
    wire [3:0] lane_valid,lane_overrun;
    genvar lane;
    generate for(lane=0;lane<4;lane=lane+1) begin: synthesis_lane
        additive_core #(.VOICES(8),.OUTPUT_SHIFT(14),
                        .LOW_VELOCITY_PROFILE(LOW_VELOCITY_PROFILE)) synth(
            sys_clk,core_reset_n,host_tick,gates[lane*8 +: 8],selected_epochs[lane*64 +: 64],
            frequencies[lane*256 +: 256],selected_voice_patches[lane*16 +: 16],
            selected_velocities[lane*56 +: 56],selected_adsr,
            lane_pcm[lane],lane_valid[lane],lane_overrun[lane]);
    end endgenerate
    wire signed [25:0] mixed_pcm=
        {{2{lane_pcm[0][23]}},lane_pcm[0]}+
        {{2{lane_pcm[1][23]}},lane_pcm[1]}+
        {{2{lane_pcm[2][23]}},lane_pcm[2]}+
        {{2{lane_pcm[3][23]}},lane_pcm[3]};
    wire signed [23:0] pcm=mixed_pcm>26'sd8388607 ? 24'sh7fffff :
                            mixed_pcm< -26'sd8388608 ? 24'sh800000 : mixed_pcm[23:0];
    assign valid=&lane_valid;
    wire fx_overrun;
    assign overrun=(|lane_overrun) || fx_overrun;
    // One gain step per frame bounds start, pause and stop discontinuities.
    reg [7:0] gain=0;
    wire manual_audible=play_pressed || (manual_seen_play && quiet_count<12'd1400);
    // Leave the amplifier on through MIDI rests; repeatedly enabling the
    // analog NS4263 can create a pop even when the DAC samples are quiet.
    // Keep the analog amplifier enabled for the whole direct USB session.
    // Switching it on for every new key makes a loud startup pop even while
    // the digital sample and gain begin at zero.
    wire audio_active=host_mode ? host_playing : manual_audible;
    wire signed [23:0] effect_pcm;
    wire effect_valid;
    echo_effect echo(sys_clk,core_reset_n,!audio_active && !host_paused && gain==0,valid,pcm,
                     host_mode ? host_effect_mix : 7'd0,
                     host_mode ? host_effect_feedback : 7'd0,
                     effect_pcm,effect_valid,fx_overrun);
    wire [7:0] gain_target=ready && audio_active ?
                           (host_mode ? host_volume : 8'd255) : 8'd0;
    always @(posedge sys_clk or negedge core_reset_n) begin
        if(!core_reset_n) gain<=0;
        else if(frame_tick) begin
            if(gain+9'd4<gain_target) gain<=gain+8'd4;
            else if(gain>gain_target+9'd4) gain<=gain-8'd4;
            else gain<=gain_target;
        end
    end
    wire signed [24:0] scaled=$signed(effect_pcm[23:8])*$signed({1'b0,gain});
    wire signed [15:0] dac_sample=scaled[23:8];
    pt8211_tx dac(sys_clk,core_reset_n,dac_sample,dac_sample,
                  hp_bck,hp_ws,hp_din,frame_tick);
    // Standard 24-bit Philips I2S on PMOD1 for an external DAC. The onboard
    // PT8211 uses a different serial format; no external DAC is fitted yet.
    i2s_tx external_dac(.clk(sys_clk),.rst_n(core_reset_n),
                        .sample_left({dac_sample,8'd0}),
                        .sample_right({dac_sample,8'd0}),
                        .mclk(ext_mclk),.bclk(ext_bck),
                        .lrclk(ext_lrclk),.sdata(ext_din),.frame_tick());
    // NS4263 enable is active low. Keep it off in idle; finish gain fade first.
    assign pa_en=!(core_reset_n && ready &&
                   (usb_audio_connected || audio_active || gain!=0));
    assign status_led={overrun,selected_bell};
    reg [23:0] led_grb;
    always @* begin
        led_grb=24'd0;
        if(|gates) case(selected_voice_patches[1:0])
            2'd0: led_grb=24'h300000; // organ: green
            2'd1: led_grb=24'h080030; // bell: blue
            2'd2: led_grb=24'h103000; // plucked: amber
            default: led_grb=24'h202020; // piano: white
        endcase
    end
`ifdef INSTRUMENT_UI
    wire touch_param_valid;
    wire [3:0] touch_param_id;
    wire [15:0] touch_param_value;
    wire guide_playing,guide_paused,guide_beat_pulse,guide_strong_beat;
    wire screen_slot_select;
    wire [1:0] screen_slot_index;
    reg [1:0] guide_beat_index;
    always @(posedge sys_clk or negedge core_reset_n)
        if(!core_reset_n)guide_beat_index<=0;
        else if(!guide_playing)guide_beat_index<=0;
        else if(guide_beat_pulse)guide_beat_index<=guide_strong_beat?2'd0:guide_beat_index+1'b1;
    wire guide_key_start,guide_key_long;
    guide_mode_button #(.LONG_SAMPLES(GUIDE_KEY_LONG_SAMPLES)) guide_key(
        .clk(sys_clk),.rst_n(core_reset_n),.enable(host_mode),.pressed(play_pressed),
        .sample_tick(frame_tick),.short_release(guide_key_start),.long_press(guide_key_long));
    wire screen_mode_write;
    wire screen_mode_value;
    reg guide_wait_mode=0;
    wire guide_mode_change=guide_key_long || (screen_mode_write && screen_mode_value!=guide_wait_mode);
    always @(posedge sys_clk or negedge core_reset_n)
        if(!core_reset_n)guide_wait_mode<=0;
        else if(screen_mode_write)guide_wait_mode<=screen_mode_value;
        else if(guide_key_long)guide_wait_mode<=!guide_wait_mode;
`ifdef WIFI_SCORE
    wire wifi_active_present,wifi_committed;
    wire [7:0] wifi_active_bpm;
    wire [6:0] wifi_active_base;
    wire [191:0] wifi_active_title;
    wire [4:0] wifi_active_title_len;
    wire [9:0] wifi_active_part,wifi_active_parts;
    wire [3:0] wifi_resident_valid;
    wire [767:0] wifi_resident_titles;
    wire [19:0] wifi_resident_title_lens;
    wire [2:0] wifi_active_slot;
    wire wifi_select_ready,wifi_select_accepted,wifi_select_rejected;
    reg wifi_select_pending;
    reg [1:0] wifi_select_index;
    always @(posedge sys_clk or negedge core_reset_n)
        if(!core_reset_n)begin wifi_select_pending<=0;wifi_select_index<=0;end
        else if(screen_slot_select)begin wifi_select_pending<=1;wifi_select_index<=screen_slot_index;end
        else if(wifi_select_pending && wifi_select_ready)wifi_select_pending<=0;
`else
    wire wifi_active_present=0;
    wire [191:0] wifi_active_title=0;
    wire [4:0] wifi_active_title_len=0;
    wire [9:0] wifi_active_part=0,wifi_active_parts=0;
    wire [3:0] wifi_resident_valid=0;
    wire [767:0] wifi_resident_titles=0;
    wire [19:0] wifi_resident_title_lens=0;
    wire [2:0] wifi_active_slot=0;
`endif
    wire diag_latency_valid,diag_latency_timeout,diag_rejected,diag_window_valid;
    wire [31:0] diag_latency_cycles,diag_latency_max,diag_missed,diag_samples;
`ifdef SERIAL_UI
    wire guide_command;
    wire [2:0] guide_command_id;
    wire [15:0] guide_command_value;
    assign screen_slot_select=guide_command && guide_command_id==6 && guide_command_value<4;
    assign screen_slot_index=guide_command_value[1:0];
    assign screen_mode_write=guide_command && guide_command_id==7 && guide_command_value<=1;
    assign screen_mode_value=guide_command_value[0];
    reg [7:0] guide_bpm=60;
    reg guide_loop=1;
    always @(posedge sys_clk or negedge core_reset_n)
        if(!core_reset_n) begin guide_bpm<=60;guide_loop<=1;end
        else begin
`ifdef WIFI_SCORE
            if(wifi_committed)guide_bpm<=wifi_active_bpm;
`endif
            if(guide_command)begin
                if(guide_command_id==4) guide_loop<=guide_command_value[0];
                if(guide_command_id==5) guide_bpm<=guide_command_value[7:0];
            end
        end
    wire screen_guide_start=guide_command && guide_command_id==0 && !guide_playing;
    wire screen_guide_stop=guide_command && guide_command_id==1;
    wire screen_guide_pause=guide_command && ((guide_command_id==2 && guide_playing && !guide_paused) ||
        (guide_command_id==3 && guide_playing && guide_paused));
    tjc_uart_panel #(.TELEMETRY_ENABLE(1),.AUTO_FAST_BAUD(UI_SCREEN_FAST),.ENV_PLOT_ENABLE(UI_SCREEN_FAST),
        .SCORE_METADATA_ENABLE(UI_SCREEN_FAST),.NATIVE_SLOTS_ENABLE(UI_SCREEN_FAST)) screen(.clk(sys_clk),.rst_n(core_reset_n),.screen_rx(screen_rx),.screen_tx(screen_tx),
        .context_ready(ready),.urgent_stop(usb_stop|(usb_connected_prev&&!usb_audio_connected)),.score_count(8'd4),
        .param_valid(ui_param_valid),.param_id(ui_param_id),.param_value(ui_param_value),
        .param_ack(ui_param_ack),.param_rejected(ui_param_rejected),
        .register_patch(host_mode ? (usb_audio_connected ? usb_patch : configured_patch) : {1'b0,bell}),
        .register_volume(host_mode ? host_volume : 8'd255),
        .register_adsr(host_mode ? register_adsr : {7'd11,7'd75,7'd4,7'd28}),
        .guide_valid(guide_command),.guide_id(guide_command_id),.guide_value(guide_command_value),
        .guide_playing(guide_playing),.guide_paused(guide_paused),.guide_loop(guide_loop),.guide_bpm(guide_bpm),
        .crc_errors(screen_crc_errors),.format_errors(screen_format_errors),.debug_rx_counts(screen_rx_counts),
        .display_transfer_fault(screen_transfer_fault),
        .sample_valid(frame_tick),.sample_pcm(dac_sample),.control_note_on(note_on_accepted),
        .latency_valid(diag_latency_valid),.latency_timeout(diag_latency_timeout),.latency_rejected(diag_rejected),
        .latency_cycles(diag_latency_cycles),.latency_max_cycles(diag_latency_max),
        .missed_deadline_count(diag_missed),.window_valid(diag_window_valid),.samples_in_window(diag_samples),
        .score_active_present(wifi_active_present),.score_title(wifi_active_title),
        .score_title_len(wifi_active_title_len),.score_part(wifi_active_part),.score_parts(wifi_active_parts),
        .resident_valid(wifi_resident_valid),.resident_titles(wifi_resident_titles),
        .resident_title_lens(wifi_resident_title_lens),.active_slot(wifi_active_slot),.guide_beat_index(guide_beat_index));
`else
    assign screen_mode_write=0;assign screen_mode_value=0;
    assign screen_slot_select=0;assign screen_slot_index=0;
    wire screen_guide_start=0,screen_guide_stop=0,screen_guide_pause=0;
    wire guide_loop=1;
    wire [7:0] guide_bpm=60;
    assign ui_param_valid=touch_param_valid;
    assign ui_param_id=touch_param_id;
    assign ui_param_value=touch_param_value;
`endif
    // MISO is asynchronous to sys_clk. Only the first stage receives the pin;
    // the 1 MHz touch clock leaves a 500 ns half period for the 40 ns pipeline.
    reg lcd_miso_meta,lcd_miso_sync;
    always @(posedge sys_clk or negedge core_reset_n)
        if(!core_reset_n) begin lcd_miso_meta<=0;lcd_miso_sync<=0;end
        else begin lcd_miso_meta<=lcd_miso;lcd_miso_sync<=lcd_miso_meta;end
    instrument_ui #(.REGISTER_FEEDBACK(1),.ENABLE_DISPLAY(UI_ENABLE_DISPLAY),
        .GUIDE_WAIT_ENABLE(1),.PRACTICE_CHANNEL(PRACTICE_CHANNEL),
        .LED_EXTERNAL_PIXELS(UI_LED_EXTERNAL_PIXELS),.LED_PREFIX_PIXELS(UI_LED_PREFIX_PIXELS),
        .LED_BEAT_PIXEL(UI_LED_BEAT_PIXEL),.LED_RANGE_PIXEL(UI_LED_RANGE_PIXEL),.LED_KEY_MAP(UI_LED_KEY_MAP),
        .LCD_RESET_LOW_CYCLES(UI_LCD_RESET_LOW_CYCLES),
        .LCD_RESET_WAIT_CYCLES(UI_LCD_RESET_WAIT_CYCLES),
        .LCD_SLEEP_OUT_CYCLES(UI_LCD_SLEEP_OUT_CYCLES),
        .TOUCH_POLL_HZ(UI_TOUCH_POLL_HZ),.TOUCH_SPI_HALF_PERIOD(UI_TOUCH_SPI_HALF_PERIOD)
`ifdef WIFI_SCORE
        ,.WIFI_UART_CLKS_PER_BIT(WIFI_UART_CLKS_PER_BIT)
`endif
        ) visual(
        .clk(sys_clk),.rst_n(core_reset_n),.start((host_mode?guide_key_start:play_pulse)|usb_play|screen_guide_start),
        .pause_toggle(screen_guide_pause),.stop(usb_stop|(usb_connected_prev&&!usb_audio_connected)|screen_guide_stop|guide_mode_change|screen_slot_select),
        .guide_wait_mode(guide_wait_mode),.keyboard_disconnected(usb_connected_prev&&!usb_audio_connected),
        .loop_enable(guide_loop),.bpm(guide_bpm),.playing(guide_playing),.paused(guide_paused),
        .beat_pulse(guide_beat_pulse),.strong_beat(guide_strong_beat),
        .base_note(7'd48),.note_valid(usb_note_valid),.note(usb_note),
        .velocity(usb_velocity),.channel(usb_channel),
        .sample_valid(frame_tick),.sample_pcm(dac_sample),
        .control_note_on(note_on_accepted),.audio_overrun(overrun),
        // Actual simultaneously audible partial counting is not yet connected.
        // Zero is an unavailable diagnostic input, not a claimed score of 256.
        .active_oscillators(16'd0),
        .touch_irq_n(touch_irq_n),.spi_miso(lcd_miso_sync),
        .led_data(rgb_din),.spi_sck(lcd_sck),.spi_mosi(lcd_mosi),
        .lcd_cs_n(lcd_cs_n),.lcd_dc(lcd_dc),.lcd_reset_n(lcd_reset_n),.touch_cs_n(touch_cs_n),
        .param_valid(touch_param_valid),.param_id(touch_param_id),.param_value(touch_param_value),
        .control_marker(debug_control),.pcm_onset_marker(debug_pcm),
        .latency_valid(diag_latency_valid),.latency_cycles(diag_latency_cycles),.latency_max_cycles(diag_latency_max),
        .latency_timeout(diag_latency_timeout),.rejected_event(diag_rejected),
        .missed_deadline_count(diag_missed),.window_valid(diag_window_valid),.samples_in_window(diag_samples),
        .register_patch(host_mode ? (usb_audio_connected ? usb_patch : configured_patch) : {1'b0,bell}),
        .register_volume(host_mode ? host_volume : 8'd255),
        .register_adsr(host_mode ? register_adsr : {7'd11,7'd75,7'd4,7'd28})
`ifdef WIFI_SCORE
        ,.wifi_rx(wifi_rx),.wifi_tx(wifi_tx),.wifi_active_present(wifi_active_present),
        .wifi_committed(wifi_committed),.wifi_active_bpm(wifi_active_bpm),.wifi_active_base(wifi_active_base),
        .wifi_active_title(wifi_active_title),.wifi_active_title_len(wifi_active_title_len),
        .wifi_active_part(wifi_active_part),.wifi_active_parts(wifi_active_parts),
        .wifi_select_valid(wifi_select_pending && wifi_select_ready),.wifi_select_slot(wifi_select_index),
        .wifi_select_ready(wifi_select_ready),.wifi_select_accepted(wifi_select_accepted),.wifi_select_rejected(wifi_select_rejected),
        .wifi_resident_valid(wifi_resident_valid),.wifi_resident_titles(wifi_resident_titles),
        .wifi_resident_title_lens(wifi_resident_title_lens),.wifi_active_slot(wifi_active_slot)
`endif
        );
`else
    assign ui_param_valid=1'b0;
    assign ui_param_id=4'd0;
    assign ui_param_value=16'd0;
    ws2812_status led(sys_clk,core_reset_n,led_grb,rgb_din);
`endif
endmodule
