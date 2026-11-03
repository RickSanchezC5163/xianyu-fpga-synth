`timescale 1ns/1ps
module tb_tjc_telemetry;
 reg clk=0,rst_n=0,request=0,sample_valid=0;reg signed[15:0] pcm=0;reg[2:0]page=3;
 reg note=0,valid=0,timeout_p=0,rejected=0,wvalid=0;reg[31:0]latency=0,maxlatency=0,missed=0,rate=0;
 wire busy,bvalid;wire[7:0]data;reg ready=0;
 tjc_telemetry_tx #(.CAPTURE_TIMEOUT_CYCLES(4096)) dut(clk,rst_n,request,page,sample_valid,pcm,note,valid,timeout_p,rejected,
 latency,maxlatency,missed,wvalid,rate,busy,bvalid,data,ready,1'b0,1'b0,8'd0,);
 always #10 clk=~clk;
 integer fd,i,tick=0;reg stalled=0;reg[7:0]held;
 always @(negedge clk) begin
 tick=tick+1;ready=(tick%7!=0 && tick%7!=1);
 end
 always @(posedge clk) if(rst_n) begin
 if(stalled && (!bvalid || data!==held)) $fatal(1,"byte changed under backpressure");
 stalled<=bvalid && !ready;held<=data;
 if(bvalid && ready) $fwrite(fd,"%02x",data);
 end else stalled<=0;
 task pulse_request;begin @(negedge clk);request=1;@(negedge clk);request=0;end endtask
 task finish_transaction;begin wait(busy);wait(!busy);repeat(3)@(negedge clk);end endtask
 initial begin
 fd=$fopen("telemetry.hex","w");repeat(4)@(negedge clk);rst_n=1;
 latency=307198;maxlatency=99999999;missed=70000;rate=48828;
 valid=1;wvalid=0;@(negedge clk);valid=0;wvalid=0;
 // Prime peak and rail measurements before snapshot.
 sample_valid=1;pcm=-32768;@(negedge clk);sample_valid=0;
 // First completed sample-rate window coincides with snapshot admission.
 @(negedge clk);request=1;wvalid=1;@(negedge clk);request=0;wvalid=0;
 for(i=0;i<1024;i=i+1)begin
 @(negedge clk);sample_valid=1;pcm=(i==0)?-32768:((i==1)?32767:((i%64-32)*256));
 @(negedge clk);sample_valid=0;
 end
 finish_transaction();
 page=0;note=1;@(negedge clk);note=0;pulse_request();finish_transaction();
 timeout_p=1;@(negedge clk);timeout_p=0;pulse_request();finish_transaction();
 rejected=1;@(negedge clk);rejected=0;pulse_request();finish_transaction();
 // A newer valid measurement replaces ambiguous status.
 valid=1;latency=0;maxlatency=400;@(negedge clk);valid=0;pulse_request();finish_transaction();
 page=3;pulse_request();finish_transaction();
 if(!dut.capture_failed)$fatal(1,"missing sample timeout absent");
 page=0;valid=1;latency=250001;maxlatency=500001;@(negedge clk);valid=0;
 pulse_request();finish_transaction();
 // New note wins over an old completion even at snapshot admission.
 @(negedge clk);request=1;note=1;valid=1;
 @(negedge clk);request=0;note=0;valid=0;finish_transaction();
 $fclose(fd);$display("PASS tjc_telemetry: capture, backpressure, state, saturation, commit");$finish;
 end
 initial begin #20000000;$fatal(1,"telemetry timeout");end
endmodule
