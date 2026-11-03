`timescale 1ns/1ps
module tb_score_metadata_uart;
    localparam CPB=8;
    reg clk=0,rst_n=0,wifi_rx=1,playing=0;
    wire wifi_tx,active_present,committed;
    wire [8:0] active_count;
    wire [7:0] active_bpm;
    wire [6:0] active_base;
    wire [31:0] active_token;
    wire [191:0] active_title;
    wire [4:0] active_title_len;
    wire [9:0] active_part,active_parts;
    wifi_guide_source #(.UART_CLKS_PER_BIT(CPB),.GAP_CYCLES(20000)) dut(
        .clk(clk),.rst_n(rst_n),.wifi_rx(wifi_rx),.wifi_tx(wifi_tx),
        .start(1'b0),.stop(1'b0),.playing(playing),.paused(1'b0),.loop_enable(1'b0),.song_tick(32'd0),
        .active_present(active_present),.committed(committed),.active_count(active_count),.active_bpm(active_bpm),
        .active_base(active_base),.active_token(active_token),.wait_mode(1'b0),.target_hit(1'b0),
        .active_title(active_title),.active_title_len(active_title_len),.active_part(active_part),.active_parts(active_parts));
    wire [7:0] ack_byte;wire ack_valid,ack_error;
    uart_rx #(.CLKS_PER_BIT(CPB)) receiver(clk,rst_n,wifi_tx,ack_byte,ack_valid,ack_error);
    always #10 clk=~clk;
    reg [159:0] requests[0:1023],responses[0:1023];
    reg [255:0] states[0:1023];
    reg [1:0] controls[0:1023];
    reg [159:0] ack;
    integer ack_index=0,ack_count=0,commit_count=0,n,i,j,count,timeout;
    reg [255:0] observed;
    always @(posedge clk)begin
        if(ack_error)$fatal(1,"UART ACK framing error");
        if(ack_valid)begin
            ack[ack_index*8+:8]<=ack_byte;
            if(ack_index==19)begin ack_index<=0;ack_count<=ack_count+1;end
            else ack_index<=ack_index+1;
        end
        if(committed)commit_count<=commit_count+1;
    end
    task bitcell;input bitvalue;begin
        wifi_rx=bitvalue;repeat(CPB)@(negedge clk);
    end endtask
    task bytecell;input[7:0] b;integer k;begin
        bitcell(0);for(k=0;k<8;k=k+1)bitcell(b[k]);bitcell(1);
    end endtask
    initial begin
        if(!$value$plusargs("COUNT=%d",count))$fatal(1,"COUNT missing");
        $readmemh("metadata_requests.hex",requests,0,count-1);
        $readmemh("metadata_responses.hex",responses,0,count-1);
        $readmemh("metadata_states.hex",states,0,count-1);
        $readmemh("metadata_controls.hex",controls,0,count-1);
        repeat(10)@(negedge clk);rst_n=1;repeat(10)@(negedge clk);
        for(n=0;n<count;n=n+1)begin
            if(controls[n][1])begin
                rst_n=0;repeat(10)@(negedge clk);rst_n=1;repeat(10)@(negedge clk);
            end
            playing=controls[n][0];j=ack_count;
            for(i=0;i<20;i=i+1)bytecell(requests[n][i*8+:8]);
            timeout=0;
            while(ack_count==j && timeout<4000)begin @(negedge clk);timeout=timeout+1;end
            if(timeout>=4000)$fatal(1,"ACK timeout transaction%0d",n);
            repeat(4)@(negedge clk);
            if(ack!==responses[n])$fatal(1,"ACK mismatch at%0d expected%040h got%040h",n,responses[n],ack);
            observed={8'd0,active_title,active_parts,active_part,active_title_len,active_count,active_bpm,active_base,active_present,6'd0};
            if(observed!==states[n])$fatal(1,"atomic metadata state mismatch at%0d expected%064h got%064h",n,states[n],observed);
        end
        $display("PASS physical UART metadata transactions=%0d commits=%0d",count,commit_count);$finish;
    end
    initial begin #100000000;$fatal(1,"global timeout");end
endmodule
