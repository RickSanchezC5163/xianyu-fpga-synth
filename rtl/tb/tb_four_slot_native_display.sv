`timescale 1ns/1ps
// Native producers under byte backpressure; decoded output is independently
// checked by run_four_slot_native_tests.py, including every navigation cut.
module tb_four_slot_native_display;
    reg clk=0,rst_n=0;
    always #10 clk=~clk;
    integer cycle=0;
    always @(posedge clk)cycle<=cycle+1;
    wire ready=cycle%7!=1 && cycle%7!=4 && cycle%7!=5;
    reg snapshot_request=0,metadata_request=0;
    reg [1:0] patch=3;
    reg [7:0] volume=255,bpm=120;
    reg [27:0] adsr={7'd127,7'd91,7'd72,7'd36};
    reg link_ready=1,playing=1,paused=0,looping=1;
    reg [2:0] result=1,active_slot=4;
    reg [3:0] resident_valid=15;
    reg [1:0] beat=3;
    wire snapshot_busy,snapshot_valid;
    wire [7:0] snapshot_data;
    tjc_snapshot_tx #(.NATIVE_SLOTS_ENABLE(1)) snapshot(
        .clk(clk),.rst_n(rst_n),.request(snapshot_request),.patch(patch),.volume(volume),.adsr(adsr),
        .link_ready(link_ready),.result(result),.guide_playing(playing),.guide_paused(paused),
        .guide_loop(looping),.guide_bpm(bpm),.busy(snapshot_busy),.byte_valid(snapshot_valid),
        .byte_data(snapshot_data),.byte_ready(ready),.page_id(3'd0),
        .resident_valid(resident_valid),.active_slot(active_slot),.guide_beat_index(beat));
    reg [2:0] page=5;
    reg [767:0] titles=0;
    reg [19:0] lengths=0;
    reg context_ready=1;
    wire metadata_busy,metadata_valid;
    wire [7:0] metadata_data;
    tjc_score_meta_tx #(.NATIVE_SLOTS_ENABLE(1)) metadata(
        .clk(clk),.rst_n(rst_n),.request(metadata_request),.page_id(page),.active_present(1'b1),
        .title(192'h41),.title_len(5'd1),.part(10'd2),.parts(10'd9),.bpm(bpm),
        .playing(playing),.paused(paused),.context_ready(context_ready),
        .busy(metadata_busy),.byte_valid(metadata_valid),.byte_data(metadata_data),.byte_ready(ready),
        .resident_valid(resident_valid),.resident_titles(titles),.resident_title_lens(lengths));
    integer snapshot_fd,metadata_fd,snapshot_bytes=0,metadata_bytes=0,case_id=0,cut=-1;
    reg snapshot_held=0,metadata_held=0;
    reg [7:0] previous_snapshot,previous_metadata;
    always @(posedge clk)if(rst_n)begin
        if(snapshot_held && (!snapshot_valid || snapshot_data!==previous_snapshot))$fatal(1,"snapshot changed during backpressure");
        if(metadata_held && (!metadata_valid || metadata_data!==previous_metadata))$fatal(1,"metadata changed during backpressure");
        snapshot_held=snapshot_valid&&!ready;previous_snapshot=snapshot_data;
        metadata_held=metadata_valid&&!ready;previous_metadata=metadata_data;
        if(snapshot_valid && ready)begin
            $fwrite(snapshot_fd,"%02x",snapshot_data);snapshot_bytes=snapshot_bytes+1;
        end
        if(metadata_valid && ready)begin
            $fwrite(metadata_fd,"%0d %0d %02x\n",case_id,cut,metadata_data);metadata_bytes=metadata_bytes+1;
        end
    end
    task defaults;
        begin
            titles=0;
            titles[0+:192]=192'h6168706c41; // Alpha
            titles[192+:192]=192'hfecfbab4; // GB2312: 春晓
            // 19 ASCII bytes plus a double-byte character: limit20 must stop at19.
            titles[384+:192]=192'hb4ba535251504f4e4d4c4b4a494847464544434241;
            titles[576+:192]=192'h61746c6544; // Delta
            lengths={5'd5,5'd21,5'd4,5'd5};
            resident_valid=15;context_ready=1;page=5;
        end
    endtask
    task metadata_case(input integer which,input integer limit);
        integer timeout;
        begin
            defaults();case_id=which;cut=limit;metadata_bytes=0;
            if(which==1)resident_valid=7;
            if(which==2)context_ready=0;
            @(negedge clk);metadata_request=1;
            @(negedge clk);metadata_request=0;
            timeout=0;
            while(metadata_busy && timeout<20000)begin
                @(negedge clk);timeout=timeout+1;
                if(limit==0 || (limit>0 && metadata_bytes>=limit))page=0;
                if(which==4 && metadata_bytes>=36)begin
                    titles={4{192'h5a5a}};lengths={4{5'd2}};
                end
            end
            if(metadata_busy)$fatal(1,"metadata timeout");
            $fwrite(metadata_fd,"END %0d %0d %0d\n",which,limit,metadata_bytes);
            repeat(2)@(negedge clk);
        end
    endtask
    integer n;
    initial begin
        snapshot_fd=$fopen("native_snapshot.hex","w");metadata_fd=$fopen("native_metadata.txt","w");
        repeat(3)@(negedge clk);rst_n=1;
        @(negedge clk);snapshot_request=1;
        @(negedge clk);snapshot_request=0;
        wait(snapshot_bytes>=4);
        @(negedge clk);
        patch=0;volume=1;adsr=0;link_ready=0;result=2;playing=0;paused=1;looping=0;bpm=240;
        resident_valid=2;active_slot=2;beat=1;
        // A busy request must not replace any member of the captured snapshot.
        snapshot_request=1;@(negedge clk);snapshot_request=0;
        wait(!snapshot_busy);repeat(2)@(negedge clk);
        snapshot_request=1;@(negedge clk);snapshot_request=0;
        wait(snapshot_busy);wait(!snapshot_busy);repeat(2)@(negedge clk);
        metadata_case(0,-1);metadata_case(1,-1);metadata_case(2,-1);metadata_case(4,-1);
        for(n=0;n<=190;n=n+1)metadata_case(3,n);
        page=0;metadata_request=1;@(negedge clk);metadata_request=0;repeat(50)@(negedge clk);
        if(metadata_busy || metadata_valid)$fatal(1,"metadata emitted on unrelated page");
        $fclose(snapshot_fd);$fclose(metadata_fd);
        $display("PASS four_slot_native_display: two atomic snapshots, native rows,191 navigation cuts,backpressure");
        $finish;
    end
    initial begin #30000000;$fatal(1,"native display timeout");end
endmodule
