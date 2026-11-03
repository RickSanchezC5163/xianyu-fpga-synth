`timescale 1ns/1ps
module tb_tjc_env_plot #(parameter integer VECTOR_COUNT=71);
    reg clk=0,rst_n=0,request=0;
    reg [2:0] page=1;
    reg [27:0] adsr=0;
    wire busy,valid;
    wire [7:0] data;
    integer tick=0;
    reg manual_stall=0;
    wire ready=!manual_stall && tick%13>=5;
    tjc_env_plot_tx dut(clk,rst_n,request,page,adsr,busy,valid,data,ready);
    always #10 clk=~clk;
    always @(negedge clk)tick=tick+1;
    integer fd,commands=0,command_bytes=0,bytes=0,ff_count=0,case_cycles=0,first_byte_cycle=0;
    reg record=0,stalled=0;
    reg [7:0] held=0;
    always @(posedge clk)begin
        if(!rst_n)stalled<=0;
        else begin
            if(stalled && (!valid || data!==held))$fatal(1,"env plot byte changed under backpressure");
            stalled<=valid&&!ready;held<=data;
            if(record)case_cycles=case_cycles+1;
            if(record && valid && ready)begin
                if(bytes==0)first_byte_cycle=case_cycles;
                $fwrite(fd,"%02x",data);bytes=bytes+1;command_bytes=command_bytes+1;
                if(data==8'hff)begin
                    ff_count=ff_count+1;
                    if(ff_count==3)begin commands=commands+1;command_bytes=0;ff_count=0;end
                end else ff_count=0;
            end
        end
    end
    task defaults;
        begin adsr={7'd11,7'd75,7'd4,7'd28};page=1;end
    endtask
    task open_case(input string name);
        begin
            wait(!busy);repeat(2)@(negedge clk);
            $fwrite(fd,"CASE %s\n",name);commands=0;command_bytes=0;bytes=0;ff_count=0;
            case_cycles=0;first_byte_cycle=0;record=1;request=1;@(negedge clk);request=0;
        end
    endtask
    task close_case(input string name);
        integer age;
        begin
            age=0;while(busy && age<20000)begin @(negedge clk);age=age+1;end
            if(busy)$fatal(1,"env plot did not drain %s",name);
            repeat(2)@(negedge clk);record=0;
            $fwrite(fd,"\nEND %s\n",name);
            if(bytes>0 && first_byte_cycle>256)$fatal(1,"unexpected long preview arithmetic %0d",first_byte_cycle);
        end
    endtask
    task abort_case(input string name);
        begin
            @(negedge clk);rst_n=0;record=0;manual_stall=0;
            $fwrite(fd,"\nABORT %s\n",name);
            repeat(3)@(negedge clk);
            if(busy || valid)$fatal(1,"reset left renderer active");
            rst_n=1;
        end
    endtask
    reg [27:0] vectors[0:VECTOR_COUNT-1];
    integer i;
    string name;
    initial begin
        fd=$fopen("env_plot.hex","w");$readmemh("env_plot_vectors.hex",vectors);
        repeat(4)@(negedge clk);rst_n=1;
        for(i=0;i<VECTOR_COUNT;i=i+1)begin
            page=1;adsr=vectors[i];name=$sformatf("vector_%0d",i);
            open_case(name);close_case(name);
            if(commands!=9)$fatal(1,"expected clear+8 lines, got%0d",commands);
        end
        defaults();open_case("mutating_inputs");wait(bytes>=4);@(negedge clk);
        adsr={7'd127,7'd0,7'd127,7'd0};request=1;@(negedge clk);request=0;
        close_case("mutating_inputs");
        open_case("mutation_followup");close_case("mutation_followup");
        defaults();page=0;open_case("not_env");repeat(400)@(negedge clk);close_case("not_env");
        defaults();open_case("leave_math");repeat(10)@(negedge clk);page=0;close_case("leave_math");
        defaults();open_case("leave_clear");wait(commands==0 && command_bytes>=5);
        @(negedge clk);page=0;close_case("leave_clear");
        defaults();open_case("reenter_after_clear");close_case("reenter_after_clear");
        defaults();open_case("leave_first_line");wait(commands==1 && command_bytes>=6);
        @(negedge clk);page=0;close_case("leave_first_line");
        defaults();open_case("leave_format");wait(commands==1);repeat(5)@(negedge clk);
        page=0;close_case("leave_format");
        defaults();open_case("leave_between_lines");wait(commands==2);@(negedge clk);
        page=0;close_case("leave_between_lines");
        defaults();open_case("leave_while_stalled");wait(commands==1 && command_bytes>=6);
        @(negedge clk);manual_stall=1;repeat(2)@(negedge clk);page=0;
        repeat(15)@(negedge clk);manual_stall=0;close_case("leave_while_stalled");
        defaults();open_case("reenter_after_stall");close_case("reenter_after_stall");
        defaults();open_case("reset_math");repeat(10)@(negedge clk);abort_case("reset_math");
        defaults();open_case("reset_math_recovery");close_case("reset_math_recovery");
        defaults();open_case("reset_line");wait(commands==1 && command_bytes>=6);abort_case("reset_line");
        defaults();open_case("reset_line_recovery");close_case("reset_line_recovery");
        repeat(10)@(negedge clk);
        if(valid || busy)$fatal(1,"renderer left unexpected trailing bytes");
        $fclose(fd);$display("PASS tjc_env_plot: arithmetic, frozen controls, backpressure, page cancellation, reset");$finish;
    end
    initial begin #100000000;$fatal(1,"env plot global timeout");end
endmodule
