`timescale 1ns/1ps
module tb_usb_midi_event_cdc;
    reg usb_clk=0,audio_clk=0,usb_rst_n=0,audio_rst_n=0;
    reg connected=0,packet_start=0,byte_valid=0;
    reg [7:0] byte_data=0;
    wire audio_connected,packet_valid;
    wire [31:0] packet;
    integer count=0;
    reg [31:0] seen [0:1];
    always #8 usb_clk=~usb_clk;
    always #10 audio_clk=~audio_clk;
    usb_midi_event_cdc dut(usb_clk,usb_rst_n,audio_clk,audio_rst_n,
                            connected,packet_start,byte_valid,byte_data,
                            audio_connected,packet_valid,packet);
    always @(posedge audio_clk)
        if(packet_valid) begin
            if(count<2) seen[count]=packet;
            count=count+1;
        end
    task send_byte(input [7:0] value);
        begin
            @(negedge usb_clk);byte_data=value;byte_valid=1;
            @(negedge usb_clk);byte_valid=0;
            repeat(38) @(negedge usb_clk);
        end
    endtask
    initial begin
        repeat(5) @(negedge usb_clk);
        usb_rst_n=1;audio_rst_n=1;connected=1;
        @(negedge usb_clk);packet_start=1;
        @(negedge usb_clk);packet_start=0;
        send_byte(8'h09);send_byte(8'h90);send_byte(8'h35);send_byte(8'h68);
        send_byte(8'h19);send_byte(8'h90);send_byte(8'h35);send_byte(8'h68);
        repeat(15) @(negedge audio_clk);
        if(!audio_connected || count!=2 ||
           seen[0]!==32'h68359009 || seen[1]!==32'h68359019)
            $fatal(1,"USB MIDI CDC failed count=%d packet0=%h packet1=%h",count,seen[0],seen[1]);
        connected=0;
        repeat(5) @(negedge audio_clk);
        if(audio_connected) $fatal(1,"USB disconnect did not cross clock domain");
        $display("PASS USB MIDI event CDC");$finish;
    end
endmodule
