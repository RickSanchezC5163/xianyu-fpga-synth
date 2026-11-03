`timescale 1ns/1ps
// Standalone screen front-end. Board pin allocation and audio/guide top-level
// wiring are intentionally separate from this verified reusable block.
module tjc_uart_panel #(
    parameter integer CLKS_PER_BIT=434,
    parameter integer REFRESH_CYCLES=10000000,
    parameter integer GAP_CYCLES=500000,
    parameter integer ACK_TIMEOUT_CYCLES=50000,
    parameter integer TELEMETRY_ENABLE=0,
    parameter integer CYCLES_PER_US=50,
    parameter integer ENV_PLOT_ENABLE=0,
    parameter integer AUTO_FAST_BAUD=0,
    parameter integer FAST_CLKS_PER_BIT=54,
    parameter integer FAST_REFRESH_CYCLES=5000000,
    // Experimental raw transfer stays off: real screen navigation can abandon
    // FE/FD and wedge that protocol. Production uses cancellable ASCII scrolling.
    parameter integer WAVE_BULK_ENABLE=0,
    parameter integer BULK_TIMEOUT_CYCLES=5000000,
    parameter integer LINK_BOOT_CYCLES=50000000,
    parameter integer LINK_RESPONSE_CYCLES=5000000,
    parameter integer LINK_RETRY_CYCLES=12500000,
    parameter integer LINK_HEARTBEAT_CYCLES=50000000,
    parameter integer LINK_SETTLE_CYCLES=1000000,
    parameter integer SCORE_METADATA_ENABLE=0,NATIVE_SLOTS_ENABLE=0
)(
    input wire clk,rst_n,screen_rx,output wire screen_tx,
    input wire context_ready,urgent_stop,input wire [7:0] score_count,
    output wire param_valid,output wire [3:0] param_id,output wire [15:0] param_value,
    input wire param_ack,param_rejected,
    input wire [1:0] register_patch,input wire [7:0] register_volume,input wire [27:0] register_adsr,
    output wire guide_valid,output wire [2:0] guide_id,output wire [15:0] guide_value,
    input wire guide_playing,guide_paused,guide_loop,input wire [7:0] guide_bpm,
    output wire [2:0] page_id,last_result,
    output wire [31:0] crc_errors,format_errors,gap_timeouts,rejected_count,
    input wire sample_valid,input wire signed [15:0] sample_pcm,
    input wire control_note_on,latency_valid,latency_timeout,latency_rejected,
    input wire [31:0] latency_cycles,latency_max_cycles,missed_deadline_count,
    input wire window_valid,input wire [31:0] samples_in_window,
    output wire [31:0] debug_rx_counts,
    output wire display_transfer_fault,
    input wire score_active_present,input wire [191:0] score_title,
    input wire [4:0] score_title_len,input wire [9:0] score_part,score_parts,
    input wire [3:0] resident_valid,input wire [767:0] resident_titles,
    input wire [19:0] resident_title_lens,input wire [2:0] active_slot,input wire [1:0] guide_beat_index
);
    wire rx_valid,rx_error,event_valid,bridge_refresh,tx_valid,tx_ready,snapshot_busy,pending;
    wire [7:0] rx_data,kind,id,tx_data;
    wire [31:0] value;
    wire link_online,link_allow_new,link_command_owns,link_command_valid,link_page_notice;
    wire [2:0] link_page;
    wire [7:0] link_command_data;
    wire fast_tx,fast_ready,negotiated_tx;
    wire permit_new=!AUTO_FAST_BAUD || link_allow_new;
    wire context_link=context_ready && (!AUTO_FAST_BAUD || link_online);
    reg [15:0] byte_count,event_count;
    always @(posedge clk or negedge rst_n)
        if(!rst_n) begin byte_count<=0;event_count<=0;end
        else begin
            if(rx_valid) byte_count<=byte_count+1'b1;
            if(event_valid) event_count<=event_count+1'b1;
        end
    assign debug_rx_counts={byte_count,event_count};
    uart_rx #(.CLKS_PER_BIT(AUTO_FAST_BAUD?FAST_CLKS_PER_BIT:CLKS_PER_BIT)) receiver(clk,rst_n,screen_rx,rx_data,rx_valid,rx_error);
    tjc_event_rx #(.GAP_CYCLES(GAP_CYCLES)) decoder(clk,rst_n,rx_valid,rx_data,rx_error,
        event_valid,kind,id,value,crc_errors,format_errors,gap_timeouts);
    wire accepted_event=event_valid && (!AUTO_FAST_BAUD || link_online);
    reg page_sync_pending;reg [2:0] sync_page;
    wire page_sync=AUTO_FAST_BAUD && page_sync_pending && !accepted_event;
    always @(posedge clk or negedge rst_n)
        if(!rst_n)begin page_sync_pending<=0;sync_page<=0;end
        else begin
            // A real new touch wins over a slightly older sendme reply.
            if(accepted_event && kind==3)page_sync_pending<=0;
            else if(AUTO_FAST_BAUD && link_page_notice)begin page_sync_pending<=1;sync_page<=link_page;end
            else if(page_sync)page_sync_pending<=0;
        end
    tjc_control_bridge #(.ACK_TIMEOUT_CYCLES(ACK_TIMEOUT_CYCLES)) control(clk,rst_n,accepted_event|page_sync,
        page_sync?8'd3:kind,page_sync?{5'd0,sync_page}:id,page_sync?32'd0:value,
        context_link,urgent_stop,score_count,param_valid,param_id,param_value,param_ack,param_rejected,
        guide_valid,guide_id,guide_value,bridge_refresh,page_id,last_result,rejected_count,pending);
    localparam integer PERIOD=AUTO_FAST_BAUD?FAST_REFRESH_CYCLES:REFRESH_CYCLES;
    localparam integer RW=PERIOD<2?1:$clog2(PERIOD);
    reg [RW-1:0] refresh_count;
    reg refresh_pending,refresh_request;
    reg telemetry_pending,telemetry_request;
    reg env_pending,env_request;
    reg metadata_pending,metadata_request;
    reg [27:0] display_adsr;
    reg env_sent;reg [27:0] env_last_adsr;
    wire telemetry_busy,telemetry_valid;
    wire env_busy,env_valid;wire [7:0] env_data;
    wire [7:0] telemetry_data;
    wire snapshot_valid;wire [7:0] snapshot_data;
    wire metadata_busy,metadata_valid;wire [7:0] metadata_data;
    wire producer_idle=!snapshot_busy && !telemetry_busy && !env_busy && !metadata_busy &&
        !refresh_request && !telemetry_request && !env_request && !metadata_request;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin refresh_count<=0;refresh_pending<=1;refresh_request<=0;telemetry_pending<=0;telemetry_request<=0;
            env_pending<=0;env_request<=0;display_adsr<=0;env_sent<=0;env_last_adsr<=0;
            metadata_pending<=0;metadata_request<=0;end
        else begin
            refresh_request<=0;telemetry_request<=0;env_request<=0;
            metadata_request<=0;
            if(refresh_request)display_adsr<=register_adsr;
            if(page_id!=1)env_sent<=0;
            else if(env_request)begin env_sent<=1;env_last_adsr<=display_adsr;end
            // Each snapshot grants the following turn to telemetry, even when
            // incoming queries keep refresh_pending asserted continuously.
            if(permit_new && producer_idle && env_pending)begin
                env_request<=1;env_pending<=0;
            end else if(permit_new && producer_idle && metadata_pending)begin
                metadata_request<=page_id==2 || page_id==5;metadata_pending<=0;
            end else if(permit_new && producer_idle && telemetry_pending) begin
                telemetry_request<=1;telemetry_pending<=0;
            end else if(permit_new && producer_idle && refresh_pending) begin
                refresh_request<=1;refresh_pending<=0;telemetry_pending<=TELEMETRY_ENABLE!=0;
                metadata_pending<=SCORE_METADATA_ENABLE!=0 && (page_id==2 || page_id==5);
                // Only redraw on entry/parameter change, not every snapshot.
                env_pending<=ENV_PLOT_ENABLE && page_id==1 && (!env_sent || env_last_adsr!=register_adsr);
            end
            if(refresh_count==PERIOD-1) begin refresh_count<=0;refresh_pending<=1;end
            else refresh_count<=refresh_count+1'b1;
            if(bridge_refresh || urgent_stop) refresh_pending<=1;
        end
    end
    tjc_snapshot_tx #(.ENV_READOUT_ENABLE(1),.NATIVE_SLOTS_ENABLE(NATIVE_SLOTS_ENABLE)) snapshot(clk,rst_n,refresh_request,register_patch,register_volume,register_adsr,
        context_link,last_result,guide_playing,guide_paused,guide_loop,guide_bpm,
        snapshot_busy,snapshot_valid,snapshot_data,tx_ready && !telemetry_busy && !env_busy && !metadata_busy,page_id,
        resident_valid,active_slot,guide_beat_index);
    generate if(SCORE_METADATA_ENABLE)begin: score_metadata
        tjc_score_meta_tx #(.NATIVE_SLOTS_ENABLE(NATIVE_SLOTS_ENABLE)) metadata(clk,rst_n,metadata_request,page_id,
            score_active_present,score_title,score_title_len,score_part,score_parts,
            guide_bpm,guide_playing,guide_paused,context_link,
            metadata_busy,metadata_valid,metadata_data,tx_ready && !snapshot_busy && !telemetry_busy && !env_busy,
            resident_valid,resident_titles,resident_title_lens);
    end else begin: no_score_metadata
        assign metadata_busy=0;assign metadata_valid=0;assign metadata_data=0;
    end endgenerate
    generate if(ENV_PLOT_ENABLE)begin: env_display
        tjc_env_plot_tx env_plot(clk,rst_n,env_request,page_id,display_adsr,
            env_busy,env_valid,env_data,tx_ready && !snapshot_busy && !telemetry_busy && !metadata_busy);
    end else begin: no_env_display
        assign env_busy=0;assign env_valid=0;assign env_data=0;
    end endgenerate
    generate if(TELEMETRY_ENABLE) begin: telemetry_enabled
        tjc_telemetry_tx #(.CYCLES_PER_US(CYCLES_PER_US),.WAVE_BULK_ENABLE(WAVE_BULK_ENABLE),
            .WAVE_SCROLL_ENABLE(AUTO_FAST_BAUD),
            .TRANSFER_TIMEOUT_CYCLES(BULK_TIMEOUT_CYCLES)) telemetry(
            clk,rst_n,telemetry_request,page_id,sample_valid,sample_pcm,
            control_note_on,latency_valid,latency_timeout,latency_rejected,
            latency_cycles,latency_max_cycles,missed_deadline_count,window_valid,samples_in_window,
            telemetry_busy,telemetry_valid,telemetry_data,tx_ready && !snapshot_busy && !env_busy && !metadata_busy,
            rx_valid,rx_error,rx_data,display_transfer_fault);
    end else begin: telemetry_disabled
        assign telemetry_busy=0;assign telemetry_valid=0;assign telemetry_data=0;
        assign display_transfer_fault=0;
    end endgenerate
    assign tx_valid=metadata_busy?metadata_valid:env_busy?env_valid:telemetry_busy?telemetry_valid:snapshot_valid;
    assign tx_data=metadata_busy?metadata_data:env_busy?env_data:telemetry_busy?telemetry_data:snapshot_data;
    tjc_high_speed_link #(.SLOW_CLKS_PER_BIT(CLKS_PER_BIT),.BOOT_CYCLES(LINK_BOOT_CYCLES),
        .RESPONSE_CYCLES(LINK_RESPONSE_CYCLES),.RETRY_CYCLES(LINK_RETRY_CYCLES),
        .HEARTBEAT_CYCLES(LINK_HEARTBEAT_CYCLES),.SETTLE_CYCLES(LINK_SETTLE_CYCLES)) link_manager(
        .clk(clk),.rst_n(rst_n && AUTO_FAST_BAUD!=0),.screen_rx(screen_rx),
        .fast_rx_data(rx_data),.fast_rx_valid(rx_valid),.fast_rx_error(rx_error),
        .panel_idle(producer_idle),.fast_tx_ready(fast_ready),.fast_tx(fast_tx),
        .fast_command_valid(link_command_valid),.fast_command_data(link_command_data),
        .command_owns_fast(link_command_owns),.allow_new(link_allow_new),.screen_tx(negotiated_tx),
        .online(link_online),.page_notice(link_page_notice),.observed_page(link_page));
    wire send_command=AUTO_FAST_BAUD && link_command_owns;
    uart_tx #(.CLKS_PER_BIT(AUTO_FAST_BAUD?FAST_CLKS_PER_BIT:CLKS_PER_BIT)) transmitter(
        clk,rst_n,send_command?link_command_data:tx_data,
        send_command?link_command_valid:(tx_valid && (!AUTO_FAST_BAUD || link_online)),fast_tx,fast_ready);
    assign tx_ready=fast_ready && !send_command && (!AUTO_FAST_BAUD || link_online);
    assign screen_tx=AUTO_FAST_BAUD?negotiated_tx:fast_tx;
    // synthesis translate_off
    initial if(CLKS_PER_BIT<4 || CLKS_PER_BIT>65535 || REFRESH_CYCLES<1)
        $fatal(1,"tjc_uart_panel invalid timing parameters");
    // synthesis translate_on
endmodule
