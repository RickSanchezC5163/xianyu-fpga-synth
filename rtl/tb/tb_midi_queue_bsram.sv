`timescale 1ns/1ps
// Real frame parser and queue controller. Only UART byte decoding is bypassed.
// The independent scoreboard never reads DUT RAM or DUT queue pointers.
module tb_midi_queue_bsram;
    reg clk=0,rst_n=0,tick=0,byte_valid=0;
    reg [7:0] byte_data=0;
    always #10 clk=~clk;
    midi_control #(.QUEUE_BSRAM(1)) dut(
        .clk(clk),.rst_n(rst_n),.rx(1'b1),.sample_tick(tick),
        .audio_ready(1'b1),.audio_overrun(1'b0),
        .usb_connected(1'b0),.usb_note_valid(1'b0),.usb_play(1'b0),.usb_stop(1'b0),
        .ui_param_valid(1'b0));
    initial begin
        force dut.rx_valid=byte_valid;
        force dut.rx_byte=byte_data;
        force dut.rx_error=1'b0;
    end
    reg [49:0] model[0:63];
    integer rd=0,wr=0,count=0,pushed=0,popped=0,simultaneous=0,flushes=0;
    always @(posedge clk) begin
        if(!rst_n) begin rd=0;wr=0;count=0;end
        else begin
            if(dut.queue_count!==count) $fatal(1,"queue occupancy mismatch %0d/%0d",dut.queue_count,count);
            if(dut.request_stop) begin rd=0;wr=0;count=0;flushes=flushes+1;end
            else begin
                if(dut.pop) begin
                    if(count==0 || dut.queue_head!==model[rd])
                        $fatal(1,"stale, repeated or reordered queue head at pop%0d",popped);
                    rd=(rd+1)%64;count=count-1;popped=popped+1;
                end
                if(dut.push) begin
                    if(count>=64) $fatal(1,"accepted event into full queue");
                    model[wr]={dut.event_time,dut.payload[4][6:0],dut.payload[5][6:0],dut.payload[6][3:0]};
                    wr=(wr+1)%64;count=count+1;pushed=pushed+1;
                end
                if(dut.push && dut.pop) simultaneous=simultaneous+1;
            end
        end
    end
    task cycles(input integer n);repeat(n) @(negedge clk);endtask
    task send_byte(input [7:0] v);
        begin byte_data=v;byte_valid=1;cycles(1);byte_valid=0;cycles(1);end
    endtask
    task command(input [7:0] cmd,input [31:0] stamp,input [6:0] nn,vv,input [3:0] ch);
        reg [7:0] checksum;
        begin
            checksum=cmd^stamp[7:0]^stamp[15:8]^stamp[23:16]^stamp[31:24]^{1'b0,nn}^{1'b0,vv}^{4'd0,ch};
            send_byte(8'ha5);send_byte(cmd);
            send_byte(stamp[7:0]);send_byte(stamp[15:8]);send_byte(stamp[23:16]);send_byte(stamp[31:24]);
            send_byte({1'b0,nn});send_byte({1'b0,vv});send_byte({4'd0,ch});send_byte(0);send_byte(checksum);
        end
    endtask
    task stop;begin command(8'h22,0,0,0,0);cycles(4);end endtask
    task play;begin command(8'h20,0,0,0,0);cycles(4);end endtask
    task drain;
        integer limit;
        begin
            tick=1;limit=0;
            while(count!=0 && limit<300) begin cycles(1);limit=limit+1;end
            cycles(5);tick=0;
            if(count!=0) $fatal(1,"queue did not drain");
        end
    endtask
    integer i,before_push,before_pop;
    initial begin
        cycles(5);rst_n=1;cycles(4);
        // Full FIFO and rejected 65th event, then advance read pointer through wrap.
        for(i=0;i<64;i=i+1) command(8'h11,0,32+i,1+i,i%16);
        if(count!=64) $fatal(1,"full depth not exercised");
        before_push=pushed;command(8'h11,0,100,127,0);
        if(pushed!=before_push) $fatal(1,"full queue event accepted");
        play;drain;
        for(i=0;i<64;i=i+1) command(8'h11,0,95-i,127-i,i%16);
        drain;
        // Keep a backlog so accepted push/pop can occur on the same edge.
        stop;
        for(i=0;i<8;i=i+1) command(8'h11,0,50+i,80,i%16);
        play;
        fork
            begin for(i=0;i<180;i=i+1) command(8'h11,0,40+i%70,1+i%127,i%16);end
            begin cycles(20);repeat(180) begin tick=1;cycles(1);tick=0;cycles(21);end end
        join
        drain;
        if(simultaneous==0) $fatal(1,"simultaneous enqueue/dequeue not exercised");
        // Flush non-empty, immediately reuse address zero, and never emit old payload.
        stop;command(8'h11,0,12,99,2);cycles(2);stop;
        before_pop=popped;play;tick=1;cycles(10);tick=0;
        if(popped!=before_pop) $fatal(1,"flush leaked an old event");
        command(8'h11,0,87,55,3);drain;
        // Out-of-order timestamp rejected. RAM does not need to be reset.
        stop;command(8'h11,100,61,90,1);
        before_push=pushed;command(8'h11,99,62,91,1);
        if(pushed!=before_push) $fatal(1,"out-of-order event accepted");
        cycles(2);rst_n=0;cycles(2);rst_n=1;cycles(4);
        before_pop=popped;play;tick=1;cycles(10);tick=0;
        if(popped!=before_pop || count!=0) $fatal(1,"reset leaked an old event");
        command(8'h11,0,101,127,15);drain;
        $display("PASS tb_midi_queue_bsram depth64, wrap, full, empty, ordered payloads, simultaneous=%0d reset/flush=%0d pushed=%0d popped=%0d",simultaneous,flushes,pushed,popped);
        $finish;
    end
    initial begin #10000000;$fatal(1,"queue regression timeout");end
endmodule
