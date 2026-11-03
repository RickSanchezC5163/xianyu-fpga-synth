`timescale 1ns/1ps
module tb_ui_controls;
    reg clk=0,rst_n=0,touch_valid=0,touch_down=0,page_ready=1;
    reg [8:0] x=0,y=0;
    wire start,pause_toggle,stop,loop_toggle,param_valid;wire [1:0] page;
    wire [3:0] param_id;wire [15:0] param_value;
    wire [1:0] patch;wire [7:0] volume;
    wire [6:0] attack,decay,sustain,release_value;
    ui_touch_controls controls(.*);
    reg clear=0,note_valid=0;reg [6:0] base_note=48,note=48,velocity=100;
    reg [3:0] channel=0;
    wire [24:0] held_keys;wire out_of_range;
    ui_key_state keys(.*);
    reg [24:0] expected_keys=0,preview_keys=0;
    reg playing=0,paused=0,beat_lit=0,strong_beat=0,range_warning=0;
    wire [983:0] frame_grb;
    wire wait_mode=1'b0;wire [24:0] wrong_keys=25'd0;
    guide_led_frame frame(.*);
    reg sample_valid=0,frame_start=0;reg signed [15:0] sample_pcm=0;
    reg [6:0] read_index=0;wire signed [7:0] read_sample;wire display_valid;
    ui_waveform_buffer #(.DECIMATE(2)) waveform(.*);
    always #5 clk=~clk;
    task tick;begin @(posedge clk);#1;end endtask
    task touch(input integer xx,yy,input bit down);
        begin @(negedge clk);x=xx;y=yy;touch_down=down;touch_valid=1;
            tick();@(negedge clk);touch_valid=0;end
    endtask
    task note_event(input integer nn,vv,ch);
        begin @(negedge clk);note=nn;velocity=vv;channel=ch;note_valid=1;
            tick();@(negedge clk);note_valid=0;end
    endtask
    integer k,p;
    initial begin
        repeat(3) tick();@(negedge clk);rst_n=1;tick();
        if(volume!=255 || page || patch) $fatal(1,"control defaults");
        touch(200,20,1);if(!param_valid || patch!=2 || param_id!=0 || param_value!=2) $fatal(1,"patch map");
        touch(300,20,1);if(param_valid || patch!=2) $fatal(1,"held button repeated");touch(300,20,0);
        touch(20,50,1);if(!start) $fatal(1,"PLAY missing");touch(20,50,0);
        touch(100,50,1);if(!pause_toggle) $fatal(1,"PAUSE missing");touch(100,50,0);
        touch(180,50,1);if(!stop) $fatal(1,"STOP missing");touch(180,50,0);
        touch(260,50,1);if(!loop_toggle) $fatal(1,"LOOP missing");touch(260,50,0);
        touch(0,96,1);if(volume!=0 || param_value!=0) $fatal(1,"volume minimum");
        touch(319,96,1);if(volume!=255 || param_id!=1) $fatal(1,"volume max drag");touch(319,96,0);
        touch(10,120,1);if(!page) $fatal(1,"page switch");touch(10,120,0);
        page_ready=0;touch(319,150,1);if(param_valid || attack!=8) $fatal(1,"hidden page edited");touch(319,150,0);
        page_ready=1;touch(319,150,1);if(attack!=127 || param_id!=2) $fatal(1,"attack map");touch(319,150,0);
        touch(0,175,1);if(decay!=0 || param_id!=3) $fatal(1,"decay map");touch(0,175,0);
        touch(319,200,1);if(sustain!=127 || param_id!=4) $fatal(1,"sustain map");touch(319,200,0);
        touch(0,230,1);if(release_value!=0 || param_id!=5) $fatal(1,"release map");touch(0,230,0);
        touch(10,120,1);if(page!=2) $fatal(1,"metric page switch");touch(10,120,0);
        touch(319,150,1);if(param_valid || attack!=127) $fatal(1,"metric page changed ADSR");touch(319,150,0);
        touch(10,120,1);if(page!=0) $fatal(1,"wave page switch");touch(10,120,0);
        touch(400,10,1);if(param_valid) $fatal(1,"out of bounds touch");touch(400,10,0);
        note_event(48,100,0);note_event(48,100,1);note_event(48,0,0);
        if(held_keys!==25'd1) $fatal(1,"cross channel off cleared key");
        note_event(72,100,15);if(!held_keys[24]) $fatal(1,"last key missing");
        note_event(127,100,0);if(!out_of_range || held_keys!==((25'd1<<24)|1)) $fatal(1,"range wrapped");
        @(negedge clk);clear=1;tick();@(negedge clk);clear=0;
        if(held_keys) $fatal(1,"clear failed");
        // Every logical key must produce one uniquely mapped external pixel;
        // onboard prefix remains black, beat and range occupy their own pixels.
        playing=1;
        for(k=0;k<25;k=k+1) begin
            expected_keys=25'd1<<k;#1;p=frame.KEY_MAP[k*8+:8];
            if(frame_grb[(p+1)*24+:24]!==24'h100000 || frame_grb[23:0]!==0)
                $fatal(1,"LED key/prefix mapping %0d",k);
        end
        expected_keys=0;beat_lit=1;strong_beat=1;range_warning=1;#1;
        if(frame_grb[24+:24]!==24'h101010 || frame_grb[40*24+:24]!==24'h001000)
            $fatal(1,"beat/range pixels");
        // Two-bank observation must hold the read frame stable while capturing.
        for(k=0;k<128;k=k+1) begin
            @(negedge clk);sample_valid=1;sample_pcm=(k-64)*256;tick();tick();
        end
        @(negedge clk);sample_valid=0;tick();
        if(display_valid || read_sample) $fatal(1,"uncommitted waveform visible");
        @(negedge clk);frame_start=1;tick();@(negedge clk);frame_start=0;
        for(k=0;k<128;k=k+1) begin
            read_index=k;#1;if($signed(read_sample)!==k-64) $fatal(1,"wave sample %0d =%0d",k,read_sample);
        end
        @(negedge clk);sample_valid=1;sample_pcm=16'h7fff;repeat(260) tick();
        @(negedge clk);sample_valid=0;read_index=0;#1;
        if($signed(read_sample)!=-64) $fatal(1,"wave frame tore");
        @(negedge clk);frame_start=1;tick();@(negedge clk);frame_start=0;#1;
        if(read_sample!=127) $fatal(1,"wave next snapshot missing");
        $display("PASS tb_ui_controls: menu gestures range channel ownership LEDs and waveform banks");$finish;
    end
    initial begin #1000000;$fatal(1,"controls timeout");end
endmodule
