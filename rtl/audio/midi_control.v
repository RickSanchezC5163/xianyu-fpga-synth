// Framed UART control and timestamped MIDI-note scheduler. No CPU or PCM stream.
// Request: A5, command, eight data bytes, XOR(command and data).
// Reply:   5A, command, result, flags, free slots, volume, frame[31:0], XOR.
module midi_control #(
    parameter integer CLKS_PER_BIT=434,
    parameter integer INTERBYTE_TIMEOUT=500000,
    parameter integer VOICES=4,
    parameter integer STEAL_ON_FULL=1,
    parameter integer QUEUE_BSRAM=0,
    parameter integer ENABLE_DIAGNOSTICS=0
) (
    input wire clk, input wire rst_n, input wire rx, output wire tx,
    input wire sample_tick, input wire audio_ready, input wire audio_overrun,
    input wire usb_dp_stable,input wire usb_dm_stable,
    input wire usb_connected,input wire usb_note_valid,
    input wire [6:0] usb_note,input wire [6:0] usb_velocity,
    input wire [3:0] usb_channel,input wire [1:0] usb_patch_select,
    input wire usb_mod_valid,input wire [6:0] usb_mod_depth,
    input wire usb_bend_valid,input wire [13:0] usb_bend_word,
    input wire usb_play,input wire usb_stop,input wire usb_record,
    input wire usb_knob_a_valid,input wire [2:0] usb_knob_a_index,
    input wire [6:0] usb_knob_a_value,
    input wire usb_knob_b_valid,input wire [2:0] usb_knob_b_index,
    input wire [6:0] usb_knob_b_value,
    input wire usb_pad_b_valid,input wire [6:0] usb_pad_b_note,
    output reg host_mode, output reg playing, output reg paused,
    output reg bell, output reg [7:0] volume,
    output reg [6:0] effect_mix, output reg [6:0] effect_feedback,
    output reg [63:0] adsr_values,
    output reg [VOICES-1:0] gates,
    // Note-on generation survives gate changes between audio snapshots.
    output reg [VOICES*8-1:0] voice_epochs,
    output reg [VOICES*2-1:0] voice_patches,
    output reg [VOICES*7-1:0] voice_velocities,
    output wire [VOICES*32-1:0] frequency_words,
    output wire synth_tick, output reg [31:0] frame_index,
    output reg [6:0] queue_count,
    // Optional synchronous UI writes. Legacy tops may leave these inputs open.
    input wire ui_param_valid, input wire [3:0] ui_param_id,
    input wire [15:0] ui_param_value,
    output reg ui_param_ack, output reg ui_param_rejected,
    output reg [27:0] adsr_controls,
    output wire [1:0] configured_patch,
    output reg note_on_accepted,
    // Optional board-level, read-only words for physical link diagnostics.
    input wire [127:0] hardware_diagnostics
);
    localparam [7:0] SET_SOUND=8'h10, NOTE_EVENT=8'h11,
                     SET_CHANNEL_SOUND=8'h12, BEND_LEAD=8'h13,
                     SET_EFFECT=8'h14, SET_MOD=8'h15, SET_ADSR=8'h16,
                     PLAY=8'h20, PAUSE=8'h21, STOP=8'h22, STATUS=8'h23,
                     USB_STATUS=8'h24, CONTROL_STATUS=8'h25;
    localparam [7:0] OK=0, BAD_CRC=1, BAD_COMMAND=2, BAD_ARGUMENT=3,
                     BUSY=4, FULL=5, OUT_OF_ORDER=6;
    wire [7:0] rx_byte;
    wire rx_valid, rx_error;
    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) receiver
        (clk,rst_n,rx,rx_byte,rx_valid,rx_error);
    wire tx_ready;
    wire [7:0] tx_byte;
    wire tx_valid;
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) transmitter
        (clk,rst_n,tx_byte,tx_valid,tx,tx_ready);

    reg [3:0] byte_index;
    reg [7:0] command, checksum;
    reg [7:0] payload [0:7];
    reg [19:0] interbyte_count;
    wire frame_done=rx_valid && byte_index==4'd10;
    wire good_crc=rx_byte==checksum;
    wire [31:0] event_time={payload[3],payload[2],payload[1],payload[0]};
    wire event_args_ok=payload[4]<8'd128 && payload[5]<8'd128 &&
                       payload[6]<8'd16 && payload[7]==0;
    // Fold the zero-argument predicate while receiving payload bytes. The
    // checksum arrives later, so STOP/PLAY validation needs no64-bit tree on
    // the high-fanout voice-register enable path. Commit timing is unchanged.
    reg zero_args;
    wire control_status_args_ok=payload[0]<(ENABLE_DIAGNOSTICS ? 8'd9 : 8'd5) && payload[1]==0 &&
                    payload[2]==0 && payload[3]==0 && payload[4]==0 &&
                    payload[5]==0 && payload[6]==0 && payload[7]==0;
    wire bend_args_ok=payload[0]<8'd128 && payload[1]<8'd128 &&
                      payload[2]<8'd16 && payload[3]==0 && payload[4]==0 &&
                      payload[5]==0 && payload[6]==0 && payload[7]==0;
    wire effect_args_ok=payload[0]<=8'd64 && payload[1]<=8'd64 &&
                        payload[2]==0 && payload[3]==0 && payload[4]==0 &&
                        payload[5]==0 && payload[6]==0 && payload[7]==0;
    wire mod_args_ok=payload[0]<8'd128 && payload[1]<8'd16 &&
                     payload[2]==0 && payload[3]==0 && payload[4]==0 &&
                     payload[5]==0 && payload[6]==0 && payload[7]==0;
    wire adsr_args_ok=payload[0]<8'd128 && payload[1]<8'd128 &&
                      payload[2]<8'd128 && payload[3]<8'd128 &&
                      payload[4]==0 && payload[5]==0 && payload[6]==0 &&
                      payload[7]==0;
    wire [13:0] bend_request={payload[1][6:0],payload[0][6:0]};
    reg [31:0] last_enqueued_time;
    wire request_stop=(frame_done && good_crc && command==STOP && zero_args) ||
                      (usb_connected && usb_stop);
    wire push=frame_done && good_crc && command==NOTE_EVENT &&
              event_args_ok && queue_count<7'd64 &&
              event_time>=last_enqueued_time;

    reg [5:0] read_ptr, write_ptr;
    wire [49:0] queue_head;
    wire queue_head_valid;
    generate if(QUEUE_BSRAM) begin: block_queue
        // One clock, separate read/write ports. Payload has no reset; empty
        // count plus cached-address validity prevent stale data after flush.
        reg [49:0] memory [0:63] /* synthesis syn_ramstyle="block_ram" */;
        reg [49:0] head;
        reg [5:0] head_address;
        reg head_valid;
        always @(posedge clk) begin
            if(rst_n && push && !request_stop)
                memory[write_ptr]<={event_time,payload[4][6:0],payload[5][6:0],payload[6][3:0]};
            head<=memory[read_ptr];
        end
        always @(posedge clk or negedge rst_n)
            if(!rst_n) begin head_address<=0;head_valid<=0;end
            else begin
                head_address<=read_ptr;
                head_valid<=queue_count!=0 && !request_stop;
            end
        assign queue_head=head;
        assign queue_head_valid=head_valid && head_address==read_ptr;
    end else begin: register_queue
        reg [49:0] memory [0:63];
        always @(posedge clk)
            if(rst_n && push && !request_stop)
                memory[write_ptr]<={event_time,payload[4][6:0],payload[5][6:0],payload[6][3:0]};
        assign queue_head=memory[read_ptr];
        assign queue_head_valid=1'b1;
    end endgenerate
    wire pop=sample_tick && playing && !paused && !usb_connected && queue_count!=0 &&
             queue_head_valid && queue_head[49:18]<=frame_index && !request_stop;
    reg late_event;
    reg [31:0] note_frequency [0:127];
    initial $readmemh("midi_increments.hex",note_frequency);
    reg [31:0] voice_frequency [0:VOICES-1];
    reg [6:0] voice_note [0:VOICES-1];
    reg [6:0] voice_pitch_note [0:VOICES-1];
    reg [3:0] voice_channel [0:VOICES-1];
    reg [31:0] channel_patches;
    reg [1:0] global_patch;
    assign configured_patch=global_patch;
    reg [15:0] voice_age [0:VOICES-1];
    reg [15:0] age_counter;
    reg [4:0] lead_voice [0:15];
    reg [15:0] lead_valid;
    reg [2:0] bend_stage;
    reg [4:0] bend_voice;
    reg [3:0] bend_channel;
    reg [6:0] bend_note;
    reg [15:0] bend_age;
    reg [13:0] bend_word,bend_magnitude;
    reg bend_up;
    reg [31:0] bend_base,bend_edge,bend_delta;
    reg [45:0] bend_product;
    reg [6:0] mod_depth;
    reg [3:0] mod_channel;
    reg [23:0] vibrato_phase;
    reg [4:0] vibrato_voice;
    reg vibrato_valid;
    reg [1:0] vibrato_stage;
    reg signed [40:0] vibrato_base_depth;
    reg signed [9:0] vibrato_triangle;
    reg signed [50:0] vibrato_product;
    reg signed [31:0] vibrato_offset;
    wire signed [9:0] phase_double=$signed({2'b00,vibrato_phase[23:16]})<<<1;
    wire signed [9:0] triangle_now=vibrato_phase[23] ?
        10'sd383-phase_double : phase_double-10'sd128;
    wire [6:0] bend_bound=bend_word>=14'd8192 ?
        (bend_note>=7'd126 ? 7'd127 : bend_note+7'd2) :
        (bend_note<7'd2 ? 7'd0 : bend_note-7'd2);
    wire [31:0] bend_change=bend_product[44:13];
    reg [VOICES-1:0] retrigger;
    reg voice_dropped;
    reg event_pending,selected_pending,pending_usb,selected_usb,usb_connected_r;
    reg [6:0] pending_note,pending_velocity;
    // REC selects touch response for direct USB notes. Fixed mode uses a
    // comfortable MIDI velocity; note-off zero must remain zero.
    reg velocity_response_enabled;
    reg [3:0] pending_channel;
    reg [4:0] selected_voice;
    reg selected_match,selected_free;
    reg [31:0] selected_frequency;
    reg [6:0] selected_pitch_note;
    reg signed [5:0] octave_shift,semitone_shift;
    reg latch_enable;
    reg [VOICES-1:0] sustained;
    wire signed [8:0] shifted_note=
        $signed({2'b00,pending_note})+
        (pending_usb && pending_channel!=4'd9 ?
            $signed(octave_shift)+$signed(semitone_shift) : 9'sd0);
    wire [6:0] tuned_note=shifted_note<0 ? 7'd0 :
        shifted_note>9'sd127 ? 7'd127 : shifted_note[6:0];
    genvar voice_pin;
    generate for(voice_pin=0;voice_pin<VOICES;voice_pin=voice_pin+1) begin: frequency_bus
        wire signed [32:0] vibrato_frequency=
            $signed({1'b0,voice_frequency[voice_pin]})+
            $signed({vibrato_offset[31],vibrato_offset});
        assign frequency_words[voice_pin*32 +: 32]=
            vibrato_valid && vibrato_voice==voice_pin &&
            lead_valid[mod_channel] && lead_voice[mod_channel]==voice_pin &&
            gates[voice_pin] ? vibrato_frequency[31:0] : voice_frequency[voice_pin];
    end endgenerate
    assign synth_tick=sample_tick && !(host_mode && paused);
    // Prefer an existing matching voice, then a free voice, then the oldest.
    reg [4:0] chosen_voice;
    reg found_match, found_free;
    reg [15:0] oldest_age;
    integer k;
    always @* begin
        chosen_voice=0;
        found_match=0;
        found_free=0;
        oldest_age=voice_age[0];
        for(k=0;k<VOICES;k=k+1) begin
            if((gates[k] || retrigger[k]) && voice_note[k]==pending_note &&
               voice_channel[k]==pending_channel) begin
                if(!found_match) chosen_voice=k;
                found_match=1;
            end else if(!found_match && !found_free && !gates[k] && !retrigger[k]) begin
                chosen_voice=k;
                found_free=1;
            end
        end
        if(STEAL_ON_FULL && !found_match && !found_free) begin
            chosen_voice=0;
            for(k=1;k<VOICES;k=k+1)
                if(voice_age[k]<oldest_age) begin
                    chosen_voice=k;
                    oldest_age=voice_age[k];
                end
        end
    end

    reg reply_pending, reply_active;
    reg [3:0] reply_index;
    reg [7:0] reply_command, reply_result, reply_flags, reply_free, reply_volume;
    reg [31:0] reply_frame;
    wire [7:0] reply_checksum=reply_command^reply_result^reply_flags^
                              reply_free^reply_volume^
                              reply_frame[7:0]^reply_frame[15:8]^
                              reply_frame[23:16]^reply_frame[31:24];
    assign tx_valid=reply_active && tx_ready;
    assign tx_byte=reply_index==0 ? 8'h5a :
                   reply_index==1 ? reply_command :
                   reply_index==2 ? reply_result :
                   reply_index==3 ? reply_flags :
                   reply_index==4 ? reply_free :
                   reply_index==5 ? reply_volume :
                   reply_index==6 ? reply_frame[7:0] :
                   reply_index==7 ? reply_frame[15:8] :
                   reply_index==8 ? reply_frame[23:16] :
                   reply_index==9 ? reply_frame[31:24] : reply_checksum;

    integer j;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            byte_index<=0;command<=0;checksum<=0;interbyte_count<=0;zero_args<=1;
            for(j=0;j<8;j=j+1) payload[j]<=0;
            host_mode<=0;playing<=0;paused<=0;bell<=0;volume<=8'd192;
            effect_mix<=0;effect_feedback<=0;
            adsr_values<={16'd48,16'd40000,16'd24,16'd512};
            adsr_controls<={7'd11,7'd75,7'd4,7'd28};
            ui_param_ack<=0;ui_param_rejected<=0;note_on_accepted<=0;
            gates<=0;voice_epochs<=0;voice_patches<=0;voice_velocities<=0;
            channel_patches<=0;global_patch<=0;
            frame_index<=0;queue_count<=0;read_ptr<=0;write_ptr<=0;
            last_enqueued_time<=0;late_event<=0;age_counter<=0;retrigger<=0;voice_dropped<=0;
            lead_valid<=0;bend_stage<=0;bend_voice<=0;bend_channel<=0;
            bend_note<=0;bend_age<=0;bend_word<=0;bend_magnitude<=0;
            bend_up<=0;bend_base<=0;bend_edge<=0;bend_delta<=0;bend_product<=0;
            mod_depth<=0;mod_channel<=0;vibrato_phase<=0;
            vibrato_voice<=0;vibrato_valid<=0;vibrato_stage<=0;
            vibrato_base_depth<=0;vibrato_triangle<=0;
            vibrato_product<=0;vibrato_offset<=0;
            event_pending<=0;selected_pending<=0;pending_usb<=0;
            selected_usb<=0;usb_connected_r<=0;pending_note<=0;
            pending_velocity<=0;pending_channel<=0;selected_voice<=0;
            velocity_response_enabled<=1;
            selected_match<=0;selected_free<=0;selected_frequency<=0;
            selected_pitch_note<=0;octave_shift<=0;semitone_shift<=0;
            latch_enable<=0;sustained<=0;
            for(j=0;j<VOICES;j=j+1) begin
                voice_frequency[j]<=0;voice_note[j]<=0;
                voice_pitch_note[j]<=0;
                voice_channel[j]<=0;voice_age[j]<=0;
            end
            for(j=0;j<16;j=j+1) lead_voice[j]<=0;
            reply_pending<=0;reply_active<=0;reply_index<=0;
            reply_command<=0;reply_result<=0;reply_flags<=0;
            reply_free<=0;reply_volume<=0;reply_frame<=0;
        end else begin
            ui_param_ack<=0;ui_param_rejected<=0;note_on_accepted<=0;
            if(rx_error) byte_index<=0;
            else if(rx_valid) begin
                interbyte_count<=0;
                if(byte_index==0) begin
                    if(rx_byte==8'ha5) begin byte_index<=1;checksum<=0;end
                end else if(byte_index==1) begin
                    command<=rx_byte;checksum<=rx_byte;byte_index<=2;zero_args<=1;
                end else if(byte_index<10) begin
                    payload[byte_index-2]<=rx_byte;
                    zero_args<=zero_args && rx_byte==0;
                    checksum<=checksum^rx_byte;byte_index<=byte_index+1'b1;
                end else begin
                    byte_index<=0;
                    reply_command<=command;
                    reply_pending<=1;
                    if(!good_crc) reply_result<=BAD_CRC;
                    else case(command)
                        SET_SOUND: if(payload[0]>3 || payload[2]!=0 ||
                                      payload[3]!=0 || payload[4]!=0 ||
                                      payload[5]!=0 || payload[6]!=0 || payload[7]!=0)
                                      reply_result<=BAD_ARGUMENT;
                                   else if(playing && payload[0]!=global_patch)
                                      reply_result<=BUSY;
                                   else begin
                                      host_mode<=1;global_patch<=payload[0][1:0];
                                      bell<=payload[0]==1;
                                      channel_patches<={16{payload[0][1:0]}};
                                      volume<=payload[1];reply_result<=OK;
                                   end
                        SET_CHANNEL_SOUND:
                            if(payload[0]>=16 || payload[1]>3 ||
                               payload[2]!=0 || payload[3]!=0 ||
                               payload[4]!=0 || payload[5]!=0 ||
                               payload[6]!=0 || payload[7]!=0)
                                reply_result<=BAD_ARGUMENT;
                            else begin
                                host_mode<=1;
                                channel_patches[payload[0][3:0]*2 +: 2]<=payload[1][1:0];
                                reply_result<=OK;
                            end
                        BEND_LEAD: if(!bend_args_ok) reply_result<=BAD_ARGUMENT;
                                   else begin
                                       host_mode<=1;reply_result<=OK;
                                       if(lead_valid[payload[2][3:0]] &&
                                          gates[lead_voice[payload[2][3:0]]]) begin
                                           bend_voice<=lead_voice[payload[2][3:0]];
                                           bend_channel<=payload[2][3:0];
                                           bend_note<=voice_pitch_note[lead_voice[payload[2][3:0]]];
                                           bend_age<=voice_age[lead_voice[payload[2][3:0]]];
                                           bend_word<=bend_request;
                                           bend_stage<=1;
                                       end
                                   end
                        SET_EFFECT: if(!effect_args_ok) reply_result<=BAD_ARGUMENT;
                                    else begin
                                        host_mode<=1;
                                        effect_mix<=payload[0][6:0];
                                        effect_feedback<=payload[1][6:0];
                                        reply_result<=OK;
                                    end
                        SET_MOD: if(!mod_args_ok) reply_result<=BAD_ARGUMENT;
                                 else begin
                                     host_mode<=1;
                                     mod_depth<=payload[0][6:0];
                                     mod_channel<=payload[1][3:0];
                                     reply_result<=OK;
                                 end
                        SET_ADSR: if(!adsr_args_ok) reply_result<=BAD_ARGUMENT;
                                  else begin
                                      host_mode<=1;
                                      adsr_controls<={payload[3][6:0],payload[2][6:0],payload[1][6:0],payload[0][6:0]};
                                      adsr_values[15:0]<=16'd64+({9'd0,payload[0][6:0]}<<4);
                                      adsr_values[31:16]<=16'd8+({9'd0,payload[1][6:0]}<<2);
                                      adsr_values[47:32]<=16'd10000+payload[2][6:0]*16'd400;
                                      adsr_values[63:48]<=16'd4+({9'd0,payload[3][6:0]}<<2);
                                      reply_result<=OK;
                                  end
                        NOTE_EVENT: if(!event_args_ok) reply_result<=BAD_ARGUMENT;
                                    else if(event_time<last_enqueued_time)
                                        reply_result<=OUT_OF_ORDER;
                                    else if(queue_count==7'd64) reply_result<=FULL;
                                    else begin
                                        host_mode<=1;
                                        last_enqueued_time<=event_time;
                                        reply_result<=OK;
                                    end
                        PLAY: if(!zero_args) reply_result<=BAD_ARGUMENT;
                              else begin host_mode<=1;playing<=1;paused<=0;
                                         reply_result<=OK;end
                        PAUSE: if(!zero_args) reply_result<=BAD_ARGUMENT;
                               else begin host_mode<=1;
                                          if(playing) begin playing<=0;paused<=1;end
                                          reply_result<=OK;end
                        STOP: if(!zero_args) reply_result<=BAD_ARGUMENT;
                              else begin host_mode<=1;playing<=0;paused<=0;
                                         gates<=0;retrigger<=0;frame_index<=0;
                                         last_enqueued_time<=0;late_event<=0;
                                         age_counter<=0;voice_dropped<=0;
                                         lead_valid<=0;bend_stage<=0;reply_result<=OK;
                                         mod_depth<=0;vibrato_valid<=0;
                                         end
                        STATUS: if(!zero_args) reply_result<=BAD_ARGUMENT;
                                else begin host_mode<=1;reply_result<=OK;end
                        USB_STATUS: if(!zero_args) reply_result<=BAD_ARGUMENT;
                                    else reply_result<=OK;
                        CONTROL_STATUS: reply_result<=control_status_args_ok ?
                                                     OK : BAD_ARGUMENT;
                        default: reply_result<=BAD_COMMAND;
                    endcase
                end
            end else if(byte_index!=0) begin
                if(interbyte_count==INTERBYTE_TIMEOUT-1) begin
                    byte_index<=0;interbyte_count<=0;
                end else interbyte_count<=interbyte_count+1'b1;
            end

            if(request_stop) begin
                queue_count<=0;read_ptr<=0;write_ptr<=0;
                event_pending<=0;selected_pending<=0;
            end else begin
                if(push) begin
                    write_ptr<=write_ptr+1'b1;
                end
                if(pop) read_ptr<=read_ptr+1'b1;
                event_pending<=pop || (usb_connected && playing && usb_note_valid);
                if(usb_connected && playing && usb_note_valid) begin
                    pending_note<=usb_note;
                    pending_velocity<=usb_velocity==0 ? 7'd0 :
                        velocity_response_enabled ? usb_velocity : 7'd96;
                    pending_channel<=usb_channel;
                    pending_usb<=1;
                end else if(pop) begin
                    pending_note<=queue_head[17:11];
                    pending_velocity<=queue_head[10:4];
                    pending_channel<=queue_head[3:0];
                    pending_usb<=0;
                    if(queue_head[49:18]<frame_index) late_event<=1;
                end
                selected_pending<=event_pending;
                if(event_pending) begin
                    selected_usb<=pending_usb;
                    selected_voice<=chosen_voice;
                    selected_match<=found_match;
                    selected_free<=found_free;
                    selected_pitch_note<=tuned_note;
                    selected_frequency<=note_frequency[tuned_note];
                end
                case({push,pop})
                    2'b10: queue_count<=queue_count+1'b1;
                    2'b01: queue_count<=queue_count-1'b1;
                    default: begin end
                endcase
            end
            if(bend_stage!=0 && !request_stop) begin
                case(bend_stage)
                    1: begin
                        bend_base<=note_frequency[bend_note];
                        bend_edge<=note_frequency[bend_bound];
                        bend_up<=bend_word>=14'd8192;
                        bend_magnitude<=bend_word>=14'd8192 ?
                            bend_word-14'd8192 : 14'd8192-bend_word;
                        bend_stage<=2;
                    end
                    2: begin
                        bend_delta<=bend_up ? bend_edge-bend_base : bend_base-bend_edge;
                        bend_stage<=3;
                    end
                    3: begin
                        bend_product<=bend_delta*bend_magnitude;
                        bend_stage<=4;
                    end
                    4: begin
                        if(lead_valid[bend_channel] &&
                           lead_voice[bend_channel]==bend_voice && gates[bend_voice] &&
                           voice_pitch_note[bend_voice]==bend_note && voice_age[bend_voice]==bend_age)
                            voice_frequency[bend_voice]<=bend_up ?
                                bend_base+bend_change : bend_base-bend_change;
                        bend_stage<=0;
                    end
                    default: bend_stage<=0;
                endcase
            end
            // A six-hertz triangle LFO modulates only the most recent held
            // note on the selected channel. Maximum depth is about 0.26
            // semitones; the frequency multiplier is split across clocks.
            if(synth_tick && !request_stop) begin
                vibrato_phase<=vibrato_phase+24'd2062;
                vibrato_voice<=lead_voice[mod_channel];
                vibrato_valid<=mod_depth!=0 && lead_valid[mod_channel] &&
                               gates[lead_voice[mod_channel]];
                vibrato_base_depth<=
                    $signed({1'b0,voice_frequency[lead_voice[mod_channel]]})*
                    $signed({1'b0,mod_depth});
                vibrato_triangle<=triangle_now;
                vibrato_stage<=1;
            end else if(vibrato_stage==1) begin
                vibrato_product<=vibrato_base_depth*vibrato_triangle;
                vibrato_stage<=2;
            end else if(vibrato_stage==2) begin
                vibrato_offset<=vibrato_product>>>20;
                vibrato_stage<=0;
            end
            if(sample_tick && playing && !paused && !request_stop) begin
                frame_index<=frame_index+32'd1;
                gates<=gates | retrigger;
                retrigger<=0;
            end
            if(selected_pending && !request_stop) begin
                if(pending_velocity!=0) begin
                    if(!selected_match && !selected_free && !STEAL_ON_FULL)
                        voice_dropped<=1;
                    else begin
                        note_on_accepted<=1;
                        voice_frequency[selected_voice]<=selected_frequency;
                        voice_note[selected_voice]<=pending_note;
                        voice_pitch_note[selected_voice]<=selected_pitch_note;
                        voice_channel[selected_voice]<=pending_channel;
                        voice_patches[selected_voice*2 +: 2]<=selected_usb ?
                            (pending_channel==4'd9 ? 2'd1 : usb_patch_select) :
                            channel_patches[pending_channel*2 +: 2];
                        voice_velocities[selected_voice*7 +: 7]<=pending_velocity;
                        voice_epochs[selected_voice*8 +: 8]<=voice_epochs[selected_voice*8 +: 8]+8'd1;
                        voice_age[selected_voice]<=age_counter;
                        sustained[selected_voice]<=0;
                        lead_voice[pending_channel]<=selected_voice;
                        lead_valid[pending_channel]<=1;
                        age_counter<=age_counter+16'd1;
                        if(gates[selected_voice]) begin
                            gates[selected_voice]<=0;
                            retrigger[selected_voice]<=1;
                        end else gates[selected_voice]<=1;
                    end
                end else if(selected_match) begin
                    if(selected_usb && latch_enable)
                        sustained[selected_voice]<=1;
                    else gates[selected_voice]<=0;
                    retrigger[selected_voice]<=0;
                    if(lead_valid[pending_channel] &&
                       lead_voice[pending_channel]==selected_voice)
                        lead_valid[pending_channel]<=0;
                end
            end
            usb_connected_r<=usb_connected;
            if(usb_connected && !usb_connected_r) begin
                // Direct USB play has no PC-side PLAY command. Start the
                // sample engine at the standalone power-on gain.
                host_mode<=1;playing<=1;paused<=0;volume<=8'd255;
                queue_count<=0;read_ptr<=0;write_ptr<=0;
                event_pending<=0;selected_pending<=0;
                octave_shift<=0;semitone_shift<=0;
                latch_enable<=0;sustained<=0;
                velocity_response_enabled<=1;
            end
            if(usb_connected && usb_knob_a_valid) begin
                case(usb_knob_a_index)
                    3'd1: octave_shift<=usb_knob_a_value<7'd32 ? -6'sd12 :
                                        usb_knob_a_value>=7'd96 ? 6'sd12 : 6'sd0;
                    3'd2: begin
                        latch_enable<=usb_knob_a_value>=7'd64;
                        if(usb_knob_a_value<7'd64) begin
                            gates<=gates & ~sustained;
                            sustained<=0;
                        end
                    end
                    3'd3: begin
                        adsr_values[63:48]<=16'd4+({9'd0,usb_knob_a_value}<<2);
                        adsr_controls[27:21]<=usb_knob_a_value;
                    end
                    3'd7: semitone_shift<=
                                 $signed({1'b0,usb_knob_a_value[6:3]})-6'sd7;
                    default: begin end
                endcase
            end
            if(usb_connected && usb_record)
                velocity_response_enabled<=!velocity_response_enabled;
            if(usb_connected && usb_knob_b_valid) begin
                case(usb_knob_b_index)
                    3'd0: begin
                        adsr_values[15:0]<=16'd64+({9'd0,usb_knob_b_value}<<4);
                        adsr_controls[0 +: 7]<=usb_knob_b_value;
                    end
                    3'd1: begin
                        adsr_values[31:16]<=16'd8+({9'd0,usb_knob_b_value}<<2);
                        adsr_controls[7 +: 7]<=usb_knob_b_value;
                    end
                    3'd2: begin
                        adsr_values[47:32]<=16'd10000+usb_knob_b_value*16'd400;
                        adsr_controls[14 +: 7]<=usb_knob_b_value;
                    end
                    3'd3: begin
                        adsr_values[63:48]<=16'd4+({9'd0,usb_knob_b_value}<<2);
                        adsr_controls[21 +: 7]<=usb_knob_b_value;
                    end
                    3'd4: effect_mix<={1'b0,usb_knob_b_value[6:1]};
                    3'd5: effect_feedback<={1'b0,usb_knob_b_value[6:1]};
                    3'd6: volume<=usb_knob_b_value==7'd127 ? 8'd255 :
                                   {usb_knob_b_value,1'b0};
                    default: begin end
                endcase
            end
            if(usb_connected && usb_pad_b_valid) begin
                if(usb_pad_b_note==7'd96)
                    effect_mix<=effect_mix==0 ? 7'd20 : 7'd0;
                else if(usb_pad_b_note==7'd97)
                    effect_feedback<=effect_feedback>=7'd48 ?
                                     7'd0 : effect_feedback+7'd16;
            end
            if(usb_connected && usb_mod_valid) begin
                mod_channel<=usb_channel;
                mod_depth<=usb_mod_depth;
            end
            if(usb_connected && usb_bend_valid &&
               lead_valid[usb_channel] &&
               gates[lead_voice[usb_channel]]) begin
                bend_voice<=lead_voice[usb_channel];
                bend_channel<=usb_channel;
                bend_note<=voice_pitch_note[lead_voice[usb_channel]];
                bend_age<=voice_age[lead_voice[usb_channel]];
                bend_word<=usb_bend_word;
                bend_stage<=1;
            end
            if(!usb_connected && usb_connected_r) begin
                // Cable removal must never leave a held note sounding.
                note_on_accepted<=0;
                gates<=0;retrigger<=0;playing<=0;paused<=0;host_mode<=0;
                event_pending<=0;selected_pending<=0;
                queue_count<=0;read_ptr<=0;write_ptr<=0;
                lead_valid<=0;mod_depth<=0;vibrato_valid<=0;
                latch_enable<=0;sustained<=0;
                velocity_response_enabled<=1;
            end
            if(usb_connected && usb_stop) begin
                host_mode<=1;playing<=0;paused<=0;
                gates<=0;retrigger<=0;frame_index<=0;
                lead_valid<=0;bend_stage<=0;mod_depth<=0;
                vibrato_valid<=0;sustained<=0;
            end else if(usb_connected && usb_play) begin
                host_mode<=1;playing<=1;paused<=0;
            end
            // Parameters never arm playback or alter note queues/gates. Place
            // after USB/UART parameter writes so one accepted UI write wins a
            // same-clock collision. Disconnect remains an urgent session end.
            if(ui_param_valid) begin
                if(!audio_ready || !host_mode ||
                   (usb_connected_r && !usb_connected)) ui_param_rejected<=1;
                else if((ui_param_id==0 && ui_param_value<=16'd3) ||
                        (ui_param_id==1 && ui_param_value<=16'd255) ||
                        (ui_param_id>=2 && ui_param_id<=5 && ui_param_value<=16'd127)) begin
                    ui_param_ack<=1;
                    case(ui_param_id)
                        4'd0: begin
                            global_patch<=ui_param_value[1:0];
                            channel_patches<={16{ui_param_value[1:0]}};
                            bell<=ui_param_value[1:0]==2'd1;
                        end
                        4'd1: volume<=ui_param_value[7:0];
                        4'd2: begin
                            adsr_values[15:0]<=16'd64+(ui_param_value<<4);
                            adsr_controls[6:0]<=ui_param_value[6:0];
                        end
                        4'd3: begin
                            adsr_values[31:16]<=16'd8+(ui_param_value<<2);
                            adsr_controls[13:7]<=ui_param_value[6:0];
                        end
                        4'd4: begin
                            adsr_values[47:32]<=16'd10000+ui_param_value*16'd400;
                            adsr_controls[20:14]<=ui_param_value[6:0];
                        end
                        4'd5: begin
                            adsr_values[63:48]<=16'd4+(ui_param_value<<2);
                            adsr_controls[27:21]<=ui_param_value[6:0];
                        end
                        default: begin end
                    endcase
                end else ui_param_rejected<=1;
            end
            if(reply_pending && !reply_active) begin
                reply_pending<=0;reply_active<=1;reply_index<=0;
                reply_flags<={voice_dropped,late_event,host_mode,audio_ready,
                              audio_overrun,bell,paused,playing};
                reply_free<=8'd64-{1'b0,queue_count};
                reply_volume<=volume;
                reply_frame<=reply_command==USB_STATUS ?
                    {30'd0,usb_dm_stable,usb_dp_stable} :
                    reply_command==CONTROL_STATUS ?
                    (payload[0]==0 ? adsr_values[31:0] :
                     payload[0]==1 ? adsr_values[63:32] :
                     payload[0]==2 ? {18'd0,effect_feedback,effect_mix} :
                     payload[0]==3 ? {30'd0,usb_patch_select} :
                     payload[0]==4 ? {31'd0,velocity_response_enabled} :
                     payload[0]==5 ? hardware_diagnostics[31:0] :
                     payload[0]==6 ? hardware_diagnostics[63:32] :
                     payload[0]==7 ? hardware_diagnostics[95:64] :
                                     hardware_diagnostics[127:96]) : frame_index;
            end
            if(tx_valid) begin
                if(reply_index==10) reply_active<=0;
                else reply_index<=reply_index+1'b1;
            end
        end
    end
endmodule
