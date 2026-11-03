`timescale 1ns/1ps
module tb_ui_control_scale_rom;
    reg clk=0,rst_n=0,touch_valid=0,touch_down=0,page_ready=1;
    reg [8:0] x=0,y=0;
    wire start,pause_toggle,stop,loop_toggle,param_valid;
    wire [3:0] param_id;wire [15:0] param_value;
    wire [1:0] patch,page;wire [7:0] volume;
    wire [6:0] attack,decay,sustain,release_value;
    ui_touch_controls #(.PIPELINED_SCALE(1)) dut(.*);
    always #5 clk=~clk;
    task touch(input integer xx,yy,input bit down);
        begin @(negedge clk);x=xx;y=yy;touch_down=down;touch_valid=1;
            @(negedge clk);touch_valid=0;@(negedge clk);end
    endtask
    integer i;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        for(i=0;i<320;i=i+1) begin
            touch(i,90,1);
            if(!param_valid || param_id!=1 || param_value!=i*255/319 || volume!=param_value)
                $fatal(1,"volume ROM event misaligned atx=%0d value%0d",i,param_value);
            touch(i,90,0);
            if(param_valid) $fatal(1,"release created an edit");
        end
        touch(10,120,1);touch(10,120,0);if(page!=1) $fatal(1,"page event pipeline");
        for(i=0;i<320;i=i+1) begin
            touch(i,150,1);
            if(!param_valid || param_id!=2 || param_value!=i*127/319 || attack!=param_value)
                $fatal(1,"ADSR ROM event misaligned atx=%0d value%0d",i,param_value);
            touch(i,150,0);
        end
        // Consecutive drag events must retain coordinate/value alignment.
        @(negedge clk);x=0;y=90;touch_down=1;touch_valid=1;
        @(negedge clk);x=319;@(negedge clk);
        if(!param_valid || param_value!=0) $fatal(1,"first back-to-back coordinate lost");
        touch_valid=0;@(negedge clk);
        if(!param_valid || param_value!=255) $fatal(1,"second back-to-back coordinate lost");
        $display("PASS tb_ui_control_scale_rom: all320volume+320ADSR coordinates, release and consecutive drag pipeline alignment");$finish;
    end
    initial begin #1000000;$fatal(1,"ROM control timeout");end
endmodule
