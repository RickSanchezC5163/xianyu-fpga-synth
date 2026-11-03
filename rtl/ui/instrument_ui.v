`timescale 1ns/1ps
// The optional register feedback comes from the audio controller, not the
// touch widget's optimistic shadow. Default keeps the standalone bench usable.
module instrument_ui #(
    parameter integer CLK_HZ=50000000,
    parameter integer LED_REFRESH_CYCLES=500000,
    parameter integer LED_BIT_CYCLES=64,LED_ZERO_HIGH=16,LED_ONE_HIGH=32,LED_RESET_CYCLES=17500,
    parameter integer LCD_RESET_LOW_CYCLES=500000,LCD_RESET_WAIT_CYCLES=6000000,
    parameter integer LCD_SLEEP_OUT_CYCLES=6000000,
    parameter integer LCD_SPI_HALF_PERIOD=2,TOUCH_SPI_HALF_PERIOD=25,
    parameter integer TOUCH_POLL_HZ=100,WAVE_DECIMATE=64,
    parameter integer TOUCH_RAW_X_MIN=200,TOUCH_RAW_X_MAX=3900,
    parameter integer TOUCH_RAW_Y_MIN=200,TOUCH_RAW_Y_MAX=3900,
    parameter integer TOUCH_SWAP_AXES=0,TOUCH_INVERT_X=0,TOUCH_INVERT_Y=0,
    parameter integer REGISTER_FEEDBACK=0,GUIDE_WAIT_ENABLE=0,PRACTICE_CHANNEL=0,
    parameter integer ENABLE_DISPLAY=1,
    parameter integer LED_EXTERNAL_PIXELS=40,LED_PREFIX_PIXELS=1,
    parameter integer LED_BEAT_PIXEL=0,LED_RANGE_PIXEL=LED_EXTERNAL_PIXELS-1,
    parameter [199:0] LED_KEY_MAP={8'd38,8'd35,8'd34,8'd32,8'd31,8'd30,8'd29,
        8'd27,8'd25,8'd23,8'd22,8'd21,8'd19,8'd17,8'd16,8'd14,8'd13,
        8'd12,8'd10,8'd9,8'd6,8'd5,8'd4,8'd3,8'd1}
`ifdef WIFI_SCORE
    ,parameter integer WIFI_UART_CLKS_PER_BIT=434
`endif
)(
    input wire clk,rst_n,
    input wire start,pause_toggle,stop,loop_enable,input wire [7:0] bpm,
    input wire [6:0] base_note,input wire note_valid,
    input wire [6:0] note,velocity,input wire [3:0] channel,
    input wire sample_valid,input wire signed [15:0] sample_pcm,
    input wire control_note_on,audio_overrun,input wire [15:0] active_oscillators,
    input wire touch_irq_n,spi_miso,
    output wire led_data,spi_sck,spi_mosi,lcd_cs_n,lcd_dc,lcd_reset_n,touch_cs_n,
    output wire playing,paused,beat_pulse,strong_beat,
    output wire [24:0] expected_keys,preview_keys,held_keys,
    output wire [31:0] song_tick,
    output wire param_valid,output wire [3:0] param_id,output wire [15:0] param_value,
    output wire lcd_ready,range_warning,
    output wire control_marker,pcm_onset_marker,latency_valid,
    output wire [31:0] latency_cycles,latency_max_cycles,
    output wire latency_le_10ms,latency_le_5ms,latency_timeout,rejected_event,
    output wire [31:0] missed_deadline_count,
    output wire window_valid,output wire [31:0] samples_in_window,
    output wire [47:0] oscillator_samples_in_window,
    input wire [1:0] register_patch,input wire [7:0] register_volume,
    input wire [27:0] register_adsr,
    input wire guide_wait_mode,keyboard_disconnected
`ifdef WIFI_SCORE
    ,input wire wifi_rx,output wire wifi_tx,
    output wire wifi_active_present,wifi_committed,
    output wire [7:0] wifi_active_bpm,
    output wire [6:0] wifi_active_base,
    output wire [191:0] wifi_active_title,output wire [4:0] wifi_active_title_len,
    output wire [9:0] wifi_active_part,wifi_active_parts,
    input wire wifi_select_valid,input wire [1:0] wifi_select_slot,
    output wire wifi_select_ready,wifi_select_accepted,wifi_select_rejected,
    output wire [3:0] wifi_resident_valid,output wire [767:0] wifi_resident_titles,
    output wire [19:0] wifi_resident_title_lens,output wire [2:0] wifi_active_slot
