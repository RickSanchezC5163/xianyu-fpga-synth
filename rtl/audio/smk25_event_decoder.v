// Measured SMK-25 default preset, USB-MIDI Event Packet decoder.
// Cable 0 mirrors musical events on cable 1; only cable 0 is accepted.
// Cable 2 carries pad-bank B and transport controls. The keyboard itself
// implements ARP, smart scale/chord, octave and Bluetooth modes.
module smk25_event_decoder (
    input wire clk,input wire rst_n,input wire packet_valid,input wire [31:0] packet,
    output reg note_valid,output reg [6:0] note,velocity,
    output reg [3:0] channel,
    output reg mod_valid,output reg [6:0] mod_depth,
    output reg bend_valid,output reg [13:0] bend_word,
    output reg knob_a_valid,output reg [2:0] knob_a_index,
    output reg [6:0] knob_a_value,
    output reg knob_b_valid,output reg [2:0] knob_b_index,
    output reg [6:0] knob_b_value,
    output reg pad_b_valid,output reg [6:0] pad_b_note,
    output reg transport_play,transport_stop,transport_record
);
    wire [3:0] cable=packet[7:4],cin=packet[3:0];
    wire [7:0] status=packet[15:8];
    wire [7:0] data1=packet[23:16],data2=packet[31:24];
    wire note_on=cin==4'h9 && status[7:4]==4'h9 && data2!=0;
    wire note_off=(cin==4'h8 && status[7:4]==4'h8) ||
                  (cin==4'h9 && status[7:4]==4'h9 && data2==0);
    reg b_active;
    reg [2:0] b_index;
    wire [6:0] pad_note=
        data1==8'd40 ? 7'd60 : data1==8'd41 ? 7'd62 :
        data1==8'd42 ? 7'd64 : data1==8'd43 ? 7'd65 :
        data1==8'd36 ? 7'd67 : data1==8'd37 ? 7'd69 :
        data1==8'd38 ? 7'd71 : 7'd72;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            note_valid<=0;note<=0;velocity<=0;channel<=0;
            mod_valid<=0;mod_depth<=0;bend_valid<=0;bend_word<=0;
            knob_a_valid<=0;knob_a_index<=0;knob_a_value<=0;
            knob_b_valid<=0;knob_b_index<=0;knob_b_value<=0;
            pad_b_valid<=0;pad_b_note<=0;
            transport_play<=0;transport_stop<=0;transport_record<=0;
            b_active<=0;b_index<=0;
        end else begin
            note_valid<=0;mod_valid<=0;bend_valid<=0;
            knob_a_valid<=0;knob_b_valid<=0;pad_b_valid<=0;
            transport_play<=0;transport_stop<=0;transport_record<=0;
            if(packet_valid && status[7] && !data1[7] &&
               (cin==4'hd || !data2[7])) begin
                if(cable==4'd0) begin
                    if((note_on || note_off) && data1<8'd128) begin
                        if(status[3:0]==4'd9 &&
                           ((data1>=8'd36 && data1<=8'd43))) begin
                            note_valid<=1;note<=pad_note;channel<=4'd9;
                            velocity<=note_off ? 7'd0 : data2[6:0];
                        end else if(status[3:0]!=4'd9) begin
                            note_valid<=1;note<=data1[6:0];
                            channel<=status[3:0];
                            velocity<=note_off ? 7'd0 : data2[6:0];
                        end
                    end else if(cin==4'hb && status[7:4]==4'hb) begin
                        if(data1==8'd1) begin
                            mod_valid<=1;mod_depth<=data2[6:0];
                            channel<=status[3:0];
                        end else if(data1>=8'd20 && data1<=8'd27 &&
                                    status[3:0]==4'd0) begin
                            knob_a_valid<=1;
                            knob_a_index<=data1[2:0]-3'd4;
                            knob_a_value<=data2[6:0];
                        end
                    end else if(cin==4'he && status[7:4]==4'he) begin
                        bend_valid<=1;
                        bend_word<={data2[6:0],data1[6:0]};
                        channel<=status[3:0];
                    end
                end else if(cable==4'd2) begin
                    if(status==8'h90 && note_on) begin
                        if(data1>=8'd104 && data1<=8'd111) begin
                            b_active<=1;b_index<=data1[2:0];
                        end else if(data1==8'd94) transport_play<=1;
                        else if(data1==8'd93) transport_stop<=1;
                        else if(data1==8'd95) transport_record<=1;
                        else if(data1<=8'd3 || data1==8'd91 ||
                                data1==8'd92 || data1==8'd96 ||
                                data1==8'd97) begin
                            pad_b_valid<=1;pad_b_note<=data1[6:0];
                        end
                    end else if(status==8'h90 && note_off &&
                                data1>=8'd104 && data1<=8'd111 &&
                                data1[2:0]==b_index) b_active<=0;
                    else if(status[7:4]==4'he && cin==4'he && b_active &&
                            status[2:0]==b_index && !status[3]) begin
                        knob_b_valid<=1;knob_b_index<=b_index;
                        knob_b_value<=data2[6:0];
                    end
                end
            end
        end
    end
endmodule
