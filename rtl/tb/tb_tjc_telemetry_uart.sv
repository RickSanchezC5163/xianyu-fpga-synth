`timescale 1ns/1ps
module tb_tjc_telemetry_uart;
 reg clk=0,rst_n=0,rx=1;wire tx;reg[7:0]sample_count=0;reg[3:0]divider=0;
 always #10 clk=~clk;
 always @(posedge clk) if(!rst_n) begin divider<=0;sample_count<=0;end else begin divider<=divider+1'b1;if(divider==0)sample_count<=sample_count+1'b1;end
 tjc_uart_panel #(.TELEMETRY_ENABLE(1),.CLKS_PER_BIT(16),.REFRESH_CYCLES(250000),.GAP_CYCLES(2000)) dut(
 .clk(clk),.rst_n(rst_n),.screen_rx(rx),.screen_tx(tx),.context_ready(1'b1),.urgent_stop(1'b0),.score_count(8'd1),
 .param_ack(1'b0),.param_rejected(1'b0),.register_patch(2'd2),.register_volume(8'd40),.register_adsr(28'd0),
 .guide_playing(1'b0),.guide_paused(1'b0),.guide_loop(1'b1),.guide_bpm(8'd120),
 .sample_valid(divider==0),.sample_pcm({sample_count,8'd0}),.control_note_on(1'b0),.latency_valid(1'b0),
 .latency_timeout(1'b0),.latency_rejected(1'b0),.latency_cycles(32'd0),.latency_max_cycles(32'd0),
 .missed_deadline_count(32'd0),.window_valid(1'b0),.samples_in_window(32'd0));
 wire[7:0]data;wire valid,error;integer fd,j,i,commits=0;
 uart_rx #(.CLKS_PER_BIT(16)) monitor(clk,rst_n,tx,data,valid,error);
 always @(negedge clk)begin
 if(rst_n && dut.snapshot_busy && dut.telemetry_busy)$fatal(1,"snapshot and telemetry overlap");
 if(error)$fatal(1,"UART framing error");
 if(valid)$fwrite(fd,"%02x",data);
 end
 task send_byte(input[7:0]b);begin
 @(negedge clk);rx=0;repeat(16)@(negedge clk);
 for(j=0;j<8;j=j+1)begin rx=b[j];repeat(16)@(negedge clk);end
 rx=1;repeat(17)@(negedge clk);end endtask
 reg[87:0]nav=88'ha65a030300000000746f7e;
 initial begin
 fd=$fopen("telemetry_uart.hex","w");repeat(4)@(negedge clk);rst_n=1;
 for(i=10;i>=0;i=i-1)send_byte(nav[i*8+:8]);
 repeat(20)@(negedge clk);
 if(dut.page_id!==3)$fatal(1,"navigation not accepted");
 // Continuous query flood must not starve telemetry.
 force dut.bridge_refresh=1'b1;
 // Read two coherent telemetry refreshes, then reset during a new transaction.
 wait(dut.telemetry_enabled.telemetry.revision==2);wait(!dut.telemetry_busy);wait(dut.tx_ready);
 repeat(32)@(negedge clk);$fclose(fd);
 wait(dut.telemetry_busy || dut.snapshot_busy);rst_n=0;repeat(3)@(negedge clk);
 if(tx!==1 || dut.snapshot_busy || dut.telemetry_busy)$fatal(1,"reset did not return idle");
 $display("PASS tjc_telemetry_uart: arbitration, physical UART, coherent refresh, reset");$finish;
 end
 initial begin #100000000;$fatal(1,"UART telemetry timeout");end
endmodule