`endif
);
    wire ui_start,ui_pause,ui_stop,ui_loop;
    wire touch_valid,touch_down;wire [8:0] touch_x,touch_y;
    wire [1:0] patch;wire [7:0] volume;
    wire [6:0] attack,decay,sustain,release_value;
    wire [1:0] page;
    wire page_ready;
    generate if(ENABLE_DISPLAY) begin: touch_display_controls
    ui_touch_controls #(.PIPELINED_SCALE(1)) controls(clk,rst_n,touch_valid,touch_down,page_ready,touch_x,touch_y,
        ui_start,ui_pause,ui_stop,ui_loop,param_valid,param_id,param_value,
        patch,volume,attack,decay,sustain,release_value,page);
    end else begin: no_touch_display_controls
        assign ui_start=0;assign ui_pause=0;assign ui_stop=0;assign ui_loop=0;
        assign param_valid=0;assign param_id=0;assign param_value=0;
        assign patch=0;assign volume=0;assign attack=0;assign decay=0;assign sustain=0;assign release_value=0;assign page=0;
    end endgenerate
    reg loop_flip;
    always @(posedge clk or negedge rst_n)
        if(!rst_n) loop_flip<=0;else if(ui_loop) loop_flip<=!loop_flip;
    wire looping=loop_enable^loop_flip;
    wire start_all=start|ui_start,stop_all=stop|ui_stop;
    wire finish,loop_restart,beat_lit;
    wire stepping=(GUIDE_WAIT_ENABLE!=0) && guide_wait_mode;
    wire target_hit,target_pulse,unsupported,wrong;
    wire [24:0] wrong_keys;
    guide_transport #(.CLK_HZ(CLK_HZ)) transport(
        clk,rst_n,start_all|loop_restart,pause_toggle|ui_pause,stop_all,finish,bpm,
        playing,paused,song_tick,beat_pulse,strong_beat,beat_lit);
`ifdef WIFI_SCORE
    wifi_guide_source #(.UART_CLKS_PER_BIT(WIFI_UART_CLKS_PER_BIT),.ENABLE_WAIT_MODE(GUIDE_WAIT_ENABLE)) wifi_guide(
        .clk(clk),.rst_n(rst_n),.wifi_rx(wifi_rx),.wifi_tx(wifi_tx),
        .start(start_all|loop_restart),.stop(stop_all),.playing(playing),.paused(paused),
        .loop_enable(looping),.song_tick(song_tick),.expected_keys(expected_keys),.preview_keys(preview_keys),
        .finish(finish),.loop_restart(loop_restart),.active_present(wifi_active_present),.committed(wifi_committed),
        .active_bpm(wifi_active_bpm),.active_base(wifi_active_base),
        .active_title(wifi_active_title),.active_title_len(wifi_active_title_len),
        .active_part(wifi_active_part),.active_parts(wifi_active_parts),
        .select_valid(wifi_select_valid),.select_slot(wifi_select_slot),.select_ready(wifi_select_ready),
        .select_accepted(wifi_select_accepted),.select_rejected(wifi_select_rejected),
        .resident_valid(wifi_resident_valid),.resident_titles(wifi_resident_titles),
        .resident_title_lens(wifi_resident_title_lens),.active_slot(wifi_active_slot),
        .wait_mode(stepping),.target_hit(target_hit),.target_pulse(target_pulse),.unsupported(unsupported));
    wire [6:0] guide_base_note=wifi_active_present?wifi_active_base:base_note;
    wire clear_keys=stop_all|wifi_committed;
