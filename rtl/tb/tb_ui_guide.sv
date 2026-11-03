`timescale 1ns/1ps
module tb_ui_guide;
    reg clk=0,rst_n=0,start=0,pause_toggle=0,stop=0,loop_enable=0,auto_finish=1;
    reg [7:0] bpm=120;
    wire playing,paused,beat_pulse,strong_beat,beat_lit,finish,loop_restart;
    wire [31:0] song_tick;
    wire [24:0] expected_keys,preview_keys;
    always #5 clk=~clk;
    guide_transport #(.CLK_HZ(1000),.FLASH_MS(8)) transport(
        clk,rst_n,start|loop_restart,pause_toggle,stop,finish&&auto_finish,bpm,
        playing,paused,song_tick,beat_pulse,strong_beat,beat_lit);
    guide_sequencer sequencer(clk,rst_n,start|loop_restart,stop,playing,paused,
        loop_enable,song_tick,expected_keys,preview_keys,finish,loop_restart,1'b0,1'b0,,);
    integer beats=0,strongs=0,loops=0;
    always @(negedge clk) begin
        if(beat_pulse) begin beats=beats+1;if(strong_beat) strongs=strongs+1;end
        if(loop_restart) loops=loops+1;
    end
    task step(input integer n);repeat(n) begin @(posedge clk);#1;end endtask
    task launch;
        begin @(negedge clk);start=1;step(1);@(negedge clk);start=0;end
    endtask
    task halt;
        begin @(negedge clk);stop=1;step(1);@(negedge clk);stop=0;step(1);end
    endtask
    reg [31:0] frozen_tick;
    integer i,ref_ticks,cycles;
    function [24:0] melody_key(input integer index);
        begin case(index)0,7:melody_key=25'd1;1,6:melody_key=25'd1<<2;
            2,5:melody_key=25'd1<<4;default:melody_key=25'd1<<7;endcase end
    endfunction
    always @(negedge clk)if(rst_n && (expected_keys & (expected_keys-1'b1))!=0)
        $fatal(1,"beginner guide emitted a chord");
    initial begin
        // Shared synchronous reader has bounded initial prefetch latency.
        step(3);@(negedge clk);rst_n=1;launch();step(16);
        if(expected_keys!==25'd1 || !playing) $fatal(1,"first single note missing at tick0");
        wait(song_tick==72);step(1);
        @(negedge clk);pause_toggle=1;step(1);@(negedge clk);pause_toggle=0;
        frozen_tick=song_tick;step(200);
        if(!paused || song_tick!=frozen_tick || expected_keys!==25'd1) $fatal(1,"pause changed score");
        @(negedge clk);pause_toggle=1;step(1);@(negedge clk);pause_toggle=0;
        wait(song_tick==145);step(1);
        if(expected_keys!==0)$fatal(1,"first 0.5beat rest missing");
        wait(song_tick==168);step(1);
        if(preview_keys!==(25'd1<<2))$fatal(1,"second-note preview missing");
        for(i=1;i<8;i=i+1)begin
            wait(song_tick==i*192+1);step(1);
            if(expected_keys!==melody_key(i))$fatal(1,"single note%0d wrong",i);
            if(i<7)begin
                wait(song_tick==i*192+145);step(1);
                if(expected_keys!==0)$fatal(1,"rest after note%0d missing",i);
            end
        end
        wait(!playing);step(2);
        if(expected_keys || preview_keys || song_tick || beat_lit) $fatal(1,"end must stop and clear");
        // Fractional tempo reference: 137*96/60000 tick per ms, no integer BPM drift.
        auto_finish=0;bpm=137;launch();
        for(i=1;i<=10000;i=i+1) begin
            step(1);ref_ticks=(i*137*96)/60000;
            if(song_tick!==ref_ticks) $fatal(1,"fractional tempo drift ms%0d tick%0d ref%0d",i,song_tick,ref_ticks);
        end
        halt();
        // Exact boundary for 4/4, 120 BPM: start and500/1000/1500/2000ms.
        bpm=120;beats=0;strongs=0;launch();step(2001);
        if(beats!=5 || strongs!=2) $fatal(1,"beat/bar count %0d/%0d",beats,strongs);
        halt();loop_enable=1;auto_finish=1;launch();
        wait(loops==1);step(16);
        if(!playing || song_tick>4 || expected_keys!==25'd1) $fatal(1,"loop did not restart");
        halt();if(playing || expected_keys || preview_keys) $fatal(1,"stop not clear");
        // Lowest/highest BPM clamp and reset while paused.
        bpm=0;launch();step(1000);if(song_tick!=48) $fatal(1,"low BPM clamp");halt();
        bpm=255;launch();step(1000);if(song_tick!=384) $fatal(1,"high BPM clamp");
        @(negedge clk);rst_n=0;step(1);
        if(playing || song_tick || expected_keys) $fatal(1,"reset failed");
        $display("PASS tb_ui_guide:8 single white notes,7 rests,repeatGgap,preview,pause,stop,loop,fractional BPM and4/4");$finish;
    end
    initial begin #1000000;$fatal(1,"guide timeout");end
endmodule
