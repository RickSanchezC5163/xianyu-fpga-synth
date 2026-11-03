`timescale 1ns/1ps
module tb_tjc_fast_panel;
 parameter FAST=54,SLOW=434;
 localparam RESP=SLOW*220, HEART=500000;
 localparam BULK_TIMEOUT=900000;
 reg clk=0;always #10 clk=~clk;
 reg rst_n=0,screen_rx=1,powered=1,txlock=0;
 wire transfer_fault;
 wire screen_tx;wire param_valid;wire[3:0]param_id;wire[15:0]param_value;
 reg param_ack=0;reg[7:0]volume=40;reg[27:0]adsr={7'd30,7'd80,7'd20,7'd10};
 wire[2:0]page_id,result;wire[31:0]crc_errors,format_errors,gap_timeouts,rejected_count,debug_rx_counts;
 integer sample_counter=0;reg sample_valid=0;reg signed[15:0]pcm=-16000;
 integer received_params=0, pcm_ticks=0;
 always @(posedge clk)begin
 sample_valid<=sample_counter==1023;
 if(sample_counter==1023)begin sample_counter<=0;pcm<=pcm+16'sd1024;pcm_ticks<=pcm_ticks+1;end else sample_counter<=sample_counter+1;
 param_ack<=param_valid;
 if(param_valid)begin received_params<=received_params+1;if(param_id==2)adsr[6:0]<=param_value[6:0];if(param_id==1)volume<=param_value[7:0];end
 end
 tjc_uart_panel #(.CLKS_PER_BIT(SLOW),.TELEMETRY_ENABLE(1),.ENV_PLOT_ENABLE(1),.AUTO_FAST_BAUD(1),.WAVE_BULK_ENABLE(1),
 .FAST_CLKS_PER_BIT(FAST),.FAST_REFRESH_CYCLES(500000),.LINK_BOOT_CYCLES(100),.LINK_RESPONSE_CYCLES(RESP),
 .LINK_RETRY_CYCLES(SLOW*70),.LINK_HEARTBEAT_CYCLES(HEART),.LINK_SETTLE_CYCLES(SLOW*3),.BULK_TIMEOUT_CYCLES(BULK_TIMEOUT)) dut(
 .clk(clk),.rst_n(rst_n),.screen_rx(screen_rx),.screen_tx(screen_tx),.context_ready(1'b1),.urgent_stop(1'b0),.score_count(8'd3),
 .param_valid(param_valid),.param_id(param_id),.param_value(param_value),.param_ack(param_ack),.param_rejected(1'b0),
 .register_patch(2'd0),.register_volume(volume),.register_adsr(adsr),.guide_valid(),.guide_id(),.guide_value(),
 .guide_playing(1'b0),.guide_paused(1'b0),.guide_loop(1'b0),.guide_bpm(8'd120),.page_id(page_id),.last_result(result),
 .crc_errors(crc_errors),.format_errors(format_errors),.gap_timeouts(gap_timeouts),.rejected_count(rejected_count),
 .sample_valid(sample_valid),.sample_pcm(pcm),.control_note_on(1'b0),.latency_valid(1'b1),.latency_timeout(1'b0),
 .latency_rejected(1'b0),.latency_cycles(32'd125000),.latency_max_cycles(32'd150000),.missed_deadline_count(32'd0),
 .window_valid(1'b1),.samples_in_window(32'd48828),.debug_rx_counts(debug_rx_counts),.display_transfer_fault(transfer_fault));
 integer model_cpb=SLOW,page_number=0,sets=0,gets=0,pages=0,low_proofs=0;
 integer count=0,ff=0,scenario=0,n,sample_cpb,bitn,j,fd;
 integer lines=0,clears=0,adds=0,snapshots=0,labels=0,query_pages=0;
 integer bulk_phase=0, bulk_requests=0, bulk_completed=0, payload_count=0;
 integer fe_delay=20000, fd_delay=HEART+1000, rawfd, saved_pcm, saved_queries, saved_labels;
 reg fe_issued=0,fd_issued=0;string rawpath;

 reg[7:0]b;reg framing;reg[7:0]bytes[0:255];string textcmd;string logpath;
 task cycles(input integer c); repeat(c) @(negedge clk); endtask
 task send_byte(input [7:0] x);
 integer j,cp;
 begin cp=model_cpb; @(negedge clk); screen_rx=0; cycles(cp);
 for(j=0;j<8;j=j+1)begin screen_rx=x[j];cycles(cp);end
 screen_rx=1; cycles(cp); end endtask
 task numeric(input [31:0] value,input integer partial);
 begin send_byte(8'h71);send_byte(value[7:0]);send_byte(value[15:8]);send_byte(value[23:16]);
 if(!partial)begin send_byte(value[31:24]);send_byte(255);send_byte(255);send_byte(255);end end endtask
 task custom;
 begin
 // CRC-valid page event, must not be mistaken for standard baud ACK.
 send_byte('ha6);send_byte('h5a);send_byte(3);send_byte(3);send_byte(0);send_byte(0);send_byte(0);send_byte(0);
 send_byte('h74);send_byte('h6f);send_byte('h7e);
 end endtask
 function match_get; input integer len;
 begin match_get=len==8 && bytes[0]=="g" && bytes[1]=="e" && bytes[2]=="t" && bytes[3]==" " &&
 bytes[4]=="b" && bytes[5]=="a" && bytes[6]=="u" && bytes[7]=="d";end endfunction
 function match_page; input integer len;
 begin match_page=len==6 && bytes[0]=="s" && bytes[1]=="e" && bytes[2]=="n" && bytes[3]=="d" && bytes[4]=="m" && bytes[5]=="e";end endfunction
 function match_set; input integer len;
 begin match_set=len==11 && bytes[0]=="b" && bytes[1]=="a" && bytes[2]=="u" && bytes[3]=="d" && bytes[4]=="=" &&
 bytes[5]=="9" && bytes[6]=="2" && bytes[7]=="1" && bytes[8]=="6" && bytes[9]=="0" && bytes[10]=="0";end endfunction

 task lock_tx;begin while(txlock)cycles(1);txlock=1;end endtask
 task event_send(input[7:0]kind,input[7:0]id,input[31:0]value);
 reg[7:0]p[0:10];reg[15:0]crc;integer a,k;
 begin lock_tx();p[0]='ha6;p[1]='h5a;p[2]=kind;p[3]=id;p[4]=value[7:0];p[5]=value[15:8];p[6]=value[23:16];p[7]=value[31:24];crc=16'hffff;
 for(a=0;a<8;a=a+1)begin crc=crc^p[a];for(k=0;k<8;k=k+1)crc=(crc>>1)^((crc&1)?16'ha001:16'h0000);end
 p[8]=crc[7:0];p[9]=crc[15:8];p[10]='h7e;for(a=0;a<11;a=a+1)send_byte(p[a]);txlock=0;end endtask
 task command_done;
 begin
 textcmd="";for(j=0;j<count;j=j+1)textcmd={textcmd,bytes[j]};
 if(bulk_phase!=0 && !fd_issued)$fatal(1,"ASCII interleaved with bulk phase %0d",bulk_phase);
 if(match_get(count))begin
 gets=gets+1;lock_tx();cycles(FAST*2);
 if(model_cpb==SLOW)begin low_proofs=low_proofs+1;numeric(115200,0);end else numeric(921600,0);txlock=0;
 end else if(match_set(count))begin
 if(!low_proofs||model_cpb!=SLOW)$fatal(1,"unproven SET");sets=sets+1;model_cpb=FAST;
 end else if(match_page(count))begin
 pages=pages+1;lock_tx();cycles(FAST*2);send_byte('h66);send_byte(page_number);send_byte(255);send_byte(255);send_byte(255);txlock=0;
 end else if(count>0 && model_cpb==FAST)begin
 $fdisplay(fd,"%0d|%s",scenario,textcmd);
 if(textcmd=="addt 2,0,420")begin
 if(bulk_phase!=0)$fatal(1,"overlapping bulk");bulk_phase=1;bulk_requests=bulk_requests+1;payload_count=0;fe_issued=0;fd_issued=0;
 end
 if(textcmd=="picq 12,64,123,124,1")clears=clears+1;
 if(count>5 && bytes[0]=="l" && bytes[1]=="i" && bytes[2]=="n" && bytes[3]=="e")lines=lines+1;
 if(count>8 && bytes[0]=="a" && bytes[1]=="d" && bytes[2]=="d")adds=adds+1;
 if(count>12 && bytes[0]=="h" && bytes[5]=="v" && bytes[6]=="8")snapshots=snapshots+1;
 if(textcmd=="wave.rwindow.txt=\"08602us\"")labels=labels+1;
 end
 count=0;ff=0;
 end endtask
 initial forever begin
 @(negedge screen_tx);
 if(powered && rst_n)begin
 sample_cpb=model_cpb;framing=1;cycles(sample_cpb/2);if(screen_tx!==0)framing=0;
 for(bitn=0;bitn<8;bitn=bitn+1)begin cycles(sample_cpb);b[bitn]=screen_tx;end
 cycles(sample_cpb);if(screen_tx!==1)framing=0;cycles(sample_cpb-sample_cpb/2);
 if(framing)begin
 if(bulk_phase==2)begin
 if(b>95)$fatal(1,"raw sample out of plot range / ASCII intruded: %0d",b);
 $fdisplay(rawfd,"%0d,%0d,%0d",bulk_requests,payload_count,b);payload_count=payload_count+1;
 if(payload_count==420)bulk_phase=3;
 end else if(bulk_phase==1 || (bulk_phase==3 && !fd_issued))$fatal(1,"unexpected UART byte while awaiting response");
 else if(b==255)begin ff=ff+1;if(ff==3)command_done();end
 else begin if(ff!=0)begin count=0;ff=0;end
 if(count<256)begin bytes[count]=b;count=count+1;end else $fatal(1,"unterminated command overflow");end
 end else begin count=0;ff=0;end
 end
 end
 initial forever begin
 wait(bulk_phase==1);cycles(fe_delay);lock_tx();
 fe_issued=1;send_byte('hfe);send_byte(255);send_byte(255);send_byte(255);bulk_phase=2;txlock=0;
 wait(bulk_phase==3);cycles(fd_delay);lock_tx();
 fd_issued=1;send_byte('hfd);send_byte(255);send_byte(255);send_byte(255);
 bulk_phase=0;bulk_completed=bulk_completed+1;txlock=0;
 end
 task wait_count(input integer kind,input integer target);
 integer age,current;
 begin age=0;current=0;
 while(current<target && age<12000000)begin
 cycles(1);age=age+1;
 case(kind)0:current=snapshots;1:current=lines;2:current=adds;3:current=labels;4:current=pages;5:current=received_params;6:current=bulk_requests;7:current=bulk_completed;8:current=payload_count;endcase
 end
 if(current<target)$fatal(1,"timeout scenario=%0d kind=%0d target=%0d current=%0d",scenario,kind,target,current);
 end endtask
 initial begin
 if(!$value$plusargs("LOG=%s",logpath))logpath="panel_commands.txt";fd=$fopen(logpath,"w");rawpath={logpath,".raw"};rawfd=$fopen(rawpath,"w");
 cycles(30);rst_n=1;scenario=1;wait_count(0,1);if(sets!=1)$fatal(1,"cold negotiate");
 scenario=2;page_number=1;event_send(3,1,0);wait_count(1,8);if(clears!=1)$fatal(1,"env clear count");
 n=snapshots;wait_count(0,n+3);cycles(FAST*1000);if(lines!=8||clears!=1)$fatal(1,"unchanged envelope repeated");
 $display("PASS envelope entry once and unchanged snapshots");
 scenario=3;event_send(1,2,100);wait_count(5,1);wait_count(1,16);if(clears!=2||adsr[6:0]!=100)$fatal(1,"parameter redraw");
 $display("PASS parameter event accepted and envelope redraw");
 scenario=4;page_number=3;event_send(3,3,0);saved_pcm=pcm_ticks;wait_count(7,1);wait_count(3,1);
 if(transfer_fault||payload_count!=420||pcm_ticks<=saved_pcm)$fatal(1,"bulk incomplete or PCM stopped");
 $display("PASS delayed FE/FD, exact420 raw, label and PCM progress");
 scenario=5;fe_delay=1000;fd_delay=1000;wait_count(6,2);wait_count(8,10);
 saved_labels=labels;page_number=0;event_send(3,0,0);wait_count(7,2);cycles(FAST*200);
 if(page_id!=0||payload_count!=420||labels!=saved_labels)$fatal(1,"page change truncated payload or emitted stale labels");
 $display("PASS mid-payload navigation completes420 and suppresses labels");
 scenario=6;fe_delay=BULK_TIMEOUT+20000;fd_delay=BULK_TIMEOUT+20000;page_number=3;event_send(3,3,0);wait_count(6,3);
 saved_queries=gets;saved_pcm=pcm_ticks;cycles(BULK_TIMEOUT+1000);
 if(!transfer_fault||payload_count!=0||gets!=saved_queries||pcm_ticks<=saved_pcm)$fatal(1,"FE timeout not isolated");
 wait_count(8,420);saved_queries=gets;cycles(BULK_TIMEOUT+1000);
 if(bulk_completed!=2||gets!=saved_queries)$fatal(1,"FD timeout not isolated");
 wait_count(7,3);wait_count(3,saved_labels+1);
 $display("PASS missing/late FE and FD quarantine then completion");
 // Leave wave only after completed transfer, preserving protocol sync.
 page_number=0;event_send(3,0,0);n=snapshots;wait_count(0,n+1);event_send(1,1,77);wait_count(5,2);
 if(volume!=77||rejected_count!=0)$fatal(1,"control after bulk");
 $display("PASS post-bulk control and fair snapshots");
 $fclose(fd);$fclose(rawfd);$display("PASS ALL PANEL FAST=%0d SLOW=%0d",FAST,SLOW);$finish;
 end
 initial begin cycles(40000000);$fatal(1,"global panel watchdog");end
endmodule
