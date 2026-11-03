`timescale 1ns/1ps
// Real board wrappers, physical 8N1 Wi-Fi and screen RX. Only screen baud
// negotiation is bypassed; all command parsing, pending selection and guide
// transport/player/loader logic below it is production RTL.
module tb_four_slot_native_top;
    localparam integer WIFI_CPB=8,SCREEN_CPB=54;
    reg clk=0,rst_n=0,wifi_rx=1,screen_rx=1;
    always #10 clk=~clk;
    wire wifi_tx;
    wire usb_dp,usb_dm;
    mega60k_tjc_wifi_top #(.ENABLE_USB_HOST(0),.STARTUP_CYCLES(8),
        .WIFI_UART_CLKS_PER_BIT(WIFI_CPB),.UI_SCREEN_FAST(1)) dut(
        .sys_clk(clk),.rst_n(rst_n),.key0_n(1'b1),.key1_n(1'b1),.uart_rx(1'b1),
        .usb_dp(usb_dp),.usb_dm(usb_dm),.screen_rx(screen_rx),.wifi_rx(wifi_rx),.wifi_tx(wifi_tx));
    reg [7:0] captured_frames [0:1819];
    reg distinct_titles_loaded=0;
    reg [7:0] ack[0:19],serial_byte;
    integer bit_index,ack_index=0,ack_count=0,commit_count=0,accepted_count=0,rejected_count=0;
    integer ack_fd,selection_fd;
    always @(negedge wifi_tx)if(rst_n)begin
        repeat(WIFI_CPB+WIFI_CPB/2)@(negedge clk);
        for(bit_index=0;bit_index<8;bit_index=bit_index+1)begin
            serial_byte[bit_index]=wifi_tx;repeat(WIFI_CPB)@(negedge clk);
        end
        if(wifi_tx!==1)$fatal(1,"Wi-Fi ACK stop bit");
        ack[ack_index]=serial_byte;$fwrite(ack_fd,"%02x",serial_byte);
        if(ack_index==19)begin ack_index=0;ack_count=ack_count+1;$fwrite(ack_fd,"\n");end
        else ack_index=ack_index+1;
    end
    always @(negedge clk)if(dut.audio.core_reset_n)begin
        if(dut.audio.wifi_committed)commit_count=commit_count+1;
        if(dut.audio.wifi_select_accepted)accepted_count=accepted_count+1;
        if(dut.audio.wifi_select_rejected)rejected_count=rejected_count+1;
        if(dut.audio.wifi_select_pending || dut.audio.wifi_select_accepted || dut.audio.wifi_select_rejected)
            $fwrite(selection_fd,"%0t pending=%0b ready=%0b playing=%0b paused=%0b active=%0d accepted=%0b rejected=%0b\n",
                $time,dut.audio.wifi_select_pending,dut.audio.wifi_select_ready,dut.audio.guide_playing,
                dut.audio.guide_paused,dut.audio.wifi_active_slot,dut.audio.wifi_select_accepted,dut.audio.wifi_select_rejected);
        if((dut.audio.wifi_select_accepted || dut.audio.wifi_select_rejected) && dut.audio.guide_playing)
            $fatal(1,"local selection accepted while guide playing");
    end
    function [15:0] crc_byte(input [15:0] previous,input [7:0] value);
        reg [15:0] c;integer k;
        begin
            c=previous^{8'd0,value};
            for(k=0;k<8;k=k+1)c=c[0]?(c>>1)^16'ha001:c>>1;
            crc_byte=c;
        end
    endfunction
    function [15:0] crc16_body(input [127:0] body);
        reg [15:0] c;integer i;
        begin
            c=16'hffff;
            for(i=0;i<16;i=i+1)c=crc_byte(c,body[i*8+:8]);
            crc16_body=c;
        end
    endfunction
    task wifi_byte(input [7:0] value);
        integer b;
        begin
            @(negedge clk);wifi_rx=0;repeat(WIFI_CPB)@(negedge clk);
            for(b=0;b<8;b=b+1)begin wifi_rx=value[b];repeat(WIFI_CPB)@(negedge clk);end
            wifi_rx=1;repeat(WIFI_CPB)@(negedge clk);
        end
    endtask
    task screen_byte(input [7:0] value);
        integer b;
        begin
            @(negedge clk);screen_rx=0;repeat(SCREEN_CPB)@(negedge clk);
            for(b=0;b<8;b=b+1)begin screen_rx=value[b];repeat(SCREEN_CPB)@(negedge clk);end
            screen_rx=1;repeat(SCREEN_CPB)@(negedge clk);
        end
    endtask
    task screen_command(input [7:0] id,input [31:0] value);
        reg [63:0] bytes;reg [15:0] c;integer i;
        begin
            bytes={value,id,8'd2,8'h5a,8'ha6};c=16'hffff;
            for(i=0;i<8;i=i+1)c=crc_byte(c,bytes[i*8+:8]);
            for(i=0;i<8;i=i+1)screen_byte(bytes[i*8+:8]);
            screen_byte(c[7:0]);screen_byte(c[15:8]);screen_byte(8'h7e);
            repeat(30)@(negedge clk);
        end
    endtask
    task await_ack(input integer target,input [7:0] opcode,input [15:0] sequence_id);
        integer timeout,i;reg [127:0] body;
        begin
            timeout=0;
            while(ack_count<target && timeout<10000)begin @(negedge clk);timeout=timeout+1;end
            if(ack_count!=target)$fatal(1,"ACK timeout target%0d got%0d",target,ack_count);
            for(i=0;i<16;i=i+1)body[i*8+:8]=ack[i+2];
            if(ack[0]!==8'hc7 || ack[1]!==8'h3a || body[31:0]!=={sequence_id,(opcode|8'h80),8'd1} ||
               body[39:32]!==0 || {ack[19],ack[18]}!==crc16_body(body))$fatal(1,"ACK status/identity/CRC seq%0d",sequence_id);
            repeat(3)@(negedge clk);
        end
    endtask
    function [191:0] slot_title(input integer slot);
        begin
            case(slot)
                1:slot_title=192'h6168706c41;
                2:slot_title=192'hfecfbab4;
                3:slot_title=192'h616d6d6147;
                default:slot_title=192'h61746c6544;
            endcase
        end
    endfunction
    function [4:0] slot_title_len(input integer slot);
        begin slot_title_len=slot==2?5'd4:5'd5;end
    endfunction
    task assert_active(input integer slot);
        begin
            if(!dut.audio.wifi_active_present || dut.audio.wifi_active_slot!==slot ||
               dut.audio.wifi_active_title!==(distinct_titles_loaded && slot!=0?slot_title(slot):192'h41) ||
               dut.audio.wifi_active_title_len!==(distinct_titles_loaded && slot!=0?slot_title_len(slot):5'd1) ||
               dut.audio.wifi_active_part!==2 || dut.audio.wifi_active_parts!==9 ||
               dut.audio.wifi_active_bpm!==120 || dut.audio.wifi_active_base!==48)
                $fatal(1,"board-wrapper active metadata slot want%0d got%0d",slot,dut.audio.wifi_active_slot);
            if(dut.audio.screen.active_slot!==slot ||
               dut.audio.screen.resident_valid!==dut.audio.wifi_resident_valid ||
               dut.audio.screen.resident_titles!==dut.audio.wifi_resident_titles ||
               dut.audio.screen.resident_title_lens!==dut.audio.wifi_resident_title_lens ||
               dut.audio.screen.guide_beat_index!==dut.audio.guide_beat_index ||
               dut.audio.screen.snapshot.resident_valid!==dut.audio.wifi_resident_valid ||
               dut.audio.screen.snapshot.active_slot!==slot ||
               dut.audio.screen.snapshot.guide_beat_index!==dut.audio.guide_beat_index ||
               dut.audio.screen.score_metadata.metadata.resident_titles!==dut.audio.wifi_resident_titles ||
               dut.audio.screen.score_metadata.metadata.resident_title_lens!==dut.audio.wifi_resident_title_lens)
                $fatal(1,"native catalog/snapshot/metadata panel port mapping");
        end
    endtask
    task await_playing;
        integer timeout;
        begin
            timeout=0;
            while((!dut.audio.guide_playing || dut.audio.visual.expected_keys!==1) && timeout<2000)begin
                @(negedge clk);timeout=timeout+1;
            end
            if(timeout==2000)$fatal(1,"FPGA guide did not start score");
        end
    endtask
    reg [159:0] query_frame;
    reg [127:0] query_body;
    reg [15:0] query_crc;
    integer frame,i,target,expected_slot,old_accepts,old_rejects,old_commits;
    initial begin
        $readmemh("s3_resident_frames.hex",captured_frames);
        ack_fd=$fopen("native_top_acks.hex","w");selection_fd=$fopen("native_top_selection.txt","w");
        // Native screen protocol is tested after successful link negotiation.
        // The link manager itself has separate UART negotiation regressions.
        force dut.audio.screen.link_online=1'b1;
        force dut.audio.screen.link_allow_new=1'b1;
        repeat(5)@(negedge clk);rst_n=1;
        wait(dut.audio.core_reset_n);wait(dut.audio.ready);repeat(5)@(negedge clk);
        for(frame=0;frame<63;frame=frame+1)begin
            target=ack_count+1;
            for(i=0;i<20;i=i+1)wifi_byte(captured_frames[frame*20+i]);
            await_ack(target,captured_frames[frame*20+3],{captured_frames[frame*20+5],captured_frames[frame*20+4]});
            if(frame%7==6)begin
                expected_slot=(frame/7)%2==1?(frame/7+1)/2:0;
                assert_active(expected_slot);
            end
        end
        if(commit_count!=5 || dut.audio.wifi_resident_valid!==15)$fatal(1,"captured transaction activation/catalog");
        // The original C capture uses title A throughout. Four additional
        // store-only uploads derived from that format make vector-order errors
        // observable across the entire loader -> board -> panel chain.
        for(frame=63;frame<91;frame=frame+1)begin
            target=ack_count+1;
            for(i=0;i<20;i=i+1)wifi_byte(captured_frames[frame*20+i]);
            await_ack(target,captured_frames[frame*20+3],{captured_frames[frame*20+5],captured_frames[frame*20+4]});
            assert_active(0);
        end
        distinct_titles_loaded=1;
        for(i=0;i<4;i=i+1)
            if(dut.audio.wifi_resident_titles[i*192+:192]!==slot_title(i+1) ||
               dut.audio.wifi_resident_title_lens[i*5+:5]!==slot_title_len(i+1))
                $fatal(1,"resident wrapper title slot%0d",i);
        assert_active(0);
        if(commit_count!=5)$fatal(1,"distinct title store-only changed active score");
        // Source remains entirely FPGA resident after the last UART frame.
        screen_command(0,0);await_playing();
        // Start a valid query but leave it incomplete, holding loader ready low.
        query_body={64'd0,32'd0,16'd62000,8'd10,8'd1};query_crc=crc16_body(query_body);
        query_frame={query_crc,query_body,16'h3ac7};target=ack_count+1;
        for(i=0;i<5;i=i+1)wifi_byte(query_frame[i*8+:8]);
        old_accepts=accepted_count;
        screen_command(6,2);
        if(dut.audio.guide_playing || !dut.audio.wifi_select_pending || dut.audio.wifi_select_ready ||
           dut.audio.wifi_active_slot!==0 || accepted_count!=old_accepts)
            $fatal(1,"screen select did not stop and wait for RX idle");
        repeat(50)@(negedge clk);
        if(!dut.audio.wifi_select_pending)$fatal(1,"pending selection lost while loader not ready");
        for(i=5;i<20;i=i+1)wifi_byte(query_frame[i*8+:8]);
        await_ack(target,10,62000);repeat(20)@(negedge clk);
        if(dut.audio.wifi_select_pending || accepted_count!=old_accepts+1)$fatal(1,"pending selection did not complete once");
        assert_active(3);
        screen_command(0,0);await_playing();screen_command(2,0);
        if(!dut.audio.guide_playing || !dut.audio.guide_paused)$fatal(1,"screen pause setup");
        screen_command(6,3);assert_active(4);
        if(dut.audio.guide_playing || dut.audio.guide_paused)$fatal(1,"slot change did not stop paused guide");
        // Fifth screen slot is rejected before it reaches board selection logic.
        screen_command(0,0);await_playing();old_accepts=accepted_count;old_rejects=rejected_count;
        screen_command(6,4);assert_active(4);
        if(!dut.audio.guide_playing || accepted_count!=old_accepts || rejected_count!=old_rejects)
            $fatal(1,"out-of-range screen selection changed guide/source");
        // A valid index for an empty resident slot stops playback and rejects
        // selection without changing the existing active RAM score.
        query_body={64'd0,32'd1,16'd62001,8'd11,8'd1};query_crc=crc16_body(query_body);
        query_frame={query_crc,query_body,16'h3ac7};target=ack_count+1;
        for(i=0;i<20;i=i+1)wifi_byte(query_frame[i*8+:8]);
        await_ack(target,11,62001);old_commits=commit_count;
        screen_command(6,1);assert_active(4);
        if(dut.audio.guide_playing || dut.audio.wifi_select_pending || rejected_count!=old_rejects+1 || commit_count!=old_commits)
            $fatal(1,"empty resident selection did not stop/reject cleanly");
        screen_command(0,0);await_playing();
        if(dut.audio.wifi_resident_valid!==13)$fatal(1,"clear slot catalog mapping");
        $fclose(ack_fd);$fclose(selection_fd);
        $display("PASS four_slot_native_top:63 captured C frames+28 distinct-title frames,sequence wrap,FPGA guide,screen stop/paused/ready/invalid/empty selection");
        $finish;
    end
    initial begin #30000000;$fatal(1,"native top timeout");end
endmodule
