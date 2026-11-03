`timescale 1ns/1ps
module tb_usb_midi_config_parser;
    reg clk=0,rst_n=0,start=0,byte_valid=0,done=0;
    reg [7:0] byte_data=0;
    wire found,malformed;
    wire [3:0] endpoint;
    wire [10:0] max_packet;
    wire [7:0] interface_number;
    usb_midi_config_parser dut(clk,rst_n,start,byte_valid,byte_data,done,
                                found,endpoint,max_packet,interface_number,malformed);
    always #10 clk=~clk;
    task put(input [7:0] value);
        begin @(negedge clk);byte_data=value;byte_valid=1;
              @(negedge clk);byte_valid=0; end
    endtask
    task reset_stream;
        begin @(negedge clk);start=1;@(negedge clk);start=0;end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;reset_stream();
        // Configuration, then AudioControl interface with no endpoints.
        put(9);put(2);put(32);put(0);put(2);put(1);put(0);put(8'h80);put(50);
        put(9);put(4);put(0);put(0);put(0);put(1);put(1);put(0);put(0);
        // SMK-25 interface 1 is Audio/MIDIStreaming, alternate setting 0.
        put(9);put(4);put(1);put(0);put(2);put(1);put(3);put(0);put(0);
        // Ignore the bulk OUT endpoint 0x04; select bulk IN 0x84/64 bytes.
        put(7);put(5);put(8'h04);put(2);put(64);put(0);put(0);
        put(7);put(5);put(8'h84);put(2);put(64);put(0);put(0);
        @(negedge clk);done=1;@(negedge clk);done=0;
        if(!found || endpoint!=4 || max_packet!=64 || interface_number!=1 || malformed)
            $fatal(1,"did not select SMK-25 MIDI bulk IN endpoint");
        reset_stream();
        put(9);put(4);put(1);put(0);put(1);put(3);put(1);put(1);put(0);
        put(7);put(5);put(8'h81);put(3);put(8);put(0);put(10);
        if(found || malformed) $fatal(1,"HID interrupt endpoint mistaken for MIDI");
        reset_stream();put(1);
        if(!malformed) $fatal(1,"bad descriptor length accepted");
        $display("PASS: USB MIDI config parser selects interface 1 bulk IN EP4/64");
        $finish;
    end
endmodule
