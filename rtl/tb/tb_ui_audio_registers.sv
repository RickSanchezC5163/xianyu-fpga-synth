`timescale 1ns/1ps
// UI register contract at the real 32-voice controller boundary; no FPGA access.
module tb_ui_audio_registers;
    reg clk=0,rst_n=0,rx=1,ready=1,tick=0;
    reg connected=0,nvalid=0,stop_key=0,play_key=0;
    reg [6:0] note=60,vel=100;
    reg [3:0] channel=0;
    reg kav=0,kbv=0; reg [2:0] kai=0,kbi=0;
    reg [6:0] ka=0,kb=0;
    reg uv=0; reg [3:0] uid=0; reg [15:0] value=0;
    wire tx,host,playing,paused,bell,st,ack,rejected,note_accepted;
    wire [7:0] volume;
    wire [6:0] mix,fb,queued;
    wire [63:0] adsr;
    wire [27:0] controls;
    wire [1:0] patch;
    wire [31:0] gates,frame;
    wire [255:0] epochs;
    wire [63:0] patches;
    wire [223:0] velocities;
    wire [1023:0] frequencies;
    always #10 clk=~clk;
    midi_control #(.VOICES(32),.CLKS_PER_BIT(16)) dut(
        .clk(clk),.rst_n(rst_n),.rx(rx),.tx(tx),.sample_tick(tick),
        .audio_ready(ready),.audio_overrun(1'b0),
        .usb_dp_stable(1'b1),.usb_dm_stable(1'b0),
        .usb_connected(connected),.usb_note_valid(nvalid),.usb_note(note),
        .usb_velocity(vel),.usb_channel(channel),.usb_patch_select(2'd2),
        .usb_mod_valid(1'b0),.usb_mod_depth(7'd0),
        .usb_bend_valid(1'b0),.usb_bend_word(14'd8192),
        .usb_play(play_key),.usb_stop(stop_key),.usb_record(1'b0),
        .usb_knob_a_valid(kav),.usb_knob_a_index(kai),.usb_knob_a_value(ka),
        .usb_knob_b_valid(kbv),.usb_knob_b_index(kbi),.usb_knob_b_value(kb),
        .usb_pad_b_valid(1'b0),.usb_pad_b_note(7'd0),
        .host_mode(host),.playing(playing),.paused(paused),.bell(bell),
        .volume(volume),.effect_mix(mix),.effect_feedback(fb),.adsr_values(adsr),
        .gates(gates),.voice_epochs(epochs),.voice_patches(patches),
        .voice_velocities(velocities),.frequency_words(frequencies),
        .synth_tick(st),.frame_index(frame),.queue_count(queued),
        .ui_param_valid(uv),.ui_param_id(uid),.ui_param_value(value),
        .ui_param_ack(ack),.ui_param_rejected(rejected),
        .adsr_controls(controls),.configured_patch(patch),.note_on_accepted(note_accepted));
    integer accepted_count=0;
    always @(negedge clk) if(note_accepted) accepted_count=accepted_count+1;
    task ui(input [3:0] id,input [15:0] v,input good);
        begin
            @(negedge clk);uv=1;uid=id;value=v;
            @(negedge clk);
            if(ack!==good || rejected!==!good) $fatal(1,"UI response id=%0d v=%0d ack=%b reject=%b",id,v,ack,rejected);
            uv=0;
            @(negedge clk);
            if(ack || rejected) $fatal(1,"UI response did not pulse");
        end
    endtask
    task send_byte(input [7:0] v);
        integer bitno;
        begin
            rx=0;repeat(16) @(negedge clk);
            for(bitno=0;bitno<8;bitno=bitno+1) begin rx=v[bitno];repeat(16) @(negedge clk);end
            rx=1;repeat(16) @(negedge clk);
        end
    endtask
    task frame_send(input [7:0] cmd,input [63:0] p);
        integer i;reg [7:0] crc;
        begin
            @(negedge clk);crc=cmd;send_byte(8'ha5);send_byte(cmd);
            for(i=0;i<8;i=i+1) begin send_byte(p[i*8 +: 8]);crc=crc^p[i*8 +: 8];end
            send_byte(crc);repeat(5) @(negedge clk);
        end
    endtask
    task usb_event(input [6:0] n,input [6:0] v);
        begin
            @(negedge clk);nvalid=1;note=n;vel=v;
            @(negedge clk);nvalid=0;repeat(8) @(negedge clk);
        end
    endtask
    task sample;
        begin @(negedge clk);tick=1;@(negedge clk);tick=0;end
    endtask
    task collide_ui(input [3:0] id,input [15:0] v);
        begin
            wait(dut.frame_done===1'b1);
            @(negedge clk);uid=id;value=v;uv=1;
            @(negedge clk);if(!ack || rejected) $fatal(1,"UART/UI collision not acknowledged");uv=0;
        end
    endtask
    task check_adsr(input integer a,input integer d,input integer s,input integer r);
        begin
            if(controls!=={r[6:0],s[6:0],d[6:0],a[6:0]}) $fatal(1,"canonical ADSR mismatch");
            if(adsr[15:0]!==64+a*16 || adsr[31:16]!==8+d*4 ||
               adsr[47:32]!==10000+s*400 || adsr[63:48]!==4+r*4)
                $fatal(1,"raw ADSR mismatch %h",adsr);
        end
    endtask
    integer i,j,before_count;reg [63:0] saved_adsr;reg [27:0] saved_controls;
    reg [31:0] saved_gates;reg [255:0] saved_epochs;
    initial begin
        repeat(4) @(negedge clk);rst_n=1;repeat(3) @(negedge clk);
        check_adsr(28,4,75,11);
        ui(1,255,0); if(volume!=192 || playing || host) $fatal(1,"UI established session");
        frame_send(8'h23,0);if(!host || playing) $fatal(1,"UART host init");
        ui(1,255,1); if(volume!=255 || playing || paused) $fatal(1,"UI volume/start error");
        ready=0;ui(1,0,0);if(volume!=255) $fatal(1,"not ready mutation");ready=1;
        // Open legacy inputs must not create writes or X propagation.
        @(negedge clk);uv=1'bz;uid=4'bz;value=16'bz;repeat(5) @(negedge clk);
        if(volume!==255 || ack || rejected) $fatal(1,"unconnected UI input changed legacy state");uv=0;
        for(i=0;i<4;i=i+1) begin
            ui(0,i,1);if(patch!==i[1:0] || dut.channel_patches!=={16{i[1:0]}}) $fatal(1,"patch fanout");
        end
        for(i=0;i<256;i=i+1) begin ui(1,i,1);if(volume!==i[7:0]) $fatal(1,"8bit gain quantized");end
        for(i=2;i<=5;i=i+1) begin
            ui(i,0,1);ui(i,127,1);
        end
        check_adsr(127,127,127,127);
        saved_adsr=adsr;saved_controls=controls;
        ui(0,4,0);ui(0,65535,0);ui(1,256,0);ui(1,65535,0);
        for(i=2;i<=5;i=i+1) begin ui(i,128,0);ui(i,65535,0);end
        for(i=6;i<16;i=i+1) ui(i,0,0);
        if(adsr!==saved_adsr || controls!==saved_controls || volume!=255 || patch!=3) $fatal(1,"invalid write changed state");
        // Actual UART SET_ADSR and SET_SOUND; UI same clock wins only its field.
        fork frame_send(8'h16,64'h0000000004030201);collide_ui(2,100);join
        check_adsr(100,2,3,4);
        fork frame_send(8'h10,64'h0000000000001400);collide_ui(1,255);join
        if(volume!=255 || patch!=0) $fatal(1,"UART config/UI priority");
        // Queued events remain ordinary timestamps; UI does not bypass queue.
        frame_send(8'h11,64'h0000643c00000000);if(queued!=1 || gates!=0) $fatal(1,"queued note semantics");
        ui(0,3,1);frame_send(8'h20,0);sample();repeat(8) @(negedge clk);
        if(gates!=1 || patches[1:0]!=3 || accepted_count!=1) $fatal(1,"UART patch snapshot or note pulse");
        saved_gates=gates;saved_epochs=epochs;
        ui(0,1,1);if(gates!==saved_gates || epochs!==saved_epochs || patches[1:0]!=3) $fatal(1,"live voice patch disturbed");
        frame_send(8'h21,0);ui(1,200,1);if(!paused || playing || gates!=1) $fatal(1,"UI unpaused playback");
        fork frame_send(8'h22,0);collide_ui(1,255);join
        if(playing || paused || gates || queued || volume!=255) $fatal(1,"STOP priority or UI started sound");
        // 64-entry queue capacity unchanged, including UI writes on a full FIFO.
        for(i=0;i<64;i=i+1) frame_send(8'h11,64'h0000643c00000000);
        if(queued!=64) $fatal(1,"queue capacity changed");
        ui(1,0,1);frame_send(8'h11,64'h0000643c00000000);
        if(queued!=64 || gates!=0) $fatal(1,"full FIFO bypassed");frame_send(8'h22,0);
        @(negedge clk);connected=1;repeat(5) @(negedge clk);
        if(!playing || !host || volume!=255) $fatal(1,"USB session bootstrap");
        // USB physical ADSR controls update both raw registers and canonical shadow.
        for(i=0;i<4;i=i+1) begin
            @(negedge clk);kbv=1;kbi=i;kb=10+i;@(negedge clk);kbv=0;
        end
        check_adsr(10,11,12,13);
        @(negedge clk);kav=1;kai=3;ka=14;@(negedge clk);kav=0;check_adsr(10,11,12,14);
        @(negedge clk);kbv=1;kbi=0;kb=77;uv=1;uid=2;value=99;
        @(negedge clk);kbv=0;uv=0;if(!ack) $fatal(1,"USB collision ack");check_adsr(99,11,12,14);
        before_count=accepted_count;
        for(i=0;i<32;i=i+1) begin
            // UI write coincides with event capture. Event must still commit.
            @(negedge clk);note=40+i;vel=100;nvalid=1;uid=1;value=255-i;uv=1;
            @(negedge clk);nvalid=0;uv=0;repeat(8) @(negedge clk);
        end
        if(gates!==32'hffffffff || accepted_count!=before_count+32) $fatal(1,"32 voice UI/note coexistence");
        saved_epochs=epochs;
        for(i=0;i<32;i=i+1) begin
            @(negedge clk);note=40+i;vel=0;nvalid=1;uid=2;value=i;uv=1;
            @(negedge clk);nvalid=0;uv=0;repeat(8) @(negedge clk);
        end
        if(gates!==0 || epochs!==saved_epochs || accepted_count!=before_count+32) $fatal(1,"note off lost or accepted pulse on off");
        usb_event(60,100);
        @(negedge clk);stop_key=1;uv=1;uid=1;value=123;
        @(negedge clk);stop_key=0;uv=0;
        if(playing || gates || volume!=123 || !ack) $fatal(1,"USB STOP/UI priority");
        // Disconnect rejects even a valid write and clears note notification.
        @(negedge clk);connected=0;uv=1;uid=1;value=222;
        @(negedge clk);uv=0;
        if(ack || !rejected || gates || playing || host || note_accepted || volume!=123) $fatal(1,"disconnect UI mutation");
        $display("PASS:tb_ui_audio_registers: 32 voices, six UI registers, endpoints, invalid writes, open inputs, USB/UART collisions, stop/disconnect, full FIFO");
        $finish;
    end
    initial begin #100000000; $fatal(1,"UI audio registers timeout");end
endmodule
