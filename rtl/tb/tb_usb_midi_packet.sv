`timescale 1ns/1ps
module tb_usb_midi_packet;
    reg clk=0,rst_n=0,valid=0;
    reg [31:0] packet=0;
    reg [3:0] cable=0;
    wire note_valid,mod_valid,bend_valid;
    wire [6:0] note,velocity,mod_depth;
    wire [3:0] channel;
    wire [13:0] bend_word;
    usb_midi_packet dut(clk,rst_n,valid,packet,cable,note_valid,note,
                         velocity,channel,mod_valid,mod_depth,bend_valid,bend_word);
    always #10 clk=~clk;
    task send(input [31:0] value);
        begin
            @(negedge clk);packet=value;valid=1;
            @(negedge clk);valid=0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        // Byte order: header, MIDI status, data1, data2.
        send(32'h643c9909); // Note On 60/100 on channel 10.
        if(!note_valid || note!=60 || velocity!=100 || channel!=9)
            $fatal(1,"USB MIDI note-on parse failed");
        send(32'h003c8008); // Note Off 60.
        if(!note_valid || velocity!=0) $fatal(1,"note-off parse failed");
        send(32'h003c9009); // Note On velocity zero is also note-off.
        if(!note_valid || velocity!=0) $fatal(1,"zero-velocity note-on failed");
        send(32'h7f01b00b); // CC1 maximum on channel 1.
        if(!mod_valid || mod_depth!=127 || channel!=0)
            $fatal(1,"MOD CC parse failed");
        send(32'h4000e00e); // Center pitch bend.
        if(!bend_valid || bend_word!=14'd8192) $fatal(1,"bend parse failed");
        cable=1;send(32'h643c9909);
        if(note_valid || mod_valid || bend_valid) $fatal(1,"wrong cable accepted");
        cable=0;send(32'h643c990f); // Wrong CIN/status pairing.
        if(note_valid) $fatal(1,"invalid CIN accepted");
        $display("PASS: USB-MIDI 1.0 event packet note, MOD, bend and cable filter");
        $finish;
    end
    initial begin #100000;$fatal(1,"USB MIDI decoder timeout");end
endmodule
