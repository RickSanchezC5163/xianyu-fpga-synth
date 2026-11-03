// USB-MIDI event packets cross from the 60 MHz USB clock to the 50 MHz
// audio clock. Wire events take at least 160 USB clocks; validated buffered
// packets drain at one byte per eight clocks (32 clocks/event), so the
// bundled payload is stable throughout
// the two-flop toggle synchronization. Only cable 0 is decoded: the SMK-25
// sends each key event on both cable 0 and cable 1.
module usb_midi_event_cdc (
    input wire usb_clk,input wire usb_rst_n,input wire audio_clk,
    input wire audio_rst_n,input wire connected,input wire packet_start,
    input wire byte_valid,input wire [7:0] byte_data,
    output reg audio_connected,output reg packet_valid,
    output reg [31:0] packet
);
    reg [1:0] byte_index=0;
    reg [7:0] header=0,status=0,data1=0;
    reg [31:0] usb_packet=0;
    reg usb_toggle=0;
    wire [1:0] index_now=packet_start ? 2'd0 : byte_index;
    always @(posedge usb_clk or negedge usb_rst_n) begin
        if(!usb_rst_n) begin
            byte_index<=0;header<=0;status<=0;data1<=0;
            usb_packet<=0;usb_toggle<=0;
        end else if(!connected) byte_index<=0;
        else begin
            if(packet_start) byte_index<=0;
            if(byte_valid) begin
                byte_index<=index_now+2'd1;
                case(index_now)
                    2'd0: header<=byte_data;
                    2'd1: status<=byte_data;
                    2'd2: data1<=byte_data;
                    2'd3: begin
                        usb_packet<={byte_data,data1,status,header};
                        usb_toggle<=!usb_toggle;
                    end
                endcase
            end
        end
    end
    reg [2:0] toggle_sync=0;
    reg [1:0] connection_sync=0;
    always @(posedge audio_clk or negedge audio_rst_n) begin
        if(!audio_rst_n) begin
            toggle_sync<=0;connection_sync<=0;
            audio_connected<=0;packet_valid<=0;packet<=0;
        end else begin
            toggle_sync<={toggle_sync[1:0],usb_toggle};
            connection_sync<={connection_sync[0],connected};
            audio_connected<=connection_sync[1];
            packet_valid<=toggle_sync[2]^toggle_sync[1];
            if(toggle_sync[2]^toggle_sync[1]) packet<=usb_packet;
        end
    end
endmodule
