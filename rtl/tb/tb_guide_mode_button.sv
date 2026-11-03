`timescale 1ns/1ps
module tb_guide_mode_button;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,en=0,pressed=0,strobe=0;
 wire short_p,long_p;
 guide_mode_button #(.LONG_SAMPLES(4)) dut(clk,rst_n,en,pressed,strobe,short_p,long_p);
 reg ev=0,ready=1,urgent=0;reg[7:0] kind=2,id=7;reg[31:0] value=0;
 wire gv,pv,snap,pending;wire[2:0] gid,page,result;wire[15:0] gval,pval;wire[3:0] pid;wire[31:0] rejected;
 tjc_control_bridge #(.ACK_TIMEOUT_CYCLES(16)) bridge(clk,rst_n,ev,kind,id,value,ready,urgent,8'd1,pv,pid,pval,1'b0,1'b0,gv,gid,gval,snap,page,result,rejected,pending);
 integer shorts=0,longs=0,failures=0,checks=0;
 always @(posedge clk)begin #1;if(short_p)shorts=shorts+1;if(long_p)longs=longs+1;end
 task cycle(input bit e,input bit p,input bit s);begin @(negedge clk);en=e;pressed=p;strobe=s;@(posedge clk);#2;end endtask
 task check(input bit ok,input string label);begin checks=checks+1;if(!ok)begin failures=failures+1;$display("FAIL %s shorts=%0d longs=%0d",label,shorts,longs);end else $display("PASS %s",label);end endtask
 task clean;begin @(negedge clk);rst_n=0;en=0;pressed=0;strobe=0;repeat(2)@(negedge clk);rst_n=1;shorts=0;longs=0;cycle(1,0,0);end endtask
 task command(input[7:0] k,input[7:0] i,input[31:0] v,input bit r,input bit u,input bit accepted,input string label);integer before_rej;begin
 @(negedge clk);before_rej=rejected;kind=k;id=i;value=v;ready=r;urgent=u;ev=1;
 @(posedge clk);#2;check(gv==accepted && !pv && (accepted?(gid==i && gval==v):(rejected==before_rej+1 && result==2)),label);
 @(negedge clk);ev=0;urgent=0;ready=1;@(posedge clk);#2;check(!gv,"guide pulse is one cycle");end endtask
 initial begin
 clean();cycle(1,1,0);repeat(12)cycle(1,1,0);check(shorts==0&&longs==0,"no pulse on down/no sample ticks");cycle(1,0,0);check(shorts==1&&longs==0,"short only on release");cycle(1,0,0);check(!short_p,"short pulse width");
 clean();cycle(1,1,1);repeat(3)begin repeat(7)cycle(1,1,0);cycle(1,1,1);end check(longs==0,"three sparse ticks below threshold");cycle(1,1,1);check(longs==1&&shorts==0,"four accepted ticks long");repeat(15)cycle(1,1,1);check(longs==1,"long held only once");cycle(1,0,0);check(shorts==0,"long release no short");
 clean();cycle(1,1,0);cycle(1,1,1);cycle(0,1,1);repeat(8)cycle(1,1,1);cycle(1,0,0);check(shorts==0&&longs==0,"disable cancels hold, reenable held ignored");cycle(1,1,0);cycle(1,0,0);check(shorts==1,"fresh press after enable works");
 clean();cycle(0,1,0);repeat(8)cycle(1,1,1);cycle(1,0,0);check(shorts==0&&longs==0,"enable midheld ignored");
 clean();cycle(1,1,0);cycle(1,1,1);@(negedge clk);rst_n=0;pressed=0;repeat(2)@(negedge clk);rst_n=1;repeat(8)cycle(1,0,1);check(shorts==0&&longs==0,"reset cancels released gesture");
 command(2,7,0,1,0,1,"mode0 accepted");command(2,7,1,1,0,1,"mode1 accepted");command(2,7,2,1,0,0,"mode2 rejected");command(2,7,32'h10000,1,0,0,"mode high bits rejected");command(2,6,0,1,0,1,"score0 retained");command(2,6,1,1,0,0,"score1 outside count rejected");command(2,7,1,0,0,0,"not ready rejected");command(2,7,1,1,1,0,"urgent stop rejected");command(2,8,0,1,0,0,"id8 cannot alias id0");
 // Strict reset safety: held through reset must be released before new gesture.
 clean();cycle(1,1,0);cycle(1,1,1);@(negedge clk);rst_n=0;repeat(2)@(negedge clk);rst_n=1;repeat(8)cycle(1,1,1);cycle(1,0,0);check(shorts==0&&longs==0,"reset while held must not create fresh long gesture");
 if(failures)$fatal(1,"FAIL %0d / %0d checks",failures,checks);$display("PASS ALL %0d checks",checks);$finish;
 end
 initial begin #1000000;$fatal(1,"watchdog");end
endmodule
