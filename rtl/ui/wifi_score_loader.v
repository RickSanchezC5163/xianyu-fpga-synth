`timescale 1ns/1ps
// Standalone byte-handshake loader. No UART, audio or guide reader is instantiated.
// Six logical banks in one synchronous block RAM; reset only invalidates metadata.
module wifi_score_loader #(
    parameter integer GAP_CYCLES=500000,
    parameter integer RESIDENT_SLOTS_ENABLE=1
)(
    input wire clk,rst_n,
    input wire [7:0] rx_byte,input wire rx_valid,
    output wire [7:0] tx_byte,output wire tx_valid,input wire tx_ready,
    input wire guide_playing,
    input wire read_req,input wire [7:0] read_address,
    output reg read_valid,output reg [63:0] read_event,
    output reg active_valid,output reg [8:0] active_count,
    output reg [7:0] active_bpm,output reg [6:0] active_base,
    output reg [31:0] active_token,
    output reg committed,
    output reg [191:0] active_title,
    output reg [4:0] active_title_len,
    output reg [9:0] active_part,active_parts,
    input wire select_valid,input wire [1:0] select_slot,
    output wire select_ready,output reg select_accepted,select_rejected,
    output reg [3:0] resident_valid,
    output wire [767:0] resident_titles,
    output wire [19:0] resident_title_lens,
    output reg [2:0] active_slot
);
    localparam [2:0] RX=0,EXECUTE=1,EVENT_CRC=2,TRANSMIT=3;
    localparam [7:0] OK=0,BAD_FRAME=1,BAD_STATE=2,BAD_ARGUMENT=3,
        BAD_ORDER=4,BAD_CRC=5,BUSY=6;
    localparam integer GW=GAP_CYCLES<2?1:$clog2(GAP_CYCLES);
    reg [2:0] state;
    reg [4:0] rx_index,tx_index;
    reg [GW-1:0] gap_count;
    reg [127:0] request_body,reply_body;
    reg [15:0] rx_crc,tx_crc;
    reg [7:0] rx_crc_low;
    reg frame_good;
    wire [7:0] opcode=request_body[15:8];
    wire [15:0] seq_number=request_body[31:16];
    wire [31:0] argument=request_body[63:32];
    wire [63:0] payload=request_body[127:64];

    reg [2:0] active_bank,staging_bank;
    reg staging_valid,staging_verified;
    reg [2:0] staging_slot;
    reg staging_store_only;
    wire [1:0] staging_slot_index=staging_slot[1:0]-2'd1;
    wire [1:0] query_slot_index=argument[1:0]-2'd1;
    reg [2:0] resident_bank [0:3];
    reg [8:0] resident_count [0:3];
    reg [7:0] resident_bpm [0:3];
    reg [6:0] resident_base [0:3];
    reg [31:0] resident_token [0:3],resident_crc [0:3];
    reg [191:0] resident_title [0:3];
    reg [4:0] resident_title_len [0:3];
    reg [9:0] resident_part [0:3],resident_parts [0:3];
    genvar ri;
    generate for(ri=0;ri<4;ri=ri+1)begin: resident_outputs
        assign resident_titles[ri*192+:192]=resident_title[ri];
        assign resident_title_lens[ri*5+:5]=resident_title_len[ri];
    end endgenerate
    // At most four resident maps and one detached legacy active bank are live.
    // A sixth bank therefore always permits an atomic replacement transaction.
    reg free_bank_valid,bank_used;
    reg [2:0] free_bank;
    integer bi,si,reset_i;
    always @* begin
        free_bank_valid=0;free_bank=0;bank_used=0;
        for(bi=0;bi<(RESIDENT_SLOTS_ENABLE?6:2);bi=bi+1)begin
            bank_used=active_valid && active_bank==bi;
            for(si=0;si<4;si=si+1)
                if(resident_valid[si] && resident_bank[si]==bi)bank_used=1;
            if(!bank_used && !free_bank_valid)begin free_bank=bi;free_bank_valid=1;end
        end
    end
    assign select_ready=RESIDENT_SLOTS_ENABLE && state==RX && rx_index==0 && !rx_valid && !guide_playing;
    wire selection_accept=select_ready && (select_valid===1'b1) && resident_valid[select_slot];
    reg [8:0] staging_count,written;
    reg [7:0] staging_bpm;
    reg [6:0] staging_base;
    reg [31:0] staging_token,expected_crc,rolling_crc,last_tick;
    reg [191:0] staging_title;
    reg [4:0] staging_title_len;
    reg [9:0] staging_part,staging_parts;
    reg staging_meta_required,staging_meta_header,staging_gb_lead;
    reg [1:0] staging_meta_words;
    wire [2:0] required_meta_words=({1'b0,staging_title_len}+6'd7)>>3;
    wire metadata_complete=staging_meta_header && {1'b0,staging_meta_words}==required_meta_words;
    wire metadata_ready=!(staging_meta_required || staging_meta_header) || metadata_complete;
    // Reject bytes that could escape a quoted HMI text assignment. GB2312
    // double-byte state is carried between words, including an eight-byte edge.
    reg meta_bytes_ok,meta_next_lead;
    reg [7:0] meta_byte;
    integer mi;
    always @* begin
        meta_bytes_ok=1;meta_next_lead=staging_gb_lead;meta_byte=0;
        for(mi=0;mi<8;mi=mi+1) begin
            meta_byte=payload[mi*8+:8];
            if(({staging_meta_words,3'b000}+mi)<staging_title_len) begin
                if(meta_next_lead) begin
                    if(meta_byte<8'ha1 || meta_byte>8'hfe)meta_bytes_ok=0;
                    meta_next_lead=0;
                end else if(meta_byte>=8'ha1 && meta_byte<=8'hf7)meta_next_lead=1;
                else if(meta_byte<8'h20 || meta_byte>8'h7e || meta_byte==8'h22 || meta_byte==8'h5c)
                    meta_bytes_ok=0;
            end else if(meta_byte!=0)meta_bytes_ok=0;
        end
        if({1'b0,staging_meta_words}+3'd1==required_meta_words && meta_next_lead)meta_bytes_ok=0;
    end
    reg [63:0] crc_event;
    reg [2:0] crc_event_index;
    reg write_enable;
    reg [2:0] write_bank;
    reg [7:0] write_address;
    reg [63:0] write_event;
    (* syn_ramstyle="block_ram" *) reg [63:0] score_ram [0:RESIDENT_SLOTS_ENABLE?2047:511];
    // Compatibility visibility for older simulation benches; no extra hardware.
    // synthesis translate_off
    wire [63:0] bank0 [0:255];
    wire [63:0] bank1 [0:255];
    genvar sim_i;
    generate for(sim_i=0;sim_i<256;sim_i=sim_i+1)begin: legacy_ram_views
        assign bank0[sim_i]=score_ram[sim_i];
        assign bank1[sim_i]=score_ram[256+sim_i];
    end endgenerate
    // synthesis translate_on
    reg cached_valid;
    reg [127:0] cached_request,cached_reply;
    wire same_seq_number=cached_valid && seq_number==cached_request[31:16];
    wire exact_retry=cached_valid && request_body==cached_request;
    wire token_arguments=argument==0 && payload[63:32]==0 && payload[31:0]==staging_token;
    wire commit_busy=guide_playing && (!staging_store_only ||
        (active_valid && active_slot==staging_slot));
    wire commit_accept=state==EXECUTE && frame_good && !same_seq_number &&
        opcode==4 && token_arguments && staging_valid && staging_verified && metadata_ready && !commit_busy && !staging_store_only;

    function [15:0] crc16_byte;
        input [15:0] previous;input [7:0] value;
        reg [15:0] c;integer k;
        begin c=previous^{8'd0,value};for(k=0;k<8;k=k+1)c=c[0]?(c>>1)^16'ha001:c>>1;crc16_byte=c;end
    endfunction
    function [31:0] crc32_byte;
        input [31:0] previous;input [7:0] value;
        reg [31:0] c;integer k;
        begin c=previous^{24'd0,value};for(k=0;k<8;k=k+1)c=c[0]?(c>>1)^32'hedb88320:c>>1;crc32_byte=c;end
    endfunction
    wire [31:0] next_event_crc=crc32_byte(rolling_crc,crc_event[7:0]);
    assign tx_valid=state==TRANSMIT;
    assign tx_byte=tx_index==0?8'hc7:tx_index==1?8'h3a:
        tx_index<18?(reply_body>>((tx_index-2)*8)):
        tx_index==18?tx_crc[7:0]:tx_crc[15:8];

    // Only accepted validated DATA schedules a write; active RAM is never a target.
    always @(posedge clk) begin
        if(write_enable) score_ram[{write_bank,write_address}]<=write_event;
    end
    wire read_enable=read_req && active_valid && read_address<active_count && !commit_accept && !selection_accept;
    // Do not attach an asynchronous data-output reset to the RAM read port.
    // read_event is meaningful only when read_valid is asserted.
    always @(posedge clk) if(read_enable) begin
        read_event<=score_ram[{active_bank,read_address}];
    end
    always @(posedge clk or negedge rst_n)
        if(!rst_n) read_valid<=0;
        else read_valid<=read_enable;

    task respond;
        input [7:0] status;
        input [8:0] next_index;
        input [31:0] token;
        reg [127:0] response;
        begin
            response={32'd0,token,8'd0,7'd0,next_index,status,seq_number,(opcode|8'h80),8'd1};
            reply_body<=response;tx_index<=0;tx_crc<=16'hffff;state<=TRANSMIT;
            if(status==OK) begin cached_valid<=1;cached_request<=request_body;cached_reply<=response;end
        end
    endtask

    // INFO/TITLE_READ have explicitly typed payloads rather than token ACKs.
    task respond_extended;
        input [31:0] response_arg;
        input [63:0] response_data;
        reg [127:0] response;
        begin
            response={response_data,response_arg,seq_number,(opcode|8'h80),8'd1};
            reply_body<=response;tx_index<=0;tx_crc<=16'hffff;state<=TRANSMIT;
            if(response_arg[7:0]==OK)begin
                cached_valid<=1;cached_request<=request_body;cached_reply<=response;
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=RX;rx_index<=0;tx_index<=0;gap_count<=0;
            request_body<=0;reply_body<=0;rx_crc<=16'hffff;tx_crc<=16'hffff;rx_crc_low<=0;frame_good<=0;
            active_valid<=0;active_bank<=0;active_count<=0;active_bpm<=120;active_base<=48;active_token<=0;
            staging_bank<=1;staging_valid<=0;staging_verified<=0;staging_count<=0;written<=0;
            staging_bpm<=120;staging_base<=48;staging_token<=0;expected_crc<=0;rolling_crc<=32'hffffffff;last_tick<=0;
            active_title<=0;active_title_len<=0;active_part<=0;active_parts<=0;active_slot<=0;
            staging_title<=0;staging_title_len<=0;staging_part<=0;staging_parts<=0;
            staging_meta_required<=0;staging_meta_header<=0;staging_gb_lead<=0;staging_meta_words<=0;
            staging_slot<=0;staging_store_only<=0;resident_valid<=0;
            select_accepted<=0;select_rejected<=0;
            for(reset_i=0;reset_i<4;reset_i=reset_i+1)begin
                resident_bank[reset_i]<=0;resident_count[reset_i]<=0;
                resident_bpm[reset_i]<=0;resident_base[reset_i]<=0;
                resident_token[reset_i]<=0;resident_crc[reset_i]<=0;
                resident_title[reset_i]<=0;resident_title_len[reset_i]<=0;
                resident_part[reset_i]<=0;resident_parts[reset_i]<=0;
            end
            crc_event<=0;crc_event_index<=0;write_enable<=0;write_bank<=0;write_address<=0;write_event<=0;
            cached_valid<=0;cached_request<=0;cached_reply<=0;
            committed<=0;
        end else begin
            write_enable<=0;
            committed<=0;select_accepted<=0;select_rejected<=0;
            if(select_ready && (select_valid===1'b1))begin
                if(resident_valid[select_slot])begin
                    active_valid<=1;active_bank<=resident_bank[select_slot];
                    active_count<=resident_count[select_slot];active_bpm<=resident_bpm[select_slot];
                    active_base<=resident_base[select_slot];active_token<=resident_token[select_slot];
                    active_title<=resident_title[select_slot];active_title_len<=resident_title_len[select_slot];
                    active_part<=resident_part[select_slot];active_parts<=resident_parts[select_slot];
                    active_slot<={1'b0,select_slot}+3'd1;committed<=1;select_accepted<=1;
                end else select_rejected<=1;
            end
            case(state)
                RX:begin
                    if(rx_valid) begin
                        gap_count<=0;
                        if(rx_index==0) begin if(rx_byte==8'hc7)rx_index<=1;end
                        else if(rx_index==1) begin
                            if(rx_byte==8'h3a)begin rx_index<=2;rx_crc<=16'hffff;end
                            else if(rx_byte!=8'hc7)rx_index<=0;
                        end else if(rx_index<18)begin
                            request_body[(rx_index-2)*8+:8]<=rx_byte;
                            rx_crc<=crc16_byte(rx_crc,rx_byte);rx_index<=rx_index+1'b1;
                        end else if(rx_index==18)begin rx_crc_low<=rx_byte;rx_index<=19;end
                        else begin
                            frame_good<=request_body[7:0]==1 && rx_crc=={rx_byte,rx_crc_low};
                            rx_index<=0;state<=EXECUTE;
                        end
                    end else if(rx_index!=0) begin
                        if(gap_count==GAP_CYCLES-1)begin rx_index<=0;gap_count<=0;end
                        else gap_count<=gap_count+1'b1;
                    end
                end
                EXECUTE:begin
                    if(!frame_good)begin
                        if(opcode==10 || opcode==11)respond_extended({24'd0,BAD_FRAME},0);
                        else respond(BAD_FRAME,written,staging_valid?staging_token:active_token);
                    end
                    else if(exact_retry)begin reply_body<=cached_reply;tx_index<=0;tx_crc<=16'hffff;state<=TRANSMIT;end
                    else if(same_seq_number)begin
                        if(opcode==10 || opcode==11)respond_extended({24'd0,BAD_ARGUMENT},0);
                        else respond(BAD_ARGUMENT,written,staging_valid?staging_token:active_token);
                    end
                    else case(opcode)
                        1:begin
                            if(argument[15:0]<2 || argument[15:0]>256 ||
                               argument[23:16]<30 || argument[23:16]>240 || argument[30:24]>103)
                                respond(BAD_ARGUMENT,written,staging_valid?staging_token:active_token);
                            else if(!free_bank_valid)respond(BUSY,written,staging_valid?staging_token:active_token);
                            else begin
                                staging_valid<=1;staging_verified<=0;staging_bank<=free_bank;
                                staging_slot<=0;staging_store_only<=0;
                                staging_count<=argument[8:0];staging_bpm<=argument[23:16];staging_base<=argument[30:24];
                                expected_crc<=payload[31:0];staging_token<=payload[63:32];written<=0;
                                rolling_crc<=32'hffffffff;last_tick<=0;
                                staging_meta_required<=argument[31];staging_meta_header<=0;
                                staging_title<=0;staging_title_len<=0;staging_part<=0;staging_parts<=0;
                                staging_gb_lead<=0;staging_meta_words<=0;
                                respond(OK,0,payload[63:32]);
                            end
                        end
                        2:begin
                            if(!staging_valid || staging_verified || !metadata_ready)respond(BAD_STATE,written,staging_token);
                            else if(argument[31:16]!=0 || argument[15:0]!=written || written>=staging_count)
                                respond(BAD_ORDER,written,staging_token);
                            else if(payload[63:57]!=0 || (written==0 && payload[31:0]!=0) ||
                                    (written!=0 && payload[31:0]<=last_tick) ||
                                    (written==staging_count-1 && payload[56:32]!=0))
                                respond(BAD_ARGUMENT,written,staging_token);
                            else begin
                                write_enable<=1;write_bank<=staging_bank;write_address<=written[7:0];write_event<=payload;
                                crc_event<=payload;crc_event_index<=0;last_tick<=payload[31:0];state<=EVENT_CRC;
                            end
                        end
                        3:begin
                            if(!staging_valid || !metadata_ready)respond(BAD_STATE,written,staging_token);
                            else if(!token_arguments)respond(BAD_ARGUMENT,written,staging_token);
                            else if(written!=staging_count)respond(BAD_STATE,written,staging_token);
                            else if((rolling_crc^32'hffffffff)!=expected_crc)respond(BAD_CRC,written,staging_token);
                            else begin staging_verified<=1;respond(OK,written,staging_token);end
                        end
                        4:begin
                            if(!staging_valid || !staging_verified)respond(BAD_STATE,written,staging_token);
                            else if(!token_arguments)respond(BAD_ARGUMENT,written,staging_token);
                            else if(commit_busy)respond(BUSY,written,staging_token);
                            else begin
                                if(staging_slot!=0)begin
                                    resident_valid[staging_slot_index]<=1;
                                    resident_bank[staging_slot_index]<=staging_bank;
                                    resident_count[staging_slot_index]<=staging_count;
                                    resident_bpm[staging_slot_index]<=staging_bpm;
                                    resident_base[staging_slot_index]<=staging_base;
                                    resident_token[staging_slot_index]<=staging_token;
                                    resident_crc[staging_slot_index]<=expected_crc;
                                    resident_title[staging_slot_index]<=staging_title;
                                    resident_title_len[staging_slot_index]<=staging_title_len;
                                    resident_part[staging_slot_index]<=staging_part;
                                    resident_parts[staging_slot_index]<=staging_parts;
                                end
                                if(!staging_store_only)begin
                                    active_valid<=1;active_bank<=staging_bank;active_count<=staging_count;
                                    active_bpm<=staging_bpm;active_base<=staging_base;active_token<=staging_token;
                                    active_title<=staging_title;active_title_len<=staging_title_len;
                                    active_part<=staging_part;active_parts<=staging_parts;active_slot<=staging_slot;
                                    committed<=1;
                                end else if(active_slot!=0 && active_slot==staging_slot)
                                    // Stored replacement does not switch the active bank.
                                    active_slot<=0;
                                staging_valid<=0;staging_verified<=0;
                                respond(OK,written,staging_token);
                            end
                        end
                        5:begin
                            if(!staging_valid)respond(BAD_STATE,written,staging_token);
                            else if(!token_arguments)respond(BAD_ARGUMENT,written,staging_token);
                            else begin staging_valid<=0;staging_verified<=0;written<=0;respond(OK,0,staging_token);end
                        end
                        6:begin
                            if(argument!=0 || payload!=0)respond(BAD_ARGUMENT,written,staging_valid?staging_token:active_token);
                            else respond(OK,staging_valid?written:9'd0,staging_valid?staging_token:active_token);
                        end
                        7:begin
                            if(!staging_valid || staging_verified || written!=0)
                                respond(BAD_STATE,written,staging_token);
                            else if(argument==0)begin
                                if(payload[31:0]!=staging_token || payload[63:61]!=0 ||
                                   payload[59:57]>4 || (payload[60] && payload[59:57]==0) ||
                                   (!RESIDENT_SLOTS_ENABLE && payload[60:57]!=0) ||
                                   payload[36:32]<1 || payload[36:32]>24 ||
                                   payload[46:37]<1 || payload[46:37]>999 ||
                                   payload[56:47]<payload[46:37] || payload[56:47]>999)
                                    respond(BAD_ARGUMENT,written,staging_token);
                                else begin
                                    staging_title<=0;staging_title_len<=payload[36:32];
                                    staging_part<=payload[46:37];staging_parts<=payload[56:47];
                                    staging_slot<=payload[59:57];staging_store_only<=payload[60];
                                    staging_meta_header<=1;staging_gb_lead<=0;staging_meta_words<=0;
                                    respond(OK,written,staging_token);
                                end
                            end else if(!staging_meta_header || argument>3 ||
                                        argument!={30'd0,staging_meta_words}+32'd1 ||
                                        {1'b0,staging_meta_words}>=required_meta_words)
                                respond(BAD_ORDER,written,staging_token);
                            else if(!meta_bytes_ok)respond(BAD_ARGUMENT,written,staging_token);
                            else begin
                                staging_title[staging_meta_words*64+:64]<=payload;
                                staging_meta_words<=staging_meta_words+1'b1;staging_gb_lead<=meta_next_lead;
                                respond(OK,written,staging_token);
                            end
                        end
                        8:begin
                            if(argument!=0 || payload!=0)respond_extended({24'd0,BAD_ARGUMENT},0);
                            else if(!active_valid)respond_extended(0,0);
                            else respond_extended(
                                {9'd0,active_title_len,active_count,1'b1,8'd0},
                                {1'b0,active_slot,active_bpm,active_parts,active_part,active_token});
                        end
                        9:begin
                            if(argument>2 || payload[63:32]!=0)respond_extended({24'd0,BAD_ARGUMENT},0);
                            else if(!active_valid || payload[31:0]!=active_token)respond_extended({24'd0,BAD_STATE},0);
                            else respond_extended(0,active_title[argument[1:0]*64+:64]);
                        end
                        10:begin
                            if(!RESIDENT_SLOTS_ENABLE || argument>4 || payload!=0)
                                respond_extended({24'd0,BAD_ARGUMENT},0);
                            else if(argument==0)
                                respond_extended({20'd0,resident_valid,8'd0},{61'd0,active_slot});
                            else respond_extended({23'd0,resident_valid[query_slot_index],8'd0},
                                {resident_token[query_slot_index],resident_crc[query_slot_index]});
                        end
                        11:begin
                            if(!RESIDENT_SLOTS_ENABLE || argument>3 || payload!=0)
                                respond_extended({24'd0,BAD_ARGUMENT},0);
                            else begin
                                resident_valid[argument[1:0]]<=0;
                                resident_bank[argument[1:0]]<=0;resident_count[argument[1:0]]<=0;
                                resident_bpm[argument[1:0]]<=0;resident_base[argument[1:0]]<=0;
                                resident_token[argument[1:0]]<=0;resident_crc[argument[1:0]]<=0;
                                resident_title[argument[1:0]]<=0;resident_title_len[argument[1:0]]<=0;
                                resident_part[argument[1:0]]<=0;resident_parts[argument[1:0]]<=0;
                                if(active_slot=={1'b0,argument[1:0]}+3'd1)active_slot<=0;
                                respond_extended(0,0);
                            end
                        end
                        default:respond(BAD_ARGUMENT,written,staging_valid?staging_token:active_token);
                    endcase
                end
                EVENT_CRC:begin
                    rolling_crc<=next_event_crc;crc_event<=crc_event>>8;
                    if(crc_event_index==7)begin written<=written+1'b1;respond(OK,written+1'b1,staging_token);end
                    else crc_event_index<=crc_event_index+1'b1;
                end
                TRANSMIT:if(tx_ready)begin
                    if(tx_index>=2 && tx_index<18)tx_crc<=crc16_byte(tx_crc,tx_byte);
                    if(tx_index==19)begin tx_index<=0;state<=RX;end
                    else tx_index<=tx_index+1'b1;
                end
                default:state<=RX;
            endcase
        end
    end
    // synthesis translate_off
    initial if(GAP_CYCLES<1)$fatal(1,"wifi_score_loader invalid gap timeout");
    always @(posedge clk)if(rst_n && write_enable && active_valid && write_bank==active_bank)
        $fatal(1,"wifi_score_loader attempted active-bank write");
    // synthesis translate_on
endmodule
