`timescale 1ns/1ps
module tb_tjc_high_speed_link;
 parameter FAST=54, SLOW=434;
 localparam RESP=SLOW*220, HEART=SLOW*250, RETRY=SLOW*70;
 reg clk=0; always #10 clk=~clk;
 reg rst_n=0,screen_rx=1,panel_idle=1,fake_valid=0;
 wire [7:0] rx_data,cmd_data; wire rx_valid,rx_error,cmd_valid,owns,allow_new,tx,ready,out,online,notice;
 wire [2:0] page;
 uart_rx #(.CLKS_PER_BIT(FAST)) fast_rx(clk,rst_n,screen_rx,rx_data,rx_valid,rx_error);
 uart_tx #(.CLKS_PER_BIT(FAST)) fast_tx(clk,rst_n,owns?cmd_data:8'h55,owns?cmd_valid:fake_valid,tx,ready);
 tjc_high_speed_link #(.SLOW_CLKS_PER_BIT(SLOW),.BOOT_CYCLES(100),.RESPONSE_CYCLES(RESP),
 .RETRY_CYCLES(RETRY),.HEARTBEAT_CYCLES(HEART),.SETTLE_CYCLES(SLOW*3)) dut(
 clk,rst_n,screen_rx,rx_data,rx_valid,rx_error,panel_idle,ready,tx,cmd_valid,cmd_data,owns,allow_new,out,online,notice,page);
 // Independent serial screen model: no DUT state references or forced signals.
 integer model_cpb=SLOW, mode=0, page_number=0, sets=0, gets=0, pages=0, low_proofs=0, notices=0;
 integer count=0, ff=0, errors=0, scenario=0, n, sample_cpb, bitn;
 reg powered=0; reg [7:0] b; reg framing; reg [7:0] bytes[0:63];
 reg [5:0] observed=0;
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
 task command_done;
 begin
 if((count>=5 && bytes[0]=="b" && bytes[1]=="a" && bytes[2]=="u" && bytes[3]=="d" && bytes[4]=="s") ||
 (count>=4 && bytes[0]=="r" && bytes[1]=="e" && bytes[2]=="s" && bytes[3]=="t") ||
 (count>=6 && bytes[0]=="c" && bytes[1]=="o" && bytes[2]=="d" && bytes[3]=="e" && bytes[4]=="_" && bytes[5]=="c") ||
 (count>=4 && bytes[0]=="w" && bytes[1]=="h" && bytes[2]=="m" && bytes[3]=="i"))
 $fatal(1,"forbidden screen command");
 if(match_get(count))begin
 gets=gets+1;cycles(FAST*2);
 if(mode!=3) custom();
 if(mode==0)begin
 if(model_cpb==SLOW)begin low_proofs=low_proofs+1;numeric(115200,0);end else numeric(921600,0);
 end else if(mode==1) numeric(230400,0);
 else if(mode==2) numeric(921600,1);
 end else if(match_page(count))begin
 pages=pages+1;cycles(FAST*2);send_byte('h66);send_byte(page_number);send_byte(255);send_byte(255);send_byte(255);
 end else if(match_set(count))begin
 if(low_proofs==0 || model_cpb!=SLOW)$fatal(1,"SET without confirmed low baud scenario=%0d",scenario);
 sets=sets+1;model_cpb=FAST;
 end
 // Wrong-baud traffic is permitted to be garbage, never executed as commands.
 count=0;ff=0;
 end endtask
 initial forever begin
 @(negedge out);
 if(powered && rst_n)begin
 sample_cpb=model_cpb;framing=1;cycles(sample_cpb/2);
 if(out!==0)framing=0;
 for(bitn=0;bitn<8;bitn=bitn+1)begin cycles(sample_cpb);b[bitn]=out;end
 cycles(sample_cpb);if(out!==1)framing=0;
 // Consume the full stop bit: model never changes baud in its middle.
 cycles(sample_cpb-sample_cpb/2);
 if(framing)begin
 if(b==255)begin ff=ff+1;if(ff==3)command_done();end
 else begin
 if(ff!=0)begin count=0;ff=0;end
 if(count<64)begin bytes[count]=b;count=count+1;end else count=0;
 end
 end else begin count=0;ff=0;end
 end
 end
 always @(negedge clk)if(rst_n && fake_valid && (owns || out!==tx))$fatal(1,"manager cut active panel UART");
 always @(posedge clk)if(rst_n && notice)begin notices=notices+1;observed[page]=1;end
 task reset_case(input integer cp,input integer badmode,input integer poweron);
 begin powered=0;rst_n=0;screen_rx=1;panel_idle=1;fake_valid=0;cycles(SLOW*30);
 model_cpb=cp;mode=badmode;count=0;ff=0;sets=0;gets=0;pages=0;low_proofs=0;notices=0;observed=0;
 powered=poweron;rst_n=1;cycles(5);end endtask
 task wait_online;
 integer c;
 begin c=0;while(!online && c<RESP*14)begin cycles(1);c=c+1;end
 if(!online)$fatal(1,"online timeout scenario=%0d gets=%0d sets=%0d pages=%0d",scenario,gets,sets,pages);
 cycles(3);if(!observed[page_number])$fatal(1,"missing expected page notice");
 end endtask
 initial begin
 scenario=1;page_number=0;reset_case(SLOW,0,1);wait_online();if(sets!=1)$fatal(1,"cold SET count");
 $display("PASS cold slow-to-fast");
 scenario=2;page_number=1;reset_case(FAST,0,1);wait_online();if(sets!=0)$fatal(1,"already-fast changed baud");
 $display("PASS already-fast reload");
 scenario=3;page_number=2;reset_case(SLOW,0,0);cycles(RESP*3);if(online||sets)$fatal(1,"offline false online");
 powered=1;wait_online();$display("PASS late screen power");
 scenario=4;page_number=3;cycles(FAST*200);model_cpb=SLOW;count=0;ff=0;screen_rx=1;
 // Wait for old online to drop, then a fresh handshake.
 n=0;while(online && n<RESP*6)begin cycles(1);n=n+1;end
 if(online)$fatal(1,"heartbeat did not detect reboot");wait_online();if(sets!=2)$fatal(1,"reboot SET count");
 $display("PASS screen-only reboot recovery");
 scenario=5;panel_idle=0;fake_valid=1;n=gets;cycles(HEART+FAST*30);
 if(cmd_valid||owns||gets!=n||allow_new)$fatal(1,"quiesce did not wait for panel idle");
 fake_valid=0;while(!ready)cycles(1);cycles(2);
 page_number=4;panel_idle=1;cycles(3);n=notices;
 while(notices==n)cycles(1);if(page!=4)$fatal(1,"heartbeat page4");$display("PASS quiesce and page4");
 scenario=6;page_number=5;n=notices;while(notices==n)cycles(1);if(page!=5)$fatal(1,"heartbeat page5");$display("PASS heartbeat page5");
 scenario=7;reset_case(FAST,1,1);cycles(RESP*9);if(online||sets||notices)$fatal(1,"wrong numeric false ACK");$display("PASS wrong numeric and async frames rejected");
 scenario=8;reset_case(FAST,2,1);cycles(RESP*9);if(online||sets||notices)$fatal(1,"partial numeric false ACK");$display("PASS partial numeric rejected");
 scenario=9;reset_case(SLOW,3,1);cycles(RESP*9);if(online||sets||notices)$fatal(1,"no-response false ACK");if(gets>10)$fatal(1,"unbounded attempts");$display("PASS absent replies bounded retries");
 $display("PASS ALL FAST=%0d SLOW=%0d",FAST,SLOW);$finish;
 end
 initial begin cycles(RESP*120);$fatal(1,"watchdog scenario=%0d",scenario);end
endmodule
