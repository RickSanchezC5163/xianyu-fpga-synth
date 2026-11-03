`timescale 1ns/1ps
module tb_tjc_control;
    reg clk=0,rst_n=0,bvalid=0,ferror=0,connected=0,ready=1,urgent=0,mask_ack=0;
    reg [7:0] bdata=0;
    wire ev,pv,gv,snap,pending,ack,reject,host;
    wire [7:0] kind,id,volume;
    wire [31:0] value,crc_errors,format_errors,gap_timeouts,rejected_count;
    wire [3:0] pid;wire [15:0] pval,gval;wire [2:0] gid,page_id,result;
    wire [27:0] adsr;
    wire [1:0] patch;
    wire [3:0] gates;
    reg nv=0;reg [6:0] note=60,velocity=100;
    tjc_event_rx #(.GAP_CYCLES(160)) decoder(clk,rst_n,bvalid,bdata,ferror,ev,kind,id,value,
        crc_errors,format_errors,gap_timeouts);
    tjc_control_bridge #(.ACK_TIMEOUT_CYCLES(40)) bridge(clk,rst_n,ev,kind,id,value,
        ready&&host,urgent,8'd1,pv,pid,pval,ack&&!mask_ack,reject&&!mask_ack,
        gv,gid,gval,snap,page_id,result,rejected_count,pending);
    midi_control #(.VOICES(4),.CLKS_PER_BIT(16)) audio(
        .clk(clk),.rst_n(rst_n),.rx(1'b1),.sample_tick(1'b0),.audio_ready(ready),.audio_overrun(1'b0),
        .usb_dp_stable(1'b1),.usb_dm_stable(1'b0),.usb_connected(connected),
        .usb_note_valid(nv),.usb_note(note),.usb_velocity(velocity),.usb_channel(4'd0),.usb_patch_select(2'd0),
        .usb_mod_valid(1'b0),.usb_mod_depth(7'd0),.usb_bend_valid(1'b0),.usb_bend_word(14'd8192),
        .usb_play(1'b0),.usb_stop(urgent),.usb_record(1'b0),
        .usb_knob_a_valid(1'b0),.usb_knob_a_index(3'd0),.usb_knob_a_value(7'd0),
        .usb_knob_b_valid(1'b0),.usb_knob_b_index(3'd0),.usb_knob_b_value(7'd0),
        .usb_pad_b_valid(1'b0),.usb_pad_b_note(7'd0),.host_mode(host),.volume(volume),.gates(gates),
        .ui_param_valid(pv),.ui_param_id(pid),.ui_param_value(pval),.ui_param_ack(ack),.ui_param_rejected(reject),
        .adsr_controls(adsr),.configured_patch(patch));
    always #10 clk=~clk;
    integer param_count=0,guide_count=0,event_count=0;
    always @(negedge clk) begin
        if(pv) param_count=param_count+1;
        if(gv) guide_count=guide_count+1;
        if(ev) event_count=event_count+1;
    end
    reg [87:0] vectors[0:273];
    task byte_send(input [7:0] data);
        begin @(negedge clk);bdata=data;bvalid=1;@(negedge clk);bvalid=0;repeat(11) @(negedge clk);end
    endtask
    task send(input [87:0] frame);
        integer i;
        begin for(i=10;i>=0;i=i-1) byte_send(frame[i*8+:8]);repeat(16) @(negedge clk);end
    endtask
    integer i,j,before_params,before_guides,before_events;reg [3:0] held;
    initial begin
        $readmemh("tjc_vectors.hex",vectors);
        repeat(4) @(negedge clk);rst_n=1;
        send(vectors[20]);
        if(result!=2 || param_count!=0 || host) $fatal(1,"screen armed disconnected audio");
        connected=1;repeat(8) @(negedge clk);
        if(!host) $fatal(1,"USB session failed");
        @(negedge clk);nv=1;@(negedge clk);nv=0;repeat(8) @(negedge clk);held=gates;
        if(held==0) $fatal(1,"test note absent");
        for(i=0;i<256;i=i+1) begin
            send(vectors[i]);
            if(volume!==i[7:0] || result!=1 || pending) $fatal(1,"volume mismatch %0d %0d",i,volume);
            if(gates!==held) $fatal(1,"screen parameter changed note gates");
        end
        for(i=256;i<262;i=i+1) send(vectors[i]);
        if(adsr!={7'd127,7'd127,7'd127,7'd127} || patch!=3) $fatal(1,"ADSR/patch mismatch");
        before_params=param_count;
        for(i=262;i<268;i=i+1) begin send(vectors[i]);if(result!=2) $fatal(1,"invalid range accepted %0d",i);end
        if(param_count!=before_params) $fatal(1,"bad command reached backend");
        // Every single-bit corruption across header/payload/CRC/tail is rejected;
        // an immediately following good frame must restore synchronization.
        for(j=0;j<88;j=j+1) begin
            before_events=event_count;send(vectors[100]^(88'd1<<j));
            if(event_count!=before_events) $fatal(1,"single-bit corruption accepted %0d",j);
            send(vectors[200]);if(volume!=200) $fatal(1,"resync failed %0d",j);
        end
        before_guides=guide_count;
        send(vectors[268]);if(guide_count!=before_guides+1 || gid!=1) $fatal(1,"guide STOP missing");
        if(gates!==held) $fatal(1,"guide STOP changed audio gates");
        send(vectors[269]);if(page_id!=4) $fatal(1,"page report lost");
        before_params=param_count;before_guides=guide_count;
        send(vectors[270]);if(param_count!=before_params || guide_count!=before_guides) $fatal(1,"query modified controls");
        send(vectors[271]);if(result!=2) $fatal(1,"unavailable score accepted");
        byte_send(8'ha6);byte_send(8'h5a);byte_send(8'h01);repeat(170) @(negedge clk);
        if(gap_timeouts==0) $fatal(1,"partial frame did not time out");
        send(vectors[201]);if(volume!=201) $fatal(1,"gap recovery failed");
        byte_send(8'ha6);byte_send(8'h5a);ferror=1;@(negedge clk);ferror=0;
        send(vectors[202]);if(volume!=202) $fatal(1,"framing recovery failed");
        urgent=1;before_params=param_count;send(vectors[203]);urgent=0;
        if(param_count!=before_params || result!=2) $fatal(1,"urgent stop priority failed");
        mask_ack=1;send(vectors[204]);repeat(45) @(negedge clk);
        if(result!=4 || pending) $fatal(1,"missing ACK test: result=%0d pending=%b host=%b ready=%b",result,pending,host,ready);mask_ack=0;
        connected=0;repeat(8) @(negedge clk);before_params=param_count;
        send(vectors[205]);if(param_count!=before_params || result!=2) $fatal(1,"disconnect write accepted");
        $display("PASS tjc_control: volume256 ADSR ranges bitflips88 resync timeout ACK STOP gates");$finish;
    end
    initial begin #30000000;$fatal(1,"tjc control bench timeout");end
endmodule
