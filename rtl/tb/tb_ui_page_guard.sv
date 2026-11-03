`timescale 1ns/1ps
module tb_ui_page_guard;
    reg clk=0,rst_n=0,touch_valid=0,touch_down=0;
    reg [8:0] x=0,y=0;
    wire start,pause_toggle,stop,loop_toggle,param_valid,page_ready;
    wire [3:0] param_id;wire [15:0] param_value;
    wire [1:0] patch,page;wire [7:0] volume;
    wire [6:0] attack,decay,sustain,release_value;
    ui_touch_controls #(.PIPELINED_SCALE(1)) controls(.*);
    wire [6:0] wave_index;wire frame_start,pixel_valid;
    wire [8:0] pixel_x,pixel_y;wire [15:0] pixel_rgb565;
    reg panel_ready=0,pixel_ready=1,playing=0,paused=0,looping=0,beat_lit=0;
    reg latency_seen=0,latency_le_5ms=0,latency_le_10ms=0;
    reg [31:0] latency_cycles=0,overrun_incidents=0;
    reg signed [7:0] wave_sample=0;
    ui_dashboard dashboard(.*);
    always #5 clk=~clk;
    task tick;begin @(posedge clk);#1;end endtask
    task touch(input integer xx,yy,input bit down);
        begin @(negedge clk);x=xx;y=yy;touch_down=down;touch_valid=1;
            tick();@(negedge clk);touch_valid=0;tick();@(negedge clk);end
    endtask
    initial begin
        repeat(3) tick();@(negedge clk);rst_n=1;repeat(3) tick();panel_ready=1;
        wait(page_ready); // first visible WAVE page
        touch(10,120,1);touch(10,120,0);
        if(page!=1 || page_ready) $fatal(1,"page change did not block edits");
        touch(319,150,1);
        if(param_valid || attack!=8) $fatal(1,"hidden ADSR edited before paint");
        // Even a held rejected touch is not retroactively accepted on paint.
        wait(page_ready);touch(319,150,1);
        if(param_valid || attack!=8) $fatal(1,"held rejected touch became slider");
        touch(319,150,0);touch(319,150,1);
        if(!param_valid || attack!=127 || param_id!=2) $fatal(1,"visible ADSR inaccessible");
        touch(319,150,0);
        $display("PASS tb_ui_page_guard: requested-vs-rendered page, hidden edits rejected, release/repress required");$finish;
    end
    initial begin #4000000;$fatal(1,"page guard timeout");end
endmodule
