// Eight independently phased partials per voice. One partial takes six clocks.
// No CPU or recorded PCM.
module additive_core #(
    parameter integer VOICES=4,
    parameter integer OUTPUT_SHIFT=12,
    parameter integer LOW_VELOCITY_PROFILE=0
) (
    input wire clk, input wire rst_n, input wire sample_tick,
    input wire [VOICES-1:0] gates,
    input wire [VOICES*8-1:0] voice_epochs,
    input wire [VOICES*32-1:0] frequency_words,
    input wire [VOICES*2-1:0] voice_patches,
    input wire [VOICES*7-1:0] voice_velocities,
    input wire [63:0] adsr_values,
    output reg signed [23:0] sample_out,
    output reg sample_valid, output reg overrun
);
    localparam integer PARTIALS=VOICES*8;
    reg [31:0] phase [0:PARTIALS-1];
    reg [15:0] envelope [0:PARTIALS-1];
    reg [2:0] env_state [0:PARTIALS-1];
    reg signed [15:0] sine [0:1023];
    initial $readmemh("sine1024.hex", sine);
    reg [VOICES-1:0] gate_prev, gate_frame;
    reg [VOICES*8-1:0] epoch_prev, epoch_frame;
    reg [VOICES*32-1:0] freq_frame;
    reg [VOICES*2-1:0] patch_frame;
    reg [VOICES*7-1:0] velocity_frame;
    reg [63:0] adsr_frame;
    reg [6:0] idx;
    reg [2:0] state;
    reg [31:0] increment;
    reg [31:0] fundamental_latched;
    reg [15:0] ratio_latched;
    reg [2:0] amplitude_shift_latched;
    reg [7:0] velocity_gain_latched;
    reg [15:0] env_current,env_next;
    reg [2:0] env_state_current,env_state_next;
    reg signed [15:0] wave_value;
    reg signed [32:0] product;
    reg signed [39:0] accumulator;
    wire [3:0] voice_idx = idx[6:3];
    wire [2:0] partial_idx = idx[2:0];
    wire [1:0] patch_kind = patch_frame[voice_idx*2 +: 2];
    wire [6:0] velocity_current = velocity_frame[voice_idx*7 +: 7];
    // Keybed quartiles near 60 and 99 map to 15 and 100 of 128: 16.5 dB
    // apart, while full velocity still equals the old maximum.  The low
    // range keeps at least one gain count for any nonzero MIDI velocity.
    wire [7:0] velocity_low_baseline = velocity_current < 7'd3 ? 8'd1 :
        ({1'b0,velocity_current}+8'd1)>>2;
    // Optional weak-key response profile: raises selected low velocities
    // without changing ADSR, oscillator phases or full-velocity mix headroom.
    // Anchors: v1/16/32/48/60/63 -> gain1/8/12/14/15/16 (out of128).
    // v60 and v99 retain the established ~16.5dB keybed dynamic span.
    wire [7:0] velocity_low_fast = velocity_current<7'd3 ? 8'd1 :
        velocity_current<7'd16 ? velocity_low_baseline+({1'b0,velocity_current}>>2) :
        velocity_current<7'd32 ? 8'd8+(({1'b0,velocity_current}-8'd16)>>2) :
        velocity_current<7'd48 ? 8'd12+(({1'b0,velocity_current}-8'd32)>>3) :
        velocity_current<7'd60 ? 8'd14+(({1'b0,velocity_current}-8'd48)>>3) :
        velocity_low_baseline;
    wire [7:0] velocity_low = LOW_VELOCITY_PROFILE==1 ? velocity_low_fast : velocity_low_baseline;
    wire [8:0] velocity_mid_x5 = ({2'b0,velocity_current}-9'd63)*9'd5;
    wire [7:0] velocity_curve = velocity_current < 7'd64 ?
        velocity_low :
        velocity_current < 7'd96 ?
        8'd16+(velocity_mid_x5>>1) :
        {1'b0,velocity_current}+8'd1;
    wire [31:0] fundamental = freq_frame[voice_idx*32 +: 32];
    wire [15:0] attack_step=adsr_frame[15:0];
    wire [15:0] decay_step=adsr_frame[31:16];
    wire [15:0] sustain_level=adsr_frame[47:32];
    wire [15:0] release_step=adsr_frame[63:48];
    wire [16:0] decay_threshold={1'b0,sustain_level}+{1'b0,decay_step};
    reg [15:0] ratio;
    always @* begin
        ratio = ({13'd0, partial_idx} + 16'd1) << 12;
        case (patch_kind)
        2'd1: case (partial_idx)
            0: ratio=4096; 1: ratio=8192; 2: ratio=11289; 3: ratio=16671;
            4: ratio=21258; 5: ratio=26092; 6: ratio=33587; 7: ratio=43008;
        endcase
        2'd2: case (partial_idx)
            0: ratio=4096; 1: ratio=8192; 2: ratio=12288; 3: ratio=16385;
            4: ratio=20482; 5: ratio=24580; 6: ratio=28679; 7: ratio=32778;
        endcase
        2'd3: case (partial_idx)
            0: ratio=4096; 1: ratio=8192; 2: ratio=12290; 3: ratio=16389;
            4: ratio=20490; 5: ratio=24593; 6: ratio=28700; 7: ratio=32809;
        endcase
        default: begin end
        endcase
    end
    reg [2:0] amplitude_shift;
    always @* begin
        // Each patch permutes the same eight powers of two.  Their summed
        // gain is identical, so changing timbre cannot raise the worst-case
        // mix bound.  These are listening-test starting values, not samples.
        case(patch_kind)
        2'd1: case(partial_idx) // Bell: emphasize an inharmonic mode.
            0: amplitude_shift=0; 1: amplitude_shift=3;
            2: amplitude_shift=1; 3: amplitude_shift=2;
            4: amplitude_shift=4; 5: amplitude_shift=5;
            6: amplitude_shift=6; default: amplitude_shift=7;
        endcase
        2'd2: case(partial_idx) // Pluck: strong second harmonic, fast decay.
            0: amplitude_shift=1; 1: amplitude_shift=0;
            2: amplitude_shift=3; 3: amplitude_shift=2;
            4: amplitude_shift=5; 5: amplitude_shift=4;
            6: amplitude_shift=6; default: amplitude_shift=7;
        endcase
        2'd3: case(partial_idx) // Piano-like: brighter third partial.
            0: amplitude_shift=0; 1: amplitude_shift=2;
            2: amplitude_shift=1; 3: amplitude_shift=3;
            4: amplitude_shift=5; 5: amplitude_shift=4;
            6: amplitude_shift=6; default: amplitude_shift=7;
        endcase
        default: amplitude_shift=partial_idx; // Organ harmonic series.
        endcase
    end
    wire [47:0] frequency_product = fundamental_latched * ratio_latched;
    // Reject partials above 0.45 Fs, including multiplication overflow.
    wire partial_in_band = frequency_product < 48'd7916483719987;
    reg in_band;
    wire signed [32:0] weighted = product >>> amplitude_shift_latched;
    // MIDI velocity 127 maps exactly to the old full-scale output.  The
    // envelope remains independent, so note-off release keeps its shape.
    wire signed [8:0] velocity_gain = $signed({1'b0,velocity_gain_latched});
    wire signed [41:0] velocity_product = weighted * velocity_gain;
    wire signed [39:0] velocity_weighted = velocity_product >>> 7;
    wire signed [39:0] total = accumulator + velocity_weighted;
    // Bound before shifting: VOICES*sum(2^-k,k=0..7)*32768*65535.
    // With VOICES=4, SHIFT=12 the peak is below 50% of 24-bit full scale;
    // with VOICES=16, SHIFT=13 it remains below 100%.
    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_out<=0; sample_valid<=0; overrun<=0; state<=0;
            accumulator<=0; idx<=0; gate_prev<=0; gate_frame<=0; epoch_prev<=0; epoch_frame<=0;
            freq_frame<=0; patch_frame<=0; velocity_frame<=0;adsr_frame<=0;increment<=0;
            fundamental_latched<=0;
            ratio_latched<=0; amplitude_shift_latched<=0; velocity_gain_latched<=0;
            env_current<=0;env_next<=0;env_state_current<=0;env_state_next<=0;
            wave_value<=0; product<=0; in_band<=0;
            for(j=0;j<PARTIALS;j=j+1) begin phase[j]<=0; envelope[j]<=0; env_state[j]<=0; end
        end else begin
            sample_valid<=0;
            if (sample_tick && state!=0) overrun<=1;
            case(state)
            0: if(sample_tick) begin
                gate_frame<=gates; epoch_frame<=voice_epochs; freq_frame<=frequency_words; patch_frame<=voice_patches;
                velocity_frame<=voice_velocities;adsr_frame<=adsr_values;
                idx<=0; accumulator<=0; state<=6;
            end
            // Prefetch the selected partial.  The next stage computes one
            // envelope value; the array write then has no arithmetic after
            // the high-fanout partial index decoder.
            6: begin
                env_current<=envelope[idx];
                env_state_current<=env_state[idx];
                state<=1;
            end
            1: begin
                // Per-partial ADSR. Bell mode decays to zero while held.
                ratio_latched<=ratio;
                fundamental_latched<=fundamental;
                amplitude_shift_latched<=amplitude_shift;
                velocity_gain_latched<=velocity_curve;
                env_next<=env_current;
                env_state_next<=env_state_current;
                if(gate_frame[voice_idx] && (!gate_prev[voice_idx] ||
                    epoch_frame[voice_idx*8 +: 8]!=epoch_prev[voice_idx*8 +: 8])) begin
                    // Retrigger from current amplitude/phase, avoiding a hard discontinuity.
                    env_state_next<=1;
                end else if(!gate_frame[voice_idx]) begin
                    if(env_current>release_step) env_next<=env_current-release_step;
                    else begin env_next<=0; env_state_next<=0; end
                end else case(env_state_current)
                    1: if({1'b0,env_current}+{1'b0,attack_step}>=17'd65535)
                           begin env_next<=65535;env_state_next<=2;end
                       else env_next<=env_current+attack_step;
                    2: case(patch_kind)
                           2'd1: if(env_current>0)
                               env_next<=env_current-(env_current>>(14-partial_idx[2:1]))-16'd1;
                           2'd2: if(env_current>0)
                               env_next<=env_current-(env_current>>(13-partial_idx[2:1]))-16'd1;
                           2'd3: if(env_current>0)
                               env_next<=env_current-(env_current>>(15-partial_idx[2:1]))-16'd1;
                           default: if({1'b0,env_current}>decay_threshold)
                                        env_next<=env_current-decay_step;
                                    else begin env_next<=sustain_level;env_state_next<=3;end
                       endcase
                    default: begin end
                endcase
                state<=5;
            end
            5: begin
                envelope[idx]<=env_next;
                env_state[idx]<=env_state_next;
                increment<=frequency_product[43:12]; in_band<=partial_in_band;
                state<=2;
            end
            2: begin
                wave_value<=sine[phase[idx][31:22]];
                phase[idx]<=phase[idx]+increment;
                state<=3;
            end
            3: begin
                product<=in_band ? wave_value * $signed({1'b0,env_next}) : 33'sd0;
                state<=4;
            end
            4: begin
                accumulator<=total;
                if(idx==PARTIALS-1) begin
                    // Explicit saturation before narrowing, even though bound is conservative.
                    if(total > (40'sd8388607 <<< OUTPUT_SHIFT)) sample_out<=24'sh7fffff;
                    else if(total < (-40'sd8388608 <<< OUTPUT_SHIFT)) sample_out<=24'sh800000;
                    else sample_out<=total[OUTPUT_SHIFT+23:OUTPUT_SHIFT];
                    gate_prev<=gate_frame; epoch_prev<=epoch_frame; sample_valid<=1; state<=0;
                end else begin idx<=idx+7'd1;state<=6;end
            end
            default: state<=0;
            endcase
        end
    end
endmodule
