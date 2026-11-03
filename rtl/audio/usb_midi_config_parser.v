// Parse a USB configuration descriptor stream and select the first MIDI 1.0
// Streaming bulk-IN endpoint. Receives bytes after a Host EP0 control read;
// this module is not itself a USB Host, PHY, or enumerator.
module usb_midi_config_parser (
    input wire clk,input wire rst_n,
    input wire start,input wire byte_valid,input wire [7:0] byte_data,
    input wire done,
    output reg found,output reg [3:0] endpoint,
    output reg [10:0] max_packet,output reg [7:0] interface_number,
    output reg malformed
);
    reg [7:0] descriptor_length,descriptor_type,index;
    reg [7:0] interface_temp,alternate_temp,class_temp;
    reg midi_interface;
    reg [7:0] endpoint_temp,attributes_temp,max_packet_low;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            descriptor_length<=0;descriptor_type<=0;index<=0;
            interface_temp<=0;alternate_temp<=0;class_temp<=0;
            midi_interface<=0;endpoint_temp<=0;attributes_temp<=0;
            max_packet_low<=0;found<=0;endpoint<=0;max_packet<=0;
            interface_number<=0;malformed<=0;
        end else if(start) begin
            descriptor_length<=0;descriptor_type<=0;index<=0;
            interface_temp<=0;alternate_temp<=0;class_temp<=0;
            midi_interface<=0;endpoint_temp<=0;attributes_temp<=0;
            max_packet_low<=0;found<=0;endpoint<=0;max_packet<=0;
            interface_number<=0;malformed<=0;
        end else begin
            if(done && index!=0) malformed<=1;
            if(byte_valid && !malformed) begin
                if(index==0) begin
                    if(byte_data<8'd2) malformed<=1;
                    descriptor_length<=byte_data;
                    index<=1;
                end else begin
                    if(index==1) begin
                        descriptor_type<=byte_data;
                        if(byte_data==8'd4 && descriptor_length<8'd9) malformed<=1;
                        if(byte_data==8'd5 && descriptor_length<8'd7) malformed<=1;
                    end
                    if(descriptor_type==8'd4) begin
                        case(index)
                            8'd2: interface_temp<=byte_data;
                            8'd3: alternate_temp<=byte_data;
                            8'd5: class_temp<=byte_data;
                            8'd6: midi_interface<=class_temp==8'd1 &&
                                                    byte_data==8'd3 &&
                                                    alternate_temp==0;
                            default: begin end
                        endcase
                    end
                    if(descriptor_type==8'd5 && midi_interface && !found) begin
                        case(index)
                            8'd2: endpoint_temp<=byte_data;
                            8'd3: attributes_temp<=byte_data;
                            8'd4: max_packet_low<=byte_data;
                            8'd5: if(endpoint_temp[7] &&
                                     attributes_temp[1:0]==2'd2 &&
                                     {byte_data[2:0],max_packet_low}!=0) begin
                                found<=1;
                                endpoint<=endpoint_temp[3:0];
                                max_packet<={byte_data[2:0],max_packet_low};
                                interface_number<=interface_temp;
                            end
                            default: begin end
                        endcase
                    end
                    if(index+8'd1>=descriptor_length) index<=0;
                    else index<=index+8'd1;
                end
            end
        end
    end
endmodule
