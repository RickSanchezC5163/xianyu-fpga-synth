`timescale 1ns/1ps
// Resistive touch client for a shared SPI-byte bus. Fixed 9-byte sessions.
// XPT2046 12-bit DOUT: one null bit, twelve result bits, three trailing bits.
// Calibration is provisional. WIDTH <= 512, HEIGHT <= 512; max > min.
module xpt2046_touch #(
    parameter integer CLK_HZ=50000000, POLL_HZ=100,
    parameter integer SPI_HALF_PERIOD=25,
    parameter integer RAW_X_MIN=200, RAW_X_MAX=3900,
    parameter integer RAW_Y_MIN=200, RAW_Y_MAX=3900,
    parameter integer WIDTH=320, HEIGHT=240, STABLE_SAMPLES=2,
    parameter integer SWAP_AXES=0,INVERT_X=0,INVERT_Y=0
)(
    input wire clk, input wire rst_n, input wire irq_n,
    output reg request, input wire grant,
    output reg tx_start, output reg [7:0] tx_data,
    output wire [15:0] tx_half_period,
    input wire tx_busy, input wire tx_done, input wire [7:0] rx_data,
    output reg cs_n, output reg touch_valid, output reg touch_down,
    output reg [8:0] x, output reg [8:0] y
);
    localparam integer POLL_CYCLES=(CLK_HZ/POLL_HZ < 1) ? 1 : CLK_HZ/POLL_HZ;
    localparam integer SETTLE_CYCLES=(CLK_HZ/100000 < 4) ? 4 : CLK_HZ/100000;
    localparam [2:0] IDLE=0, ACQUIRE=1, LAUNCH=2, WAIT_BYTE=3, SETTLE=4;
    reg [2:0] state;
    reg irq_meta, irq_sync;
    reg [31:0] poll_count, settle_count, press_count;
    reg poll_due, boot_pending;
    reg [3:0] byte_index;
    reg [7:0] high_byte;
    reg [11:0] raw_x, raw_y;
    assign tx_half_period=SPI_HALF_PERIOD;
    // Exact calibration with bounded register-to-register arithmetic. Start
    // after byte5 (X LSB) so the 22 arithmetic clocks overlap bytes6..8 and
    // the existing power-down/IRQ settle interval. No SPI timing changes.
    localparam [12:0] X_DIVISOR=RAW_X_MAX-RAW_X_MIN;
    localparam [12:0] Y_DIVISOR=RAW_Y_MAX-RAW_Y_MIN;
    reg [1:0] calibration_stage;
    reg calibration_ready;
    reg [11:0] offset_x,offset_y;
    reg [20:0] numerator_x,numerator_y;
    reg [12:0] remainder_x,remainder_y;
    reg [8:0] quotient_x,quotient_y,calibrated_x,calibrated_y;
    reg [4:0] divide_left;
    wire [11:0] received_x={high_byte[6:0],rx_data[7:3]};
    wire [11:0] source_x=SWAP_AXES?raw_y:received_x;
    wire [11:0] source_y=SWAP_AXES?received_x:raw_y;
    wire calibration_start=(state==WAIT_BYTE && tx_done && byte_index==5);
    wire [12:0] shifted_remainder_x={remainder_x[11:0],numerator_x[20]};
    wire [12:0] shifted_remainder_y={remainder_y[11:0],numerator_y[20]};
    wire subtract_x=shifted_remainder_x>=X_DIVISOR;
    wire subtract_y=shifted_remainder_y>=Y_DIVISOR;
    wire [8:0] next_quotient_x={quotient_x[7:0],subtract_x};
    wire [8:0] next_quotient_y={quotient_y[7:0],subtract_y};
    function [11:0] clamp_x_offset;
        input [11:0] raw;
        begin
            if(raw<=RAW_X_MIN) clamp_x_offset=0;
            else if(raw>=RAW_X_MAX) clamp_x_offset=RAW_X_MAX-RAW_X_MIN;
            else clamp_x_offset=raw-RAW_X_MIN;
        end
    endfunction
    function [11:0] clamp_y_offset;
        input [11:0] raw;
        begin
            if(raw<=RAW_Y_MIN) clamp_y_offset=0;
            else if(raw>=RAW_Y_MAX) clamp_y_offset=RAW_Y_MAX-RAW_Y_MIN;
            else clamp_y_offset=raw-RAW_Y_MIN;
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            calibration_stage<=0;calibration_ready<=0;offset_x<=0;offset_y<=0;
            numerator_x<=0;numerator_y<=0;remainder_x<=0;remainder_y<=0;
            quotient_x<=0;quotient_y<=0;calibrated_x<=0;calibrated_y<=0;divide_left<=0;
        end else if(calibration_start) begin
            offset_x<=clamp_x_offset(source_x);offset_y<=clamp_y_offset(source_y);
            calibration_ready<=0;calibration_stage<=1;
        end else if(calibration_stage==1) begin
            numerator_x<=offset_x*(WIDTH-1);numerator_y<=offset_y*(HEIGHT-1);
            quotient_x<=0;quotient_y<=0;remainder_x<=0;remainder_y<=0;
            divide_left<=21;calibration_stage<=2;
        end else if(calibration_stage==2) begin
            numerator_x<=numerator_x<<1;numerator_y<=numerator_y<<1;
            remainder_x<=subtract_x?shifted_remainder_x-X_DIVISOR:shifted_remainder_x;
            remainder_y<=subtract_y?shifted_remainder_y-Y_DIVISOR:shifted_remainder_y;
            quotient_x<=next_quotient_x;quotient_y<=next_quotient_y;
            divide_left<=divide_left-1'b1;
            if(divide_left==1) begin
                calibrated_x<=next_quotient_x;calibrated_y<=next_quotient_y;
                calibration_stage<=0;calibration_ready<=1;
            end
        end
    end
    function [7:0] command_byte;
        input [3:0] index;
        begin
            case(index)
                0:command_byte=8'h93; // Y, differential, 12-bit, reference+ADC on
                3:command_byte=8'hD3; // X, same power state
                6:command_byte=8'hD0; // X again, power down / re-enable PENIRQ
                default:command_byte=0;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin irq_meta<=1; irq_sync<=1; end
        else begin irq_meta<=irq_n; irq_sync<=irq_meta; end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; request<=0; tx_start<=0; tx_data<=0; cs_n<=1;
            touch_valid<=0; touch_down<=0; x<=0; y<=0;
            poll_count<=0; settle_count<=0; press_count<=0;
            poll_due<=0; boot_pending<=1; byte_index<=0;
            high_byte<=0; raw_x<=0; raw_y<=0;
        end else begin
            tx_start<=0; touch_valid<=0;
            if(poll_count==POLL_CYCLES-1) begin poll_count<=0; poll_due<=1; end
            else poll_count<=poll_count+1;
            case(state)
                IDLE: begin
                    if(boot_pending || poll_due) begin
                        poll_due<=0;
                        if(boot_pending || !irq_sync) begin
                            request<=1; state<=ACQUIRE;
                        end else begin
                            press_count<=0;
                            if(touch_down) begin touch_down<=0; touch_valid<=1; end
                        end
                    end
                end
                ACQUIRE: if(grant && !tx_busy) begin
                    cs_n<=0; byte_index<=0; state<=LAUNCH;
                end
                LAUNCH: if(!tx_busy) begin
                    tx_data<=command_byte(byte_index); tx_start<=1; state<=WAIT_BYTE;
                end
                WAIT_BYTE: if(tx_done) begin
                    if(byte_index==1 || byte_index==4) high_byte<=rx_data;
                    if(byte_index==2) raw_y<={high_byte[6:0],rx_data[7:3]};
                    if(byte_index==5) raw_x<={high_byte[6:0],rx_data[7:3]};
                    if(byte_index==8) begin
                        cs_n<=1; settle_count<=0; state<=SETTLE;
                    end else begin byte_index<=byte_index+1; state<=LAUNCH; end
                end
                SETTLE: begin
                    if(settle_count==SETTLE_CYCLES-1) begin
                      if(calibration_ready) begin
                        request<=0; state<=IDLE;
                        if(boot_pending) begin boot_pending<=0; press_count<=0; end
                        else if(irq_sync) begin
                            press_count<=0;
                            if(touch_down) begin touch_down<=0; touch_valid<=1; end
                        end else begin
                            if(press_count<STABLE_SAMPLES) press_count<=press_count+1;
                            if(press_count>=STABLE_SAMPLES-1) begin
                                touch_down<=1; touch_valid<=1;
                                x<=INVERT_X?WIDTH-1-calibrated_x:calibrated_x;
                                y<=INVERT_Y?HEIGHT-1-calibrated_y:calibrated_y;
                            end
                        end
                      end
                    end else settle_count<=settle_count+1;
                end
                default: begin state<=IDLE; request<=0; cs_n<=1; end
            endcase
        end
    end
    // synthesis translate_off
    initial begin
        if(CLK_HZ<1 || POLL_HZ<1 || POLL_HZ>CLK_HZ || SPI_HALF_PERIOD<1 ||
           SPI_HALF_PERIOD>65535 || STABLE_SAMPLES<1 ||
           RAW_X_MIN<0 || RAW_X_MAX>4095 || RAW_X_MAX<=RAW_X_MIN ||
           RAW_Y_MIN<0 || RAW_Y_MAX>4095 || RAW_Y_MAX<=RAW_Y_MIN ||
           WIDTH<1 || WIDTH>512 || HEIGHT<1 || HEIGHT>512 ||
           (SWAP_AXES!=0 && SWAP_AXES!=1) || (INVERT_X!=0 && INVERT_X!=1) ||
           (INVERT_Y!=0 && INVERT_Y!=1)) $fatal(1,"Invalid XPT2046 parameter");
    end
    // synthesis translate_on
endmodule
