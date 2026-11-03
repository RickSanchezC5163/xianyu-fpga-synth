`timescale 1ns/1ps
// Snapshot formatting, independent of the audio path. Serial restoring divide
// followed by17-bit double dabble avoids a chain of per-pixel32-bit divisions.
module ui_decimal_formatter #(parameter integer DIVISOR=1)(
    input wire clk,rst_n,load,input wire [31:0] value,
    output wire [39:0] text,output reg [31:0] divided_value,
    output reg done
);
    localparam integer RW=DIVISOR<2?1:$clog2(DIVISOR);
    reg [1:0] state;
    reg [5:0] count;
    reg [31:0] dividend,quotient;
    reg [RW:0] remainder;
    reg [16:0] binary;
    reg [19:0] bcd,digits;
    reg [19:0] adjusted;
    wire [RW+1:0] trial={remainder,dividend[31]};
    wire subtract=trial>=DIVISOR;
    wire [31:0] next_quotient={quotient[30:0],subtract};
    integer i;
    always @* begin
        adjusted=bcd;
        for(i=0;i<5;i=i+1)
            if(bcd[i*4+:4]>=5) adjusted[i*4+:4]=bcd[i*4+:4]+4'd3;
    end
    genvar digit;
    generate for(digit=0;digit<5;digit=digit+1) begin: ascii_digit
        assign text[digit*8+:8]=8'd48+{4'd0,digits[digit*4+:4]};
    end endgenerate
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=0;count<=0;dividend<=0;quotient<=0;remainder<=0;
            binary<=0;bcd<=0;digits<=0;divided_value<=0;done<=0;
        end else begin
            done<=0;
            if(load) begin
                bcd<=0;count<=0;
                if(DIVISOR==1) begin
                    divided_value<=value;binary<=value>99999?17'd99999:value[16:0];state<=2;
                end else begin dividend<=value;quotient<=0;remainder<=0;state<=1;end
            end else if(state==1) begin
                dividend<={dividend[30:0],1'b0};quotient<=next_quotient;
                remainder<=subtract?trial-DIVISOR:trial;
                if(count==31) begin
                    divided_value<=next_quotient;
                    binary<=next_quotient>99999?17'd99999:next_quotient[16:0];
                    count<=0;state<=2;
                end else count<=count+1'b1;
            end else if(state==2) begin
                bcd<={adjusted[18:0],binary[16]};binary<={binary[15:0],1'b0};
                if(count==16) begin digits<={adjusted[18:0],binary[16]};done<=1;state<=0;end
                else count<=count+1'b1;
            end
        end
    end
    // synthesis translate_off
    initial if(DIVISOR<1) $fatal(1,"decimal formatter divisor must be positive");
    // synthesis translate_on
endmodule
