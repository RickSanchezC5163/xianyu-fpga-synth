`timescale 1ns/1ps
// Observational only:420 consecutive native PCM samples =8.6016ms at48828.125Hz.
// Each of420 compact curve add commands corresponds to a distinct captured sample.
// A bounded rising-zero-cross trigger waits at most256 input samples, then falls
// back to a free-running capture (including silence/DC/nonperiodic signals).
// WAVE_DECIMATE>1 retains explicit legacy averaging, never repeats source buckets.
// This preview is NOT an FFT. Its display quantization does not affect audio.
// Visual power-of-two gain never changes audio. Raw PCM peak stays unscaled.
// t0..t8 retain the original coherent diagnostic contract and units.
module tjc_telemetry_tx #(
 parameter integer CYCLES_PER_US=50,
 parameter integer CAPTURE_TIMEOUT_CYCLES=2000000,
 parameter integer WAVE_DECIMATE=1,
 parameter integer TRIGGER_ENABLE=1,
 parameter integer TRIGGER_WAIT_SAMPLES=256,
 parameter integer WAVE_BULK_ENABLE=0,
 parameter integer WAVE_SCROLL_ENABLE=0,
 parameter integer TRANSFER_TIMEOUT_CYCLES=CYCLES_PER_US*100000,
 parameter integer RESPONSE_GAP_CYCLES=CYCLES_PER_US*2000
)(
 input wire clk,rst_n,request,input wire [2:0] page_id,
 input wire sample_valid,input wire signed [15:0] sample_pcm,
 input wire control_note_on,latency_valid,latency_timeout,latency_rejected,
 input wire [31:0] latency_cycles,latency_max_cycles,missed_deadline_count,
 input wire window_valid,input wire [31:0] samples_in_window,
 output wire busy,byte_valid,output wire [7:0] byte_data,input wire byte_ready,
 input wire raw_rx_valid,raw_rx_error,input wire [7:0] raw_rx_data,
 output reg transfer_fault
);
 localparam integer CW=$clog2(CAPTURE_TIMEOUT_CYCLES+1);
 localparam integer DW=WAVE_DECIMATE<2?1:$clog2(WAVE_DECIMATE);
 localparam integer AVG_SHIFT=$clog2(WAVE_DECIMATE);
 localparam integer SW=17+AVG_SHIFT;
 localparam integer SECOND_CYCLES=CYCLES_PER_US*1000000;
 localparam integer FW=$clog2(SECOND_CYCLES);
 // Current board is50MHz and produces one sample per1024 clocks.
 localparam integer WINDOW_US=(420*WAVE_DECIMATE*1024+CYCLES_PER_US/2)/CYCLES_PER_US;
 localparam integer TW=TRIGGER_WAIT_SAMPLES<2?1:$clog2(TRIGGER_WAIT_SAMPLES);
 reg [TW-1:0] trigger_wait_count;
 reg triggered,trigger_have_prev,trigger_prev_negative;
 wire trigger_admit=triggered || TRIGGER_ENABLE==0 ||
     (trigger_have_prev && trigger_prev_negative && !sample_pcm[15]) ||
     trigger_wait_count==TRIGGER_WAIT_SAMPLES-1;
 reg [CW-1:0] capture_age;reg capture_failed,capture_enabled,send_wave;
 (* syn_ramstyle="block_ram" *) reg signed [15:0] capture[0:419];
 reg [8:0] capture_count;
 wire capture_complete=capture_count==9'd420;
 reg [DW-1:0] decimate_count;
 reg signed [SW-1:0] sample_sum;
 wire signed [SW-1:0] accumulated=sample_sum+$signed(sample_pcm);
 wire signed [15:0] average_sample=accumulated>>>AVG_SHIFT;
 wire [16:0] average_magnitude=average_sample[15] ? -$signed({average_sample[15],average_sample}):{1'b0,average_sample};
 reg [15:0] capture_peak,capture_raw_peak;
 reg [3:0] gain_shift;
 reg signed [15:0] read_sample;
 wire signed [31:0] extended_sample={{16{read_sample[15]}},read_sample};
 wire signed [31:0] visual_pcm=extended_sample<<<gain_shift;
 wire signed [31:0] visual_units=(visual_pcm+(visual_pcm<<<1))>>>11;
 wire signed [31:0] level=32'sd48+visual_units;
 wire [7:0] display_level=level<1?8'd1:level>94?8'd94:level[7:0];
 reg [8:0] point;
 reg [15:0] peak,rails;reg [1:0] latency_status;reg rate_seen;
 reg [31:0] rate;
 wire [1:0] next_latency_status=control_note_on?2'd0:
     latency_rejected?2'd3:latency_timeout?2'd2:latency_valid?2'd1:latency_status;
 wire [16:0] magnitude=sample_pcm[15] ? -$signed({sample_pcm[15],sample_pcm}):{1'b0,sample_pcm};
 reg [287:0] snapshot;reg [15:0] revision;
 reg [3:0] field;reg [4:0] state;reg [5:0] position;
 reg [1:0] control_kind,label_kind;
 reg format_load;reg [31:0] format_value;
 wire [39:0] formatted;wire format_done;reg [39:0] digits;
 reg [1:0] point_digits;
 wire [31:0] selected=snapshot[field*32+:32];
 ui_decimal_formatter #(.DIVISOR(CYCLES_PER_US)) fmt(clk,rst_n,format_load,format_value,formatted,,format_done);
 // Once addt is issued the screen owns a binary transaction. Timeout must
 // NEVER release busy or send ASCII: late FE/FD can still complete safely.
 // transfer_fault is sticky; unrecoverable link loss requires BOTH endpoints reset.
 localparam integer XW=$clog2(TRANSFER_TIMEOUT_CYCLES+1);
 reg [XW-1:0] transfer_age;
 reg [1:0] response_count;
 reg [7:0] response_kind;
 reg [3:0] reply_skip;
 reg reply_drop;
 reg [1:0] reply_ffs;
 localparam integer RX_GAP_CYCLES=RESPONSE_GAP_CYCLES;
 localparam integer RGW=$clog2(RX_GAP_CYCLES+1);
 reg [RGW-1:0] reply_gap;
 wire awaiting_response=state==15 || state==18;
 wire response_done=awaiting_response && raw_rx_valid && !raw_rx_error &&
     response_count==3 && response_kind==(state==15?8'hfe:8'hfd) && raw_rx_data==8'hff;
 function [7:0] bulk_command;input [5:0] n;begin
 case(n)0:bulk_command="a";1:bulk_command="d";2:bulk_command="d";3:bulk_command="t";
 4:bulk_command=" ";5:bulk_command="2";6:bulk_command=",";7:bulk_command="0";
 8:bulk_command=",";9:bulk_command="4";10:bulk_command="2";11:bulk_command="0";
 default:bulk_command=8'hff;endcase end endfunction
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin transfer_age<=0;transfer_fault<=0;end
 else begin
     if(state>=14 && state<=18)begin
         if(transfer_age==TRANSFER_TIMEOUT_CYCLES-1)transfer_fault<=1;
         else transfer_age<=transfer_age+1'b1;
     end else transfer_age<=0;
 end
 // Frame at the RX message boundary, not a sliding FE/FD byte search.
 // A6 custom frames have 11 bytes; standard numeric/touch replies are fixed
 // length. Strings/unknown replies are discarded through their terminator.
 // A 2ms interbyte gap resynchronizes truncated frames without deadlock.
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin response_count<=0;response_kind<=0;reply_skip<=0;
     reply_drop<=0;reply_ffs<=0;reply_gap<=0;end
 else begin
     if(raw_rx_valid)reply_gap<=0;
     else if(reply_gap<RX_GAP_CYCLES)reply_gap<=reply_gap+1'b1;
     if(raw_rx_error)begin response_count<=0;reply_skip<=0;reply_drop<=1;reply_ffs<=0;end
     else if(!raw_rx_valid && reply_gap==RX_GAP_CYCLES-1)begin
         response_count<=0;reply_skip<=0;reply_drop<=0;reply_ffs<=0;
     end else if(raw_rx_valid)begin
         if(reply_skip!=0)reply_skip<=reply_skip-1'b1;
         else if(reply_drop)begin
             if(raw_rx_data==8'hff)begin
                 if(reply_ffs==2)begin reply_drop<=0;reply_ffs<=0;end
                 else reply_ffs<=reply_ffs+1'b1;
             end else reply_ffs<=0;
         end else if(response_count!=0)begin
             if(raw_rx_data==8'hff)response_count<=response_count+1'b1;
             else begin response_count<=0;reply_drop<=1;reply_ffs<=0;end
         end else begin
             case(raw_rx_data)
             8'hfe,8'hfd:begin response_kind<=raw_rx_data;response_count<=1;end
             8'ha6:reply_skip<=10;
             8'h71:reply_skip<=7;
             8'h65:reply_skip<=6;
             8'h66:reply_skip<=4;
             8'h67,8'h68:reply_skip<=8;
             default:begin reply_drop<=1;reply_ffs<=raw_rx_data==8'hff ? 1 : 0;end
             endcase
         end
     end
 end
 function [15:0] sat16;input [31:0] n;begin sat16=|n[31:16]?16'hffff:n[15:0];end endfunction
 function [3:0] gain_for_peak;input [15:0] p;begin
 if(p==0)gain_for_peak=0;else if(p<128)gain_for_peak=8;else if(p<256)gain_for_peak=7;
 else if(p<512)gain_for_peak=6;else if(p<1024)gain_for_peak=5;else if(p<2048)gain_for_peak=4;
 else if(p<4096)gain_for_peak=3;else if(p<8192)gain_for_peak=2;else if(p<16384)gain_for_peak=1;else gain_for_peak=0;
 end endfunction
 function [7:0] prefix;input [5:0] n;input [3:0] f;begin
 case(n) 0:prefix="h";1:prefix="o";2:prefix="m";3:prefix="e";4:prefix=".";
 5:prefix="t";6:prefix=48+f;7:prefix=".";8:prefix="v";9:prefix="a";10:prefix="l";default:prefix="=";endcase end endfunction
 function [7:0] add_prefix;input [5:0] n;begin
 case(n) 0:add_prefix="a";1:add_prefix="d";2:add_prefix="d";3:add_prefix=" ";4:add_prefix="2";
 5:add_prefix=",";6:add_prefix="0";default:add_prefix=",";endcase end endfunction
 function [7:0] control_byte;input [5:0] n;input [1:0] kind;begin
 case(kind)
 0:case(n) 0:control_byte=8'd119;1:control_byte=8'd97;2:control_byte=8'd118;3:control_byte=8'd101;4:control_byte=8'd46;5:control_byte=8'd116;6:control_byte=8'd112;7:control_byte=8'd111;8:control_byte=8'd108;9:control_byte=8'd108;10:control_byte=8'd46;11:control_byte=8'd101;12:control_byte=8'd110;13:control_byte=8'd61;14:control_byte=8'd48;default:control_byte=8'hff;endcase
 1:case(n) 0:control_byte=8'd119;1:control_byte=8'd97;2:control_byte=8'd118;3:control_byte=8'd101;4:control_byte=8'd46;5:control_byte=8'd114;6:control_byte=8'd119;7:control_byte=8'd105;8:control_byte=8'd110;9:control_byte=8'd100;10:control_byte=8'd111;11:control_byte=8'd119;12:control_byte=8'd95;13:control_byte=8'd116;14:control_byte=8'd105;15:control_byte=8'd109;16:control_byte=8'd101;17:control_byte=8'd46;18:control_byte=8'd102;19:control_byte=8'd111;20:control_byte=8'd110;21:control_byte=8'd116;22:control_byte=8'd61;23:control_byte=8'd50;default:control_byte=8'hff;endcase
 2:case(n) 0:control_byte=8'd99;1:control_byte=8'd108;2:control_byte=8'd101;3:control_byte=8'd32;4:control_byte=8'd50;5:control_byte=8'd44;6:control_byte=8'd48;default:control_byte=8'hff;endcase
 default:control_byte=8'hff;endcase end endfunction
 function [5:0] control_last;input [1:0] kind;begin case(kind)0:control_last=17;1:control_last=26;2:control_last=9;default:control_last=0;endcase end endfunction
 function [7:0] label_prefix;input [5:0] n;input [1:0] kind;begin
 case(kind)
 0:case(n) 0:label_prefix=8'd119;1:label_prefix=8'd97;2:label_prefix=8'd118;3:label_prefix=8'd101;4:label_prefix=8'd46;5:label_prefix=8'd114;6:label_prefix=8'd112;7:label_prefix=8'd101;8:label_prefix=8'd97;9:label_prefix=8'd107;10:label_prefix=8'd46;11:label_prefix=8'd116;12:label_prefix=8'd120;13:label_prefix=8'd116;14:label_prefix=8'd61;15:label_prefix=8'd34;default:label_prefix=8'hff;endcase
 1:case(n) 0:label_prefix=8'd119;1:label_prefix=8'd97;2:label_prefix=8'd118;3:label_prefix=8'd101;4:label_prefix=8'd46;5:label_prefix=8'd114;6:label_prefix=8'd119;7:label_prefix=8'd105;8:label_prefix=8'd110;9:label_prefix=8'd100;10:label_prefix=8'd111;11:label_prefix=8'd119;12:label_prefix=8'd46;13:label_prefix=8'd116;14:label_prefix=8'd120;15:label_prefix=8'd116;16:label_prefix=8'd61;17:label_prefix=8'd34;default:label_prefix=8'hff;endcase
 2:case(n) 0:label_prefix=8'd119;1:label_prefix=8'd97;2:label_prefix=8'd118;3:label_prefix=8'd101;4:label_prefix=8'd46;5:label_prefix=8'd114;6:label_prefix=8'd119;7:label_prefix=8'd105;8:label_prefix=8'd110;9:label_prefix=8'd100;10:label_prefix=8'd111;11:label_prefix=8'd119;12:label_prefix=8'd95;13:label_prefix=8'd116;14:label_prefix=8'd105;15:label_prefix=8'd109;16:label_prefix=8'd101;17:label_prefix=8'd46;18:label_prefix=8'd116;19:label_prefix=8'd120;20:label_prefix=8'd116;21:label_prefix=8'd61;22:label_prefix=8'd34;23:label_prefix=8'd120;default:label_prefix=8'hff;endcase
 3:case(n) 0:label_prefix=8'd119;1:label_prefix=8'd97;2:label_prefix=8'd118;3:label_prefix=8'd101;4:label_prefix=8'd46;5:label_prefix=8'd114;6:label_prefix=8'd114;7:label_prefix=8'd101;8:label_prefix=8'd102;9:label_prefix=8'd114;10:label_prefix=8'd101;11:label_prefix=8'd115;12:label_prefix=8'd104;13:label_prefix=8'd46;14:label_prefix=8'd116;15:label_prefix=8'd120;16:label_prefix=8'd116;17:label_prefix=8'd61;18:label_prefix=8'd34;default:label_prefix=8'hff;endcase
 default:label_prefix=8'hff;endcase end endfunction

 function [5:0] label_prefix_length;input [1:0] k;begin
 case(k)0:label_prefix_length=16;1:label_prefix_length=18;2:label_prefix_length=24;3:label_prefix_length=19;endcase end endfunction
 wire [5:0] label_start=label_prefix_length(label_kind);
 wire [2:0] label_digits=label_kind==3?2:5;
 wire [5:0] label_length=label_start+label_digits+(label_kind==1?3:label_kind==3?5:1)+3;
 wire [5:0] label_tail_position=position-label_start-label_digits;
 wire [7:0] label_tail=label_kind==1 ? (label_tail_position==0?"u":label_tail_position==1?"s":8'h22):
     label_kind==3 ? (label_tail_position==0?"T":label_tail_position==1?"X":
                     label_tail_position==2?"/":label_tail_position==3?"s":8'h22):8'h22;
 wire [7:0] label_byte=position<label_start?label_prefix(position,label_kind):
     position<label_start+label_digits?(digits>>((label_digits-1-(position-label_start))*8)):
     position<label_length-3?label_tail:8'hff;
 wire frame_done=WAVE_BULK_ENABLE ? (state==18 && response_done) : state==12 && byte_ready && position==label_length-1 && label_kind==3 && page_id==3;
 reg [FW-1:0] second_count;reg [15:0] frame_count,last_fps;
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin second_count<=0;frame_count<=0;last_fps<=0;end
 else if(second_count==SECOND_CYCLES-1)begin
     second_count<=0;last_fps<=frame_count==65535?16'hffff:frame_count+frame_done;frame_count<=0;
 end else begin second_count<=second_count+1'b1;if(frame_done && frame_count!=65535)frame_count<=frame_count+1'b1;end
 assign busy=state!=0;
 assign byte_valid=state==3 || state==5 || state==9 || state==12 || state==14 || state==17;
 assign byte_data=state==14 ? bulk_command(position):state==17 ? display_level:state==3 ? (position<12?prefix(position,field):(position<17?(digits>>((16-position)*8)):8'hff)):
     state==9 ? control_byte(position,control_kind):state==12 ? label_byte:
     position<8 ? add_prefix(position):position<8+point_digits ?
     (digits>>((point_digits-1-(position-8))*8)):8'hff;
 always @(posedge clk or negedge rst_n) begin
 if(!rst_n)begin
 state<=0;capture_age<=0;capture_failed<=0;capture_count<=0;capture_enabled<=0;send_wave<=0;
 trigger_wait_count<=0;triggered<=0;trigger_have_prev<=0;trigger_prev_negative<=0;
 sample_sum<=0;decimate_count<=0;capture_peak<=0;capture_raw_peak<=0;gain_shift<=0;read_sample<=0;
 peak<=0;rails<=0;latency_status<=0;rate_seen<=0;rate<=0;snapshot<=0;revision<=0;field<=0;
 point<=0;position<=0;format_load<=0;format_value<=0;digits<=0;
 point_digits<=1;control_kind<=0;label_kind<=0;
 end else begin
 format_load<=0;
 if(capture_enabled)begin
     if(capture_age==CAPTURE_TIMEOUT_CYCLES-1)begin capture_failed<=1;capture_enabled<=0;end
     else capture_age<=capture_age+1'b1;
 end
 latency_status<=next_latency_status;
 if(window_valid)begin rate<=samples_in_window;rate_seen<=1;end
 if(sample_valid)begin
     if(magnitude>peak)peak<=magnitude[15:0];
     if((sample_pcm==16'sh7fff || sample_pcm==16'sh8000) && rails!=65535)rails<=rails+1'b1;
     if(capture_enabled)begin
         trigger_have_prev<=1;trigger_prev_negative<=sample_pcm[15];
         if(!trigger_admit)trigger_wait_count<=trigger_wait_count+1'b1;
         else begin
             triggered<=1;
             if(magnitude>capture_raw_peak)capture_raw_peak<=magnitude[15:0];
             if(decimate_count==WAVE_DECIMATE-1)begin
                 capture[capture_count]<=average_sample;sample_sum<=0;decimate_count<=0;
                 if(average_magnitude>capture_peak)capture_peak<=average_magnitude[15:0];
                 if(capture_count==419)begin capture_count<=420;capture_enabled<=0;end
                 else capture_count<=capture_count+1'b1;
             end else begin sample_sum<=accumulated;decimate_count<=decimate_count+1'b1;end
         end
     end
 end
 case(state)
 0:if(request)begin
     snapshot<={{16'd0,revision+16'd1},{16'd0,rails},{16'd0,peak},{31'd0,(rate_seen|window_valid)},
         {16'd0,sat16(window_valid?samples_in_window:rate)},{16'd0,sat16(missed_deadline_count)},
         {30'd0,next_latency_status},latency_max_cycles,latency_cycles};
     revision<=revision+1'b1;field<=0;state<=1;send_wave<=page_id==3;
     capture_count<=0;capture_age<=0;capture_failed<=0;capture_enabled<=page_id==3;
     capture_peak<=0;capture_raw_peak<=0;sample_sum<=0;decimate_count<=0;
     trigger_wait_count<=0;triggered<=0;trigger_have_prev<=0;trigger_prev_negative<=0;
     peak<=sample_valid?magnitude[15:0]:0;
 end
 1:begin format_value<=field<2?(selected>65535*CYCLES_PER_US?65535*CYCLES_PER_US:selected+CYCLES_PER_US-1):selected*CYCLES_PER_US;
     format_load<=1;state<=2;end
 2:if(format_done)begin digits<=formatted;position<=0;state<=3;end
 3:if(byte_ready)begin
     if(position==19)begin if(field==8)state<=send_wave?4:0;else begin field<=field+1'b1;state<=1;end end
     else position<=position+1'b1;
 end
 4:if(capture_failed || page_id!=3)begin state<=0;capture_enabled<=0;end
     else if(capture_complete)begin gain_shift<=gain_for_peak(capture_peak);control_kind<=0;position<=0;state<=9;end
 9:if(byte_ready)begin
     if(position==control_last(control_kind))begin
         if(page_id!=3)state<=0;
         else if(WAVE_BULK_ENABLE && control_kind==1)begin position<=0;state<=19;end
         else if(WAVE_SCROLL_ENABLE && control_kind==1)begin point<=0;state<=6;end
         else if(control_kind<2)begin control_kind<=control_kind+1'b1;position<=0;state<=13;end
         else begin point<=0;state<=6;end
     end else position<=position+1'b1;
 end
 6:if(page_id!=3)state<=0;else begin read_sample<=capture[point];state<=7;end
 7:begin format_value<=display_level*CYCLES_PER_US;point_digits<=display_level<10?1:2;format_load<=1;state<=8;end
 8:if(format_done)begin
     if(page_id!=3)state<=0;else begin digits<=formatted;position<=0;state<=5;end
 end
 5:if(byte_ready)begin
     if(position==10+point_digits)begin
         if(page_id!=3)state<=0;
         else if(point==419)begin label_kind<=0;state<=10;end
         else begin
             point<=point+1'b1;
             state<=6;
         end
     end else position<=position+1'b1;
 end
 10:if(page_id!=3)state<=0;else begin
     case(label_kind) 0:format_value<=capture_raw_peak*CYCLES_PER_US;
     1:format_value<=WINDOW_US*CYCLES_PER_US;2:format_value<=(32'd1<<gain_shift)*CYCLES_PER_US;
     default:format_value<=(last_fps>99?99:last_fps)*CYCLES_PER_US;endcase
     format_load<=1;state<=11;
 end
 11:if(format_done)begin if(page_id!=3)state<=0;else begin digits<=formatted;position<=0;state<=12;end end
 12:if(byte_ready)begin
     if(position==label_length-1)begin
         if(page_id!=3 || label_kind==3)state<=0;else begin label_kind<=label_kind+1'b1;state<=10;end
     end else position<=position+1'b1;
 end
 // Leave an explicit command boundary before clear; do not start it on a
 // page that changed just after the previous terminator was accepted.
 13:if(page_id!=3)state<=0;else state<=9;
 // Last cancellable boundary. From state14 through FD, ignore page changes.
 19:if(page_id!=3)state<=0;else begin position<=0;state<=14;end
 14:if(byte_ready)begin
     if(position==14)state<=15;else position<=position+1'b1;
 end
 15:if(response_done)begin point<=0;state<=16;end
 16:begin read_sample<=capture[point];state<=17;end
 17:if(byte_ready)begin
     if(point==419)state<=18;
     else begin point<=point+1'b1;state<=16;end
 end
 18:if(response_done)begin
     if(page_id!=3)state<=0;else begin label_kind<=0;state<=10;end
 end
 endcase
 end
 end
 // synthesis translate_off
 initial begin
 if(WAVE_DECIMATE<1 || (WAVE_DECIMATE&(WAVE_DECIMATE-1))!=0)$fatal(1,"WAVE_DECIMATE must be power of2");
 if(TRIGGER_WAIT_SAMPLES<1 || (TRIGGER_ENABLE!=0 && TRIGGER_ENABLE!=1))$fatal(1,"invalid wave trigger parameters");
 if(TRANSFER_TIMEOUT_CYCLES<8)$fatal(1,"invalid transfer timeout");
 if(CYCLES_PER_US<1 || CAPTURE_TIMEOUT_CYCLES<8)$fatal(1,"invalid wave timing");
 end
 // synthesis translate_on
endmodule

