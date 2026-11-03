`timescale 1ns/1ps
module tb_ui_ws2812_strip;
    localparam integer PIXELS=3, CELL=64, ZHI=16, OHI=32, RESET=17500;
    reg clk=0, rst_n=0, start=0;
    reg [71:0] frame=0;
    wire data_out,busy,done;
    integer frames_checked=0;
    always #10 clk=~clk;
    ws2812_strip #(.PIXELS(PIXELS),.BIT_CYCLES(CELL),.ZERO_HIGH(ZHI),
        .ONE_HIGH(OHI),.RESET_CYCLES(RESET)) dut (
        .clk(clk),.rst_n(rst_n),.start(start),.frame_grb(frame),
        .data_out(data_out),.busy(busy),.done(done));

    task tick;
        begin @(posedge clk); #1; end
    endtask
    task check_startup;
        integer c;
        begin
            for(c=1;c<=RESET;c=c+1) begin
                tick;
                if(data_out!==0 || done!==0) $fatal(1,"startup emitted output/done");
                if(busy!==(c<RESET)) $fatal(1,"startup reset duration cycle %0d",c);
            end
            @(negedge clk); start=0;
            tick;
            if(busy!==0 || data_out!==0) $fatal(1,"startup request was incorrectly queued");
        end
    endtask
    task check_frame(input [71:0] expected);
        integer p,b,c,high_cycles;
        reg value;
        begin
            @(negedge clk); frame=expected; start=1;
            tick;
            if(busy!==1 || done!==0 || data_out!==1) $fatal(1,"frame start");
            // Every source bit is subsequently corrupted. A second request is
            // deliberately raised during SEND and must not disturb/queue a frame.
            @(negedge clk); start=0; frame=~expected;
            for(p=0;p<PIXELS;p=p+1) begin
                for(b=23;b>=0;b=b-1) begin
                    value=expected[p*24+b];
                    high_cycles=value ? OHI : ZHI;
                    // At entry the bit's first high cycle has already begun.
                    if(data_out!==1) $fatal(1,"missing bit start p%0d b%0d",p,b);
                    for(c=1;c<=CELL;c=c+1) begin
                        tick;
                        if(busy!==1 || done!==0) $fatal(1,"premature end p%0d b%0d c%0d",p,b,c);
                        if(c<CELL) begin
                            if(data_out!==(c<high_cycles))
                                $fatal(1,"bit pulse mismatch p%0d b%0d c%0d expected%0d got%0d",p,b,c,c<high_cycles,data_out);
                        end else if(data_out!==!(p==PIXELS-1 && b==0))
                            $fatal(1,"cell boundary/last bit length p%0d b%0d",p,b);
                        @(negedge clk);
                        start=(p==1 && b==12 && c>=2 && c<=4);
                        frame=~frame;
                    end
                end
            end
            // Already at the falling edge after exactly CELL clocks of final bit.
            start=1; // Requests during final latch must also be ignored.
            for(c=1;c<=RESET;c=c+1) begin
                tick;
                if(data_out!==0) $fatal(1,"reset/latch not low");
                if(busy!==(c<RESET) || done!==(c==RESET))
                    $fatal(1,"latch duration/done c%0d busy%0d done%0d",c,busy,done);
                @(negedge clk); start=0;
            end
            repeat(3) begin
                tick;
                if(busy!==0 || done!==0 || data_out!==0) $fatal(1,"extra frame/done accepted");
            end
            frames_checked=frames_checked+1;
        end
    endtask

    initial begin
        // Force a real asynchronous edge, then offer a startup request.
        #1; rst_n=1; #1; rst_n=0; #3;
        if(data_out!==0 || busy!==1) $fatal(1,"async reset output");
        @(negedge clk); rst_n=1; start=1;
        check_startup;
        check_frame(72'h800001_5aa53c_012345);
        check_frame(72'h000000_000000_000000);
        check_frame(72'hffffff_ffffff_ffffff);

        @(negedge clk); start=1; frame=72'hfedcba_987654_3210ff;
        tick;
        @(negedge clk); start=0;
        repeat(82) tick;
        #3; rst_n=0; #1;
        if(data_out!==0 || busy!==1 || done!==0) $fatal(1,"mid-frame asynchronous reset failed");
        @(negedge clk); rst_n=1; start=1;
        check_startup;
        check_frame(72'h010203_040506_070809);
        $display("PASS tb_ui_ws2812_strip frames=%0d all bits/cells, atomic snapshot, startup/latch17500, busy reject, mid-frame reset",frames_checked);
        $finish;
    end
    initial begin #20000000; $fatal(1,"timeout"); end
endmodule
