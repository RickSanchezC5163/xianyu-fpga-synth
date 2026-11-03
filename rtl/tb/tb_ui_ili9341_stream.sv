`timescale 1ns/1ps
module tb_ui_ili9341_stream;
    reg clk=0; always #10 clk=~clk;
    reg rst_n=0,grant=1,pixel_valid=0;
    wire request,tx_start,tx_busy,tx_done,cs_n,dc,lcd_reset_n,ready,pixel_ready;
    wire [7:0] tx_data,rx_data; wire [15:0] tx_half_period;
    wire sck,mosi;
    reg [8:0] pixel_x=0,pixel_y=0;
    reg [15:0] pixel_rgb565=0;
    ili9341_panel #(.RESET_LOW_CYCLES(1),.RESET_WAIT_CYCLES(1),
        .SLEEP_OUT_CYCLES(2),.STREAM_ROW(1)) dut(.*);
    ui_spi_byte master(clk,rst_n,tx_start,tx_data,tx_half_period,1'b0,
        sck,mosi,rx_data,tx_busy,tx_done);
    integer count=0,sessions=0,bits=0,errors=0,accepted=0,cycle=0,row_start=0;
    reg [7:0] shift=0;
    reg [7:0] bytes[0:1023];
    reg flags[0:1023];
    integer lengths[0:63],starts[0:63];
    task check; input condition; input [8*120-1:0] message;
        begin if(!condition) begin errors=errors+1; $display("FAIL %0s",message); end end
    endtask
    always @(posedge clk) begin
        cycle=cycle+1;
        if(rst_n && pixel_valid && pixel_ready) accepted=accepted+1;
    end
    always @(negedge cs_n) if(rst_n) begin
        check(!tx_busy && !sck,"CS asserts only while SPI idle");
        starts[sessions]=count; lengths[sessions]=0; sessions=sessions+1;
    end
    always @(posedge sck) if(rst_n) begin
        check(!cs_n && grant && request,"wire clock owned by active CS");
        shift={shift[6:0],mosi};
        if(bits==7) begin
            bytes[count]=shift; flags[count]=dc; count=count+1;
            lengths[sessions-1]=lengths[sessions-1]+1; bits=0;
        end else bits=bits+1;
    end
    always @(posedge cs_n) if(rst_n && sessions>0) begin
        #1; // Let continuous request decode settle after state/CS nonblocking updates.
        check(bits==0 && !sck && !tx_busy,"CS releases at complete-byte boundary");
        check(!request,"ownership releases with CS");
    end
    task ticks; input integer n; begin repeat(n) @(negedge clk); end endtask
    task put; input [8:0] x,y; input [15:0] rgb;
        begin
            @(negedge clk); pixel_x=x;pixel_y=y;pixel_rgb565=rgb;pixel_valid=1;
            do @(posedge clk); while(!pixel_ready);
            @(negedge clk); pixel_valid=0;
        end
    endtask
    task expect_byte; input integer index; input [7:0] value; input flag;
        begin
            if(bytes[index]!==value || flags[index]!==flag)
                $display("byte[%0d] got=%h/%b expected=%h/%b",index,bytes[index],flags[index],value,flag);
            check(bytes[index]===value && flags[index]===flag,"wire byte data and DC");
        end
    endtask
    task wait_idle;
        begin wait(cs_n && pixel_ready); ticks(1); end
    endtask
    initial begin
        ticks(2); rst_n=1;
        wait(ready); ticks(2);
        check(count==54 && sessions==19,"initialization passes through actual byte master");

        // Last three pixels of row: 11 setup bytes + two bytes per pixel.
        put(317,2,16'h1234);
        put(318,2,16'habcd);
        put(319,2,16'hf800);
        // Inputs may change as soon as accepted, even while the last byte shifts.
        pixel_x=0;pixel_y=0;pixel_rgb565=16'hffff;
        wait_idle();
        check(accepted==3 && count==71 && sessions==20 && lengths[19]==17,
            "three-pixel row uses one 17-byte session");
        expect_byte(54,8'h2a,0);expect_byte(55,1,1);expect_byte(56,8'h3d,1);
        expect_byte(57,1,1);expect_byte(58,8'h3f,1);
        expect_byte(59,8'h2b,0);expect_byte(60,0,1);expect_byte(61,2,1);
        expect_byte(62,0,1);expect_byte(63,2,1);expect_byte(64,8'h2c,0);
        expect_byte(65,8'h12,1);expect_byte(66,8'h34,1);
        expect_byte(67,8'hab,1);expect_byte(68,8'hcd,1);
        expect_byte(69,8'hf8,1);expect_byte(70,0,1);

        // A pending noncontiguous pixel must survive closing/readdressing.
        put(10,5,16'h001f);
        put(20,5,16'h07e0);
        pixel_rgb565=16'haaaa;
        wait_idle();
        check(accepted==5 && count==97 && sessions==22,
            "noncontiguous pixel is consumed once and readdressed, never dropped");
        check(lengths[20]==13 && lengths[21]==13,"mismatch splits two independent sessions");
        expect_byte(73,10,1);expect_byte(78,5,1);
        expect_byte(82,0,1);expect_byte(83,8'h1f,1);
        expect_byte(86,20,1);expect_byte(95,8'h07,1);expect_byte(96,8'he0,1);

        // Early producer gap releases a short row rather than monopolizing SPI.
        put(0,9,16'hbeef);
        wait_idle();
        check(count==110 && sessions==23 && lengths[22]==13,"missing next valid releases ownership");
        expect_byte(108,8'hbe,1);expect_byte(109,8'hef,1);

        // Exact row-end single pixel; the row must close with no next demand.
        put(319,239,16'h55aa);
        wait_idle();
        check(count==123 && sessions==24 && accepted==7,"final coordinate terminates row session");
        expect_byte(112,8'h3f,1);expect_byte(116,0,1);expect_byte(117,8'hef,1);
        expect_byte(121,8'h55,1);expect_byte(122,8'haa,1);

        row_start=cycle;
        for(integer x=0;x<320;x=x+1) put(x,30,16'h4000+x);
        wait_idle();
        check(count==774 && sessions==25 && lengths[24]==651 && accepted==327,
            "complete 320-pixel row uses 11+640 bytes and exactly320 handshakes");
        check(cycle-row_start<30000,"complete row holds bus less than0.6ms at50MHz");
        expect_byte(134,8'h40,1);expect_byte(135,0,1);
        expect_byte(772,8'h41,1);expect_byte(773,8'h3f,1);
        $display("STREAM_ROW full320-pixel row including producer/handshake overhead: %0d clk cycles at50MHz",cycle-row_start);
        if(errors) $fatal(1,"%0d streaming LCD checks failed",errors);
        $display("PASS tb_ui_ili9341_stream: real SPI, row window, 11+2N bytes, latching, mismatch/gap, row end");
        $finish;
    end
    initial begin #1000000; $fatal(1,"stream test timeout"); end
endmodule

