`timescale 1ns/1ps
module tb_tjc_snapshot;
    reg clk=0,rst_n=0,request=0;
    reg [7:0] volume=255;reg [1:0] patch=3;
    reg [27:0] adsr={7'd127,7'd91,7'd72,7'd36};
    wire busy,valid;wire [7:0] data;
    reg [7:0] counter=0;wire ready=counter[1:0]!=0;
    tjc_snapshot_tx dut(clk,rst_n,request,patch,volume,adsr,1'b1,3'd1,1'b1,1'b0,1'b1,8'd120,
        busy,valid,data,ready,3'd0,4'd0,3'd0,2'd0);
    always #10 clk=~clk;
    integer fd,n=0;
    reg stalled=0;reg [7:0] previous;
    always @(posedge clk) begin
        counter<=counter+1'b1;
        if(stalled && (!valid || data!==previous)) $fatal(1,"TX changed under backpressure");
        stalled=valid&&!ready;previous=data;
        if(valid&&ready) begin $fwrite(fd,"%02x",data);n=n+1;end
    end
    initial begin
        fd=$fopen("tjc_tx.hex","w");repeat(3) @(negedge clk);rst_n=1;
        @(negedge clk);request=1;@(negedge clk);request=0;
        wait(n>=4);volume=1;patch=0;adsr=0;
        // A busy request must not splice a newer value into the snapshot.
        request=1;@(negedge clk);request=0;
        wait(!busy);repeat(3) @(negedge clk);
        request=1;@(negedge clk);request=0;wait(busy);wait(!busy);
        repeat(2) @(negedge clk);$fclose(fd);
        $display("PASS tjc_snapshot: coherent capture, backpressure, two commits");$finish;
    end
    initial begin #3000000;$fatal(1,"snapshot bench timeout");end
endmodule
