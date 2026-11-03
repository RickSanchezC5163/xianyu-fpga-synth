`timescale 1ns/1ps
// Real controller -> additive lanes -> mix -> echo -> DAC-sample regression.
// Only decoded USB input boundary wires are stimulated; no synthesis/PCM force.
module tb_ui_audio_requirements #(parameter integer RESPONSE_PROFILE=0,TJC_CASE=0);
    reg clk=0,rst_n=0;
    always #10 clk=~clk; // actual 50 MHz
    reg connected=0,note_strobe=0,knob_strobe=0;
    reg [6:0] midi_note=69,midi_velocity=127,knob_value=0;
    reg [3:0] midi_channel=0;
    wire dp=0,dm=0;
    reg hmi_rx=1;
    wire hmi_tx;
`ifdef WIFI_SCORE
    reg wifi_rx=1;
    wire wifi_tx;
    `include "wifi_audio_stimulus.vh"
`endif
    mega60k_audio_top #(.STARTUP_CYCLES(10),.DEBOUNCE_CYCLES(8),.ENABLE_USB_HOST(0),
        .UI_ENABLE_DISPLAY(!TJC_CASE),.MIDI_QUEUE_BSRAM(TJC_CASE),
        .LOW_VELOCITY_PROFILE(RESPONSE_PROFILE)) dut(
        .sys_clk(clk),.rst_n(rst_n),.key0_n(1'b1),.key1_n(1'b1),.uart_rx(1'b1),
        .uart_tx(),.usb_dp(dp),.usb_dm(dm),.hp_bck(),.hp_ws(),.hp_din(),
        .ext_mclk(),.ext_bck(),.ext_lrclk(),.ext_din(),.pa_en(),.status_led(),.rgb_din()
`ifdef INSTRUMENT_UI
        ,.touch_irq_n(1'b1),.lcd_miso(1'b0)
`endif
`ifdef SERIAL_UI
        ,.screen_rx(hmi_rx),.screen_tx(hmi_tx)
`endif
`ifdef WIFI_SCORE
        ,.wifi_rx(wifi_rx),.wifi_tx(wifi_tx)
`endif
        );
    initial begin
        force dut.usb_audio_connected=connected;
        force dut.usb_note_valid=note_strobe;
        force dut.usb_note=midi_note;
        force dut.usb_velocity=midi_velocity;
        force dut.usb_channel=midi_channel;
        force dut.knob_a_valid=knob_strobe;
        force dut.knob_a_index=3'd0;
        force dut.knob_a_value=knob_value;
    end
    reg [255:0] previous_epochs=0;
    wire accepted_note=dut.host_epochs!=previous_epochs;
    always @(posedge clk) if(!dut.core_reset_n) previous_epochs<=0;
        else previous_epochs<=dut.host_epochs;
    wire lv,l5,l10,to,rejected,window_valid;
    wire [31:0] latency,maximum,missed,samples;
    wire [47:0] oscillator_samples;
    reg [15:0] active_envelopes;
    integer e;
    // Observe once per audio frame; no need to rescan256 entries on each
    // individual per-partial envelope RAM write in an event-driven simulator.
    always @(negedge clk) if(dut.frame_tick || !dut.core_reset_n) begin
        active_envelopes=0;
        for(e=0;e<64;e=e+1) begin
            if(dut.synthesis_lane[0].synth.envelope[e]!=0) active_envelopes=active_envelopes+1;
            if(dut.synthesis_lane[1].synth.envelope[e]!=0) active_envelopes=active_envelopes+1;
            if(dut.synthesis_lane[2].synth.envelope[e]!=0) active_envelopes=active_envelopes+1;
            if(dut.synthesis_lane[3].synth.envelope[e]!=0) active_envelopes=active_envelopes+1;
        end
    end
    ui_performance_monitor #(.WINDOW_CYCLES(204800)) monitor(
        .clk(clk),.rst_n(dut.core_reset_n),.control_note_on(accepted_note),
        .sample_valid(dut.frame_tick),.sample_pcm(dut.dac_sample),.audio_overrun(dut.overrun),
        .active_oscillators(active_envelopes),.control_marker(),.pcm_onset_marker(),
        .latency_valid(lv),.latency_cycles(latency),.latency_max_cycles(maximum),
        .latency_le_10ms(l10),.latency_le_5ms(l5),.latency_timeout(to),
        .rejected_event(rejected),.missed_deadline_count(missed),.window_valid(window_valid),
        .samples_in_window(samples),.oscillator_samples_in_window(oscillator_samples));
    wire lv1,to1;wire [31:0] latency1;
    ui_performance_monitor #(.QUIET_THRESHOLD(0),.ONSET_THRESHOLD(1),.WINDOW_CYCLES(204800)) low_monitor(
        .clk(clk),.rst_n(dut.core_reset_n),.control_note_on(accepted_note),
        .sample_valid(dut.frame_tick),.sample_pcm(dut.dac_sample),.audio_overrun(dut.overrun),
        .active_oscillators(active_envelopes),.latency_valid(lv1),.latency_cycles(latency1),.latency_timeout(to1));
    // The UI runs concurrently on the same real clock and actual PCM frames.
    wire led_data,spi_sck,lcd_cs_n,touch_cs_n;
    wire lcd_ready;
    reg guide_start=0;
    generate if(TJC_CASE) begin: serial_concurrency
        assign led_data=dut.rgb_din;
        assign spi_sck=0;assign lcd_cs_n=1;assign touch_cs_n=1;assign lcd_ready=1;
    end else begin: spi_concurrency
    instrument_ui #(.LCD_RESET_LOW_CYCLES(3),.LCD_RESET_WAIT_CYCLES(5),.LCD_SLEEP_OUT_CYCLES(10)) ui(
        .clk(clk),.rst_n(dut.core_reset_n),.start(guide_start),.pause_toggle(1'b0),.stop(1'b0),
        .loop_enable(1'b1),.bpm(8'd120),.base_note(7'd48),.note_valid(note_strobe),
        .note(midi_note),.velocity(midi_velocity),.channel(midi_channel),
        .sample_valid(dut.frame_tick),.sample_pcm(dut.dac_sample),
        .control_note_on(accepted_note),.audio_overrun(dut.overrun),.active_oscillators(active_envelopes),
        .touch_irq_n(1'b1),.spi_miso(1'b0),.led_data(led_data),.spi_sck(spi_sck),
        .lcd_cs_n(lcd_cs_n),.touch_cs_n(touch_cs_n),.lcd_ready(lcd_ready));
    end endgenerate
    integer hmi_reset_epoch=0,screen_epoch;
    always @(negedge dut.core_reset_n) hmi_reset_epoch=hmi_reset_epoch+1;
    task screen_byte(input [7:0] value);
        integer b,epoch;
        begin: byte_body
            epoch=hmi_reset_epoch;
            if(!dut.core_reset_n) begin hmi_rx=1;disable byte_body;end
            hmi_rx=0;repeat(434) @(negedge clk);
            for(b=0;b<8;b=b+1) begin
                if(!dut.core_reset_n || epoch!=hmi_reset_epoch) begin hmi_rx=1;disable byte_body;end
                hmi_rx=value[b];repeat(434) @(negedge clk);
            end
            hmi_rx=1;repeat(434) @(negedge clk);
        end
    endtask
    task screen_frame(input [87:0] bits);
        integer b,epoch;begin: frame_body
            epoch=hmi_reset_epoch;
            for(b=10;b>=0;b=b-1) begin
                if(!dut.core_reset_n || epoch!=hmi_reset_epoch) begin hmi_rx=1;disable frame_body;end
                screen_byte(bits[b*8 +: 8]);
            end
        end
    endtask
    integer hmi_frames=0,hmi_edges=0;
    always @(posedge hmi_tx) if(dut.core_reset_n) hmi_edges=hmi_edges+1;
    initial if(TJC_CASE) forever begin
        wait(dut.core_reset_n && dut.ready);
        screen_epoch=hmi_reset_epoch;
        // A short reset can interrupt a byte while this task is sleeping in a
        // bit repeat. Let the restarted receiver drain that partial phase.
        hmi_rx=1;repeat(434*12) @(negedge clk);
        if(dut.core_reset_n && screen_epoch==hmi_reset_epoch) begin
        screen_frame(88'hA65A030300000000746F7E); // real UART waveform page
        if(dut.core_reset_n && screen_epoch==hmi_reset_epoch) begin
            repeat(30) @(negedge clk);
            if(dut.screen.page_id!=3) $fatal(1,"wave page was not accepted by real UART receiver");
            screen_frame(88'hA65A02000000000031BE7E); // real UART guide START
        end
        while(dut.core_reset_n && screen_epoch==hmi_reset_epoch) begin
            screen_frame(88'hA65A04000000000031D87E); // query, no audio mutation
            if(dut.core_reset_n) hmi_frames=hmi_frames+1;
        end
        end
    end
`ifdef SERIAL_UI
    integer wave_payload_bytes=0;
    reg wave_capture_seen=0;
    always @(posedge clk) if(TJC_CASE && dut.core_reset_n) begin
        if(dut.screen.telemetry_enabled.telemetry.capture_complete) wave_capture_seen<=1;
        if(dut.screen.telemetry_enabled.telemetry.state==5 &&
           dut.screen.telemetry_enabled.telemetry.byte_valid && dut.screen.tx_ready)
            wave_payload_bytes<=wave_payload_bytes+1;
    end
`endif
    integer cycle=0,last_frame=-1,frame_count=0,lcd_edges=0,led_edges=0,verified_windows=0;
    integer accepted_count=0,peak=0,nonzero_samples=0,max_active=0;
    reg seen_latency=0,seen_low_latency=0,seen_timeout=0;
    reg [31:0] saved_latency=0,saved_low_latency=0;
    integer magnitude;
    always @(posedge spi_sck) if(!lcd_cs_n) lcd_edges=lcd_edges+1;
    always @(posedge led_data) led_edges=led_edges+1;
    always @(posedge clk) begin
        cycle=cycle+1;
        if(!dut.core_reset_n) begin last_frame=-1;frame_count=0;end
        else begin
            if(dut.overrun) $fatal(1,"actual audio overrun during UI activity");
            if(accepted_note) accepted_count=accepted_count+1;
            if(lv) begin seen_latency=1;saved_latency=latency;end
            if(lv1) begin seen_low_latency=1;saved_low_latency=latency1;end
            if(to) seen_timeout=1;
            if(window_valid) begin
                if(samples!=200) $fatal(1,"actual sample window expected200 got%0d",samples);
                verified_windows=verified_windows+1;
            end
            if(dut.frame_tick) begin
                if(last_frame>=0 && cycle-last_frame!=1024) $fatal(1,"sample frame deadline changed");
                last_frame=cycle;frame_count=frame_count+1;
                magnitude=$signed(dut.dac_sample);
                if(magnitude<0) magnitude=-magnitude;
                if(magnitude>peak) peak=magnitude;
                if(magnitude!=0) nonzero_samples=nonzero_samples+1;
                if(active_envelopes>max_active) max_active=active_envelopes;
            end
        end
    end
    task step(input integer n);repeat(n) @(negedge clk);endtask
    task frames(input integer n);
        integer target;
        begin target=frame_count+n;while(frame_count<target) @(negedge clk);end
    endtask
    task prepare(input integer patch);
        begin
            @(negedge clk);rst_n=0;connected=0;note_strobe=0;knob_strobe=0;
            step(5);rst_n=1;wait(dut.core_reset_n);wait(dut.ready);
            @(negedge clk);connected=1;step(5);
            knob_value=patch*32;knob_strobe=1;step(1);knob_strobe=0;
            frames(80); // startup gain255 is settled, >8 actual quiet samples
            if(dut.gain!=255 || dut.host_volume!=255 || dut.host_gates!=0 || dut.dac_sample!=0)
                $fatal(1,"warm-up/quiet precondition failed");
            peak=0;nonzero_samples=0;max_active=0;
            seen_latency=0;seen_low_latency=0;seen_timeout=0;
            guide_start=1;step(1);guide_start=0;
        end
    endtask
    task send_note(input integer nn,vv,offset);
        integer before_count,bound;
        begin
            @(posedge dut.frame_tick);@(negedge clk);step(offset);
            before_count=accepted_count;midi_note=nn;midi_velocity=vv;note_strobe=1;
            step(1);note_strobe=0;bound=0;
            while(accepted_count==before_count && bound<80) begin step(1);bound=bound+1;end
            if(vv!=0 && accepted_count==before_count) $fatal(1,"controller never accepted note");
        end
    endtask
    task measure(input integer patch,nn,vv,offset);
        integer bound;
        begin
            prepare(patch);send_note(nn,vv,offset);bound=0;
            while(!seen_latency && !seen_timeout && bound<600000) begin step(1);bound=bound+1;end
            if(!seen_latency || seen_timeout || saved_latency+1>(RESPONSE_PROFILE==1?250000:500000))
                $fatal(1,"REAL PCM onset failed profile%0d patch%0d note%0d velocity%0d phase%0d peak%0d accepted_cycles=%0d accepted_us=%0.3f",RESPONSE_PROFILE,patch,nn,vv,offset,peak,saved_latency+1,(saved_latency+1)*0.02);
            $display("METRIC real_audio_latency profile=%0d patch=%0d note=%0d velocity=%0d phase=%0d threshold=16 gain=255 observed_epoch_cycles=%0d accepted_cycles=%0d accepted_us=%0.3f peak=%0d",RESPONSE_PROFILE,patch,nn,vv,offset,saved_latency,saved_latency+1,(saved_latency+1)*0.02,peak);
            $fflush();
        end
    endtask
    function integer popcount(input [31:0] bits);
        integer i;begin popcount=0;for(i=0;i<32;i=i+1) popcount=popcount+bits[i];end
    endfunction
    task polyphony(input integer voices);
        integer i;
        begin
            prepare(0);
            for(i=0;i<voices;i=i+1) send_note(48+i,127,(i*37)%900);
            frames(200);
            if(popcount(dut.host_gates)!=voices || max_active!=voices*8 || nonzero_samples==0 || missed!=0)
                $fatal(1,"polyphony fail voices%0d gates%0d envelopes%0d PCMcount%0d",voices,popcount(dut.host_gates),max_active,nonzero_samples);
            $display("METRIC real_audio_polyphony voices=%0d gated=%0d nonzero_envelopes=%0d peak=%0d PCM_nonzero=%0d frame_cycles=1024 overrun=0",voices,popcount(dut.host_gates),max_active,peak,nonzero_samples);
`ifdef WIFI_SCORE
            if(voices==32) wifi_upload_concurrent();
`endif
        end
    endtask
    integer p,n,v,phase,offset;
    initial begin
        if($test$plusargs("LOW_ONLY")) begin
            for(phase=0;phase<3;phase=phase+1)
                measure(0,48,16,phase==0?0:phase==1?500:1000);
            $display("PASS tb_ui_audio_requirements LOW_ONLY profile=%0d threshold16",RESPONSE_PROFILE);
            $finish;
        end
        // Default organ across low C / A4, quiet/full velocities and frame phases.
        if(!$test$plusargs("NUMERIC_ONLY")) begin
            for(n=0;n<2;n=n+1) for(v=0;v<2;v=v+1) for(phase=0;phase<3;phase=phase+1) begin
                offset=phase==0?0:phase==1?500:1000;
                measure(0,n==0?48:69,v==0?16:127,offset);
            end
            for(p=1;p<4;p=p+1) for(phase=0;phase<3;phase=phase+1)
                measure(p,69,127,phase==0?0:phase==1?500:1000);
        end
        // Extreme velocity1 is real but below the16-count onset definition.
        prepare(0);send_note(69,1,500);frames(1100);
        if(peak==0 || peak>=16 || seen_latency || !seen_timeout || !seen_low_latency)
            $fatal(1,"velocity1 threshold limitation not characterized peak%0d latency%0b timeout%0b oneLSB%0b",peak,seen_latency,seen_timeout,seen_low_latency);
        $display("METRIC real_audio_velocity1 peak=%0d threshold16_detected=0 threshold16_expected_timeout=1 threshold1_accepted_cycles=%0d threshold1_accepted_us=%0.3f",peak,saved_low_latency+1,(saved_low_latency+1)*0.02);
        polyphony(4);polyphony(32);
        if(TJC_CASE) begin
            // Keep32 real voices active while a20.97ms capture completes and
            // its native-curve UART output starts. This is digital simulation.
            frames(3000);
`ifdef SERIAL_UI
            if(!wave_capture_seen || wave_payload_bytes==0 || missed!=0)
                $fatal(1,"wave/audio overlap not exercised capture=%0b bytes=%0d missed=%0d",wave_capture_seen,wave_payload_bytes,missed);
            $display("METRIC wave_audio_overlap capture_complete=%0b transmitted_wave_bytes=%0d missed=0",wave_capture_seen,wave_payload_bytes);
`endif
            if(hmi_frames<10 || hmi_edges<100 || led_edges<984)
                $fatal(1,"UART/LED concurrency not exercised frames%0d edges%0d LEDs%0d",hmi_frames,hmi_edges,led_edges);
        end else if(lcd_edges<1000 || led_edges<984 || !lcd_ready) $fatal(1,"concurrent UI not exercised");
        if(verified_windows<5) $fatal(1,"insufficient real sample windows");
        $display("METRIC real_audio_sample_clock clock_hz=50000000 frame_cycles=1024 nominal_fs=48828.125 samples_per_window=200 window_cycles=204800 verified_windows=%0d",verified_windows);
        $display("METRIC real_audio_ui_concurrency lcd_spi_edges=%0d strip_edges=%0d",lcd_edges,led_edges);
        $display("METRIC real_audio_tjc_concurrency enabled=%0d uart_queries=%0d uart_tx_edges=%0d",TJC_CASE,hmi_frames,hmi_edges);
        $display("PASS tb_ui_audio_requirements actual controller/synthesis/mix/echo/DAC PCM with concurrent UI, digital-only latency and4/32voices");
        $finish;
    end
    initial begin #1000000000;$fatal(1,"real audio regression global timeout");end
endmodule
