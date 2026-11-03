`timescale 1ns/1ps
module tb_wifi_score_loader;
    `include "loader_vectors.vh"
    reg clk=0,rst_n=0,rx_valid=0,tx_ready=0,guide_playing=0,read_req=0;
    reg [7:0] rx_byte=0,read_address=0;
    wire [7:0] tx_byte;
    wire tx_valid,read_valid,active_valid;
    wire [63:0] read_event;
    wire [8:0] active_count;
    wire [7:0] active_bpm;
    wire [6:0] active_base;
    wire [31:0] active_token;
    wire committed;
    wire [191:0] active_title;
    wire [4:0] active_title_len;
    wire [9:0] active_part,active_parts;
    reg select_valid=0;reg [1:0] select_slot=0;
    wire select_ready,select_accepted,select_rejected;
    wire [3:0] resident_valid;wire [767:0] resident_titles;
    wire [19:0] resident_title_lens;wire [2:0] active_slot;
    wifi_score_loader #(.GAP_CYCLES(64)) dut(.*);
    always #10 clk=~clk;
    integer cycle=0,ack_position=0,ack_count=0,transactions=0;
    integer req_file,ack_file;
    reg stalls=1;
    reg held_tx=0;
    reg [7:0] held_byte;
    reg [7:0] ack[0:19];
    always @(negedge clk) begin
        cycle=cycle+1;
        tx_ready=(!stalls || cycle%7<3);
    end
    always @(posedge clk) begin
        if(!rst_n)begin held_tx=0;ack_position=0;end
        else begin
            if(held_tx && (!tx_valid || tx_byte!==held_byte))$fatal(1,"TX changed under backpressure");
            held_tx=tx_valid && !tx_ready;held_byte=tx_byte;
            if(tx_valid && tx_ready)begin
                ack[ack_position]=tx_byte;
                $fwrite(ack_file,"%02x",tx_byte);
                if(ack_position==19)begin ack_position=0;ack_count=ack_count+1;$fwrite(ack_file,"\n");end
                else ack_position=ack_position+1;
            end
        end
    end
    function [15:0] crc16;
        input [127:0] bytes;
        reg [15:0] c;reg [127:0] v;integer i,j;
        begin
            c=16'hffff;v=bytes;
            for(i=0;i<16;i=i+1)begin
                c=c^{8'd0,v[7:0]};v=v>>8;
                for(j=0;j<8;j=j+1)c=c[0]?(c>>1)^16'ha001:c>>1;
            end
            crc16=c;
        end
    endfunction
    function [63:0] event_word;
        input [31:0] tick;input [24:0] mask;
        begin event_word={7'd0,mask,tick};end
    endfunction
    task send_byte(input [7:0] value);
        begin
            @(negedge clk);rx_valid=1;rx_byte=value;
            @(negedge clk);rx_valid=0;
            repeat(2)@(negedge clk);
        end
    endtask
    task exchange;
        input [7:0] op;input [15:0] seq;input [31:0] arg;input [63:0] data;
        input [7:0] expected_status;input [15:0] expected_next;input [31:0] expected_token;
        input corrupt;input [7:0] version;
        reg [127:0] body,got_body;reg [15:0] crc,got_crc;
        integer i,target,timeout;
        reg [7:0] b;
        begin
            body={data,arg,seq,op,version};crc=crc16(body);
            if(corrupt)crc=crc^16'h0100;
            target=ack_count+1;
            for(i=0;i<20;i=i+1)begin
                b=i==0?8'hc7:i==1?8'h3a:i<18?(body>>((i-2)*8)):i==18?crc[7:0]:crc[15:8];
                $fwrite(req_file,"%02x",b);send_byte(b);
            end
            $fwrite(req_file,"\n");
            timeout=0;
            while(ack_count<target && timeout<1000)begin @(negedge clk);timeout=timeout+1;end
            if(timeout==1000)$fatal(1,"noACK forop%0d seq%0d",op,seq);
            for(i=0;i<16;i=i+1)got_body[i*8+:8]=ack[i+2];
            got_crc={ack[19],ack[18]};
            if(ack[0]!==8'hc7 || ack[1]!==8'h3a || got_crc!==crc16(got_body))$fatal(1,"ACK framing/CRC failed");
            if(got_body[7:0]!==1 || got_body[15:8]!== (op|8'h80) || got_body[31:16]!==seq)
                $fatal(1,"ACK identity mismatch");
            if(got_body[39:32]!==expected_status || got_body[55:40]!==expected_next ||
               got_body[63:56]!==0 || got_body[95:64]!==expected_token || got_body[127:96]!==0)
                $fatal(1,"op%0d seq%0d status/next/token got%h expectedstatus%0d next%0d token%h",
                    op,seq,got_body,expected_status,expected_next,expected_token);
            transactions=transactions+1;
            repeat(2)@(negedge clk);
        end
    endtask
    task valid_read(input [7:0] address,input [63:0] expected);
        begin
            @(negedge clk);read_address=address;read_req=1;
            @(negedge clk);
            if(!read_valid || read_event!==expected)$fatal(1,"active RAMread%0d got%h expected%h valid%b",address,read_event,expected,read_valid);
            read_req=0;@(negedge clk);
            if(read_valid)$fatal(1,"read_valid not request qualified");
        end
    endtask
    task invalid_read(input [7:0] address);
        begin
            @(negedge clk);read_address=address;read_req=1;
            @(negedge clk);if(read_valid)$fatal(1,"invalid RAMread accepted");
            read_req=0;@(negedge clk);
        end
    endtask
    localparam [31:0] TOKEN_A=32'h12345678,TOKEN_B=32'habcd0011,TOKEN_C=32'h99887766;
    integer n,commit_suppressed=0;
    integer committed_count=0;
    reg [63:0] retained_bank0,retained_bank1;
    // This concurrent observer specifically checks the atomic bank-switch edge.
    always @(negedge clk)if(rst_n && read_req && active_token==TOKEN_B && !read_valid)commit_suppressed=commit_suppressed+1;
    always @(negedge clk)if(rst_n && committed)committed_count=committed_count+1;
    initial begin
        req_file=$fopen("loader_requests.hex","w");ack_file=$fopen("loader_acks.hex","w");
        repeat(5)@(negedge clk);rst_n=1;
        invalid_read(0);
        if(active_valid || active_count!=0)$fatal(1,"reset metadata valid");
        exchange(1,1,32'h30780001,{TOKEN_A,CRC_A},3,0,0,0,1);
        exchange(1,2,32'h30780101,{TOKEN_A,CRC_A},3,0,0,0,1);
        exchange(1,3,32'h68780003,{TOKEN_A,CRC_A},3,0,0,0,1);
        exchange(1,4,32'h301d0003,{TOKEN_A,CRC_A},3,0,0,0,1);
        // bit31 now requests metadata; an out-of-range count is still invalid.
        exchange(1,5,32'hb0780101,{TOKEN_A,CRC_A},3,0,0,0,1);
        exchange(1,6,32'h30f10003,{TOKEN_A,CRC_A},3,0,0,0,1);
        send_byte(8'hc7); // C7 C7 3A header must resynchronize.
        exchange(1,21,32'h30780003,{TOKEN_A,CRC_A},0,0,TOKEN_A,0,1);
        exchange(1,21,32'h30780003,{TOKEN_A,CRC_A},0,0,TOKEN_A,0,1);
        exchange(2,22,1,event_word(0,1),4,0,TOKEN_A,0,1);
        exchange(2,22,0,event_word(1,1),3,0,TOKEN_A,0,1);
        exchange(2,22,0,event_word(0,1),0,1,TOKEN_A,0,1);
        exchange(2,22,0,event_word(0,1),0,1,TOKEN_A,0,1);
        exchange(2,23,1,event_word(0,3),3,1,TOKEN_A,0,1);
        exchange(2,23,32'h00010001,event_word(96,3),4,1,TOKEN_A,0,1);
        exchange(2,23,1,64'h0200000300000060,3,1,TOKEN_A,0,1);
        exchange(2,23,1,event_word(96,3),0,2,TOKEN_A,0,1);
        exchange(2,24,2,event_word(192,1),3,2,TOKEN_A,0,1);
        exchange(2,24,2,event_word(96,0),3,2,TOKEN_A,0,1);
        exchange(2,24,2,event_word(192,0),0,3,TOKEN_A,0,1);
        exchange(3,25,0,{32'd0,TOKEN_B},3,3,TOKEN_A,0,1);
        exchange(3,25,0,{32'd0,TOKEN_A},0,3,TOKEN_A,0,1);
        exchange(3,25,0,{32'd0,TOKEN_A},0,3,TOKEN_A,0,1);
        guide_playing=1;
        exchange(4,26,0,{32'd0,TOKEN_A},6,3,TOKEN_A,0,1);
        if(active_valid)$fatal(1,"BUSY commit changed active bank");
        guide_playing=0;
        exchange(4,26,0,{32'd0,TOKEN_A},0,3,TOKEN_A,0,1);
        exchange(4,26,0,{32'd0,TOKEN_A},0,3,TOKEN_A,0,1);
        if(committed_count!=1)$fatal(1,"duplicate COMMIT produced morethan one pulse");
        if(!active_valid || active_count!=3 || active_bpm!=120 || active_base!=48 || active_token!=TOKEN_A)
            $fatal(1,"bankA metadata mismatch");
        valid_read(0,event_word(0,1));valid_read(1,event_word(96,3));valid_read(2,event_word(192,0));invalid_read(3);

        guide_playing=1;
        exchange(1,27,32'h3c5a0002,{TOKEN_B,CRC_B},0,0,TOKEN_B,0,1);
        exchange(2,28,0,event_word(0,4),0,1,TOKEN_B,0,1);
        valid_read(0,event_word(0,1));valid_read(1,event_word(96,3));
        exchange(2,29,1,event_word(48,0),0,2,TOKEN_B,0,1);
        valid_read(2,event_word(192,0));
        exchange(3,30,0,{32'd0,TOKEN_B},0,2,TOKEN_B,0,1);
        exchange(4,31,0,{32'd0,TOKEN_B},6,2,TOKEN_B,0,1);
        guide_playing=0;
        // Read constantly across commit: one old-bank request must be invalidated.
        @(negedge clk);read_req=1;read_address=0;
        exchange(4,31,0,{32'd0,TOKEN_B},0,2,TOKEN_B,0,1);
        read_req=0;
        if(commit_suppressed!=1)$fatal(1,"commit did not suppress exactlyone coincident read: %0d",commit_suppressed);
        if(active_count!=2 || active_bpm!=90 || active_base!=60 || active_token!=TOKEN_B)$fatal(1,"bankB metadata mismatch");
        valid_read(0,event_word(0,4));valid_read(1,event_word(48,0));invalid_read(2);
        exchange(6,31,0,0,3,2,TOKEN_B,0,1); // Same successful seq, changed body.
        exchange(6,32,0,0,1,2,TOKEN_B,1,1);
        exchange(6,32,0,0,1,2,TOKEN_B,0,2);
        exchange(6,32,0,0,0,0,TOKEN_B,0,1);
        send_byte(8'hc7);send_byte(8'h3a);send_byte(1);send_byte(6);
        repeat(80)@(negedge clk);
        exchange(6,33,0,0,0,0,TOKEN_B,0,1);
        exchange(1,34,32'h30780002,{TOKEN_C,32'd0},0,0,TOKEN_C,0,1);
        exchange(2,35,0,event_word(0,4),0,1,TOKEN_C,0,1);
        exchange(3,36,0,{32'd0,TOKEN_C},2,1,TOKEN_C,0,1);
        exchange(2,37,1,event_word(48,0),0,2,TOKEN_C,0,1);
        exchange(3,38,0,{32'd0,TOKEN_C},5,2,TOKEN_C,0,1);
        exchange(5,39,0,{32'd0,TOKEN_A},3,2,TOKEN_C,0,1);
        exchange(5,39,0,{32'd0,TOKEN_C},0,0,TOKEN_C,0,1);
        valid_read(0,event_word(0,4));
        exchange(1,40,32'h67f00100,{TOKEN_C,CRC_FULL},0,0,TOKEN_C,0,1);
        for(n=0;n<256;n=n+1)
            exchange(2,41+n,n,event_word(n*96,n==255?25'd0:(25'd1<<(n%25))),0,n+1,TOKEN_C,0,1);
        exchange(2,297,256,event_word(256*96,0),4,256,TOKEN_C,0,1);
        exchange(3,298,0,{32'd0,TOKEN_C},0,256,TOKEN_C,0,1);
        exchange(4,299,0,{32'd0,TOKEN_C},0,256,TOKEN_C,0,1);
        if(active_count!=256 || active_base!=103 || active_bpm!=240)$fatal(1,"full256 metadata truncated");
        valid_read(0,event_word(0,1));valid_read(254,event_word(254*96,25'd1<<(254%25)));valid_read(255,event_word(255*96,0));
        if(committed_count!=3)$fatal(1,"successful COMMIT pulse count mismatch");
        // Reset halfway through a frame invalidates active metadata without RAM clears.
        retained_bank0=dut.bank0[0];retained_bank1=dut.bank1[255];
        send_byte(8'hc7);send_byte(8'h3a);send_byte(1);
        @(negedge clk);rst_n=0;repeat(3)@(negedge clk);rst_n=1;
        invalid_read(0);if(active_valid || active_count!=0)$fatal(1,"reset leaked old score");
        if(dut.bank0[0]!==retained_bank0 || dut.bank1[255]!==retained_bank1)$fatal(1,"reset cleared RAM contents");
        exchange(6,300,0,0,0,0,0,0,1);
        $display("PASS wifi_score_loader transactions=%0d full256=1 duplicate_ack=1 blocked_tx_stable=1 active_bank_preserved=1 commit_read_suppressed=1",transactions);
        $fclose(req_file);$fclose(ack_file);$finish;
    end
    initial begin #20000000;$fatal(1,"loader simulation timed out");end
endmodule
