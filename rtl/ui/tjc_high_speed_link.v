`timescale 1ns/1ps
// Temporary baud negotiation only. No bauds/EEPROM write, reset, audio or notes.
// Prove921600 first; only after a valid115200 query may baud=921600 be sent.
module tjc_high_speed_link #(
    parameter integer SLOW_CLKS_PER_BIT=434,
    parameter integer BOOT_CYCLES=50000000,
    parameter integer RESPONSE_CYCLES=5000000,
    parameter integer RETRY_CYCLES=12500000,
    parameter integer HEARTBEAT_CYCLES=50000000,
    parameter integer SETTLE_CYCLES=1000000
)(
    input wire clk,rst_n,screen_rx,
    input wire [7:0] fast_rx_data,input wire fast_rx_valid,fast_rx_error,
    input wire panel_idle,fast_tx_ready,fast_tx,
    output wire fast_command_valid,output wire [7:0] fast_command_data,
    output wire command_owns_fast,allow_new,
    output wire screen_tx,output reg online,
    output reg page_notice,output reg [2:0] observed_page
);
    localparam [3:0] BOOT=0,QUIESCE=1,SEND=2,DRAIN=3,WAIT_REPLY=4,SETTLE=5,RUN=6,BACKOFF=7;
    localparam [1:0] GET_BAUD=0,GET_PAGE=1,SET_BAUD=2;
    reg [3:0] state;
    reg [1:0] command;
    reg slow_mode;
    reg [4:0] position;
    reg [31:0] age;
    reg high_ack,low_ack,page_ack;
    reg [2:0] received_page;
    reg [63:0] high_shift,low_shift;
    reg [39:0] page_shift;
    wire [7:0] slow_data;
    wire slow_valid,slow_error,slow_ready,slow_tx;
    uart_rx #(.CLKS_PER_BIT(SLOW_CLKS_PER_BIT)) slow_receiver(
        clk,rst_n,screen_rx,slow_data,slow_valid,slow_error);
    wire [63:0] next_high={high_shift[55:0],fast_rx_data};
    wire [63:0] next_low={low_shift[55:0],slow_data};
    wire [39:0] next_page={page_shift[31:0],fast_rx_data};
    function [4:0] last_byte(input [1:0] kind);
        begin last_byte=kind==SET_BAUD?16:kind==GET_PAGE?11:13;end
    endfunction
    function [7:0] command_byte(input [1:0] kind,input [4:0] index);
        begin
            command_byte=8'hff;
            // Three correctly timed FFs close any partial command before query.
            if(index>=3)case(kind)
                GET_BAUD:case(index)
                    3:command_byte="g";4:command_byte="e";5:command_byte="t";6:command_byte=" ";
                    7:command_byte="b";8:command_byte="a";9:command_byte="u";10:command_byte="d";
                endcase
                GET_PAGE:case(index)
                    3:command_byte="s";4:command_byte="e";5:command_byte="n";
                    6:command_byte="d";7:command_byte="m";8:command_byte="e";
                endcase
                SET_BAUD:case(index)
                    3:command_byte="b";4:command_byte="a";5:command_byte="u";6:command_byte="d";
                    7:command_byte="=";8:command_byte="9";9:command_byte="2";10:command_byte="1";
                    11:command_byte="6";12:command_byte="0";13:command_byte="0";
                endcase
            endcase
        end
    endfunction
    wire [7:0] outgoing=command_byte(command,position);
    uart_tx #(.CLKS_PER_BIT(SLOW_CLKS_PER_BIT)) slow_transmitter(
        clk,rst_n,outgoing,state==SEND && slow_mode,slow_tx,slow_ready);
    assign fast_command_valid=state==SEND && !slow_mode;
    assign fast_command_data=outgoing;
    assign command_owns_fast=!slow_mode && (state==SEND || state==DRAIN);
    assign screen_tx=slow_mode?slow_tx:fast_tx;
    assign allow_new=state==RUN;
    wire byte_ready=slow_mode?slow_ready:fast_tx_ready;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            state<=BOOT;command<=GET_BAUD;slow_mode<=0;position<=0;age<=0;
            high_ack<=0;low_ack<=0;page_ack<=0;received_page<=0;
            high_shift<=0;low_shift<=0;page_shift<=0;online<=0;page_notice<=0;observed_page<=0;
        end else begin
            page_notice<=0;
            if(fast_rx_error)begin high_shift<=0;page_shift<=0;end
            else if(fast_rx_valid)begin
                high_shift<=next_high;page_shift<=next_page;
                if(!slow_mode && command==GET_BAUD && next_high==64'h7100100e00ffffff)high_ack<=1;
                if(!slow_mode && command==GET_PAGE && next_page[39:32]==8'h66 &&
                    next_page[31:24]<6 && next_page[23:0]==24'hffffff)begin
                    page_ack<=1;received_page<=next_page[26:24];
                end
            end
            if(slow_error)low_shift<=0;
            else if(slow_valid)begin
                low_shift<=next_low;
                if(slow_mode && command==GET_BAUD && next_low==64'h7100c20100ffffff)low_ack<=1;
            end
            case(state)
                BOOT:if(age==BOOT_CYCLES-1)begin
                    age<=0;position<=0;command<=GET_BAUD;slow_mode<=0;high_ack<=0;high_shift<=0;state<=SEND;
                end else age<=age+1'b1;
                RUN:if(age==HEARTBEAT_CYCLES-1)begin age<=0;state<=QUIESCE;end
                    else age<=age+1'b1;
                // Never cut a snapshot, graph or native waveform in progress.
                QUIESCE:if(panel_idle && fast_tx_ready)begin
                    position<=0;command<=GET_BAUD;slow_mode<=0;high_ack<=0;high_shift<=0;state<=SEND;
                end
                SEND:if(byte_ready)begin
                    if(position==last_byte(command))begin age<=0;state<=DRAIN;end
                    else position<=position+1'b1;
                end
                DRAIN:if(byte_ready)begin age<=0;state<=command==SET_BAUD?SETTLE:WAIT_REPLY;end
                WAIT_REPLY:begin
                    if(!slow_mode && command==GET_BAUD && high_ack)begin
                        command<=GET_PAGE;position<=0;page_ack<=0;page_shift<=0;state<=SEND;
                    end else if(!slow_mode && command==GET_PAGE && page_ack)begin
                        online<=1;observed_page<=received_page;page_notice<=1;age<=0;state<=RUN;
                    end else if(slow_mode && low_ack)begin
                        command<=SET_BAUD;position<=0;state<=SEND;
                    end else if(age==RESPONSE_CYCLES-1)begin
                        online<=0;age<=0;
                        if(!slow_mode)begin
                            slow_mode<=1;command<=GET_BAUD;position<=0;low_ack<=0;low_shift<=0;state<=SEND;
                        end else state<=BACKOFF;
                    end else age<=age+1'b1;
                end
                SETTLE:if(age==SETTLE_CYCLES-1)begin
                    slow_mode<=0;command<=GET_BAUD;position<=0;high_ack<=0;high_shift<=0;age<=0;state<=SEND;
                end else age<=age+1'b1;
                BACKOFF:if(age==RETRY_CYCLES-1)begin
                    slow_mode<=0;command<=GET_BAUD;position<=0;high_ack<=0;high_shift<=0;age<=0;state<=SEND;
                end else age<=age+1'b1;
                default:begin state<=BOOT;online<=0;age<=0;end
            endcase
        end
    end
    // synthesis translate_off
    initial if(BOOT_CYCLES<1 || RESPONSE_CYCLES<1 || RETRY_CYCLES<1 || HEARTBEAT_CYCLES<1 || SETTLE_CYCLES<1)
        $fatal(1,"invalid TJC link timers");
    // synthesis translate_on
endmodule
