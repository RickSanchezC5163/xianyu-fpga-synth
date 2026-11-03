`timescale 1ns/1ps
module tb_midi_control #(parameter integer QUEUE_BSRAM=0,parameter integer ENABLE_DIAGNOSTICS=0);
    reg clk=0,rst_n=0,rx=1,sample_tick=0,ready=1,usb_dp=0,usb_dm=0;
    wire tx,host_mode,playing,paused,bell,synth_tick;
    wire [7:0] volume;
    wire [6:0] effect_mix,effect_feedback;
    wire [63:0] adsr_values;
    wire [3:0] gates;
    wire [7:0] voice_patches;
    wire [27:0] voice_velocities;
    wire [127:0] frequencies;
    wire [31:0] frame_index;
    wire [6:0] queue_count;
    localparam [127:0] DIAG_WORDS=128'hf1e2d3c4_11223344_00fedcba_80010002;
    midi_control #(.CLKS_PER_BIT(16),.INTERBYTE_TIMEOUT(200),.QUEUE_BSRAM(QUEUE_BSRAM),
        .ENABLE_DIAGNOSTICS(ENABLE_DIAGNOSTICS)) dut(
        .clk(clk),.rst_n(rst_n),.rx(rx),.tx(tx),.sample_tick(sample_tick),
        .audio_ready(ready),.audio_overrun(1'b0),
        .usb_dp_stable(usb_dp),.usb_dm_stable(usb_dm),.host_mode(host_mode),
        .usb_connected(1'b0),.usb_note_valid(1'b0),.usb_note(7'd0),
        .usb_velocity(7'd0),.usb_channel(4'd0),.usb_patch_select(2'd0),
        .usb_mod_valid(1'b0),.usb_mod_depth(7'd0),
        .usb_bend_valid(1'b0),.usb_bend_word(14'd0),
        .usb_play(1'b0),.usb_stop(1'b0),.usb_record(1'b0),
        .usb_knob_a_valid(1'b0),.usb_knob_a_index(3'd0),
        .usb_knob_a_value(7'd0),
        .usb_knob_b_valid(1'b0),.usb_knob_b_index(3'd0),
        .usb_knob_b_value(7'd0),
        .usb_pad_b_valid(1'b0),.usb_pad_b_note(7'd0),
        .playing(playing),.paused(paused),.bell(bell),.volume(volume),
        .effect_mix(effect_mix),.effect_feedback(effect_feedback),
        .adsr_values(adsr_values),
        .gates(gates),.voice_patches(voice_patches),
        .voice_velocities(voice_velocities),
        .frequency_words(frequencies),.synth_tick(synth_tick),
        .frame_index(frame_index),.queue_count(queue_count),.hardware_diagnostics(DIAG_WORDS));
    always #10 clk=~clk;
    reg [5:0] sample_div=0;
    always @(posedge clk) begin
        if(!rst_n) begin sample_div<=0;sample_tick<=0;end
        else begin sample_div<=sample_div+1'b1;sample_tick<=sample_div==63;end
    end
    wire [7:0] reply_byte;
    wire reply_valid,reply_error;
    uart_rx #(.CLKS_PER_BIT(16)) reply_receiver
        (clk,rst_n,tx,reply_byte,reply_valid,reply_error);
    reg [7:0] reply [0:10];
    integer reply_count=0;
    reg saw_on=0,saw_off=0,saw_mixed=0;
    always @(posedge clk) begin
        if(reply_valid) begin
            if(reply_count<11) reply[reply_count]=reply_byte;
            reply_count=reply_count+1;
        end
        if(playing && gates!=0) saw_on=1;
        if(gates[0] && gates[1] && voice_patches[1:0]==2'd1 &&
           voice_patches[3:2]==2'd0) saw_mixed=1;
        if(saw_on && gates==0) saw_off=1;
        if(reply_error) $fatal(1,"bad FPGA UART reply framing");
    end
    reg [7:0] p [0:7];
    task send_byte(input [7:0] value);
        integer b;
        begin
            rx=0;repeat(16) @(negedge clk);
            for(b=0;b<8;b=b+1) begin
                rx=value[b];repeat(16) @(negedge clk);
            end
            rx=1;repeat(16) @(negedge clk);
        end
    endtask
    task send_frame(input [7:0] cmd,input [7:0] expected_result,
                    input corrupt_crc);
        reg [7:0] crc,reply_crc;
        integer i,timeout;
        begin
            reply_count=0;
            crc=cmd;
            send_byte(8'ha5);send_byte(cmd);
            for(i=0;i<8;i=i+1) begin send_byte(p[i]);crc=crc^p[i];end
            send_byte(corrupt_crc ? crc^8'h01 : crc);
            timeout=0;
            while(reply_count<11 && timeout<6000) begin
                @(negedge clk);timeout=timeout+1;
            end
            if(reply_count!=11) $fatal(1,"missing reply to %h",cmd);
            if(reply[0]!=8'h5a || reply[1]!=cmd || reply[2]!=expected_result)
                $fatal(1,"reply command/result %h %h %h",reply[0],reply[1],reply[2]);
            reply_crc=0;
            for(i=1;i<10;i=i+1) reply_crc=reply_crc^reply[i];
            if(reply[10]!=reply_crc) $fatal(1,"reply CRC failed");
            if(!playing && !paused && reply[4]!=8'd64-queue_count)
                $fatal(1,"reply queue free count mismatch");
        end
    endtask
    task clear_payload;
        integer i;
        begin for(i=0;i<8;i=i+1) p[i]=0;end
    endtask
    task make_event(input [31:0] stamp,input [7:0] note,
               input [7:0] velocity,input [7:0] channel);
        begin
            p[0]=stamp[7:0];p[1]=stamp[15:8];
            p[2]=stamp[23:16];p[3]=stamp[31:24];
            p[4]=note;p[5]=velocity;p[6]=channel;p[7]=0;
        end
    endtask
    reg [31:0] pause_frame,base60,base64;
    integer k;
    initial begin
        repeat(5) @(negedge clk);rst_n=1;
        clear_payload();send_frame(8'h23,0,0);
        if(!host_mode || playing) $fatal(1,"status did not establish host mode");
        usb_dp=1;clear_payload();send_frame(8'h24,0,0);
        if(reply[6]!=8'd1 || reply[7]!=0 || reply[8]!=0 || reply[9]!=0)
            $fatal(1,"USB-A2 line status did not report D+ attach");
        p[0]=1;p[1]=120;send_frame(8'h10,0,0);
        if(!bell || volume!=120) $fatal(1,"sound configuration not applied");
        clear_payload();p[0]=65;send_frame(8'h14,3,0);
        clear_payload();p[0]=32;p[1]=48;send_frame(8'h14,0,0);
        if(effect_mix!=32 || effect_feedback!=48)
            $fatal(1,"effect parameters not applied");
        // Every payload position participates in the registered zero-args
        // predicate, including the final byte immediately before checksum.
        for(k=0;k<8;k=k+1) begin
            clear_payload();p[k]=1;
            send_frame(8'h20,3,0);send_frame(8'h21,3,0);send_frame(8'h22,3,0);
            send_frame(8'h23,3,0);send_frame(8'h24,3,0);
            if(playing || paused || gates || queue_count || volume!=120)
                $fatal(1,"nonzero control arguments changed stopped state");
        end
        clear_payload();send_frame(8'h25,0,0);
        if({reply[9],reply[8],reply[7],reply[6]}!=adsr_values[31:0])
            $fatal(1,"ADSR low readback failed");
        clear_payload();p[0]=1;send_frame(8'h25,0,0);
        if({reply[9],reply[8],reply[7],reply[6]}!=adsr_values[63:32])
            $fatal(1,"ADSR high readback failed");
        clear_payload();p[0]=2;send_frame(8'h25,0,0);
        if({reply[9],reply[8],reply[7],reply[6]}!={18'd0,7'd48,7'd32})
            $fatal(1,"effect readback failed");
        clear_payload();p[0]=4;send_frame(8'h25,0,0);
        if({reply[9],reply[8],reply[7],reply[6]}!=32'd1)
            $fatal(1,"REC touch-mode readback failed");
        if(ENABLE_DIAGNOSTICS) begin
            for(k=5;k<=8;k=k+1) begin
                clear_payload();p[0]=k;send_frame(8'h25,0,0);
                if({reply[9],reply[8],reply[7],reply[6]}!==DIAG_WORDS[(k-5)*32+:32])
                    $fatal(1,"board diagnostic word/endianness failed selector %0d",k);
                if(playing || gates || volume!=120) $fatal(1,"diagnostic query changed audio state");
            end
            clear_payload();p[0]=9;send_frame(8'h25,3,0);
            clear_payload();p[0]=5;p[1]=1;send_frame(8'h25,3,0);
        end else begin clear_payload();p[0]=5;send_frame(8'h25,3,0);end
        if(adsr_values!={16'd48,16'd40000,16'd24,16'd512})
            $fatal(1,"default ADSR changed");
        clear_payload();p[0]=128;send_frame(8'h16,3,0);
        clear_payload();p[0]=28;p[1]=4;p[2]=75;p[3]=11;
        send_frame(8'h16,0,0);
        if(adsr_values!={16'd48,16'd40000,16'd24,16'd512})
            $fatal(1,"ADSR parameter conversion is wrong");
        clear_payload();p[1]=127;p[3]=127;send_frame(8'h16,0,0);
        if(adsr_values!={16'd512,16'd10000,16'd516,16'd64})
            $fatal(1,"ADSR alternate values did not apply");
        clear_payload();p[0]=28;p[1]=4;p[2]=75;p[3]=11;
        send_frame(8'h16,0,0);
        clear_payload();p[0]=16;send_frame(8'h12,3,0);
        clear_payload();p[0]=1;p[1]=0;send_frame(8'h12,0,0);
        clear_payload();make_event(0,60,37,0);send_frame(8'h11,0,0);
        make_event(0,64,100,1);send_frame(8'h11,0,0);
        make_event(15,60,0,0);send_frame(8'h11,0,0);
        make_event(15,64,0,1);send_frame(8'h11,0,0);
        if(queue_count!=4) $fatal(1,"MIDI events were not queued");
        for(k=0;k<8;k=k+1) begin
            clear_payload();p[k]=1;send_frame(8'h22,3,0);
            if(queue_count!=4) $fatal(1,"nonzero STOP arguments flushed queued notes");
        end
        clear_payload();send_frame(8'h20,0,0);
        if(!saw_on || !saw_off || !saw_mixed || queue_count!=0 || frame_index<15)
            $fatal(1,"FPGA did not schedule mixed-timbre note on/off by audio frames");
        if(voice_velocities[6:0]!=7'd37 || voice_velocities[13:7]!=7'd100)
            $fatal(1,"per-voice MIDI velocity was not retained");
        for(k=0;k<8;k=k+1) begin
            clear_payload();p[k]=1;
            send_frame(8'h20,3,0);send_frame(8'h21,3,0);send_frame(8'h22,3,0);
            if(!playing || paused) $fatal(1,"nonzero control arguments interrupted playback");
        end
        clear_payload();send_frame(8'h22,1,1);
        if(!playing || paused) $fatal(1,"bad CRC bypassed zero-argument validation");
        clear_payload();p[7]=1;send_frame(8'h22,1,1);
        if(!playing || paused) $fatal(1,"bad CRC with last argument interrupted playback");
        send_byte(8'ha5);send_byte(8'h22);send_byte(8'h01);
        repeat(250) @(negedge clk); // abandon nonzero short frame by timeout
        clear_payload();send_frame(8'h23,0,0);
        if(!playing || paused) $fatal(1,"short frame poisoned the next zero-argument command");
        clear_payload();
        send_frame(8'h21,0,0);
        pause_frame=frame_index;
        repeat(200) @(negedge clk);
        if(frame_index!=pause_frame || synth_tick || !paused)
            $fatal(1,"pause did not freeze local synth clock");
        send_frame(8'h20,0,0);
        repeat(200) @(negedge clk);
        if(frame_index<=pause_frame) $fatal(1,"resume failed");
        send_frame(8'h22,0,0);
        if(frame_index!=0 || playing || paused || gates!=0)
            $fatal(1,"stop did not clear playback");
        make_event(0,60,100,0);send_frame(8'h11,0,0);
        make_event(0,64,100,0);send_frame(8'h11,0,0);
        clear_payload();send_frame(8'h20,0,0);
        if(gates[1:0]!=2'b11) $fatal(1,"lead-bend chord did not start");
        base60=frequencies[31:0];base64=frequencies[63:32];
        clear_payload();p[1]=8'd96;send_frame(8'h13,0,0); // +1 semitone
        if(frequencies[31:0]!=base60 || frequencies[63:32]<=base64)
            $fatal(1,"pitch bend moved chord or missed selected lead");
        clear_payload();p[1]=8'd32;send_frame(8'h13,0,0); // -1 semitone
        if(frequencies[31:0]!=base60 || frequencies[63:32]>=base64)
            $fatal(1,"negative lead bend failed");
        clear_payload();p[1]=8'd64;send_frame(8'h13,0,0); // center
        if(frequencies[31:0]!=base60 || frequencies[63:32]!=base64)
            $fatal(1,"lead bend did not return to center");
        clear_payload();p[0]=8'd127;send_frame(8'h15,0,0);
        repeat(64*300) @(negedge clk);
        if(frequencies[31:0]!=base60 || frequencies[63:32]==base64)
            $fatal(1,"MOD vibrato moved chord or missed selected lead");
        clear_payload();send_frame(8'h15,0,0);
        repeat(64*3) @(negedge clk);
        if(frequencies[31:0]!=base60 || frequencies[63:32]!=base64)
            $fatal(1,"MOD zero did not return to unmodulated pitch");
        clear_payload();p[0]=128;send_frame(8'h15,3,0);
        clear_payload();p[1]=8'd64;p[3]=1;send_frame(8'h13,3,0);
        clear_payload();send_frame(8'h22,0,0);
        make_event(0,60,100,0);send_frame(8'h11,0,0);
        make_event(0,64,100,0);send_frame(8'h11,0,0);
        make_event(0,67,100,0);send_frame(8'h11,0,0);
        make_event(0,71,100,0);send_frame(8'h11,0,0);
        make_event(0,74,100,0);send_frame(8'h11,0,0);
        clear_payload();send_frame(8'h20,0,0);
        if(gates!=4'b1111 || dut.voice_note[0]!=7'd74)
            $fatal(1,"fifth simultaneous MIDI note did not steal oldest voice");
        send_frame(8'h22,0,0);
        make_event(100,60,100,0);send_frame(8'h11,1,1);
        if(queue_count!=0) $fatal(1,"CRC error enqueued a note");
        make_event(100,60,100,0);send_frame(8'h11,0,0);
        make_event(99,62,100,0);send_frame(8'h11,6,0);
        make_event(100,128,100,0);send_frame(8'h11,3,0);
        if(queue_count!=1) $fatal(1,"invalid or unordered note was accepted");
        clear_payload();send_frame(8'h22,0,0);
        for(k=0;k<64;k=k+1) begin
            make_event(1000+k,60,100,0);send_frame(8'h11,0,0);
        end
        if(queue_count!=64) $fatal(1,"queue failed to fill");
        make_event(1064,60,100,0);send_frame(8'h11,5,0);
        clear_payload();send_frame(8'h22,0,0);
        if(queue_count!=0) $fatal(1,"stop did not flush FIFO");
        $display("PASS: UART MIDI notes, velocity, lead bend/MOD, effect control, queue and playback");
        $finish;
    end
    initial begin #100000000;$fatal(1,"MIDI control simulation timeout");end
endmodule
