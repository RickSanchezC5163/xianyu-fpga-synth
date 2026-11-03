`timescale 1ns/1ps
module tb_tjc_wave_transfer;
 reg clk=0,rst_n=0,request=0,sv=0;reg signed[15:0]pcm=0;reg[2:0]page=3;
 reg ready=1,rv=0,re=0;reg[7:0]rd=0;wire busy,bv,fault;wire[7:0]bd;
 tjc_telemetry_tx #(.WAVE_BULK_ENABLE(1),.TRIGGER_ENABLE(0),.CAPTURE_TIMEOUT_CYCLES(8192),.TRANSFER_TIMEOUT_CYCLES(2048),.RESPONSE_GAP_CYCLES(64)) dut(
 .clk(clk),.rst_n(rst_n),.request(request),.page_id(page),.sample_valid(sv),.sample_pcm(pcm),
 .control_note_on(1'b0),.latency_valid(1'b0),.latency_timeout(1'b0),.latency_rejected(1'b0),
 .latency_cycles(32'd0),.latency_max_cycles(32'd0),.missed_deadline_count(32'd0),.window_valid(1'b0),.samples_in_window(32'd0),
 .busy(busy),.byte_valid(bv),.byte_data(bd),.byte_ready(ready),.raw_rx_valid(rv),.raw_rx_error(re),.raw_rx_data(rd),.transfer_fault(fault));
 always #10 clk=~clk;
 reg[15:0]stim[0:419];integer fd,i,cycles=0,mode=0,payload=0,commits=0;reg stall=0;reg[7:0]held;reg hold_tx=0;
 always @(negedge clk)begin cycles=cycles+1;ready=!hold_tx && cycles%5!=0;end
 always @(posedge clk)if(rst_n)begin
 if(stall && (!bv || bd!==held))$fatal(1,"unstable backpressure");stall<=bv&&!ready;held<=bd;
 if(bv&&ready)begin $fwrite(fd,"%02x",bd);if(dut.state==17)payload=payload+1;end
 if(payload>420)$fatal(1,"extra payload");
 end else stall<=0;
 task rx;input[7:0]v;begin @(negedge clk);rv=1;rd=v;@(negedge clk);rv=0;end endtask
 task token;input[7:0]v;begin rx(v);rx(255);rx(255);rx(255);end endtask
 task hostile;input[7:0]v;begin
 // Embedded FE/FD FFF inside custom value and standard numeric/string replies.
 rx(8'ha6);rx(8'h5a);rx(1);rx(1);rx(v);rx(255);rx(255);rx(255);rx(8'h0c);rx(v==8'hfe ? 8'h25 : 8'h61);rx(8'h7e);
 rx(8'h71);rx(v);rx(255);rx(255);rx(255);rx(255);rx(255);rx(255);
 rx(8'h70);rx(v);rx(255);rx(255);rx(255);
 // Truncated custom packet must expire before accepting a later response.
 rx(8'ha6);rx(8'h5a);repeat(70)@(negedge clk);
 end endtask
 initial begin
 if($value$plusargs("MODE=%d",mode))begin end
 $readmemh("stimulus.hex",stim);fd=$fopen("transfer.hex","w");repeat(4)@(negedge clk);rst_n=1;
 @(negedge clk);request=1;@(negedge clk);request=0;
 fork
 begin for(i=0;i<420;i=i+1)begin @(negedge clk);pcm=stim[i];sv=1;@(negedge clk);sv=0;end end
 begin
 if(mode==1)begin wait(dut.state==14 && dut.position==4);@(negedge clk);page=0;end
 if(mode==6)begin wait(dut.state==19);@(negedge clk);page=0;wait(!busy);$fclose(fd);$display("PASS cancel before addt");$finish;end
 wait(dut.state==15);hostile(8'hfe);if(payload!=0 || dut.state!=15)$fatal(1,"embedded FE accepted");
 // Wrong, truncated, and errored response frames may not enable raw data.
 token(8'hfd);rx(8'hfe);rx(255);rx(0);repeat(5)@(negedge clk);
 rx(8'hfe);@(negedge clk);re=1;@(negedge clk);re=0;rx(255);rx(255);rx(255);
 if(payload!=0 || dut.state!=15)$fatal(1,"invalid FE accepted");
 if(mode==2)begin repeat(2100)@(negedge clk);if(!fault||!busy||bv)$fatal(1,"FE timeout not failclosed");end
 token(8'hfe);
 if(mode==7)begin wait(payload==20);@(negedge clk);rst_n=0;repeat(3)@(negedge clk);if(busy||bv||fault)$fatal(1,"reset");$fclose(fd);$display("PASS coordinated reset assumption");$finish;end
 if(mode==3)begin wait(payload==20);@(negedge clk);hold_tx=1;repeat(2100)@(negedge clk);if(!fault||!busy)$fatal(1,"payload stall not failclosed");hold_tx=0;end
 if(mode==4)begin wait(payload==200);@(negedge clk);page=0;end
 wait(dut.state==18);hostile(8'hfd);if(dut.state!=18)$fatal(1,"embedded FD accepted");if(payload!=420)$fatal(1,"incomplete payload");
 token(8'hfe);repeat(4)@(negedge clk);if(!busy||bv)$fatal(1,"ASCII before FD");
 if(mode==5)begin repeat(2100)@(negedge clk);if(!fault||!busy||bv)$fatal(1,"FD timeout not failclosed");end
 token(8'hfd);commits=commits+1;
 end
 join
 wait(!busy);repeat(3)@(negedge clk);if(commits!=1)$fatal(1,"commit count");
 if(mode==0 && fault)$fatal(1,"unexpected timeout");
 $fclose(fd);$display("PASS bulk mode=%0d payload=%0d fault=%0d",mode,payload,fault);$finish;
 end
 initial begin #2000000;$fatal(1,"watchdog");end
endmodule
