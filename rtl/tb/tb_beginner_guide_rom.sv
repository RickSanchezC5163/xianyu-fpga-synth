`timescale 1ns/1ps
// Independent table oracle and Wi-Fi-source ROM fallback boundary checks.
module tb_beginner_guide_rom;
    reg clk=0,rst_n=0,start=0,stop=0,playing=0,paused=0,loop_enable=0;
    reg [31:0] song_tick=0;
    wire [24:0] expected_keys,preview_keys;
    wire finish,loop_restart,active_present;
    wifi_guide_source #(.UART_CLKS_PER_BIT(8)) dut(
        .clk(clk),.rst_n(rst_n),.wifi_rx(1'b1),.wifi_tx(),.start(start|loop_restart),
        .stop(stop),.playing(playing),.paused(paused),.loop_enable(loop_enable),.song_tick(song_tick),
        .expected_keys(expected_keys),.preview_keys(preview_keys),.finish(finish),.loop_restart(loop_restart),
        .active_present(active_present),.committed(),.active_count(),.active_bpm(),.active_base(),.active_token());
    reg [3:0] address=0;
    wire [31:0] rom_tick;wire [24:0] rom_keys;wire rom_last;
    guide_score_rom probe(address,rom_tick,rom_keys,rom_last);
    always #10 clk=~clk;
    integer finishes=0,loops=0,checked=0;
    always @(posedge clk)begin
        if(rst_n && finish)begin finishes=finishes+1;playing<=0;end
        if(rst_n && loop_restart)begin loops=loops+1;song_tick<=0;end
    end
    function [31:0] tick_ref(input integer index);
        begin tick_ref=(index==15)?1536:(index/2)*192+(index%2?144:0);end
    endfunction
    function [24:0] mask_ref(input integer index);
        begin
            if(index%2)mask_ref=0;
            else case(index/2)0,7:mask_ref=1;1,6:mask_ref=25'd1<<2;2,5:mask_ref=25'd1<<4;default:mask_ref=25'd1<<7;endcase
        end
    endfunction
    task settle;repeat(16)@(negedge clk);endtask
    task launch;
        begin @(negedge clk);playing=1;song_tick=0;start=1;@(negedge clk);start=0;settle();end
    endtask
    task at(input [31:0] tick,input [24:0] mask);
        begin
            @(negedge clk);song_tick=tick;settle();
            if(expected_keys!==mask)$fatal(1,"WiFiROM tick%0d got%h expected%h",tick,expected_keys,mask);
            if((expected_keys & (expected_keys-1'b1))!=0)$fatal(1,"WiFiROM emittedchord");
            checked=checked+1;
        end
    endtask
    integer i;
    initial begin
        address=15;#1;
        for(i=0;i<16;i=i+1)begin
            address=i;#1;
            if(rom_tick!==tick_ref(i) || rom_keys!==mask_ref(i) || rom_last!==(i==15))
                $fatal(1,"ROMentry%0d got tick%0d key%h last%b expected tick%0d key%h last%b",i,rom_tick,rom_keys,rom_last,tick_ref(i),mask_ref(i),(i==15));
            if(rom_keys!=0 && rom_keys!=1 && rom_keys!=(25'd1<<2) && rom_keys!=(25'd1<<4) && rom_keys!=(25'd1<<7))
                $fatal(1,"ROM nonwhite/multinote mask");
            $display("ROM %0d %0d %0h %0d",i,rom_tick,rom_keys,rom_last);
        end
        repeat(4)@(negedge clk);rst_n=1;launch();
        if(active_present || dut.source_count!=16 || expected_keys!==1)$fatal(1,"ROMfallback count/firstnote failed");
        // Pausing prevents an OFF event from advancing either expected or preview.
        @(negedge clk);paused=1;song_tick=144;settle();
        if(expected_keys!==1 || preview_keys!=0)$fatal(1,"paused source advanced");
        @(negedge clk);paused=0;at(144,0);
        for(i=2;i<16;i=i+1)begin
            if(i%2==0)begin
                at(tick_ref(i)-25,0);if(preview_keys!=0)$fatal(1,"preview tooearly");
                at(tick_ref(i)-24,0);if(preview_keys!==mask_ref(i))$fatal(1,"preview at24tick missing");
            end
            at(tick_ref(i),mask_ref(i));
            if(i<15 && finishes!=0)$fatal(1,"ROM finished early beforeaddress15");
        end
        if(finishes!=1 || playing || dut.player.head_index!=0 || expected_keys!=0)$fatal(1,"finaloff didnotstop");
        // Full16event loop, including an explicit gap between repeatedG notes.
        loop_enable=1;launch();
        for(i=1;i<16;i=i+1)at(tick_ref(i),i==15?25'd1:mask_ref(i));
        if(loops!=1 || song_tick!=0 || expected_keys!==1)$fatal(1,"ROM16entry looprestartfailed");
        @(negedge clk);stop=1;@(negedge clk);stop=0;playing=0;settle();
        if(expected_keys || preview_keys)$fatal(1,"STOP didnotclear");
        $display("PASS tb_beginner_guide_rom entries16 notes8 rests7 repeatedGgap final1536 loop checks=%0d",checked);$finish;
    end
    initial begin #1000000;$fatal(1,"beginnerROMtimeout");end
endmodule
