`timescale 1ns/1ps
// Pixel-for-pixel reference frozen before timing optimization. Both rasters
// advance only on the pipelined producer handshake, so bubbles are irrelevant.
module tb_ui_dashboard_pipeline;
    reg clk=0,rst_n=0,panel_ready=0,pixel_ready=1;
    reg [1:0] patch=2,page=2;reg [7:0] volume=128;
    reg [6:0] attack=16,decay=32,sustain=96,release_value=64;
    reg playing=1,paused=0,looping=0,beat_lit=0;
    reg latency_seen=1,latency_le_5ms=1,latency_le_10ms=1;
    reg [31:0] latency_cycles=123450,overrun_incidents=2;
    reg signed [7:0] wave_sample=-128;
    wire [6:0] wave_index,ref_wave_index;
    wire frame_start,pixel_valid,page_ready;
    wire [8:0] pixel_x,pixel_y;
    wire [15:0] pixel_rgb565;
    wire advance=pixel_valid && pixel_ready;
    wire ref_frame_start,ref_valid,ref_page_ready;
    wire [8:0] ref_x,ref_y;wire [15:0] ref_color;
    ui_dashboard #(.PIPELINED(1)) dut(.*);
    ui_dashboard_reference reference(
        .clk(clk),.rst_n(rst_n),.panel_ready(panel_ready),.pixel_ready(advance),
        .patch(patch),.volume(volume),.attack(attack),.decay(decay),.sustain(sustain),.release_value(release_value),
        .page(page),.playing(playing),.paused(paused),.looping(looping),.beat_lit(beat_lit),
        .latency_seen(latency_seen),.latency_le_5ms(latency_le_5ms),.latency_le_10ms(latency_le_10ms),
        .latency_cycles(latency_cycles),.overrun_incidents(overrun_incidents),.wave_sample(wave_sample),
        .wave_index(ref_wave_index),.frame_start(ref_frame_start),.page_ready(ref_page_ready),
        .pixel_valid(ref_valid),.pixel_x(ref_x),.pixel_y(ref_y),.pixel_rgb565(ref_color));
    always #5 clk=~clk;
    integer n=0,count=0,case_n=0,all_pixels=0;
    reg stalled=0;reg [33:0] saved;
    always @(negedge clk) begin
        n=n+1;pixel_ready=n%13!=0 && n%17!=0;
    end
    always @(posedge clk) if(rst_n && panel_ready) begin
        if(stalled && {pixel_x,pixel_y,pixel_rgb565}!==saved) $fatal(1,"producer changed stalled pixel");
        stalled=pixel_valid && !pixel_ready;saved={pixel_x,pixel_y,pixel_rgb565};
        if(advance) begin
            if(pixel_x!==ref_x || pixel_y!==ref_y || pixel_rgb565!==ref_color || wave_index!==ref_wave_index)
                $fatal(1,"raster mismatch case%0d pixel%0d,%0d actual%h ref%h",case_n,pixel_x,pixel_y,pixel_rgb565,ref_color);
            count=count+1;all_pixels=all_pixels+1;
        end
    end
    initial begin
        for(case_n=0;case_n<6;case_n=case_n+1) begin
            @(negedge clk);rst_n=0;panel_ready=0;count=0;stalled=0;
            page=case_n%3;patch=case_n%4;wave_sample=case_n%2?-128:127;
            latency_seen=case_n!=4;latency_le_5ms=case_n%2;latency_le_10ms=case_n!=5;
            latency_cycles=case_n==5?32'hffffffff:32'd123450;
            overrun_incidents=case_n==5?32'hffffffff:32'd2;
            repeat(3) @(negedge clk);rst_n=1;repeat(3) @(negedge clk);panel_ready=1;
            wait(count==76800);@(negedge clk);panel_ready=0;
        end
        $display("PASS tb_ui_dashboard_pipeline: %0d pixels identical to frozen pre-optimization renderer, sixpage/state fixtures, stalls, signedwave and saturatednumbers",all_pixels);$finish;
    end
    initial begin #100000000;$fatal(1,"pipelined dashboard timeout");end
endmodule
