`timescale 1ns/1ps
module tb_ui_xpt2046;
    reg clk=0,rst_n=0,allow_grant=0,physical_down=0;
    reg [11:0] sensor_x=200,sensor_y=200;
    wire request,grant,tx_start,tx_busy,tx_done,cs_n,touch_valid,touch_down;
    wire [7:0] tx_data,rx_data;
    wire [15:0] tx_half_period;
    wire [8:0] x,y;
    wire sck,mosi;
    reg miso=0;
    // PENIRQ can be disabled/high throughout conversion; not a release event.
    wire irq_n=physical_down ? !cs_n : 1'b1;
    assign grant=request && allow_grant;
    xpt2046_touch #(.CLK_HZ(1000000),.POLL_HZ(1000),.SPI_HALF_PERIOD(1)) dut(.*);
    // Same physical readback, independent calibrated orientation instance.
    wire rr,rs,rc,rv,rd;wire [7:0] rb;wire [15:0] rh;wire [8:0] xx,yy;
    xpt2046_touch #(.CLK_HZ(1000000),.POLL_HZ(1000),.SPI_HALF_PERIOD(1),
        .SWAP_AXES(1),.INVERT_X(1),.INVERT_Y(1)) rotated(
        .clk(clk),.rst_n(rst_n),.irq_n(irq_n),.request(rr),.grant(rr&&allow_grant),
        .tx_start(rs),.tx_data(rb),.tx_half_period(rh),.tx_busy(tx_busy),.tx_done(tx_done),.rx_data(rx_data),
        .cs_n(rc),.touch_valid(rv),.touch_down(rd),.x(xx),.y(yy));
    // Different asymmetric calibration bounds and maximum output width.
    // Share the exact same physical SPI replies; only arithmetic differs.
    wire ar,ast,ac,av,ad;wire [7:0] ab;wire [15:0] ah;wire [8:0] ax,ay;
    xpt2046_touch #(.CLK_HZ(1000000),.POLL_HZ(1000),.SPI_HALF_PERIOD(1),
        .RAW_X_MIN(13),.RAW_X_MAX(4094),.RAW_Y_MIN(101),.RAW_Y_MAX(2053),
        .WIDTH(512),.HEIGHT(127)) asymmetric(
        .clk(clk),.rst_n(rst_n),.irq_n(irq_n),.request(ar),.grant(ar&&allow_grant),
        .tx_start(ast),.tx_data(ab),.tx_half_period(ah),.tx_busy(tx_busy),.tx_done(tx_done),.rx_data(rx_data),
        .cs_n(ac),.touch_valid(av),.touch_down(ad),.x(ax),.y(ay));
    ui_spi_byte spi(.clk(clk),.rst_n(rst_n),.start(tx_start),.tx_data(tx_data),
        .half_period(tx_half_period),.miso(miso),.sck(sck),.mosi(mosi),
        .rx_data(rx_data),.busy(tx_busy),.done(tx_done));
    always #5 clk=~clk;
    integer bits=0,sessions=0,events=0,pressed_samples=0;
    reg [7:0] command=0;
    reg [11:0] snapshot_x,snapshot_y;
    function automatic integer scaled(input integer raw,extent);
        begin scaled=raw<=200?0:(raw>=3900?extent:(raw-200)*extent/3700);end
    endfunction
    function automatic integer scaled_bounds(input integer raw,lo,hi,extent);
        begin scaled_bounds=raw<=lo?0:(raw>=hi?extent:(raw-lo)*extent/(hi-lo));end
    endfunction
    always @(negedge clk) if(rst_n) begin
        if(ac!==cs_n || av!==touch_valid || ad!==touch_down) $fatal(1,"calibration bounds changed transaction lifecycle");
        if(touch_valid && touch_down && (ax!=scaled_bounds(snapshot_x,13,4094,511) || ay!=scaled_bounds(snapshot_y,101,2053,126)))
            $fatal(1,"asymmetric calibration incorrect raw=%0d,%0d result=%0d,%0d",snapshot_x,snapshot_y,ax,ay);
        if(rc!==cs_n || rv!==touch_valid || rd!==touch_down) $fatal(1,"orientation changed transaction lifecycle");
        if(touch_valid && touch_down && (xx!=319-scaled(snapshot_y,319) || yy!=239-scaled(snapshot_x,239)))
            $fatal(1,"axis swap/inversion calibration incorrect");
    end
    function automatic slave_bit(input integer pos);
        integer byte_n,bit_n;
        reg [15:0] response;
        begin
            byte_n=pos/8;bit_n=pos%8;
            response=(byte_n<3 ? snapshot_y : snapshot_x)<<3;
            case(byte_n%3)
                1: slave_bit=response[15-bit_n];
                2: slave_bit=response[7-bit_n];
                default:slave_bit=0;
            endcase
        end
    endfunction
    always @(negedge cs_n) begin
        if(!request || !grant || sck) $fatal(1,"CS asserted without ownership / idle clock");
        bits=0;command=0;snapshot_x=sensor_x;snapshot_y=sensor_y;miso=0;
    end
    always @(posedge sck) if(!cs_n) begin
        command={command[6:0],mosi};
        bits=bits+1;
        if(bits%8==0) begin
            case(bits/8)
                1:if(command!==8'h93) $fatal(1,"Y command %h",command);
                4:if(command!==8'hD3) $fatal(1,"X command %h",command);
                7:if(command!==8'hD0) $fatal(1,"powerdown command %h",command);
                default:if(command!==0) $fatal(1,"nonzero dummy");
            endcase
        end
    end
    always @(negedge sck) if(!cs_n) miso=slave_bit(bits);
    always @(posedge cs_n) if(rst_n) begin
        if(bits!=72 || sck) $fatal(1,"session must contain 72 clocks and end low: %0d",bits);
        if(dut.calibration_ready!==1'b1 || rotated.calibration_ready!==1'b1 || asymmetric.calibration_ready!==1'b1)
            $fatal(1,"calibration extended the SPI/powerdown lifecycle");
        sessions=sessions+1;
    end
    always @(posedge clk) if(touch_valid) begin
        events=events+1;
        if(touch_down) pressed_samples=pressed_samples+1;
    end
    task await_touch(input integer ex,input integer ey);
        begin
            @(posedge touch_valid);#1;
            if(!touch_down || x!=ex || y!=ey)
                $fatal(1,"touch mismatch down=%b xy=%0d,%0d expected=%0d,%0d",touch_down,x,y,ex,ey);
        end
    endtask
    integer raw_i;
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        wait(request);repeat(30) @(negedge clk);
        if(!cs_n || tx_start || sck) $fatal(1,"must wait for grant");
        allow_grant=1;
        wait(sessions==1);wait(!request);
        if(touch_down || events!=0) $fatal(1,"boot conversion is not a touch");
        // A brief IRQ perturbation outside polling must not create a touch.
        @(negedge clk);physical_down=1;
        @(negedge clk);physical_down=0;
        repeat(1200) @(negedge clk);
        if(touch_down || events!=0) $fatal(1,"short IRQ glitch accepted");
        // First held poll confirms presence, second publishes calibrated endpoint.
        physical_down=1;sensor_x=200;sensor_y=200;
        wait(dut.press_count==1);#1;
        if(touch_down) $fatal(1,"press debounce bypassed");
        await_touch(0,0);
        wait(!request);sensor_x=3900;sensor_y=3900;
        await_touch(319,239);
        wait(!request);sensor_x=0;sensor_y=4095;
        await_touch(0,239);
        wait(!request);sensor_x=2050;sensor_y=2050;
        await_touch(159,119);
        wait(!request);sensor_x=2500;sensor_y=2700;
        await_touch(198,161);
        // Exhaust all legal 12-bit raw values on both axes. The two axes sweep
        // in opposite directions, exercising clamp, floor rounding, endpoints,
        // swap/inversion and unequal calibration denominators through real SPI.
        for(raw_i=0;raw_i<4096;raw_i=raw_i+1) begin
            wait(!request);sensor_x=raw_i;sensor_y=4095-raw_i;
            await_touch(scaled(raw_i,319),scaled(4095-raw_i,239));
        end
        // Release during own conversion must be reported only after powerdown/settle.
        @(negedge cs_n);physical_down=0;
        if(!touch_down) $fatal(1,"unexpected early release");
        @(posedge touch_valid);#1;
        if(touch_down || !cs_n) $fatal(1,"release not reported after session");
        repeat(1100) @(negedge clk);
        // Grant starvation cannot toggle CS, and reset cancels request cleanly.
        allow_grant=0;physical_down=1;
        wait(request);repeat(40) @(negedge clk);
        if(!cs_n || sck) $fatal(1,"no-grant transfer");
        rst_n=0;#1;
        if(request || !cs_n || touch_down || touch_valid) $fatal(1,"reset outputs");
        $display("PASS: XPT2046 command/null-bit model, ownership, boot, debounce, all4096 raw values, asymmetric bounds, 512-wide output, swap/invert, no extra publication latency, IRQ conversion masking, release/reset; %0d sessions",sessions);
        $finish;
    end
    initial begin #100000000;$fatal(1,"touch timeout");end
endmodule
