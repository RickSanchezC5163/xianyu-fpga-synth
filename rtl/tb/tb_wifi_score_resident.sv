`timescale 1ns/1ps
module tb_wifi_score_resident;
    `include "resident_vectors.vh"
    reg clk=0,rst_n=0,rx_valid=0,tx_ready=0,guide_playing=0,read_req=0;
    reg [7:0] rx_byte=0,read_address=0;
    reg select_valid=0;
    reg [1:0] select_slot=0;
    wire [7:0] tx_byte,active_bpm;
    wire tx_valid,read_valid,active_valid,committed,select_ready,select_accepted,select_rejected;
    wire [63:0] read_event;
    wire [8:0] active_count;
    wire [6:0] active_base;
    wire [31:0] active_token;
    wire [191:0] active_title;
    wire [4:0] active_title_len;
    wire [9:0] active_part,active_parts;
    wire [3:0] resident_valid;
    wire [767:0] resident_titles;
    wire [19:0] resident_title_lens;
    wire [2:0] active_slot;
    wifi_score_loader #(.GAP_CYCLES(64)) dut(.*);
    always #10 clk=~clk;
    integer cycles=0,ack_count=0,ack_index=0,sequence_number=1,transactions=0;
    integer commit_count=0,accept_count=0,reject_count=0;
    reg [7:0] ack[0:19];
    reg held=0;
    reg [7:0] held_byte;
    reg [31:0] reply_arg;
    reg [63:0] reply_data;
    always @(negedge clk)begin
        cycles=cycles+1;tx_ready=cycles%7<3;
        if(committed)commit_count=commit_count+1;
        if(select_accepted)accept_count=accept_count+1;
        if(select_rejected)reject_count=reject_count+1;
    end
    always @(posedge clk)if(rst_n)begin
        if(held && (!tx_valid || tx_byte!==held_byte))$fatal(1,"TX backpressure");
        held=tx_valid && !tx_ready;held_byte=tx_byte;
        if(tx_valid && tx_ready)begin
            ack[ack_index]=tx_byte;
            if(ack_index==19)begin ack_count=ack_count+1;ack_index=0;end
            else ack_index=ack_index+1;
        end
    end
    function [15:0] crc16(input [127:0] bytes);
        reg [15:0] c;integer i,j;
        begin
            c=16'hffff;
            for(i=0;i<16;i=i+1)begin
                c=c^{8'd0,bytes[i*8+:8]};
                for(j=0;j<8;j=j+1)c=c[0]?(c>>1)^16'ha001:c>>1;
            end
            crc16=c;
        end
    endfunction
    function [63:0] event_word(input integer id,input integer index);
        reg [24:0] mask;reg [31:0] tick;
        begin
            tick=index*(12+id);mask=index==(1+(id%2))?0:(25'd1<<id);
            event_word={7'd0,mask,tick};
        end
    endfunction
    function [63:0] title_word(input integer id);
        begin title_word={16'd0,(8'd48+id),40'h45524f4353};end
    endfunction
    task send_byte(input [7:0] b);
        begin @(negedge clk);rx_valid=1;rx_byte=b;@(negedge clk);rx_valid=0;end
    endtask
    task exchange(input [7:0] op,input [31:0] arg,input [63:0] data,input [7:0] status,input corrupt);
        reg [127:0] body,response;
        reg [15:0] c;reg [7:0] b;
        integer i,target,timeout;
        begin
            body={data,arg,sequence_number[15:0],op,8'd1};c=crc16(body);
            if(corrupt)c=c^16'h0100;
            target=ack_count+1;
            for(i=0;i<20;i=i+1)begin
                b=i==0?8'hc7:i==1?8'h3a:i<18?(body>>((i-2)*8)):i==18?c[7:0]:c[15:8];
                send_byte(b);
            end
            timeout=0;
            while(ack_count<target && timeout<1000)begin @(negedge clk);timeout=timeout+1;end
            if(timeout==1000)$fatal(1,"reply timeout");
            for(i=0;i<16;i=i+1)response[i*8+:8]=ack[i+2];
            if(ack[0]!==8'hc7 || ack[1]!==8'h3a || {ack[19],ack[18]}!==crc16(response))$fatal(1,"reply CRC/frame");
            if(response[31:0]!=={sequence_number[15:0],(op|8'h80),8'd1})$fatal(1,"reply identity");
            reply_arg=response[63:32];reply_data=response[127:64];
            if(reply_arg[7:0]!==status)$fatal(1,"op%0d seq%0d status got%0d want%0d",op,sequence_number,reply_arg[7:0],status);
            transactions=transactions+1;sequence_number=sequence_number+1;
            repeat(2)@(negedge clk);
        end
    endtask
    task check_active(input integer id,input integer slot);
        begin
            if(!active_valid || active_token!==(32'h10000000+id) || active_count!==(2+id%2) ||
               active_bpm!==(60+id) || active_base!==(48+id) || active_title[63:0]!==title_word(id) ||
               active_title[191:64]!==0 || active_title_len!==6 || active_part!==(id+1) || active_parts!==20 || active_slot!==slot)
                $fatal(1,"active metadata id%0d slot%0d actual token%h slot%0d",id,slot,active_token,active_slot);
        end
    endtask
    task read_score(input integer id);
        integer n;
        begin
            for(n=0;n<2+id%2;n=n+1)begin
                @(negedge clk);read_req=1;read_address=n;
                @(negedge clk);if(!read_valid || read_event!==event_word(id,n))$fatal(1,"read id%0d index%0d got%h",id,n,read_event);
                read_req=0;@(negedge clk);if(read_valid)$fatal(1,"read_valid stretched");
            end
        end
    endtask
    task stage_score(input integer id,input integer slot,input store_only,input bad_crc);
        reg [31:0] arg;reg [63:0] meta;
        integer n;
        begin
            arg=32'h80000000 | ((48+id)<<24) | ((60+id)<<16) | (2+id%2);
            exchange(1,arg,{(32'h10000000+id),(score_crc(id)^(bad_crc?32'd1:32'd0))},0,0);
            meta=(64'd20<<47) | ((id+64'd1)<<37) | (64'd6<<32) | (32'h10000000+id) | (slot*64'h0200000000000000) | (store_only?64'h1000000000000000:64'd0);
            exchange(7,0,meta,0,0);exchange(7,1,title_word(id),0,0);
            for(n=0;n<2+id%2;n=n+1)exchange(2,n,event_word(id,n),0,0);
            exchange(3,0,32'h10000000+id,bad_crc?5:0,0);
        end
    endtask
    task commit_score(input integer id,input [7:0] status);
        begin exchange(4,0,32'h10000000+id,status,0);end
    endtask
    task select_score(input integer slot,input valid_slot);
        integer old_count;
        begin
            old_count=commit_count;
            @(negedge clk);if(!select_ready)$fatal(1,"selection not ready");select_slot=slot;select_valid=1;
            read_req=1;read_address=0;
            @(negedge clk);
            if(select_accepted!==valid_slot || select_rejected===valid_slot)$fatal(1,"selection pulse");
            if(valid_slot && read_valid)$fatal(1,"selection did not suppress read");
            select_valid=0;read_req=0;
            repeat(2)@(negedge clk);
            if(commit_count!=old_count+valid_slot)$fatal(1,"selection commit pulse");
            if(select_accepted || select_rejected)$fatal(1,"selection pulse stretched");
        end
    endtask
    task query_slot(input integer slot,input valid_slot,input integer id);
        begin
            exchange(10,slot,0,0,0);
            if(reply_arg!==((valid_slot?32'd1:32'd0)<<8) || reply_data!==(valid_slot?{(32'h10000000+id),score_crc(id)}:64'd0))
                $fatal(1,"slot%0d query arg%h data%h",slot,reply_arg,reply_data);
        end
    endtask
    integer n,old_commits;
    reg [63:0] meta;
    initial begin
        repeat(5)@(negedge clk);rst_n=1;
        exchange(10,0,0,0,0);if(reply_arg!==0 || reply_data!==0)$fatal(1,"empty catalog");
        select_score(0,0);if(active_valid)$fatal(1,"invalid selection changed active");
        // Named temporary legacy active plus four resident slots occupy five banks.
        stage_score(0,0,0,0);commit_score(0,0);check_active(0,0);
        old_commits=commit_count;
        guide_playing=1;
        for(n=1;n<=4;n=n+1)begin
            stage_score(n,n,1,0);commit_score(n,0);check_active(0,0);read_score(0);
        end
        if(commit_count!=old_commits || resident_valid!==4'hf)$fatal(1,"store-only activated score");
        // All five live banks are protected; a replacement must use bank six.
        stage_score(2,2,1,0);
        if(dut.staging_bank!==5)$fatal(1,"sixth free staging bank not allocated");
        query_slot(2,1,2);check_active(0,0);commit_score(2,0);read_score(0);
        if(select_ready)$fatal(1,"select ready during play");
        exchange(10,0,0,0,0);if(reply_arg!==32'hf00 || reply_data!==0)$fatal(1,"full catalog");
        for(n=1;n<=4;n=n+1)begin
            query_slot(n,1,n);
            if(resident_titles[(n-1)*192+:192]!=={128'd0,title_word(n)} || resident_title_lens[(n-1)*5+:5]!==6)$fatal(1,"resident title outputs");
        end
        guide_playing=0;
        for(n=1;n<=4;n=n+1)begin
            select_score(n-1,1);check_active(n,n);read_score(n);
            exchange(8,0,0,0,0);if(reply_data[63:60]!==n || reply_data[31:0]!==32'h10000000+n)$fatal(1,"INFO slot");
        end
        // Active slot replacement is BUSY during play, with retry accepted after stop.
        guide_playing=1;stage_score(5,4,1,0);commit_score(5,6);check_active(4,4);
        guide_playing=0;commit_score(5,0);check_active(4,0);read_score(4);query_slot(4,1,5);
        select_score(3,1);check_active(5,4);read_score(5);
        // Staged bad CRC, corrupt frame, and invalid reserved metadata cannot touch slots.
        stage_score(6,2,1,1);commit_score(6,2);query_slot(2,1,2);check_active(5,4);
        exchange(5,0,32'h10000006,0,0);
        exchange(11,1,0,1,1);if(reply_arg!==1 || reply_data!==0)$fatal(1,"bad-frame clear shape");query_slot(2,1,2);
        exchange(1,32'hb03c0002,{32'h10000000,score_crc(0)},0,0);
        meta=(64'd20<<47)|(64'd1<<37)|(64'd6<<32)|32'h10000000;
        exchange(7,0,meta|64'h2000000000000000,3,0);
        exchange(7,0,meta|64'h0a00000000000000,3,0);
        exchange(7,0,meta|64'h1000000000000000,3,0);
        exchange(10,0,1,3,0);exchange(10,5,0,3,0);
        exchange(11,4,0,3,0);if(reply_arg!==3 || reply_data!==0)$fatal(1,"clear invalid shape");
        exchange(11,0,1,3,0);if(reply_arg!==3 || reply_data!==0)$fatal(1,"clear reserved shape");
        exchange(5,0,32'h10000000,0,0);
        // CLEAR active detaches the source but preserves RAM, title, and playback.
        guide_playing=1;exchange(11,3,0,0,0);if(reply_arg!==0 || reply_data!==0)$fatal(1,"clear shape");
        check_active(5,0);read_score(5);query_slot(4,0,0);
        if(resident_valid!==4'h7 || resident_titles[767:576]!==0 || resident_title_lens[19:15]!==0)$fatal(1,"clear metadata");
        guide_playing=0;select_score(3,0);check_active(5,0);
        // Reuse freed and previous active banks repeatedly, retaining all residents.
        for(n=7;n<15;n=n+1)begin
            stage_score(n,0,0,0);commit_score(n,0);check_active(n,0);read_score(n);
            query_slot(1,1,1);query_slot(2,1,2);query_slot(3,1,3);
        end
        stage_score(4,4,0,0);commit_score(4,0);check_active(4,4);
        // Cached COMMIT retry produces no second pulse or bank change.
        old_commits=commit_count;sequence_number=sequence_number-1;commit_score(4,0);
        if(commit_count!=old_commits)$fatal(1,"retry commit pulse");
        query_slot(4,1,4);
        // Partial RX and an incoming byte hold off local selection.
        send_byte(8'hc7);if(select_ready)$fatal(1,"selection ready during partial frame");
        repeat(70)@(negedge clk);if(!select_ready)$fatal(1,"gap did not free selection");
        select_score(0,1);check_active(1,1);read_score(1);
        @(negedge clk);rst_n=0;repeat(3)@(negedge clk);rst_n=1;
        if(active_valid || active_slot!==0 || resident_valid!==0 || resident_titles!==0 || resident_title_lens!==0)$fatal(1,"reset metadata");
        $display("PASS wifi_score_resident transactions=%0d commits=%0d accepts=%0d rejects=%0d",transactions,commit_count,accept_count,reject_count);
        $finish;
    end
    initial begin #20000000;$fatal(1,"resident test timeout");end
endmodule
