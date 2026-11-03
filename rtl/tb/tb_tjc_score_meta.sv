`timescale 1ns/1ps
module tb_tjc_score_meta;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,request=0,active=0,playing=0,paused=0,context_ready=1;
reg[2:0]page=2;reg[191:0]title=0;reg[4:0]title_len=0;reg[9:0]part=0,parts=0;reg[7:0]bpm=120;
wire busy,valid;wire[7:0]data;integer cycle=0;
wire ready=(cycle%7!=1 && cycle%7!=4 && cycle%7!=5);
tjc_score_meta_tx dut(clk,rst_n,request,page,active,title,title_len,part,parts,bpm,playing,paused,context_ready,busy,valid,data,ready,4'd0,768'd0,20'd0);
integer fd,case_id=0,cut=-1,accepted=0,ticks=0,previous_count=0;string path;
reg stalled=0;reg[7:0]previous_data;
always @(posedge clk)begin
 cycle<=cycle+1;
 if(rst_n && valid && !ready)begin
  if(stalled && data!==previous_data)$fatal(1,"metadata changed under backpressure");
  stalled<=1;previous_data<=data;
 end else stalled<=0;
 if(rst_n && valid && ready)begin
  $fwrite(fd,"%0d %0d %02x\n",case_id,cut,data);accepted=accepted+1;
 end
end
task cycles(input integer n);repeat(n)@(negedge clk);endtask
task run_case(input integer which,input integer limit);
 begin
 case_id=which;cut=limit;accepted=0;page=which==3?5:2;active=which!=0 && which!=7;context_ready=which!=5;
 playing=which!=0;paused=which==4;bpm=which==4?240:120;part=2;parts=359;
 title=192'ha6d0a2ceebd3f9c9e8b8;title_len=10;
 if(which==0 || which==7)begin title=0;title_len=0;part=0;parts=0;playing=0;end
 if(which==2)begin title={192{1'b1}};title_len=0;end
 if(which==3)begin title=192'he8b8535251504f4e4d4c4b4a494847464544434241;title_len=21;end
 if(which==4)begin title=192'hf9c9e8b8a6d0a2ceebd3f9c9e8b8a6d0a2ceebd3f9c9e8b8;title_len=24;part=999;parts=999;end
 cycles(1);request=1;cycles(1);request=0;ticks=0;
 while(busy && ticks<5000)begin
  cycles(1);ticks=ticks+1;
  if(limit==0 || limit>0 && accepted>=limit)page=0;
  if(which==6 && accepted>1)begin title=0;title_len=0;part=888;parts=888;active=0;end
 end
 if(busy)$fatal(1,"metadata timeout");
 $fwrite(fd,"END %0d %0d %0d\n",which,limit,accepted);
 cycles(2);
 end
endtask
integer n;
initial begin
 if(!$value$plusargs("LOG=%s",path))path="tmp/tjc_score_meta_commands.txt";
 fd=$fopen(path,"w");cycles(3);rst_n=1;cycles(1);
 for(n=0;n<7;n=n+1)run_case(n,-1);
 run_case(1,0);
 for(n=1;n<=180;n=n+1)run_case(1,n);
 // Reset clears prior Wi-Fi identity; the next batch must explicitly show ROM.
 rst_n=0;cycles(2);rst_n=1;cycles(2);run_case(7,-1);
 page=0;request=1;cycles(1);request=0;cycles(100);
 if(busy || valid)$fatal(1,"metadata on unrelated page");
 $fclose(fd);$display("PASS METADATA: GB2312, old sender, reset, source, snapshot, 181 navigation cuts and stalled TX");$finish;
end
initial begin #30000000;$fatal(1,"test timeout");end
endmodule
