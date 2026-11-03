`timescale 1ns/1ps
// Dedicated screen UART byte stream, not the existing PC MIDI UART protocol.
// A6 5A kind id value[7:0] value[15:8] value[23:16] value[31:24]
// CRC16/MODBUS low high 7E. CRC covers the first eight bytes, init FFFF.
module tjc_event_rx #(parameter integer GAP_CYCLES=500000)(
    input wire clk,rst_n,
    input wire byte_valid,input wire [7:0] byte_data,input wire framing_error,
    output reg event_valid,output reg [7:0] event_kind,event_id,
    output reg [31:0] event_value,
    output reg [31:0] crc_errors,format_errors,gap_timeouts
);
    reg [79:0] history;
    wire [87:0] candidate={history,byte_data};
    reg header_seen,busy;
    localparam integer GW=GAP_CYCLES<2?1:$clog2(GAP_CYCLES);
    reg [GW-1:0] gap_count;
    reg [87:0] packet;
    reg [63:0] crc_data;
    reg [15:0] crc;
    reg [2:0] crc_index;
    function [15:0] crc_byte;
        input [15:0] previous;input [7:0] data;
        reg [15:0] work;integer i;
        begin
            work=previous^{8'd0,data};
            for(i=0;i<8;i=i+1) work=work[0]?(work>>1)^16'ha001:(work>>1);
            crc_byte=work;
        end
    endfunction
    wire [15:0] next_crc=crc_byte(crc,crc_data[63:56]);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            history<=0;header_seen<=0;busy<=0;gap_count<=0;
            packet<=0;crc_data<=0;crc<=16'hffff;crc_index<=0;
            event_valid<=0;event_kind<=0;event_id<=0;event_value<=0;
            crc_errors<=0;format_errors<=0;gap_timeouts<=0;
        end else begin
            event_valid<=0;
            if(framing_error) begin
                history<=0;header_seen<=0;busy<=0;gap_count<=0;
                format_errors<=format_errors+1'b1;
            end else begin
                if(byte_valid) begin
                    history<=candidate[79:0];gap_count<=0;
                    if(history[7:0]==8'ha6 && byte_data==8'h5a) header_seen<=1;
                    if(candidate[87:72]==16'ha65a) begin
                        if(candidate[7:0]!=8'h7e || busy) begin
                            format_errors<=format_errors+1'b1;header_seen<=0;
                        end else begin
                            packet<=candidate;crc_data<=candidate[87:24];
                            crc<=16'hffff;crc_index<=0;busy<=1;
                        end
                    end
                end else if(header_seen) begin
                    if(gap_count==GAP_CYCLES-1) begin
                        history<=0;header_seen<=0;busy<=0;gap_count<=0;
                        gap_timeouts<=gap_timeouts+1'b1;
                    end else gap_count<=gap_count+1'b1;
                end
                if(busy) begin
                    crc<=next_crc;crc_data<={crc_data[55:0],8'd0};
                    if(crc_index==7) begin
                        busy<=0;header_seen<=0;
                        if(next_crc=={packet[15:8],packet[23:16]}) begin
                            event_valid<=1;event_kind<=packet[71:64];event_id<=packet[63:56];
                            event_value<={packet[31:24],packet[39:32],packet[47:40],packet[55:48]};
                        end else crc_errors<=crc_errors+1'b1;
                    end else crc_index<=crc_index+1'b1;
                end
            end
        end
    end
    // synthesis translate_off
    initial if(GAP_CYCLES<16) $fatal(1,"tjc_event_rx GAP_CYCLES must exceed CRC processing time");
    // synthesis translate_on
endmodule
