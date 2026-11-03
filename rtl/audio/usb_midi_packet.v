// USB-MIDI 1.0 four-byte Event Packet decoder. This is downstream of a USB
// host controller, not a USB PHY or enumerator. No host or CPU is instantiated.
module usb_midi_packet (
    input wire clk,input wire rst_n,
    input wire packet_valid,input wire [31:0] packet,
    input wire [3:0] cable_select,
    output reg note_valid,output reg [6:0] note,
    output reg [6:0] velocity,output reg [3:0] channel,
    output reg mod_valid,output reg [6:0] mod_depth,
    output reg bend_valid,output reg [13:0] bend_word
);
    wire [3:0] cable=packet[7:4];
    wire [3:0] cin=packet[3:0];
    wire [7:0] status=packet[15:8];
    wire [7:0] data1=packet[23:16];
    wire [7:0] data2=packet[31:24];
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            note_valid<=0;note<=0;velocity<=0;channel<=0;
            mod_valid<=0;mod_depth<=0;bend_valid<=0;bend_word<=0;
        end else begin
            note_valid<=0;mod_valid<=0;bend_valid<=0;
            if(packet_valid && cable==cable_select && status[7] &&
               !data1[7] && !data2[7]) begin
                channel<=status[3:0];
                case(cin)
                    4'h8: if(status[7:4]==4'h8) begin
                        note<=data1[6:0];velocity<=0;note_valid<=1;
                    end
                    4'h9: if(status[7:4]==4'h9) begin
                        note<=data1[6:0];velocity<=data2[6:0];note_valid<=1;
                    end
                    4'hb: if(status[7:4]==4'hb && data1==8'd1) begin
                        mod_depth<=data2[6:0];mod_valid<=1;
                    end
                    4'he: if(status[7:4]==4'he) begin
                        bend_word<={data2[6:0],data1[6:0]};bend_valid<=1;
                    end
                    default: begin end
                endcase
            end
        end
    end
endmodule
