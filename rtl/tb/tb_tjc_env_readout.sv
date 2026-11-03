`timescale 1ns/1ps
// Independent byte-level tests. No native editor, serial port or hardware.
module tb_tjc_env_readout #(parameter integer TEST_ENV_ENABLE=1);
    reg clk=0,rst_n=0,request=0;
    reg [1:0] patch=3;
    reg [7:0] volume=192;
    reg [27:0] adsr=0;
    reg link_ready=1;
    reg [2:0] page=1;
    wire busy,valid;
    wire [7:0] data;
    integer tick=0;
    wire ready=(tick%11)>=4;
    tjc_snapshot_tx #(.ENV_READOUT_ENABLE(TEST_ENV_ENABLE)) dut(
        clk,rst_n,request,patch,volume,adsr,link_ready,3'd1,
        1'b0,1'b0,1'b1,8'd120,busy,valid,data,ready,page);
    always #10 clk=~clk;
    integer fd,cmd_index=0,cmd_bytes=0,case_bytes=0,ff_count=0;
    reg recording=0,stalled=0;
    reg [7:0] held=0;
    always @(negedge clk) tick=tick+1;
    always @(posedge clk) begin
        if(!rst_n) stalled<=0;
        else begin
            if(stalled && (!valid || data!==held))
                $fatal(1,"snapshot byte changed under backpressure, command %0d",cmd_index);
            stalled<=valid&&!ready;held<=data;
            if(valid && ready && recording) begin
                $fwrite(fd,"%02x",data);
                case_bytes=case_bytes+1;cmd_bytes=cmd_bytes+1;
                if(data==8'hff) begin
                    ff_count=ff_count+1;
                    if(ff_count==3) begin cmd_index=cmd_index+1;cmd_bytes=0;ff_count=0;end
                end else ff_count=0;
            end
        end
    end
    task set_values(input integer a,d,s,r);
        begin adsr={r[6:0],s[6:0],d[6:0],a[6:0]};end
    endtask
    task open_case(input string name);
        begin
            wait(!busy);repeat(2)@(negedge clk);
            $fwrite(fd,"CASE %s\n",name);
            cmd_index=0;cmd_bytes=0;case_bytes=0;ff_count=0;recording=1;
            request=1;@(negedge clk);request=0;
        end
    endtask
    task close_case(input string name);
        integer age;
        begin
            age=0;
            while(busy && age<20000)begin @(negedge clk);age=age+1;end
            if(busy)$fatal(1,"case did not drain: %s",name);
            repeat(2)@(negedge clk);recording=0;
            $fwrite(fd,"\nEND %s\n",name);
        end
    endtask
    integer i,v;
    string name;
    initial begin
        fd=$fopen("env_readout.hex","w");
        repeat(4)@(negedge clk);rst_n=1;
        for(i=0;i<6;i=i+1)begin
            case(i)0:v=0;1:v=9;2:v=10;3:v=99;4:v=100;default:v=127;endcase
            set_values(v,v,v,v);name=$sformatf("boundary_%0d",v);
            open_case(name);close_case(name);
        end
        set_values(9,10,99,100);open_case("mixed");close_case("mixed");
        set_values(28,4,75,11);open_case("mutating_inputs");
        wait(case_bytes>=4);@(negedge clk);
        set_values(127,126,125,124);patch=2;volume=1;link_ready=0;
        // A busy request cannot splice the second group into the first snapshot.
        request=1;@(negedge clk);request=0;
        close_case("mutating_inputs");
        link_ready=1;
        open_case("mutation_followup");close_case("mutation_followup");
        patch=3;volume=192;set_values(28,4,75,11);page=0;
        open_case("not_env");close_case("not_env");
        page=1;link_ready=0;
        open_case("not_ready");wait(case_bytes>=4);@(negedge clk);link_ready=1;
        close_case("not_ready");
        if(TEST_ENV_ENABLE)begin
            page=0;open_case("enter_during_global");wait(cmd_index==4 && cmd_bytes>=3);
            @(negedge clk);page=1;close_case("enter_during_global");
            open_case("leave_before_direct");wait(cmd_index==4 && cmd_bytes>=3);
            @(negedge clk);page=0;close_case("leave_before_direct");
            page=1;
            open_case("leave_during_format");wait(cmd_index==13);
            // No direct command has started yet. Leave while its decimal
            // formatter is working; it must not begin a new page-local command.
            repeat(4)@(negedge clk);page=0;close_case("leave_during_format");
            page=1;set_values(9,10,99,100);
            open_case("leave_inside_text");wait(cmd_index==13 && cmd_bytes>=4);
            @(negedge clk);page=0;close_case("leave_inside_text");
            page=1;open_case("reenter_after_text");close_case("reenter_after_text");
            open_case("leave_inside_ref");wait(cmd_index==14 && cmd_bytes>=3);
            @(negedge clk);page=0;close_case("leave_inside_ref");
            page=1;open_case("reenter_after_ref");close_case("reenter_after_ref");
            open_case("reset_partial");wait(cmd_index==13 && cmd_bytes>=4);
        end else begin
            open_case("reset_partial");wait(cmd_index==4 && cmd_bytes>=4);
        end
        @(negedge clk);rst_n=0;recording=0;
        $fwrite(fd,"\nABORT reset_partial\n");
        repeat(3)@(negedge clk);
        if(busy || valid)$fatal(1,"reset did not stop pending snapshot");
        rst_n=1;patch=3;volume=192;page=1;link_ready=1;set_values(28,4,75,11);
        open_case("reset_recovery");close_case("reset_recovery");
        repeat(5)@(negedge clk);
        if(valid || busy)$fatal(1,"unexpected leftover output after final snapshot");
        $fclose(fd);
        $display("PASS tjc_env_readout mode=%0d: boundaries, coherent snapshot, ready/valid, page cancellation and reset",TEST_ENV_ENABLE);
        $finish;
    end
    initial begin #30000000;$fatal(1,"env readout bench timeout");end
endmodule
