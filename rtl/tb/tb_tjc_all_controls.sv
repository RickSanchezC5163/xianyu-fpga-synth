`timescale 1ns/1ps
module tb_tjc_all_controls;
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
    reg [87:0] frames[0:`CASE_COUNT-1];
    reg [47:0] expectations[0:`CASE_COUNT-1];
    task byte_send(input [7:0] data);
        begin @(negedge clk);bdata=data;bvalid=1;@(negedge clk);bvalid=0;repeat(11) @(negedge clk);end
    endtask
    task send(input [87:0] frame);
        integer j;
        begin for(j=10;j>=0;j=j-1) byte_send(frame[j*8+:8]);repeat(16) @(negedge clk);end
    endtask
    integer i,pc,gc,ec;
    reg [3:0] held;
    reg [7:0] ek,ei;
    reg [31:0] ex;
    initial begin
        $readmemh("control_frames.hex",frames);
        $readmemh("control_expected.hex",expectations);
        repeat(4) @(negedge clk);rst_n=1;connected=1;
        repeat(8) @(negedge clk);
        if(!host) $fatal(1,"USB session failed");
        @(negedge clk);nv=1;@(negedge clk);nv=0;
        repeat(8) @(negedge clk);held=gates;
        if(held==0) $fatal(1,"held note missing");
        for(i=0;i<`CASE_COUNT;i=i+1) begin
            {ek,ei,ex}=expectations[i];
            pc=param_count;gc=guide_count;ec=event_count;
            send(frames[i]);
            if(event_count!=ec+1 || kind!==ek || id!==ei || value!==ex)
                $fatal(1,"decoder mismatch case %0d",i);
            if(ek==1) begin
                if(param_count!=pc+1 || guide_count!=gc || pid!==ei[3:0] || pval!==ex[15:0] || result!=1 || pending)
                    $fatal(1,"parameter route/ACK mismatch case %0d",i);
                case(ei)
                    0: if(patch!==ex[1:0]) $fatal(1,"patch commit case %0d",i);
                    1: if(volume!==ex[7:0]) $fatal(1,"volume commit case %0d",i);
                    2: if(adsr[6:0]!==ex[6:0]) $fatal(1,"attack commit case %0d",i);
                    3: if(adsr[13:7]!==ex[6:0]) $fatal(1,"decay commit case %0d",i);
                    4: if(adsr[20:14]!==ex[6:0]) $fatal(1,"sustain commit case %0d",i);
                    5: if(adsr[27:21]!==ex[6:0]) $fatal(1,"release commit case %0d",i);
                endcase
            end else if(ek==2) begin
                if(guide_count!=gc+1 || param_count!=pc || gid!==ei[2:0] || gval!==ex[15:0])
                    $fatal(1,"guide route mismatch case %0d",i);
            end else begin
                if(guide_count!=gc || param_count!=pc) $fatal(1,"read-only command wrote backend case %0d",i);
                if(ek==3 && page_id!==ei[2:0]) $fatal(1,"page mismatch case %0d",i);
            end
            if(gates!==held) $fatal(1,"screen control changed held note gates case %0d",i);
        end
        if(crc_errors || format_errors || gap_timeouts) $fatal(1,"valid controls generated decoder errors");
        $display("PASS tjc_all_controls: %0d frames, 51 control script matrix, audio commit/ACK, guide route, page, query, held-note invariant",`CASE_COUNT);
        $finish;
    end
    initial begin #30000000;$fatal(1,"all-controls timeout");end
endmodule
