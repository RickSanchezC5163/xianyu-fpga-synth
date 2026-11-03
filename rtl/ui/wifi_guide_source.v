`timescale 1ns/1ps
// Independent UART upload port and a synchronous ROM/RAM event reader.
// Musical time is supplied by the existing guide_transport; no clock is added.
module wifi_guide_source #(
    parameter integer UART_CLKS_PER_BIT=434,
    parameter integer GAP_CYCLES=500000,
    parameter integer PREVIEW_TICKS=24,ENABLE_WAIT_MODE=0
)(
    input wire clk,rst_n,wifi_rx,output wire wifi_tx,
    input wire start,stop,playing,paused,loop_enable,
    input wire [31:0] song_tick,
    output wire [24:0] expected_keys,output wire [24:0] preview_keys,
    output wire finish,loop_restart,
    output wire active_present,committed,
    output wire [8:0] active_count,output wire [7:0] active_bpm,
    output wire [6:0] active_base,output wire [31:0] active_token,
    input wire wait_mode,target_hit,output wire target_pulse,unsupported,
    output wire [191:0] active_title,output wire [4:0] active_title_len,
    output wire [9:0] active_part,active_parts,
    input wire select_valid,input wire [1:0] select_slot,
    output wire select_ready,select_accepted,select_rejected,
    output wire [3:0] resident_valid,output wire [767:0] resident_titles,
    output wire [19:0] resident_title_lens,output wire [2:0] active_slot
);
    wire [7:0] rx_data,tx_data;
    wire rx_valid,rx_error,tx_valid,tx_ready;
    uart_rx #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) receiver(
        .clk(clk),.rst_n(rst_n),.rx(wifi_rx),.data(rx_data),.valid(rx_valid),.framing_error(rx_error));
    uart_tx #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) transmitter(
        .clk(clk),.rst_n(rst_n),.data(tx_data),.valid(tx_valid),.tx(wifi_tx),.ready(tx_ready));
    wire source_req;
    wire [7:0] source_address;
    wire ram_valid;
    wire [63:0] ram_event;
    wifi_score_loader #(.GAP_CYCLES(GAP_CYCLES)) loader(
        .clk(clk),.rst_n(rst_n),.rx_byte(rx_data),.rx_valid(rx_valid && !rx_error),
        .tx_byte(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready),.guide_playing(playing),
        .read_req(source_req && active_present),.read_address(source_address),
        .read_valid(ram_valid),.read_event(ram_event),
        .active_valid(active_present),.active_count(active_count),.active_bpm(active_bpm),
        .active_base(active_base),.active_token(active_token),.committed(committed),
        .active_title(active_title),.active_title_len(active_title_len),.active_part(active_part),.active_parts(active_parts),
        .select_valid(select_valid),.select_slot(select_slot),.select_ready(select_ready),
        .select_accepted(select_accepted),.select_rejected(select_rejected),
        .resident_valid(resident_valid),.resident_titles(resident_titles),
        .resident_title_lens(resident_title_lens),.active_slot(active_slot));
    wire [31:0] rom_tick;
    wire [24:0] rom_keys;
    wire rom_last;
    guide_score_rom rom(.address(source_address[3:0]),.at_tick(rom_tick),.keys(rom_keys),.last(rom_last));
    reg rom_valid;
    reg [63:0] rom_event;
    always @(posedge clk or negedge rst_n)
        if(!rst_n)begin rom_valid<=0;rom_event<=0;end
        else begin
            rom_valid<=source_req && !active_present;
            if(source_req && !active_present)rom_event<={7'd0,rom_keys,rom_tick};
        end
    wire source_valid=active_present?ram_valid:rom_valid;
    wire [63:0] source_event=active_present?ram_event:rom_event;
    wire [8:0] source_count=active_present?active_count:9'd16;
    guide_event_player #(.ENABLE_WAIT_MODE(ENABLE_WAIT_MODE),.PREVIEW_TICKS(PREVIEW_TICKS)) player(
        .clk(clk),.rst_n(rst_n),.start(start),.stop(stop),.playing(playing),.paused(paused),
        .loop_enable(loop_enable),.source_changed(committed),.song_tick(song_tick),.source_count(source_count),
        .read_req(source_req),.read_address(source_address),.read_valid(source_valid),.read_event(source_event),
        .wait_mode(wait_mode),.target_hit(target_hit),.expected_keys(expected_keys),.preview_keys(preview_keys),
        .finish(finish),.loop_restart(loop_restart),.target_pulse(target_pulse),.unsupported(unsupported));
endmodule
