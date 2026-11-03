`timescale 1ns/1ps
// Pin-level XPT2046 -> shared SPI -> touch event -> real audio registers.
// USB events are injected AFTER decoding; USB enumeration is not this fixture.
module tb_ui_connected_instrument;
    reg sys_clk=0,rst_n=0,key0_n=1,key1_n=1,uart_rx=1;
    wire uart_tx,usb_dp,usb_dm,hp_bck,hp_ws,hp_din,ext_mclk,ext_bck,ext_lrclk,ext_din;
    wire pa_en,rgb_din,lcd_sck,lcd_mosi,lcd_cs_n,lcd_dc,lcd_reset_n,touch_cs_n;
    wire [1:0] status_led;wire debug_control,debug_pcm;
    reg physical_down=0,lcd_miso=0;
    wire touch_irq_n=physical_down ? !touch_cs_n : 1'b1;
    mega60k_instrument_top #(.ENABLE_USB_HOST(0),.STARTUP_CYCLES(4),
        .UI_LCD_RESET_LOW_CYCLES(3),.UI_LCD_RESET_WAIT_CYCLES(5),
        .UI_LCD_SLEEP_OUT_CYCLES(10),.UI_TOUCH_POLL_HZ(5000),
        .UI_TOUCH_SPI_HALF_PERIOD(4)) dut(.*);
    // Only gesture thresholds are accelerated; audio remains one frame/1024 clocks.
    defparam dut.audio.DEBOUNCE_CYCLES=3;
    defparam dut.audio.GUIDE_KEY_LONG_SAMPLES=4;
    always #10 sys_clk=~sys_clk;
    integer bits=0,acks=0,notes=0,frames=0,cycles=0,trace;
    integer last_frame=0;
    reg [11:0] sensor_x=3900,sensor_y=500;
    reg [11:0] snapshot_x,snapshot_y;
    reg connected=0,nvalid=0,stop_key=0,kb_valid=0;
    reg [6:0] note=60,vel=100,kb_value=0;
    reg [2:0] kb_index=0;
    function automatic slave_bit(input integer pos);
        integer byte_n,j;reg [15:0] response;
        begin byte_n=pos/8;j=pos%8;response=(byte_n<3?snapshot_y:snapshot_x)<<3;
            case(byte_n%3) 1:slave_bit=response[15-j];2:slave_bit=response[7-j];default:slave_bit=0;endcase
        end
    endfunction
    always @(negedge touch_cs_n) begin
        bits=0;lcd_miso=0;snapshot_x=sensor_x;snapshot_y=sensor_y;
    end
    always @(posedge lcd_sck) if(!touch_cs_n) bits=bits+1;
    always @(negedge lcd_sck) if(!touch_cs_n) lcd_miso=slave_bit(bits);
    always @(negedge sys_clk) begin
        cycles=cycles+1;
        if(!lcd_cs_n && !touch_cs_n) $fatal(1,"SPI simultaneous selects");
        if(dut.audio.core_reset_n && dut.audio.overrun) $fatal(1,"audio deadline missed");
        if(dut.audio.frame_tick) begin
            if(frames>0 && cycles-last_frame!=1024) $fatal(1,"audio period disturbed by UI");
            last_frame=cycles;frames=frames+1;
        end
        if(dut.audio.note_on_accepted) notes=notes+1;
        if(dut.audio.ui_param_ack) begin
            acks=acks+1;
            $fdisplay(trace,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",cycles,
                dut.audio.ui_param_id,dut.audio.ui_param_value,dut.audio.usb_patch,dut.audio.host_volume,
                dut.audio.register_adsr[6:0],dut.audio.register_adsr[13:7],
                dut.audio.register_adsr[20:14],dut.audio.register_adsr[27:21]);
        end
    end
    task step(input integer n);repeat(n) begin @(posedge sys_clk);#1;end endtask
    task release_touch;
        begin physical_down=0;wait(!dut.audio.visual.touch_down);step(3);end
    endtask
    task press(input integer x,input integer y,input integer id,input integer value);
        integer guard;
        begin
            sensor_x=x==319?3900:200+(x*3700+318)/319;
            sensor_y=y==239?3900:200+(y*3700+238)/239;
            physical_down=1;guard=0;
            while(!dut.audio.ui_param_ack && guard<150000) begin step(1);guard=guard+1;end
            if(!dut.audio.ui_param_ack || dut.audio.ui_param_id!=id || dut.audio.ui_param_value!=value)
                $fatal(1,"pin->register touch failed id/value=%0d/%0d expected%0d/%0d",dut.audio.ui_param_id,dut.audio.ui_param_value,id,value);
            release_touch();
        end
    endtask
    task usb_note(input integer n,input integer velocity);
        begin @(negedge sys_clk);note=n;vel=velocity;nvalid=1;
            @(negedge sys_clk);nvalid=0;step(12);end
    endtask
    initial begin
        trace=$fopen("connected_register_trace.csv","w");
        $fdisplay(trace,"cycle,param_id,request,patch,volume,attack,decay,sustain,release");
        force dut.audio.usb_audio_connected=connected;
        force dut.audio.usb_note_valid=nvalid;force dut.audio.usb_note=note;
        force dut.audio.usb_velocity=vel;force dut.audio.usb_stop=stop_key;
        force dut.audio.knob_b_valid=kb_valid;force dut.audio.knob_b_index=kb_index;
        force dut.audio.knob_b_value=kb_value;
        step(4);@(negedge sys_clk);rst_n=1;wait(dut.audio.ready);step(4);
        @(negedge sys_clk);connected=1;step(10);
        if(!dut.audio.host_mode || !dut.audio.host_playing) $fatal(1,"session bootstrap failed");
        wait(dut.audio.visual.lcd_ready);
        press(280,20,0,3);
        if(dut.audio.usb_patch!=3 || dut.audio.visual.display_patch!=3) $fatal(1,"USB patch readback not canonical");
        usb_note(60,100);if(dut.audio.host_gates!=1 || notes!=1) $fatal(1,"note lost under UI");
        press(0,90,1,0);step(66000);
        if(dut.audio.host_volume || dut.audio.gain || dut.audio.host_gates!=1 || dut.audio.visual.display_volume)
            $fatal(1,"UI volume zero should fade gain without removing held note");
        // A physical B knob changes canonical A, despite stale UI local shadow.
        @(negedge sys_clk);kb_valid=1;kb_index=0;kb_value=99;
        @(negedge sys_clk);kb_valid=0;step(3);
        if(dut.audio.visual.display_adsr[6:0]!=99 || dut.audio.host_adsr[15:0]!=1648)
            $fatal(1,"external knob missing canonical feedback");
        press(319,90,1,255);
        if(dut.audio.visual.display_volume!=255) $fatal(1,"full255 readback");
        usb_note(60,0);if(dut.audio.host_gates || notes!=1) $fatal(1,"note off lost");
        @(negedge sys_clk);stop_key=1;@(negedge sys_clk);stop_key=0;step(4);
        press(160,90,1,127);
        if(dut.audio.host_playing || dut.audio.host_gates || dut.audio.host_volume!=127)
            $fatal(1,"touch parameter improperly restarted STOP");
        // A USB disconnect has no final NoteOff packet. Both audio AND held
        // key LEDs must clear; retaining the last purple key is misleading.
        @(negedge sys_clk);connected=0;step(5);
        @(negedge sys_clk);connected=1;step(8);
        usb_note(60,100);
        if(!dut.audio.visual.held_keys[12] || !dut.audio.host_gates) $fatal(1,"disconnect fixture did not hold a key");
        @(negedge sys_clk);connected=0;step(5);
        if(dut.audio.visual.held_keys || dut.audio.host_gates || dut.audio.visual.playing)
            $fatal(1,"USB disconnect must clear held-key visualization and audio");
        if(dut.audio.visual.display_volume!=255 || dut.audio.visual.display_patch!=0 ||
           dut.audio.visual.display_adsr!=={7'd11,7'd75,7'd4,7'd28})
            $fatal(1,"manual fallback must display manual audio parameters, not stale host state");
        // The guide mode switch must never masquerade as USB STOP or mute audio.
        @(negedge sys_clk);connected=1;step(16);usb_note(48,100);
        @(negedge sys_clk);key1_n=0;step(8);step(5*1024);
        if(!dut.audio.guide_wait_mode || dut.audio.visual.playing || !dut.audio.host_playing || !dut.audio.host_gates)
            $fatal(1,"long KEY1 must switch/stop guide while preserving audio");
        @(negedge sys_clk);key1_n=1;step(16);
        if(dut.audio.visual.playing)$fatal(1,"long release unexpectedly restarted guide");
        @(negedge sys_clk);key1_n=0;step(8);@(negedge sys_clk);key1_n=1;step(24);
        if(!dut.audio.visual.playing || dut.audio.visual.expected_keys!=1)$fatal(1,"short release failed to start wait guide");
        usb_note(48,100);step(20);
        if(dut.audio.visual.expected_keys!=1)$fatal(1,"preheld duplicate passed wait lesson");
        usb_note(48,0);usb_note(48,100);step(24);
        if(dut.audio.visual.expected_keys!=(25'd1<<2))$fatal(1,"fresh correct C did not advance to D");
        usb_note(48,0);usb_note(50,100);step(24);
        if(dut.audio.visual.expected_keys!=(25'd1<<4) || !dut.audio.host_gates)$fatal(1,"correct D/audio coexistence failed");
        @(negedge sys_clk);key1_n=0;step(8);step(5*1024);
        @(negedge sys_clk);key1_n=1;step(16);
        if(dut.audio.guide_wait_mode || dut.audio.visual.playing || !dut.audio.host_gates)
            $fatal(1,"switch back must preserve current note and require explicit start");
        usb_note(50,0);
        if(acks<4 || frames<100) $fatal(1,"insufficient integration exercise");
        $fclose(trace);
        $display("PASS tb_ui_connected_instrument: physical touch SPI -> real audio state -> canonical display; USB coexistence, gain fade, knobs, STOP, frame period, KEY1 modes and wait-note/audio isolation; acks=%0d frames=%0d",acks,frames);
        $finish;
    end
    initial begin #20000000;$fatal(1,"connected instrument timeout");end
endmodule
