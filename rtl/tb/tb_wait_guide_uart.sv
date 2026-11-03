`timescale 1ns/1ps
// Real instrument_ui, real UART 8N1 upload and serialized ACK checks.
// Physical ledger stimulus enters only through normal note_valid messages.
module tb_wait_guide_uart #(parameter integer CPB=8);
    `include "wait_guide_vectors.vh"
    reg clk=0,rst_n=0,wifi_rx=1,start=0,stop=0,pause_toggle=0,loop_enable=0;
    reg guide_wait_mode=1,keyboard_disconnected=0;
    reg [7:0] bpm=120;
    reg note_valid=0;reg [6:0] note=48,velocity=0;reg [3:0] channel=0;
    wire wifi_tx,playing,paused,beat_pulse,strong_beat,active_present,committed,range_warning;
    wire [24:0] expected_keys,preview_keys,held_keys;
    wire [31:0] song_tick;
    wire [7:0] active_bpm;wire [6:0] active_base;
    instrument_ui #(.CLK_HZ(10000),.ENABLE_DISPLAY(0),.GUIDE_WAIT_ENABLE(1),
        .WIFI_UART_CLKS_PER_BIT(CPB)) dut(
        .clk(clk),.rst_n(rst_n),.start(start),.pause_toggle(pause_toggle),.stop(stop),.loop_enable(loop_enable),.bpm(bpm),
        .base_note(7'd48),.note_valid(note_valid),.note(note),.velocity(velocity),.channel(channel),
        .sample_valid(1'b0),.sample_pcm(16'sd0),.control_note_on(1'b0),.audio_overrun(1'b0),.active_oscillators(16'd0),
        .touch_irq_n(1'b1),.spi_miso(1'b0),.playing(playing),.paused(paused),.beat_pulse(beat_pulse),.strong_beat(strong_beat),
        .expected_keys(expected_keys),.preview_keys(preview_keys),.held_keys(held_keys),.song_tick(song_tick),.range_warning(range_warning),
        .register_patch(2'd0),.register_volume(8'd20),.register_adsr(28'd0),
        .guide_wait_mode(guide_wait_mode),.keyboard_disconnected(keyboard_disconnected),
        .wifi_rx(wifi_rx),.wifi_tx(wifi_tx),.wifi_active_present(active_present),.wifi_committed(committed),
        .wifi_active_bpm(active_bpm),.wifi_active_base(active_base));
    always #10 clk=~clk;
    always @(posedge clk or negedge rst_n)
        if(!rst_n)bpm<=120;else if(committed)bpm<=active_bpm;
    integer transactions=0,commit_count=0,beat_count=0,hit_count=0,target_count=0,unsupported_count=0;
    always @(negedge clk)if(rst_n)begin
        if(committed)commit_count=commit_count+1;
        if(beat_pulse)beat_count=beat_count+1;
        if(dut.target_hit)hit_count=hit_count+1;
        if(dut.target_pulse)target_count=target_count+1;
        if(dut.unsupported)unsupported_count=unsupported_count+1;
    end
    integer req_file,ack_file,ack_position=0,ack_count=0;
    reg [7:0] ack[0:19],serial_byte;
    integer bit_index;
    always @(negedge wifi_tx)if(rst_n)begin
        repeat(CPB+CPB/2)@(negedge clk);
        for(bit_index=0;bit_index<8;bit_index=bit_index+1)begin
            serial_byte[bit_index]=wifi_tx;repeat(CPB)@(negedge clk);
        end
        if(wifi_tx!==1)$fatal(1,"ACK UART stop bit failed");
        ack[ack_position]=serial_byte;$fwrite(ack_file,"%02x",serial_byte);
        if(ack_position==19)begin ack_position=0;ack_count=ack_count+1;$fwrite(ack_file,"\n");end
        else ack_position=ack_position+1;
    end
    function [15:0] crc16(input [127:0] bytes);
        reg [15:0] c;reg [127:0] v;integer i,j;
        begin
            c=16'hffff;v=bytes;
            for(i=0;i<16;i=i+1)begin
                c=c^{8'd0,v[7:0]};v=v>>8;
                for(j=0;j<8;j=j+1)c=c[0]?(c>>1)^16'ha001:c>>1;
            end
            crc16=c;
        end
    endfunction
    function [63:0] event_word(input [31:0] tick,input [24:0] mask);
        begin event_word={7'd0,mask,tick};end
    endfunction
    task send_byte(input [7:0] value);
        integer b;
        begin
            @(negedge clk);wifi_rx=0;repeat(CPB)@(negedge clk);
            for(b=0;b<8;b=b+1)begin wifi_rx=value[b];repeat(CPB)@(negedge clk);end
            wifi_rx=1;repeat(CPB)@(negedge clk);
        end
    endtask
    task exchange(input [7:0] op,input [15:0] seq,input [31:0] arg,input [63:0] data,
                  input [7:0] status,input [15:0] next_index,input [31:0] token);
        reg [127:0] body,response;reg [15:0] crc;reg [7:0] b;
        integer i,target,timeout;
        begin
            body={data,arg,seq,op,8'd1};crc=crc16(body);target=ack_count+1;
            for(i=0;i<20;i=i+1)begin
                b=i==0?8'hc7:i==1?8'h3a:i<18?(body>>((i-2)*8)):i==18?crc[7:0]:crc[15:8];
                $fwrite(req_file,"%02x",b);send_byte(b);
            end
            $fwrite(req_file,"\n");timeout=0;
            while(ack_count<target && timeout<CPB*300)begin @(negedge clk);timeout=timeout+1;end
            if(ack_count<target)$fatal(1,"UART ACK timeout op%0d seq%0d",op,seq);
            for(i=0;i<16;i=i+1)response[i*8+:8]=ack[i+2];
            if({ack[19],ack[18]}!==crc16(response) || ack[0]!==8'hc7 || ack[1]!==8'h3a)
                $fatal(1,"ACK CRC/header failed");
            if(response[31:0]!=={seq,(op|8'h80),8'd1} || response[63:32]!=={8'd0,next_index,status} ||
               response[127:64]!=={32'd0,token})$fatal(1,"ACK fields wrong op%0d seq%0d got%h",op,seq,response);
            transactions=transactions+1;repeat(CPB*2)@(negedge clk);
        end
    endtask
    task pulse_start;
        begin @(negedge clk);start=1;@(negedge clk);start=0;repeat(16)@(negedge clk);end
    endtask
    task pulse_stop;
        begin @(negedge clk);stop=1;@(negedge clk);stop=0;repeat(4)@(negedge clk);end
    endtask
    task toggle_pause;
        begin @(negedge clk);pause_toggle=1;@(negedge clk);pause_toggle=0;repeat(4)@(negedge clk);end
    endtask
    task wait_tick(input [31:0] target);
        integer timeout;
        begin timeout=0;while(song_tick<target && playing && timeout<20000)begin @(negedge clk);timeout=timeout+1;end
            if(song_tick<target)$fatal(1,"guide tick target%0d not reached got%0d",target,song_tick);
            repeat(10)@(negedge clk);
        end
    endtask
    localparam [31:0] TOKEN_A=32'h13572468,TOKEN_B=32'h24681357;
    integer saved_hits,saved_targets,saved_beats,saved_index,n;
    reg [31:0] saved_tick;
    task key(input [3:0] ch,input [6:0] pitch,input [6:0] vel);
        begin @(negedge clk);note_valid=1;channel=ch;note=pitch;velocity=vel;
            @(negedge clk);note_valid=0;repeat(24)@(negedge clk);end
    endtask
    task expect_head(input integer index,input [24:0] mask);
        integer timeout;
        begin timeout=0;
            while((dut.wifi_guide.player.head_index!=index || expected_keys!==mask || !dut.wait_for_key.matcher.armed) && timeout<500)
                begin @(negedge clk);timeout=timeout+1;end
            if(timeout==500)$fatal(1,"target failed index=%0d expected=%h got index=%0d mask=%h armed=%b",index,mask,
                dut.wifi_guide.player.head_index,expected_keys,dut.wait_for_key.matcher.armed);
            if(preview_keys!==0)$fatal(1,"wait mode leaked timed preview");
        end
    endtask
    task unchanged(input integer hits,input integer index,input [24:0] mask);
        begin repeat(32)@(negedge clk);
            if(hit_count!=hits || dut.wifi_guide.player.head_index!=index || expected_keys!==mask)
                $fatal(1,"unexpected wait advance hits=%0d/%0d index=%0d/%0d mask=%h/%h",hit_count,hits,
                    dut.wifi_guide.player.head_index,index,expected_keys,mask);
        end
    endtask
    task release_all;
        begin
            key(0,48,0);key(0,50,0);key(0,52,0);key(0,53,0);
            if(dut.wait_for_key.matcher.down_count!=0)$fatal(1,"release ledger not empty");
        end
    endtask
    task expect_finished;
        integer timeout;
        begin timeout=0;while(playing && timeout<500)begin @(negedge clk);timeout=timeout+1;end
            if(playing || expected_keys!=0)$fatal(1,"guide did not finish/clear target");
        end
    endtask
    task upload_melody;
        begin
            exchange(1,1,32'h30780008,{TOKEN_A,CRC_MELODY},0,0,TOKEN_A);
            exchange(2,2,0,event_word(0,0),0,1,TOKEN_A);
            exchange(2,3,1,event_word(24,1),0,2,TOKEN_A);
            exchange(2,4,2,event_word(48,0),0,3,TOKEN_A);
            exchange(2,5,3,event_word(96,1),0,4,TOKEN_A);
            exchange(2,6,4,event_word(144,4),0,5,TOKEN_A);
            exchange(2,7,5,event_word(168,0),0,6,TOKEN_A);
            exchange(2,8,6,event_word(192,16),0,7,TOKEN_A);
            exchange(2,9,7,event_word(240,0),0,8,TOKEN_A);
            exchange(3,10,0,{32'd0,TOKEN_A},0,8,TOKEN_A);
            if(active_present)$fatal(1,"VERIFY activated score before COMMIT");
            exchange(4,11,0,{32'd0,TOKEN_A},0,8,TOKEN_A);
            if(!active_present || active_base!=48 || active_bpm!=120 || commit_count!=1)
                $fatal(1,"RAM commit metadata failed");
        end
    endtask
    initial begin
        req_file=$fopen("wait_guide_requests.hex","w");ack_file=$fopen("wait_guide_acks.hex","w");
        repeat(5)@(negedge clk);rst_n=1;repeat(CPB*12)@(negedge clk);
        // Pre-held physical key survives upload/commit; UI-held clearing is not release evidence.
        key(0,48,100);upload_melody();
        if(!dut.wait_for_key.matcher.physical_down[48])$fatal(1,"commit erased physical ledger");
        pulse_start();expect_head(1,1);saved_hits=hit_count;saved_beats=beat_count;saved_tick=song_tick;
        repeat(12000)@(negedge clk);
        unchanged(saved_hits,1,1);
        if(beat_count<=saved_beats || song_tick<=saved_tick+96)$fatal(1,"wait stalled reference beat clock");
        key(9,48,100);unchanged(saved_hits,1,1);key(9,48,0); // PAD channel must not count.
        key(0,48,100);unchanged(saved_hits,1,1); // pre-held/duplicate does not count.
        key(0,52,100);unchanged(saved_hits,1,1); // wrong key and release cannot count.
        key(0,52,0);unchanged(saved_hits,1,1);
        key(0,48,0);unchanged(saved_hits,1,1);
        key(0,48,100);expect_head(3,1);
        if(hit_count!=saved_hits+1)$fatal(1,"fresh C did not advance exactly once");
        saved_hits=hit_count;key(0,48,100);unchanged(saved_hits,3,1);
        key(0,48,0);unchanged(saved_hits,3,1);key(0,48,100);expect_head(4,4);
        // One immediately preceding note may remain held for legato.
        key(0,50,100);expect_head(6,16);
        if(dut.wait_for_key.matcher.down_count!=2)$fatal(1,"legato setup wrong");
        saved_hits=hit_count;
        key(0,53,100);unchanged(saved_hits,6,16); // extra held key blocks next correct attack.
        key(0,52,100);unchanged(saved_hits,6,16);
        key(0,53,0);key(0,48,0);key(0,52,100);unchanged(saved_hits,6,16); // duplicate still not fresh.
        key(0,52,0);key(0,52,100);expect_finished();
        if(hit_count!=saved_hits+1)$fatal(1,"released/re-attacked E did not finish exactly once");
        release_all();
        $display("CHECK CPB=%0d leading-empty/reference-clock/PAD/wrong/preheld/repeat/legato/extra-held PASS",CPB);

        // Inputs arriving during pause are tracked but cannot count after resume.
        pulse_start();expect_head(1,1);toggle_pause();saved_hits=hit_count;saved_tick=song_tick;
        key(0,48,100);repeat(300)@(negedge clk);
        if(!paused || song_tick!=saved_tick)$fatal(1,"pause reference clock changed");
        unchanged(saved_hits,1,1);toggle_pause();unchanged(saved_hits,1,1);
        key(0,48,100);unchanged(saved_hits,1,1);key(0,48,0);key(0,48,100);expect_head(3,1);
        // STOP/restart must retain physical C-down until a real Note Off.
        pulse_stop();if(!dut.wait_for_key.matcher.physical_down[48])$fatal(1,"STOP erased physical ledger");
        pulse_start();expect_head(1,1);saved_hits=hit_count;key(0,48,100);unchanged(saved_hits,1,1);
        key(0,48,0);key(0,48,100);expect_head(3,1);pulse_stop();release_all();
        $display("CHECK CPB=%0d pause-input/STOP-restart-ledger PASS",CPB);

        // Stage a chord while current wait score is held. VERIFY ACK is not activation.
        pulse_start();expect_head(1,1);
        exchange(1,12,32'h30780002,{TOKEN_B,CRC_CHORD},0,0,TOKEN_B);
        exchange(2,13,0,event_word(0,3),0,1,TOKEN_B);
        exchange(2,14,1,event_word(96,0),0,2,TOKEN_B);
        exchange(3,15,0,{32'd0,TOKEN_B},0,2,TOKEN_B);
        if(dut.wifi_guide.active_token!=TOKEN_A || expected_keys!==1)$fatal(1,"staging changed active guide");
        exchange(4,16,0,{32'd0,TOKEN_B},6,2,TOKEN_B);
        if(dut.wifi_guide.active_token!=TOKEN_A || expected_keys!==1)$fatal(1,"BUSY commit changed active guide");
        pulse_stop();exchange(4,16,0,{32'd0,TOKEN_B},0,2,TOKEN_B);
        saved_hits=hit_count;n=unsupported_count;pulse_start();expect_finished();
        if(!range_warning || unsupported_count!=n+1 || hit_count!=saved_hits)
            $fatal(1,"wait chord not explicitly unsupported/finished/range flagged");
        $display("CHECK CPB=%0d UART-staging/BUSY/unsupported-chord PASS",CPB);

        // Same uploaded chord is legal in timed mode. Keys must not advance it.
        guide_wait_mode=0;pulse_start();
        repeat(30)@(negedge clk);
        if(expected_keys!==3 || range_warning)$fatal(1,"timed chord did not start normally");
        saved_hits=hit_count;key(0,48,100);key(0,49,100);key(0,48,0);key(0,49,0);
        repeat(1500)@(negedge clk);
        if(!playing || expected_keys!==3 || dut.wifi_guide.player.head_index!=1 || hit_count!=saved_hits || song_tick>=96)
            $fatal(1,"timed mode advanced early due to keyboard input");
        wait_tick(90);if(expected_keys!==3)$fatal(1,"timed chord disappeared before final tick");
        n=0;while(playing && n<1000)begin @(negedge clk);n=n+1;end
        if(playing || expected_keys!=0 || song_tick!=0)$fatal(1,"timed final empty did not stop normally");
        if(commit_count!=2)$fatal(1,"unexpected bank flip count");
        $display("PASS tb_wait_guide_uart CPB=%0d transactions=%0d commits=%0d hits=%0d targets=%0d beats=%0d UART/RAM/wait/timed/ledger",CPB,transactions,commit_count,hit_count,target_count,beat_count);
        $fclose(req_file);$fclose(ack_file);$finish;
    end
    initial begin #100000000;$fatal(1,"wait guide UART integration timeout");end
endmodule
