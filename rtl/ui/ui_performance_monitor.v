`timescale 1ns/1ps
// Diagnostic-only control-to-postmix-PCM latency and throughput counters.
// No output feeds the audio path. Latency is valid only for isolated notes
// after fresh digital silence; it excludes sensor scan, DAC and analog delay.
module ui_performance_monitor #(
    parameter integer CLK_HZ = 50000000,
    parameter integer QUIET_SAMPLES = 8,
    parameter integer QUIET_THRESHOLD = 2,
    parameter integer ONSET_THRESHOLD = 16,
    parameter integer WINDOW_CYCLES = CLK_HZ,
    parameter integer TIMEOUT_CYCLES = CLK_HZ/50
) (
    input wire clk,
    input wire rst_n,
    input wire control_note_on,
    input wire sample_valid,
    input wire signed [15:0] sample_pcm,
    input wire audio_overrun,
    // Externally qualified independent active oscillator count at this sample.
    // This is not a key count or a polyphony detector, and does not prove audibility.
    input wire [15:0] active_oscillators,
    output reg control_marker,
    output reg pcm_onset_marker,
    output reg latency_valid,
    output reg [31:0] latency_cycles,
    output reg [31:0] latency_max_cycles,
    output reg latency_le_10ms,
    output reg latency_le_5ms,
    output reg latency_timeout,
    output reg rejected_event,
    output reg [31:0] missed_deadline_count,
    output reg window_valid,
    output reg [31:0] samples_in_window,
    output reg [47:0] oscillator_samples_in_window
);
    localparam integer QUIET_W = (QUIET_SAMPLES > 1) ? $clog2(QUIET_SAMPLES+1) : 1;
    localparam integer WINDOW_W = (WINDOW_CYCLES > 1) ? $clog2(WINDOW_CYCLES) : 1;
    localparam integer TIMEOUT_W = (TIMEOUT_CYCLES > 1) ? $clog2(TIMEOUT_CYCLES) : 1;
    localparam integer LIMIT_10MS = CLK_HZ/100;
    localparam integer LIMIT_5MS = CLK_HZ/200;
    reg [QUIET_W-1:0] quiet_count;
    reg pending;
    reg [TIMEOUT_W-1:0] age;
    reg [WINDOW_W-1:0] window_count;
    reg [31:0] sample_count;
    reg [47:0] oscillator_sample_count;
    reg overrun_d;
    wire signed [16:0] extended_pcm = {sample_pcm[15],sample_pcm};
    wire [16:0] magnitude = sample_pcm[15] ? -extended_pcm : extended_pcm;
    wire onset = sample_valid && magnitude >= ONSET_THRESHOLD;
    wire [31:0] next_age = { {(32-TIMEOUT_W){1'b0}}, age } + 32'd1;
    wire [31:0] next_sample_count = sample_count + (sample_valid ? 32'd1 : 32'd0);
    wire [47:0] next_oscillator_count = oscillator_sample_count +
        (sample_valid ? {32'd0,active_oscillators} : 48'd0);

    // synthesis translate_off
    initial begin
        if (CLK_HZ < 1 || QUIET_SAMPLES < 1 || WINDOW_CYCLES < 1 || TIMEOUT_CYCLES < 1 ||
            QUIET_THRESHOLD < 0 || QUIET_THRESHOLD >= ONSET_THRESHOLD || ONSET_THRESHOLD > 32768)
            $fatal(1,"Invalid UI performance monitor parameter");
    end
    // synthesis translate_on

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            control_marker <= 0;
            pcm_onset_marker <= 0;
            latency_valid <= 0;
            latency_cycles <= 0;
            latency_max_cycles <= 0;
            latency_le_10ms <= 0;
            latency_le_5ms <= 0;
            latency_timeout <= 0;
            rejected_event <= 0;
            quiet_count <= 0;
            pending <= 0;
            age <= 0;
            overrun_d <= 0;
            missed_deadline_count <= 0;
            window_valid <= 0;
            window_count <= 0;
            sample_count <= 0;
            oscillator_sample_count <= 0;
            samples_in_window <= 0;
            oscillator_samples_in_window <= 0;
        end else begin
            control_marker <= control_note_on;
            pcm_onset_marker <= 0;
            latency_valid <= 0;
            latency_timeout <= 0;
            rejected_event <= 0;
            window_valid <= 0;
            overrun_d <= audio_overrun;
            if (audio_overrun && !overrun_d && missed_deadline_count != 32'hffffffff)
                missed_deadline_count <= missed_deadline_count + 1'b1;

            if (window_count == WINDOW_CYCLES-1) begin
                samples_in_window <= next_sample_count;
                oscillator_samples_in_window <= next_oscillator_count;
                window_valid <= 1;
                window_count <= 0;
                sample_count <= 0;
                oscillator_sample_count <= 0;
            end else begin
                window_count <= window_count + 1'b1;
                sample_count <= next_sample_count;
                oscillator_sample_count <= next_oscillator_count;
            end

            if (pending) begin
                quiet_count <= 0;
                if (control_note_on) begin
                    // A second event makes attribution ambiguous: discard both.
                    pending <= 0;
                    rejected_event <= 1;
                end else if (onset) begin
                    pending <= 0;
                    pcm_onset_marker <= 1;
                    latency_valid <= 1;
                    latency_cycles <= next_age;
                    if (next_age > latency_max_cycles) latency_max_cycles <= next_age;
                    latency_le_10ms <= next_age <= LIMIT_10MS;
                    latency_le_5ms <= next_age <= LIMIT_5MS;
                end else if (next_age >= TIMEOUT_CYCLES) begin
                    pending <= 0;
                    latency_timeout <= 1;
                end else age <= next_age;
            end else if (control_note_on) begin
                quiet_count <= 0;
                age <= 0;
                if (quiet_count == QUIET_SAMPLES) begin
                    if (onset) begin
                        pcm_onset_marker <= 1;
                        latency_valid <= 1;
                        latency_cycles <= 0;
                        latency_le_10ms <= 1;
                        latency_le_5ms <= 1;
                    end else pending <= 1;
                end else rejected_event <= 1;
            end else if (sample_valid) begin
                if (magnitude <= QUIET_THRESHOLD) begin
                    if (quiet_count < QUIET_SAMPLES) quiet_count <= quiet_count + 1'b1;
                end else quiet_count <= 0;
            end
        end
    end
endmodule
