`timescale 1ns/1ps
module tb;
reg[24:0] expected=0,preview=0,held=0,wrong=0;reg playing=1,paused=0,beat=0,strong_beat=0,range_warn=0,waitmode=0;wire[2423:0] frame;
guide_led_frame #(.EXTERNAL_PIXELS(100),.PREFIX_PIXELS(1),.MODE_FEEDBACK(1),.BEAT_PIXEL(30),.RANGE_PIXEL(31),.KEY_MAP(200'h1d1b1a1918171615131211100f0d0c0b0a0908070504030201)) dut(expected,preview,held,playing,paused,beat,strong_beat,range_warn,frame,waitmode,wrong);
integer k,p,i;reg[199:0] mapping=200'h1d1b1a1918171615131211100f0d0c0b0a0908070504030201;
initial begin
for(k=0;k<25;k=k+1)begin
 expected=25'b1<<k;#1;p=mapping[k*8+:8];
 for(i=0;i<101;i=i+1)if(frame[i*24+:24]!==((i==p+1)?24'h100000:24'h000000))$fatal(1,"onehot key %0d pixel %0d",k,i);
end
expected=0;beat=1;strong_beat=1;range_warn=1;#1;
if(frame[31*24+:24]!==24'h101010 || frame[32*24+:24]!==24'h001000)$fatal(1,"indicators");
held=1;#1;if(frame[24+:24]!==0)$fatal(1,"external first LED must stay dark");if(frame[48+:24]!==24'h001010)$fatal(1,"first key");
for(i=33;i<101;i=i+1)if(frame[i*24+:24]!==0)$fatal(1,"unused tail");
if(frame[23:0]!==0)$fatal(1,"prefix");
$display("PASS 25 mapped keys, second LED anchors first key, indicators, dark tail incl failed last LED");$finish;end
endmodule
