`timescale 1ns/1ps
module tb_guide_event_player;
reg clk=0,rst_n=0,start=0,stop=0,playing=0,paused=0,loop_en=0,changed=0,wait_mode=0,hit=0;
reg[31:0]tick=0;reg[8:0]count=0;wire req;wire[7:0]addr;reg rv=0;reg[63:0]rd=0,mem[0:255];wire[24:0]expected,preview;wire finish,restart,tp,unsupported;
guide_event_player #(.ENABLE_WAIT_MODE(1)) dut(clk,rst_n,start,stop,playing,paused,loop_en,changed,tick,count,req,addr,rv,rd,wait_mode,hit,expected,preview,finish,restart,tp,unsupported);
always #5 clk=~clk;
integer reads=0,finishes=0,loops=0,targets=0,uns=0,maxaddr=0,i;
always @(posedge clk)begin rv<=req;if(req)begin rd<=mem[addr];reads=reads+1;if(addr>maxaddr)maxaddr=addr;if(addr>=count)$fatal(1,"out of bounds addr%0d count%0d",addr,count);end end
always @(negedge clk)if(rst_n)begin finishes=finishes+finish;loops=loops+restart;targets=targets+tp;uns=uns+unsupported;end
 task cycles(input integer n);repeat(n)begin @(posedge clk);#1;end endtask
 task launch(input integer stepping,input integer size,input integer looping);begin
 @(negedge clk);rst_n=0;playing=0;start=0;stop=0;changed=0;paused=0;hit=0;tick=0;wait_mode=stepping;count=size;loop_en=looping;cycles(2);
 @(negedge clk);rst_n=1;playing=1;start=1;reads=0;finishes=0;loops=0;targets=0;uns=0;maxaddr=0;cycles(1);@(negedge clk);start=0;end endtask
 task target_wait(input[24:0] mask);integer n;begin n=0;while(expected!==mask && n<4000)begin cycles(1);n=n+1;end if(expected!==mask)$fatal(1,"target timeout want%h got%h",mask,expected);end endtask
 task accept;begin @(negedge clk);hit=1;cycles(1);@(negedge clk);hit=0;cycles(1);end endtask
initial begin
 // Timed: exact ticks, preview window, chords, no note dependency.
 mem[0]={7'd0,25'd1,32'd50};mem[1]={7'd0,25'd3,32'd80};mem[2]=100;
 launch(0,3,0);cycles(20);tick=25;cycles(1);if(preview!=0||expected!=0)$fatal(1,"early preview");tick=26;cycles(1);if(preview!=1)$fatal(1,"preview boundary");hit=1;cycles(1);hit=0;if(expected!=0)$fatal(1,"timed reacted hit");tick=49;cycles(1);if(expected!=0)$fatal(1,"early target");tick=50;target_wait(1);cycles(10);tick=80;target_wait(3);cycles(10);tick=100;cycles(10);if(finishes!=1||expected!=0||uns)$fatal(1,"timed ending");
 // Leading/middle/trailing empty; identical masks require separate target hits.
 mem[0]=0;mem[1]={7'd0,25'd4,32'd10};mem[2]=20;mem[3]={7'd0,25'd4,32'd30};mem[4]=40;
 launch(1,5,0);target_wait(4);cycles(30);if(targets!=1||finishes||preview)$fatal(1,"wait advanced alone");paused=1;accept();cycles(10);if(expected!=4||targets!=1)$fatal(1,"paused advance");paused=0;accept();cycles(20);target_wait(4);if(targets!=2)$fatal(1,"duplicate target omitted");accept();cycles(20);if(finishes!=1||expected)$fatal(1,"wait final");
 launch(1,5,1);target_wait(4);accept();cycles(20);target_wait(4);accept();cycles(20);if(loops!=1||finishes)$fatal(1,"loop result");
 mem[0]=0;mem[1]=10;mem[2]=20;launch(1,3,1);cycles(80);if(finishes!=1||loops||targets)$fatal(1,"empty hot loop");
 mem[0]={7'd0,25'd3,32'd0};mem[1]=100;launch(1,2,0);cycles(40);if(uns!=1||finishes!=1||expected)$fatal(1,"chord not rejected");
 launch(1,0,0);cycles(20);if(uns!=1||finishes!=1||reads)$fatal(1,"empty count");
 // 256 entries exercise255, all preceding empty states then final single target.
 for(i=0;i<256;i=i+1)mem[i]=i;mem[254]={7'd0,25'd16,32'd254};
 launch(1,256,0);target_wait(16);accept();cycles(20);if(reads!=256||maxaddr!=255||finishes!=1)$fatal(1,"last-address reads%0d max%0d finish%0d",reads,maxaddr,finishes);
 //255-event boundary and timed looping retain their original semantics.
 for(i=0;i<255;i=i+1)mem[i]=i;mem[253]={7'd0,25'd32,32'd253};
 launch(1,255,0);target_wait(32);accept();cycles(20);if(reads!=255||maxaddr!=254||finishes!=1)$fatal(1,"255 boundary");
 mem[0]={7'd0,25'd1,32'd0};mem[1]=10;launch(0,2,1);target_wait(1);tick=10;cycles(20);if(loops!=1||finishes)$fatal(1,"timed loop");
 //Hit coinciding with initial target admission cannot consume that target.
 launch(1,2,0);wait(dut.state==2 && !dut.waiting_for_hit);@(negedge clk);hit=1;cycles(1);@(negedge clk);hit=0;cycles(10);if(expected!=1||finishes)$fatal(1,"early hit admitted");
 //Paused reference tick cannot advance a timed event; resume catches due event.
 mem[0]={7'd0,25'd2,32'd20};mem[1]=40;launch(0,2,0);cycles(20);paused=1;tick=20;cycles(10);if(expected||preview)$fatal(1,"paused timed progress");paused=0;target_wait(2);
 // Pending reader cancellation and source replacement.
 mem[0]={7'd0,25'd1,32'd0};mem[1]=10;launch(1,2,0);wait(req);@(negedge clk);changed=1;mem[0]={7'd0,25'd8,32'd0};cycles(1);@(negedge clk);changed=0;target_wait(8);if(expected!=8)$fatal(1,"old source leaked");
 @(negedge clk);stop=1;cycles(1);if(expected||tp)$fatal(1,"stop not cleared");@(negedge clk);stop=0;playing=0;cycles(10);if(expected)$fatal(1,"stopped target");
 $display("PASS guide_event_player timed/wait/preview/pause/loop/empty/chord/cancel/256");$finish;
end
initial begin #1000000;$fatal(1,"watchdog");end
endmodule
