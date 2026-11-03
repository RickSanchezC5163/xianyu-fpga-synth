`timescale 1ns/1ps
module tb_ui_ili9341;
    reg clk=0; always #10 clk=~clk;
    reg rst_n=0,grant=0;
    wire request,tx_start,cs_n,dc,lcd_reset_n,ready,pixel_ready;
    wire [7:0] tx_data; wire [15:0] tx_half_period;
    reg tx_busy=0,tx_done=0,pixel_valid=0;
    reg [8:0] pixel_x=0,pixel_y=0;
    reg [15:0] pixel_rgb565=0;
    ili9341_panel #(.RESET_LOW_CYCLES(3),.RESET_WAIT_CYCLES(5),
        .SLEEP_OUT_CYCLES(7)) dut(.*);
    integer cycle=0,count=0,sessions=0,busy_count=0,errors=0;
    integer sleep_cycle=-1,display_cycle=-1,reset_cycle=0,release_cycle=-1;
    integer reset_low_observed=0,first_start_cycle=-1,releases=0;
    reg prev_cs=1;
    reg [7:0] saved_data;
    reg saved_dc;
    reg [7:0] bytes[0:255],expected_data[0:53];
    reg flags[0:255],expected_dc[0:53];
    integer starts[0:63],lengths[0:63];
    task check;
        input condition; input [8*140-1:0] msg;
        begin if(!condition) begin $display("FAIL: %0s at cycle %0d",msg,cycle); errors=errors+1; end end
    endtask
    always @(posedge clk) begin
        cycle=cycle+1;
        tx_done<=0;
        if(!rst_n) begin
            tx_busy<=0; busy_count<=0; prev_cs<=1;
        end else begin
            if(!lcd_reset_n) begin
                reset_cycle=cycle;
                if(release_cycle<0) reset_low_observed=reset_low_observed+1;
            end
            if(lcd_reset_n && release_cycle<0) release_cycle=cycle;
            if(prev_cs && !cs_n) begin
                starts[sessions]=count; lengths[sessions]=0; sessions=sessions+1;
            end
            if(!prev_cs && cs_n) begin
                check(!request,"CS session boundary yields SPI ownership");
                releases=releases+1;
            end
            prev_cs<=cs_n;
            if(tx_busy) begin
                check(saved_data===tx_data && saved_dc===dc,"byte/DC remain stable until completion");
                check(!cs_n,"CS cannot release during byte");
                if(busy_count==0) begin tx_busy<=0; tx_done<=1; end
                else busy_count<=busy_count-1;
            end
            if(tx_start) begin
                if(first_start_cycle<0) first_start_cycle=cycle;
                check(grant && request && !cs_n && !tx_busy,"start requires grant, request, CS and idle");
                check(tx_half_period==2,"SPI half period propagated");
                bytes[count]=tx_data; flags[count]=dc;
                saved_data<=tx_data; saved_dc<=dc;
                count=count+1; lengths[sessions-1]=lengths[sessions-1]+1;
                tx_busy<=1; busy_count<=2;
                if(!dc && tx_data==8'h11) sleep_cycle=cycle;
                if(!dc && tx_data==8'h29) display_cycle=cycle;
            end
        end
    end
    task ticks; input integer n; begin repeat(n) @(negedge clk); end endtask
    task submit_pixel; input [8:0] x,y; input [15:0] color;
        begin
            wait(pixel_ready); @(negedge clk);
            pixel_x=x; pixel_y=y; pixel_rgb565=color; pixel_valid=1;
            @(negedge clk); pixel_valid=0;
        end
    endtask
    task expect_byte; input integer index; input [7:0] value; input data_flag;
        begin
            if(bytes[index]!==value || flags[index]!==data_flag)
                $display("byte[%0d] got DC=%b data=%h expected DC=%b data=%h",index,flags[index],bytes[index],data_flag,value);
            check(bytes[index]===value && flags[index]===data_flag,"pixel command/data byte");
        end
    endtask
    initial begin
        expected_data[0]=8'hef; expected_dc[0]=1'b0;
        expected_data[1]=8'h03; expected_dc[1]=1'b1;
        expected_data[2]=8'h80; expected_dc[2]=1'b1;
        expected_data[3]=8'h02; expected_dc[3]=1'b1;
        expected_data[4]=8'hcf; expected_dc[4]=1'b0;
        expected_data[5]=8'h00; expected_dc[5]=1'b1;
        expected_data[6]=8'hc1; expected_dc[6]=1'b1;
        expected_data[7]=8'h30; expected_dc[7]=1'b1;
        expected_data[8]=8'hed; expected_dc[8]=1'b0;
        expected_data[9]=8'h64; expected_dc[9]=1'b1;
        expected_data[10]=8'h03; expected_dc[10]=1'b1;
        expected_data[11]=8'h12; expected_dc[11]=1'b1;
        expected_data[12]=8'h81; expected_dc[12]=1'b1;
        expected_data[13]=8'he8; expected_dc[13]=1'b0;
        expected_data[14]=8'h85; expected_dc[14]=1'b1;
        expected_data[15]=8'h00; expected_dc[15]=1'b1;
        expected_data[16]=8'h78; expected_dc[16]=1'b1;
        expected_data[17]=8'hcb; expected_dc[17]=1'b0;
        expected_data[18]=8'h39; expected_dc[18]=1'b1;
        expected_data[19]=8'h2c; expected_dc[19]=1'b1;
        expected_data[20]=8'h00; expected_dc[20]=1'b1;
        expected_data[21]=8'h34; expected_dc[21]=1'b1;
        expected_data[22]=8'h02; expected_dc[22]=1'b1;
        expected_data[23]=8'hf7; expected_dc[23]=1'b0;
        expected_data[24]=8'h20; expected_dc[24]=1'b1;
        expected_data[25]=8'hea; expected_dc[25]=1'b0;
        expected_data[26]=8'h00; expected_dc[26]=1'b1;
        expected_data[27]=8'h00; expected_dc[27]=1'b1;
        expected_data[28]=8'hc0; expected_dc[28]=1'b0;
        expected_data[29]=8'h23; expected_dc[29]=1'b1;
        expected_data[30]=8'hc1; expected_dc[30]=1'b0;
        expected_data[31]=8'h10; expected_dc[31]=1'b1;
        expected_data[32]=8'hc5; expected_dc[32]=1'b0;
        expected_data[33]=8'h3e; expected_dc[33]=1'b1;
        expected_data[34]=8'h28; expected_dc[34]=1'b1;
        expected_data[35]=8'hc7; expected_dc[35]=1'b0;
        expected_data[36]=8'h86; expected_dc[36]=1'b1;
        expected_data[37]=8'h36; expected_dc[37]=1'b0;
        expected_data[38]=8'h28; expected_dc[38]=1'b1;
        expected_data[39]=8'h3a; expected_dc[39]=1'b0;
        expected_data[40]=8'h55; expected_dc[40]=1'b1;
        expected_data[41]=8'hb1; expected_dc[41]=1'b0;
        expected_data[42]=8'h00; expected_dc[42]=1'b1;
        expected_data[43]=8'h18; expected_dc[43]=1'b1;
        expected_data[44]=8'hb6; expected_dc[44]=1'b0;
        expected_data[45]=8'h08; expected_dc[45]=1'b1;
        expected_data[46]=8'h82; expected_dc[46]=1'b1;
        expected_data[47]=8'h27; expected_dc[47]=1'b1;
        expected_data[48]=8'hf2; expected_dc[48]=1'b0;
        expected_data[49]=8'h00; expected_dc[49]=1'b1;
        expected_data[50]=8'h26; expected_dc[50]=1'b0;
        expected_data[51]=8'h01; expected_dc[51]=1'b1;
        expected_data[52]=8'h11; expected_dc[52]=1'b0;
        expected_data[53]=8'h29; expected_dc[53]=1'b0;
        ticks(2); rst_n=1;
        ticks(12);
        check(request && cs_n && count==0,"grant denial causes no CS/SPI activity");
        check(lcd_reset_n && !ready && !pixel_ready,"reset leaves init pending");
        grant=1;
        wait(ready); ticks(2);
        check(count==54 && sessions==19,"all 54 init bytes and 19 command sessions");
        check(releases==19,"each initialization command releases SPI ownership");
        check(reset_low_observed==3,"hardware reset low uses configured clock count");
        check(first_start_cycle-release_cycle>=5,"post-reset recovery completes before SPI");
        check(release_cycle-reset_cycle>=1,"reset low interval observed");
        check(display_cycle-sleep_cycle>=7+4,"sleepout wait before displayon");
        for(integer i=0;i<54;i=i+1)
            check(bytes[i]===expected_data[i] && flags[i]===expected_dc[i],"complete initialization command/data stream");
        check(!request && cs_n && pixel_ready,"initialization releases bus");

        // Acquire denial must preserve the pending pixel and make no CS activity.
        grant=0;
        submit_pixel(9'd300,9'd239,16'habcd);
        pixel_x=1; pixel_y=2; pixel_rgb565=16'h1234;
        ticks(8);
        check(request && cs_n && count==54 && !pixel_ready,"pending pixel waits for ownership");
        grant=1; wait(pixel_ready); ticks(1);
        check(count==67 && sessions==20 && lengths[19]==13,"one complete 13-byte pixel session");
        expect_byte(54,8'h2a,0); expect_byte(55,8'h01,1);
        expect_byte(56,8'h2c,1); expect_byte(57,8'h01,1); expect_byte(58,8'h2c,1);
        expect_byte(59,8'h2b,0); expect_byte(60,0,1); expect_byte(61,8'hef,1);
        expect_byte(62,0,1); expect_byte(63,8'hef,1); expect_byte(64,8'h2c,0);
        expect_byte(65,8'hab,1); expect_byte(66,8'hcd,1);
        check(cs_n && !request,"pixel releases ownership");

        submit_pixel(320,10,16'hffff); ticks(3);
        submit_pixel(0,240,16'hffff); ticks(3);
        check(count==67 && pixel_ready && cs_n,"out-of-bounds pixels consumed without transfer");

        // Two legal corners ensure no mistaken omission at coordinate zero.
        submit_pixel(0,0,16'hf800); wait(pixel_ready); ticks(1);
        expect_byte(78,8'hf8,1); expect_byte(79,0,1);
        submit_pixel(319,239,16'h001f); wait(pixel_ready); ticks(1);
        check(count==93 && sessions==22,"back-to-back legal pixels");
        expect_byte(81,8'h01,1); expect_byte(82,8'h3f,1); expect_byte(90,8'h2c,0);
        expect_byte(91,0,1); expect_byte(92,8'h1f,1);

        submit_pixel(20,20,16'h7777);
        wait(!cs_n); @(negedge clk); rst_n=0;
        #1; check(cs_n && !ready && !request && !lcd_reset_n && !tx_start,"reset aborts pending session safely");
        ticks(2); rst_n=1; grant=0; ticks(12);
        check(request && cs_n && !ready,"reset restarts initialization before accepting pixels");
        if(errors==0) $display("PASS tb_ui_ili9341: init, reset, grant denial, pixel latching, invalid coordinates, sessions");
        else $fatal(1,"%0d LCD checks failed",errors);
        $finish;
    end
    initial begin #200000; $fatal(1,"LCD test timed out"); end
endmodule

