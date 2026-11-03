`timescale 1ns/1ps
module tb_smk25_event_decoder;
    reg clk=0,rst_n=0,valid=0;
    reg [31:0] packet=0;
    wire note_valid,mod_valid,bend_valid,knob_a_valid,knob_b_valid;
    wire pad_b_valid,transport_play,transport_stop,transport_record;
    wire [6:0] note,velocity,mod_depth,knob_a_value,knob_b_value,pad_b_note;
    wire [3:0] channel;
    wire [13:0] bend_word;
    wire [2:0] knob_a_index,knob_b_index;
    smk25_event_decoder dut(
        .clk(clk),.rst_n(rst_n),.packet_valid(valid),.packet(packet),
        .note_valid(note_valid),.note(note),.velocity(velocity),.channel(channel),
        .mod_valid(mod_valid),.mod_depth(mod_depth),
        .bend_valid(bend_valid),.bend_word(bend_word),
        .knob_a_valid(knob_a_valid),.knob_a_index(knob_a_index),
        .knob_a_value(knob_a_value),.knob_b_valid(knob_b_valid),
        .knob_b_index(knob_b_index),.knob_b_value(knob_b_value),
        .pad_b_valid(pad_b_valid),.pad_b_note(pad_b_note),
        .transport_play(transport_play),.transport_stop(transport_stop),
        .transport_record(transport_record));
    always #10 clk=~clk;
    integer b;
    task send(input [7:0] head,input [7:0] stat,input [7:0] d1,input [7:0] d2);
        begin
            @(negedge clk);packet={d2,d1,stat,head};valid=1;
            @(negedge clk);valid=0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        send(8'h09,8'h90,8'd53,8'd104);
        if(!note_valid || note!=53 || velocity!=104 || channel!=0)
            $fatal(1,"cable 0 key failed");
        send(8'h19,8'h90,8'd53,8'd104);
        if(note_valid) $fatal(1,"mirrored cable 1 duplicated key");
        send(8'h09,8'h99,8'd40,8'd46);
        if(!note_valid || note!=60 || velocity!=46 || channel!=9)
            $fatal(1,"pad A translation failed");
        send(8'h08,8'h89,8'd40,8'd64);
        if(!note_valid || note!=60 || velocity!=0)
            $fatal(1,"pad A release failed");
        send(8'h0b,8'hb0,8'd20,8'd70);
        if(!knob_a_valid || knob_a_index!=0 || knob_a_value!=70)
            $fatal(1,"A MODE failed");
        send(8'h0b,8'hb0,8'd27,8'd21);
        if(!knob_a_valid || knob_a_index!=7 || knob_a_value!=21)
            $fatal(1,"A TRANSPOSE failed");
        send(8'h29,8'h90,8'd104,8'd127);
        send(8'h2e,8'he0,8'd0,8'd72);
        if(!knob_b_valid || knob_b_index!=0 || knob_b_value!=72)
            $fatal(1,"B MODE failed");
        send(8'h2e,8'he1,8'd0,8'd71);
        if(knob_b_valid) $fatal(1,"wrong B knob channel accepted");
        send(8'h29,8'h90,8'd104,8'd0);
        send(8'h2e,8'he0,8'd0,8'd73);
        if(knob_b_valid) $fatal(1,"B knob out-of-window value accepted");
        send(8'h29,8'h90,8'd105,8'd127);
        send(8'h2e,8'he1,8'd0,8'd37);
        if(!knob_b_valid || knob_b_index!=1 || knob_b_value!=37)
            $fatal(1,"B OCT failed");
        send(8'h29,8'h90,8'd105,8'd0);
        for(b=2;b<8;b=b+1) begin
            send(8'h29,8'h90,8'd104+b,8'd127);
            send(8'h2e,8'he0+b,8'd0,8'd20+b);
            if(!knob_b_valid || knob_b_index!=b || knob_b_value!=20+b)
                $fatal(1,"B knob %0d failed",b);
            send(8'h29,8'h90,8'd104+b,8'd0);
        end
        send(8'h29,8'h90,8'd0,8'd127);
        if(!pad_b_valid || pad_b_note!=0 || note_valid)
            $fatal(1,"pad B preset failed");
        send(8'h29,8'h90,8'd94,8'd127);
        if(!transport_play) $fatal(1,"PLAY failed");
        send(8'h29,8'h90,8'd93,8'd127);
        if(!transport_stop) $fatal(1,"STOP failed");
        send(8'h29,8'h90,8'd95,8'd127);
        if(!transport_record) $fatal(1,"REC failed");
        $display("PASS measured SMK25 MIDI cable and control mapping");
        $finish;
    end
endmodule
