`timescale 1ns/1ps
// Physical8N1 stimulus/ACK receiver around the real instrument_ui guide clock.
module tb_wifi_guide_source #(
    parameter integer CPB=8,ALTERNATE_LEDS=0
);
    `include "wifi_guide_vectors.vh"
    reg clk=0,rst_n=0,wifi_rx=1,start=0,stop=0,pause_toggle=0,loop_enable=0;
    reg [7:0] bpm=120;
    reg note_valid=0;reg [6:0] note=48,velocity=127;
    wire wifi_tx,playing,paused,beat_pulse,strong_beat,active_present,committed;
    wire [24:0] expected_keys,preview_keys,held_keys;
    wire [31:0] song_tick;
    wire [7:0] active_bpm;
    wire [6:0] active_base;
    localparam [199:0] MAP_DEFAULT={8'd38,8'd35,8'd34,8'd32,8'd31,8'd30,8'd29,
        8'd27,8'd25,8'd23,8'd22,8'd21,8'd19,8'd17,8'd16,8'd14,8'd13,
        8'd12,8'd10,8'd9,8'd6,8'd5,8'd4,8'd3,8'd1};
    localparam [199:0] MAP_LINEAR={8'd25,8'd24,8'd23,8'd22,8'd21,8'd20,8'd19,8'd18,
        8'd17,8'd16,8'd15,8'd14,8'd13,8'd12,8'd11,8'd10,8'd9,8'd8,8'd7,8'd6,
        8'd5,8'd4,8'd3,8'd2,8'd1};
    localparam integer EXTERNAL=ALTERNATE_LEDS?27:40;
    instrument_ui #(.CLK_HZ(10000),.ENABLE_DISPLAY(0),.WIFI_UART_CLKS_PER_BIT(CPB),
        .LED_EXTERNAL_PIXELS(EXTERNAL),.LED_PREFIX_PIXELS(1),
        .LED_KEY_MAP(ALTERNATE_LEDS?MAP_LINEAR:MAP_DEFAULT)) dut(
        .clk(clk),.rst_n(rst_n),.start(start),.pause_toggle(pause_toggle),.stop(stop),.loop_enable(loop_enable),.bpm(bpm),
        .base_note(7'd48),.note_valid(note_valid),.note(note),.velocity(velocity),.channel(4'd0),
        .sample_valid(1'b0),.sample_pcm(16'sd0),.control_note_on(1'b0),.audio_overrun(1'b0),.active_oscillators(16'd0),
        .touch_irq_n(1'b1),.spi_miso(1'b0),.playing(playing),.paused(paused),.beat_pulse(beat_pulse),.strong_beat(strong_beat),
        .expected_keys(expected_keys),.preview_keys(preview_keys),.held_keys(held_keys),.song_tick(song_tick),
        .register_patch(2'd0),.register_volume(8'd20),.register_adsr(28'd0),
        .wifi_rx(wifi_rx),.wifi_tx(wifi_tx),.wifi_active_present(active_present),.wifi_committed(committed),
        .wifi_active_bpm(active_bpm),.wifi_active_base(active_base));
    always #10 clk=~clk;
    always @(posedge clk or negedge rst_n)
        if(!rst_n)bpm<=120;else if(committed)bpm<=active_bpm;
    integer commit_count=0,beat_count=0,loop_count=0,transactions=0;
    always @(negedge clk)if(rst_n)begin
        if(committed)commit_count=commit_count+1;
        if(beat_pulse)beat_count=beat_count+1;
        if(dut.loop_restart)loop_count=loop_count+1;
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
    localparam [31:0] TOKEN_A=32'h11223344,TOKEN_B=32'h55667788,TOKEN_C=32'h99aabbcc;
    integer n,old_loop;
    reg [31:0] paused_tick;
    initial begin
        req_file=$fopen("wifi_guide_requests.hex","w");ack_file=$fopen("wifi_guide_acks.hex","w");
        repeat(5)@(negedge clk);rst_n=1;repeat(CPB*12)@(negedge clk);
        if(active_present)$fatal(1,"reset did not chooseROM");
        if($bits(dut.led_frame)!=(EXTERNAL+1)*24 || dut.strip.PIXELS!=EXTERNAL+1)
            $fatal(1,"LED frame/serializer counts disagree");
        pulse_start();
        if(expected_keys!==25'd1)$fatal(1,"ROM first single note missing");
        toggle_pause();paused_tick=song_tick;repeat(200)@(negedge clk);
        if(!paused || song_tick!=paused_tick || preview_keys!=0)$fatal(1,"ROM pause failed");
        pulse_stop();if(playing || expected_keys!=0)$fatal(1,"ROM STOP failed");

        // Held feedback must clear on metadata commit; it is not audio retuning.
        @(negedge clk);note_valid=1;note=48;@(negedge clk);note_valid=0;
        if(held_keys!==1)$fatal(1,"baseline held key missing");
        exchange(1,1,32'h3cb40003,{TOKEN_A,CRC_A},0,0,TOKEN_A);
        exchange(2,2,0,event_word(0,1),0,1,TOKEN_A);
        exchange(2,3,1,event_word(96,6),0,2,TOKEN_A);
        exchange(2,4,2,event_word(192,0),0,3,TOKEN_A);
        exchange(3,5,0,{32'd0,TOKEN_A},0,3,TOKEN_A);
        exchange(4,6,0,{32'd0,TOKEN_A},0,3,TOKEN_A);
        if(!active_present || active_bpm!=180 || bpm!=180 || active_base!=60 || held_keys!=0 || commit_count!=1)
            $fatal(1,"commit metadata/held clear failed");
        exchange(4,6,0,{32'd0,TOKEN_A},0,3,TOKEN_A);
        if(commit_count!=1)$fatal(1,"duplicate COMMIT pulsed again");
        @(negedge clk);note_valid=1;note=60;@(negedge clk);note_valid=0;
        if(held_keys!==1)$fatal(1,"uploaded base note not applied");
        pulse_start();if(expected_keys!==1)$fatal(1,"RAM firsteventtick0 failed");
        wait_tick(72);if(preview_keys!==6)$fatal(1,"RAM lookahead preview failed");
        toggle_pause();paused_tick=song_tick;repeat(200)@(negedge clk);
        if(!paused || song_tick!=paused_tick || expected_keys!==1 || preview_keys!=0)$fatal(1,"RAM pause changed clock/state");
        toggle_pause();wait_tick(96);if(expected_keys!==6)$fatal(1,"RAM chord atomicsnapshot failed");
        wait_tick(190);repeat(100)@(negedge clk);
        if(playing || expected_keys!=0)$fatal(1,"RAM finalempty didnot finish");

        loop_enable=1;pulse_start();old_loop=loop_count;
        exchange(1,7,32'h485a0002,{TOKEN_B,CRC_B},0,0,TOKEN_B);
        exchange(2,8,0,event_word(0,4),0,1,TOKEN_B);
        exchange(2,9,1,event_word(200,0),0,2,TOKEN_B);
        exchange(3,10,0,{32'd0,TOKEN_B},0,2,TOKEN_B);
        if(!playing || dut.wifi_guide.active_token!=TOKEN_A || active_base!=60 || loop_count<=old_loop)
            $fatal(1,"staging upload disturbed oldplaying/looped score");
        exchange(4,11,0,{32'd0,TOKEN_B},6,2,TOKEN_B);
        pulse_stop();loop_enable=0;
        exchange(4,11,0,{32'd0,TOKEN_B},0,2,TOKEN_B);
        if(active_base!=72 || bpm!=90 || held_keys!=0 || commit_count!=2)$fatal(1,"secondscore commitfailed");
        pulse_start();if(expected_keys!==4)$fatal(1,"two-event score failed");pulse_stop();

        // Same token/count/BPM/base but different event data still requires a
        // real metadata-commit pulse; comparing token alone would miss this.
        exchange(1,280,32'h485a0002,{TOKEN_B,CRC_B2},0,0,TOKEN_B);
        exchange(2,281,0,event_word(0,8),0,1,TOKEN_B);
        exchange(2,282,1,event_word(200,0),0,2,TOKEN_B);
        exchange(3,283,0,{32'd0,TOKEN_B},0,2,TOKEN_B);
        exchange(4,284,0,{32'd0,TOKEN_B},0,2,TOKEN_B);
        exchange(4,284,0,{32'd0,TOKEN_B},0,2,TOKEN_B);
        if(commit_count!=3)$fatal(1,"same-token metadata commit not detected exactlyonce");
        pulse_start();if(expected_keys!==8)$fatal(1,"same-token replacementscore notused");pulse_stop();

        // Address255/count256 must remain nine-bit metadata while RAM address is8bit.
        exchange(1,12,32'h30f00100,{TOKEN_C,CRC_FULL},0,0,TOKEN_C);
        for(n=0;n<256;n=n+1)
            exchange(2,13+n,n,event_word(n,n==255?25'd0:(25'd1<<(n%25))),0,n+1,TOKEN_C);
        exchange(3,269,0,{32'd0,TOKEN_C},0,256,TOKEN_C);
        exchange(4,270,0,{32'd0,TOKEN_C},0,256,TOKEN_C);
        if(dut.wifi_guide.active_count!=256 || commit_count!=4)$fatal(1,"fullscore countwrong");
        pulse_start();
        while(playing)@(negedge clk);
        if(expected_keys!=0 || dut.wifi_guide.player.head_index!=255)$fatal(1,"fullscore wrapped or notended");

        // Reuse exactly the same token/metadata with another file: a realcommit must pulse.
        exchange(1,271,32'h30f00100,{TOKEN_C,CRC_FULL},0,0,TOKEN_C);
        exchange(5,272,0,{32'd0,TOKEN_C},0,0,TOKEN_C);
        @(negedge clk);rst_n=0;repeat(5)@(negedge clk);rst_n=1;repeat(CPB*12)@(negedge clk);
        if(active_present)$fatal(1,"reset failed ROM fallback");
        pulse_start();if(expected_keys!==25'd1)$fatal(1,"ROM fallback afterreset single note missing");
        pulse_stop();
        $display("PASS wifi_guide_source CPB=%0d external_pixels=%0d transactions=%0d commits=%0d beats=%0d loops=%0d ROM/RAM/preview/pause/stop/full256/metadata/serial8N1",CPB,EXTERNAL,transactions,commit_count,beat_count,loop_count);
        $fclose(req_file);$fclose(ack_file);$finish;
    end
    initial begin #100000000;$fatal(1,"wifi guide integration timeout");end
endmodule
