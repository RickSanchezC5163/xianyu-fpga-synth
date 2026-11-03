`timescale 1ns/1ps
module tb_tjc_score_meta_panel;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,rx=1;wire tx;reg active=1,playing=1,paused=0;
reg[191:0]title=192'ha6d0a2ceebd3f9c9e8b8;reg[4:0]title_len=10;reg[9:0]part=2,parts=359;
wire[2:0]page,result;wire fault;
tjc_uart_panel #(.CLKS_PER_BIT(4),.REFRESH_CYCLES(20000),.GAP_CYCLES(1000),.SCORE_METADATA_ENABLE(1)) dut(
 .clk(clk),.rst_n(rst_n),.screen_rx(rx),.screen_tx(tx),.context_ready(1'b1),.urgent_stop(1'b0),.score_count(8'd1),
 .param_ack(1'b0),.param_rejected(1'b0),.register_patch(2'd0),.register_volume(8'd40),.register_adsr(28'd0),
 .guide_playing(playing),.guide_paused(paused),.guide_loop(1'b0),.guide_bpm(8'd120),.page_id(page),.last_result(result),
 .sample_valid(1'b0),.sample_pcm(16'sd0),.control_note_on(1'b0),.latency_valid(1'b0),.latency_timeout(1'b0),
 .latency_rejected(1'b0),.latency_cycles(32'd0),.latency_max_cycles(32'd0),.missed_deadline_count(32'd0),
 .window_valid(1'b0),.samples_in_window(32'd0),.display_transfer_fault(fault),
 .score_active_present(active),.score_title(title),.score_title_len(title_len),.score_part(part),.score_parts(parts));
wire[7:0]data;wire valid,err;
uart_rx #(.CLKS_PER_BIT(4)) monitor(clk,rst_n,tx,data,valid,err);
integer fd,stage=0;string path;
always @(posedge clk)if(rst_n)begin
 if(err || fault)$fatal(1,"panel transport fault");
 if(dut.metadata_busy && (dut.snapshot_busy || dut.env_busy || dut.telemetry_busy))$fatal(1,"metadata producers overlap");
 if(valid)$fwrite(fd,"%0d %02x\n",stage,data);
end
task cycles(input integer n);repeat(n)@(negedge clk);endtask
task send_byte(input[7:0]b);integer k;begin
 rx=0;cycles(4);for(k=0;k<8;k=k+1)begin rx=b[k];cycles(4);end rx=1;cycles(4);
end endtask
function[15:0]crcbyte(input[15:0]old,input[7:0]b);reg[15:0]c;integer k;begin
 c=old^b;for(k=0;k<8;k=k+1)c=c[0]?(c>>1)^16'ha001:c>>1;crcbyte=c;
end endfunction
task show_page(input[7:0]p);reg[15:0]crc;integer k;begin
 crc=crcbyte(crcbyte(16'hffff,8'ha6),8'h5a);send_byte(8'ha6);send_byte(8'h5a);send_byte(3);crc=crcbyte(crc,3);
 send_byte(p);crc=crcbyte(crc,p);for(k=0;k<4;k=k+1)begin send_byte(0);crc=crcbyte(crc,0);end
 send_byte(crc[7:0]);send_byte(crc[15:8]);send_byte(8'h7e);cycles(20);
 if(page!=p)$fatal(1,"page UART event not accepted");
end endtask
initial begin
 if(!$value$plusargs("LOG=%s",path))path="tmp/tjc_score_meta_panel.hex";
 fd=$fopen(path,"w");cycles(4);rst_n=1;cycles(2);show_page(2);cycles(75000);
 stage=1;show_page(5);cycles(65000);
 stage=2;show_page(0);cycles(65000);
 stage=3;active=0;show_page(2);cycles(65000);
 force dut.refresh_pending=0;
 while(!dut.producer_idle || dut.metadata_pending || dut.telemetry_pending || dut.env_pending || !dut.tx_ready)cycles(1);
 cycles(100);
 $fclose(fd);$display("PASS METADATA PANEL: actual 8N1 page events, snapshots and exclusive metadata arbitration");$finish;
end
initial begin #6000000;$fatal(1,"panel timeout");end
endmodule