`else
    guide_sequencer #(.ENABLE_WAIT_MODE(GUIDE_WAIT_ENABLE)) sequencer(
        clk,rst_n,start_all|loop_restart,stop_all,playing,paused,looping,song_tick,
        expected_keys,preview_keys,finish,loop_restart,stepping,target_hit,target_pulse,unsupported);
    wire [6:0] guide_base_note=base_note;
    wire clear_keys=stop_all;
`endif
    generate if(GUIDE_WAIT_ENABLE)begin: wait_for_key
        guide_note_match #(.PRACTICE_CHANNEL(PRACTICE_CHANNEL)) matcher(
            .clk(clk),.rst_n(rst_n),.keyboard_disconnected(keyboard_disconnected),
            .clear_progress(clear_keys|start_all|loop_restart),.enabled(stepping),
            .playing(playing),.paused(paused),.target_pulse(target_pulse),.expected_keys(expected_keys),
            .base_note(guide_base_note),.note_valid(note_valid),.note(note),.velocity(velocity),.channel(channel),
            .hit(target_hit),.wrong(wrong),.wrong_keys(wrong_keys));
    end else begin: no_wait_matcher
        assign target_hit=0;assign wrong=0;assign wrong_keys=0;
    end endgenerate
    wire range_pulse;
    ui_key_state keys(clk,rst_n,clear_keys,guide_base_note,note_valid,note,velocity,channel,held_keys,range_pulse);
    reg range_latched;
    always @(posedge clk or negedge rst_n)
        if(!rst_n) range_latched<=0;
        else if(clear_keys || start_all) range_latched<=0;
        else if(range_pulse || unsupported) range_latched<=1;
    assign range_warning=range_latched;
    localparam integer LED_STREAM_PIXELS=LED_EXTERNAL_PIXELS+LED_PREFIX_PIXELS;
    wire [LED_STREAM_PIXELS*24-1:0] led_frame;
    guide_led_frame #(.EXTERNAL_PIXELS(LED_EXTERNAL_PIXELS),.PREFIX_PIXELS(LED_PREFIX_PIXELS),
        .MODE_FEEDBACK(GUIDE_WAIT_ENABLE),.BEAT_PIXEL(LED_BEAT_PIXEL),.RANGE_PIXEL(LED_RANGE_PIXEL),.KEY_MAP(LED_KEY_MAP)) frame(expected_keys,preview_keys,held_keys,playing,paused,
        beat_lit,strong_beat,range_latched,led_frame,stepping,wrong_keys);
    localparam integer LW=(LED_REFRESH_CYCLES<=1)?1:$clog2(LED_REFRESH_CYCLES);
    reg [LW-1:0] led_count;
    wire led_busy,led_done;
    wire led_start=(led_count==LED_REFRESH_CYCLES-1) && !led_busy;
    always @(posedge clk or negedge rst_n)
        if(!rst_n) led_count<=0;
        else if(led_count==LED_REFRESH_CYCLES-1) begin if(!led_busy) led_count<=0;end
        else led_count<=led_count+1'b1;
    ws2812_strip #(.PIXELS(LED_STREAM_PIXELS),.BIT_CYCLES(LED_BIT_CYCLES),.ZERO_HIGH(LED_ZERO_HIGH),
        .ONE_HIGH(LED_ONE_HIGH),.RESET_CYCLES(LED_RESET_CYCLES)) strip(
        clk,rst_n,led_start,led_frame,led_data,led_busy,led_done);

    // The musical clock, LED guide and measurements above/below remain shared.
    // UART-HMI builds statically remove the entire pixel/touch path.
    generate if(ENABLE_DISPLAY) begin: pixel_display
    wire lcd_request,touch_request;
    reg [1:0] owner;
    wire lcd_grant=owner==1,touch_grant=owner==2;
    wire lcd_tx_start,touch_tx_start,master_busy,master_done;
    wire [7:0] lcd_tx_data,touch_tx_data,rx_data;
    wire [15:0] lcd_half,touch_half;
    // Nonpreemptive sessions. Touch wins each new session; LCD yields after
    // one pixel/init command, rather than holding the bus for a full frame.
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) owner<=0;
        else case(owner)
            0:if(touch_request) owner<=2;else if(lcd_request) owner<=1;
            1:if(!lcd_request && !master_busy) owner<=0;
            2:if(!touch_request && !master_busy) owner<=0;
            default:owner<=0;
        endcase
    end
    ui_spi_byte spi(clk,rst_n,(lcd_grant&&lcd_tx_start)||(touch_grant&&touch_tx_start),
        touch_grant?touch_tx_data:lcd_tx_data,touch_grant?touch_half:lcd_half,
        spi_miso,spi_sck,spi_mosi,rx_data,master_busy,master_done);
    xpt2046_touch #(.CLK_HZ(CLK_HZ),.POLL_HZ(TOUCH_POLL_HZ),
        .SPI_HALF_PERIOD(TOUCH_SPI_HALF_PERIOD),
        .RAW_X_MIN(TOUCH_RAW_X_MIN),.RAW_X_MAX(TOUCH_RAW_X_MAX),
        .RAW_Y_MIN(TOUCH_RAW_Y_MIN),.RAW_Y_MAX(TOUCH_RAW_Y_MAX),
        .SWAP_AXES(TOUCH_SWAP_AXES),.INVERT_X(TOUCH_INVERT_X),.INVERT_Y(TOUCH_INVERT_Y)) touch(
        clk,rst_n,touch_irq_n,touch_request,touch_grant,touch_tx_start,touch_tx_data,
        touch_half,master_busy||!touch_grant,master_done&&touch_grant,rx_data,
        touch_cs_n,touch_valid,touch_down,touch_x,touch_y);
    wire pixel_valid,pixel_ready,frame_start;
    wire [8:0] pixel_x,pixel_y;
    wire [15:0] pixel_rgb565;
    ili9341_panel #(.CLK_HZ(CLK_HZ),.SPI_HALF_PERIOD(LCD_SPI_HALF_PERIOD),.STREAM_ROW(1),
        .RESET_LOW_CYCLES(LCD_RESET_LOW_CYCLES),.RESET_WAIT_CYCLES(LCD_RESET_WAIT_CYCLES),
        .SLEEP_OUT_CYCLES(LCD_SLEEP_OUT_CYCLES)) panel(
        clk,rst_n,lcd_request,lcd_grant,lcd_tx_start,lcd_tx_data,lcd_half,
        master_busy||!lcd_grant,master_done&&lcd_grant,lcd_cs_n,lcd_dc,lcd_reset_n,lcd_ready,
        pixel_valid,pixel_ready,pixel_x,pixel_y,pixel_rgb565);
    wire [6:0] wave_index;
    wire signed [7:0] wave_sample;
    wire wave_valid;
    ui_waveform_buffer #(.DECIMATE(WAVE_DECIMATE)) waveform(
        clk,rst_n,sample_valid,sample_pcm,frame_start,wave_index,wave_sample,wave_valid);
    end else begin: no_pixel_display
        assign spi_sck=0;assign spi_mosi=0;assign lcd_cs_n=1;assign lcd_dc=0;
        assign lcd_reset_n=0;assign touch_cs_n=1;assign lcd_ready=0;
        assign touch_valid=0;assign touch_down=0;assign touch_x=0;assign touch_y=0;
        assign page_ready=1;
    end endgenerate
    reg latency_seen;
    always @(posedge clk or negedge rst_n)
        if(!rst_n) latency_seen<=0;
        else if(rejected_event || latency_timeout || control_note_on) latency_seen<=0;
        else if(latency_valid) latency_seen<=1;
    ui_performance_monitor #(.CLK_HZ(CLK_HZ)) diagnostics(
        clk,rst_n,control_note_on,sample_valid,sample_pcm,audio_overrun,active_oscillators,
        control_marker,pcm_onset_marker,latency_valid,latency_cycles,latency_max_cycles,
        latency_le_10ms,latency_le_5ms,latency_timeout,rejected_event,
        missed_deadline_count,window_valid,samples_in_window,oscillator_samples_in_window);
    wire [1:0] display_patch=REGISTER_FEEDBACK ? register_patch : patch;
    wire [7:0] display_volume=REGISTER_FEEDBACK ? register_volume : volume;
    wire [27:0] display_adsr=REGISTER_FEEDBACK ? register_adsr : {release_value,sustain,decay,attack};
    generate if(ENABLE_DISPLAY) begin: dashboard_display
    ui_dashboard #(.CLK_HZ(CLK_HZ),.PIPELINED(1)) dashboard(clk,rst_n,lcd_ready,pixel_display.pixel_ready,display_patch,display_volume,
        display_adsr[6:0],display_adsr[13:7],display_adsr[20:14],display_adsr[27:21],page,playing,paused,looping,beat_lit,
        latency_seen,latency_le_5ms,latency_le_10ms,latency_cycles,missed_deadline_count,
        pixel_display.wave_sample,pixel_display.wave_index,pixel_display.frame_start,page_ready,
        pixel_display.pixel_valid,pixel_display.pixel_x,pixel_display.pixel_y,pixel_display.pixel_rgb565);
    end endgenerate
endmodule
