`timescale 1ns/1ps
module tb_ui_key_state;
    reg clk=0,rst_n=0,clear=0,note_valid=0;
    reg [6:0] base_note=60,note=60,velocity=127;
    reg [3:0] channel=0;
    wire [24:0] held_keys;wire out_of_range;
    ui_key_state dut(.*);
    always #10 clk=~clk;
    task step;begin @(posedge clk);#1;end endtask
    task send(input [6:0] n,v,input [3:0] ch);
        begin @(negedge clk);note=n;velocity=v;channel=ch;note_valid=1;
            step();@(negedge clk);note_valid=0;end
    endtask
    initial begin
        step();step();
        if(held_keys!==0 || out_of_range!==0 || dut.old_base!==0)$fatal(1,"constant async reset failed");
        // A note on the first active edge must not disappear because base!=0.
        @(negedge clk);rst_n=1;note_valid=1;step();
        if(held_keys!==1)$fatal(1,"first note after reset lost");
        @(negedge clk);note_valid=0;
        send(60,127,1);send(60,0,0);
        if(held_keys!==1)$fatal(1,"another channel held key was cleared");
        send(60,0,1);if(held_keys!==0)$fatal(1,"last Note Off did not clear");
        send(84,127,0);if(held_keys!==(25'd1<<24))$fatal(1,"upper key missing");
        send(85,127,0);if(!out_of_range)$fatal(1,"out-of-range missing");
        @(negedge clk);base_note=48;step();if(held_keys!==0)$fatal(1,"base change retained old keys");
        send(48,127,0);@(negedge clk);clear=1;step();
        if(held_keys!==0)$fatal(1,"STOP/COMMIT clear failed");
        @(negedge clk);clear=0;base_note=103;rst_n=0;step();
        if(dut.old_base!==0 || held_keys!==0)$fatal(1,"reset depended on live base input");
        $display("PASS tb_ui_key_state constant_reset first_edge_note channel_overlap range base_change clear");$finish;
    end
    initial begin #100000;$fatal(1,"key state timeout");end
endmodule
