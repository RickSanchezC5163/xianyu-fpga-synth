`timescale 1ns/1ps
module tb_ui_dashboard;
    reg clk=0,rst_n=0,panel_ready=0,pixel_ready=1;
    reg [1:0] patch=2,page=2;reg [7:0] volume=128;
    reg [6:0] attack=16,decay=32,sustain=96,release_value=64;
    reg playing=1,paused=0,looping=0,beat_lit=0;
    reg latency_seen=1,latency_le_5ms=1,latency_le_10ms=1;
    reg [31:0] latency_cycles=123450,overrun_incidents=2;
    reg signed [7:0] wave_sample=-128;
    wire [6:0] wave_index;wire frame_start,pixel_valid,page_ready;
    wire [8:0] pixel_x,pixel_y;wire [15:0] pixel_rgb565;
    ui_dashboard dut(.*);
    always #5 clk=~clk;
    task tick;begin @(posedge clk);#1;end endtask
    integer x,y,pixels=0,frames=0,image_fd;
    initial begin
        image_fd=$fopen("ui_metrics.ppm","wb");
        if(!image_fd) $fatal(1,"cannot open dashboard render artifact");
        $fwrite(image_fd,"P6\n320 240\n255\n");
        repeat(3) tick();@(negedge clk);rst_n=1;tick();tick();panel_ready=1;#1;
        // Independent raster oracle, all 76800 pixels; snapshot stable per frame.
        for(y=0;y<240;y=y+1) begin
            for(x=0;x<320;x=x+1) begin
                if(pixel_x!=x || pixel_y!=y || !pixel_valid || ^pixel_rgb565===1'bx)
                    $fatal(1,"raster/undefined color at%0d,%0d",x,y);
                if(y==20 && x==160 && pixel_rgb565!==16'h0460) $fatal(1,"selected patch not green");
                if(x==300 && (y==150 || y==175) && pixel_rgb565!==16'h0460) $fatal(1,"numeric pass status not green");
                if(x==20 && y==150) begin patch=0;page=0;end // should apply only next frame
                if(x==100 && y==100) begin
                    pixel_ready=0;repeat(7) tick();
                    if(pixel_x!=x || pixel_y!=y) $fatal(1,"backpressure skipped pixel");pixel_ready=1;
                end
                $fwrite(image_fd,"%c%c%c",((pixel_rgb565>>11)&31)*255/31,
                    ((pixel_rgb565>>5)&63)*255/63,(pixel_rgb565&31)*255/31);
                tick();pixels=pixels+1;
            end
        end
        $fclose(image_fd);
        if(!frame_start || pixel_x || pixel_y) $fatal(1,"frame boundary incorrect");
        tick();
        if(dut.latency_us_l!=2469) $fatal(1,"cycles->microseconds conversion wrong");
        if(dut.decimal5(2469)!=="02469" || dut.decimal5(100000)!=="99999") $fatal(1,"numeric text wrong");
        if(dut.page_l!=0 || dut.patch_l!=0) $fatal(1,"next frame state not captured");
        if(page_ready) $fatal(1,"page enabled before complete rendering");
        // Wave y spans158..222 at signed8 fullscale, never wraps through header.
        wait(pixel_x==32 && pixel_y==222);#1;
        if(pixel_rgb565!==16'h07ff || wave_index!=0) $fatal(1,"negative waveform coordinate");
        wait(frame_start);#1;if(!page_ready) $fatal(1,"rendered page not enabled");
        @(negedge clk);rst_n=0;#1;if(pixel_x || pixel_y) $fatal(1,"renderer reset");
        $display("PASS tb_ui_dashboard: full 76800pixel raster, frame snapshot, stalls, metrics and signed waveform");$finish;
    end
    initial begin #3000000;$fatal(1,"dashboard timeout");end
endmodule
