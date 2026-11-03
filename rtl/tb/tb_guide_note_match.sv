`timescale 1ns/1ps
module tb_guide_note_match;
reg clk=0,rst_n=0,disc=0,clear=0,en=1,playing=1,paused=0,tp=0,nv=0;
reg[24:0]target=0;reg[6:0]base=48,note=0,vel=0;reg[3:0]ch=0;wire hit,wrong;wire[24:0]wk;
guide_note_match dut(clk,rst_n,disc,clear,en,playing,paused,tp,target,base,nv,note,vel,ch,hit,wrong,wk);
always #5 clk=~clk;
integer hits=0,wrongs=0,checks=0;
always @(negedge clk)if(rst_n)begin hits=hits+hit;wrongs=wrongs+wrong;end
 task cycle;begin @(posedge clk);#1;end endtask
 task idle;begin @(negedge clk);nv=0;tp=0;clear=0;cycle();end endtask
 task event_note(input integer p,input integer v,input integer channel_id,input integer expected_hit);begin
 @(negedge clk);note=p;vel=v;ch=channel_id;nv=1;cycle();checks=checks+1;
 if(hit!==expected_hit)$fatal(1,"note=%0d vel=%0d ch=%0d expectedhit=%0d actual=%0d check=%0d",p,v,channel_id,expected_hit,hit,checks);
 idle();end endtask
 task arm(input integer p);begin @(negedge clk);target=25'd1<<(p-base);tp=1;cycle();if(hit)$fatal(1,"activation hit");idle();end endtask
 task reset_all;begin @(negedge clk);rst_n=0;nv=0;tp=0;clear=0;disc=0;paused=0;en=1;playing=1;base=48;target=0;cycle();@(negedge clk);rst_n=1;cycle();end endtask
initial begin
 reset_all();arm(60);event_note(60,90,0,1);event_note(60,110,0,0);event_note(60,0,0,0);
 arm(60);event_note(60,90,0,1);arm(60);event_note(60,90,0,0);event_note(60,0,0,0);event_note(60,90,0,1);
 // Only previous accepted note may overlap, not arbitrary extra keys.
 arm(62);event_note(62,90,0,1);arm(64);event_note(64,90,0,0);event_note(64,0,0,0);event_note(60,0,0,0);event_note(64,90,0,1);
 reset_all();event_note(60,90,0,0);arm(60);event_note(60,110,0,0);event_note(60,0,0,0);event_note(60,90,0,1);
 reset_all();@(negedge clk);target=1<<12;tp=1;nv=1;note=60;vel=90;cycle();if(hit)$fatal(1,"same-cycle target accepted");idle();event_note(60,90,0,0);event_note(60,0,0,0);event_note(60,90,0,1);
 reset_all();arm(60);@(negedge clk);paused=1;event_note(60,90,0,0);@(negedge clk);paused=0;event_note(60,90,0,0);event_note(60,0,0,0);event_note(60,90,0,1);
 reset_all();arm(60);event_note(61,90,0,0);if(wk!=(1<<13))$fatal(1,"wrong key indication");event_note(60,90,0,0);event_note(61,0,0,0);event_note(60,90,0,0);event_note(60,0,0,0);event_note(60,90,0,1);
 reset_all();arm(60);event_note(60,90,9,0);event_note(60,90,1,0);event_note(60,90,0,1);
 // clear/base change must retain physical state and defeat duplicate NoteOn.
 @(negedge clk);clear=1;cycle();idle();arm(60);event_note(60,90,0,0);event_note(60,0,0,0);event_note(60,90,0,1);
 @(negedge clk);base=59;cycle();arm(60);event_note(60,90,0,0);event_note(60,0,0,0);event_note(60,90,0,1);
 @(negedge clk);disc=1;cycle();@(negedge clk);disc=0;cycle();arm(60);event_note(60,90,0,1);
 reset_all();base=103;cycle();arm(127);event_note(102,90,0,0);event_note(102,0,0,0);event_note(127,90,0,1);
 reset_all();arm(60);@(negedge clk);playing=0;event_note(60,90,0,0);@(negedge clk);playing=1;arm(60);event_note(60,90,0,0);event_note(60,0,0,0);event_note(60,90,0,1);
 //Source filtering also applies to releases: PAD/wrong-channel off cannot free a held key.
 reset_all();arm(60);event_note(60,90,0,1);arm(60);event_note(60,0,9,0);event_note(60,0,1,0);event_note(60,90,0,0);event_note(60,0,0,0);event_note(60,90,0,1);
 //Pause and progress-clear must dominate coincident matching NoteOn.
 reset_all();arm(60);@(negedge clk);paused=1;nv=1;note=60;vel=90;ch=0;cycle();if(hit)$fatal(1,"pause race");idle();paused=0;event_note(60,90,0,0);event_note(60,0,0,0);
 @(negedge clk);clear=1;nv=1;note=60;vel=90;cycle();if(hit)$fatal(1,"clear race");idle();arm(60);event_note(60,90,0,0);event_note(60,0,0,0);event_note(60,90,0,1);
 $display("PASS guide_note_match checks=%0d",checks);$finish;
end
initial begin #100000;$fatal(1,"watchdog");end
endmodule
