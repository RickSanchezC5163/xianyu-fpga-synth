`timescale 1ns/1ps
module tb_ui_instrument;
    wire guide_wait_mode=1'b0,keyboard_disconnected=1'b0;
    wire [1:0] register_patch=0;wire [7:0] register_volume=0;wire [27:0] register_adsr=0;
    reg clk=0,rst_n=0,start=0,pause_toggle=0,stop=0,loop_enable=0;
    reg [7:0] bpm=120;reg [6:0] base_note=48,note=48,velocity=100;
    reg [3:0] channel=0;reg note_valid=0,sample_valid=0;
    reg signed [15:0] sample_pcm=0;
    reg control_note_on=0,audio_overrun=0;reg [15:0] active_oscillators=0;
    wire control_marker,pcm_onset_marker,latency_valid,latency_le_10ms,latency_le_5ms;
    wire latency_timeout,rejected_event,window_valid;
    wire [31:0] latency_cycles,latency_max_cycles,missed_deadline_count,samples_in_window;
    wire [47:0] oscillator_samples_in_window;
    reg physical_down=0,spi_miso=0;
    wire touch_irq_n=physical_down?!touch_cs_n:1'b1;
    wire led_data,spi_sck,spi_mosi,lcd_cs_n,lcd_dc,lcd_reset_n,touch_cs_n;
    wire playing,paused,beat_pulse,strong_beat,param_valid,lcd_ready,range_warning;
    wire [24:0] expected_keys,preview_keys,held_keys;
    wire [31:0] song_tick;wire [3:0] param_id;wire [15:0] param_value;
    instrument_ui #(.CLK_HZ(1000000),.LED_REFRESH_CYCLES(1000),
        .LCD_RESET_LOW_CYCLES(3),.LCD_RESET_WAIT_CYCLES(5),.LCD_SLEEP_OUT_CYCLES(10),
        .LCD_SPI_HALF_PERIOD(1),.TOUCH_SPI_HALF_PERIOD(1),.TOUCH_POLL_HZ(1000),.WAVE_DECIMATE(1)) dut(.*);
    always #5 clk=~clk;
    integer bits=0,touch_sessions=0,lcd_sessions=0,beat_count=0,events=0;
    reg [7:0] command=0;reg [11:0] sensor_x=2520,sensor_y=520;
    reg [15:0] response;
    function automatic bit slave_bit(input integer pos);
        integer b,j;reg [15:0] data;
        begin
            b=pos/8;j=pos%8;data=(b<3?sensor_y:sensor_x)<<3;
            case(b%3) 1:slave_bit=data[15-j];2:slave_bit=data[7-j];default:slave_bit=0;endcase
        end
    endfunction
    always @(negedge touch_cs_n) begin bits=0;command=0;spi_miso=0;end
    always @(posedge spi_sck) begin
        if(!lcd_cs_n && !touch_cs_n) $fatal(1,"shared SPI double owner");
        if(lcd_cs_n && touch_cs_n) $fatal(1,"SPI clock without CS");
        if(!touch_cs_n) begin
            command={command[6:0],spi_mosi};bits=bits+1;
            if(bits%8==0) begin
                if(bits==8 && command!==8'h93) $fatal(1,"shared touch Y command corrupted");
                if(bits==32 && command!==8'hd3) $fatal(1,"shared touch X command corrupted");
                if(bits==56 && command!==8'hd0) $fatal(1,"shared touch PD command corrupted");
            end
        end
    end
    always @(negedge spi_sck) if(!touch_cs_n) spi_miso=slave_bit(bits);
    always @(posedge touch_cs_n) if(rst_n) begin
        if(bits!=72 || spi_sck) $fatal(1,"touch session interrupted");
        touch_sessions=touch_sessions+1;
    end
    always @(posedge lcd_cs_n) if(rst_n) begin
        if(spi_sck) $fatal(1,"LCD session interrupted");lcd_sessions=lcd_sessions+1;
    end
    always @(negedge clk) begin
        if(param_valid) events=events+1;
        if(beat_pulse) beat_count=beat_count+1;
        if(!lcd_cs_n && !touch_cs_n) $fatal(1,"CS conflict");
    end
    task step(input integer n);repeat(n) begin @(posedge clk);#1;end endtask
    integer prior_sessions,wait_cycles;
    initial begin
        step(3);@(negedge clk);rst_n=1;
        wait(lcd_ready);step(5);
        @(negedge clk);start=1;note_valid=1;step(1);
        // ROM now shares the synchronous RAM reader; allow bounded prefetch.
        @(negedge clk);start=0;note_valid=0;step(16);
        if(!playing || expected_keys!==25'd1 || held_keys!==25'd1) $fatal(1,"single-note guide integration start");
        // Background painting must not monopolize the bus: press reaches menu.
        prior_sessions=lcd_sessions;physical_down=1;wait_cycles=0;
        while(!param_valid && wait_cycles<20000) begin step(1);wait_cycles=wait_cycles+1;end
        if(!param_valid || param_id!=0 || param_value!=2) $fatal(1,"shared touch event failed/starved");
        physical_down=0;step(1500);
        if(touch_sessions<3 || lcd_sessions<=prior_sessions) $fatal(1,"SPI client starvation");
        @(negedge clk);note=127;note_valid=1;step(1);@(negedge clk);note_valid=0;step(3);
        if(!range_warning) $fatal(1,"range warning not latched");
        @(negedge clk);pause_toggle=1;step(1);@(negedge clk);pause_toggle=0;
        if(!paused) $fatal(1,"pause integration");
        @(negedge clk);stop=1;step(1);@(negedge clk);stop=0;step(3);
        if(playing || held_keys || expected_keys || range_warning) $fatal(1,"stop integration clear");
        // Complete at least one full strip transaction while SPI keeps working.
        wait(dut.led_done);step(1);
        if(beat_count<1) $fatal(1,"beat absent");
        @(negedge clk);rst_n=0;#1;
        if(led_data || spi_sck || !lcd_cs_n || !touch_cs_n) $fatal(1,"reset outputs unsafe");
        $display("METRIC shared_spi_touch_menu_cycles=%0d (accelerated test config)",wait_cycles);
        $display("PASS tb_ui_instrument: concurrent LED/score/LCD/touch ownership, menu and reset");$finish;
    end
    initial begin #4000000;$fatal(1,"instrument UI timeout");end
endmodule
