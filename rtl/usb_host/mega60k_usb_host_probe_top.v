// Standalone, no-audio proof-of-concept for direct SMK-25 USB connection.
// UART emits 12-byte snapshots at 10 Hz; no MIDI is yet sent to the synth.
module mega60k_usb_host_probe_top (
    input wire sys_clk,input wire rst_n,
    inout wire usb_dp,inout wire usb_dm,
    output wire uart_tx,output wire [1:0] status_led,
    output wire pa_en,output wire hp_bck,output wire hp_ws,output wire hp_din
);
    // This probe has no audio path. Keep the onboard amplifier disabled.
    assign pa_en=1'b1;
    assign hp_bck=1'b0;
    assign hp_ws=1'b0;
    assign hp_din=1'b0;
    wire usb_clk,pll_lock;
    pll_60 pll(.clkout0(usb_clk),.lock(pll_lock),.clkin(sys_clk));
    reg [2:0] reset_sync=0;
    always @(posedge usb_clk or negedge rst_n)
        if(!rst_n) reset_sync<=0;
        else reset_sync<={reset_sync[1:0],pll_lock};
    wire usb_reset=!reset_sync[2];
    wire usb_dp_o,usb_dm_o,usb_oe;
    assign usb_dp=usb_oe ? usb_dp_o : 1'bz;
    assign usb_dm=usb_oe ? usb_dm_o : 1'bz;
    wire [1:0] typ;
    wire full_report,connerr,busy,midi_connected,midi_packet_start;
    wire midi_byte_valid;
    wire [7:0] midi_byte;
    wire [63:0] dbg_report,dbg_regs;
    wire [9:0] rom_addr;
    wire [3:0] rom_dout;
    wire rom_en;
    usb_hid_host #(.FULL_SPEED(1),.KEYBOARD_SUPPORT(0),
                   .MOUSE_SUPPORT(0),.GAME_SUPPORT(1)) host(
        .clk(usb_clk),.reset(usb_reset),.cs(1'b1),
        .usb_dm_i(usb_dm),.usb_dp_i(usb_dp),
        .usb_dm_o(usb_dm_o),.usb_dp_o(usb_dp_o),.usb_oe(usb_oe),
        .typ(typ),.full_report(full_report),.connerr(connerr),.busy(busy),
        .midi_connected(midi_connected),.midi_packet_start(midi_packet_start),
        .midi_byte_valid(midi_byte_valid),.midi_byte(midi_byte),
        .dbg_hid_report(dbg_report),.dbg_hid_regs(dbg_regs),
        .rom_addr(rom_addr),.rom_dout(rom_dout),.rom_en(rom_en));
    usb_hid_host_rom rom(usb_clk,rom_addr,rom_dout,rom_en);
    wire midi_event_valid,decoded_note_valid;
    wire [31:0] midi_event;
    wire [6:0] decoded_note,decoded_velocity;
    usb_midi_event_cdc event_bridge(
        .usb_clk(usb_clk),.usb_rst_n(!usb_reset),
        .audio_clk(usb_clk),.audio_rst_n(!usb_reset),
        .connected(midi_connected),.packet_start(midi_packet_start),
        .byte_valid(midi_byte_valid),.byte_data(midi_byte),
        .audio_connected(),.packet_valid(midi_event_valid),.packet(midi_event));
    usb_midi_packet event_decoder(
        .clk(usb_clk),.rst_n(!usb_reset),
        .packet_valid(midi_event_valid),.packet(midi_event),
        .cable_select(4'd0),.note_valid(decoded_note_valid),
        .note(decoded_note),.velocity(decoded_velocity),.channel(),
        .mod_valid(),.mod_depth(),.bend_valid(),.bend_word());
    reg [127:0] active_notes=0;
    reg [7:0] active_count=0;
    reg [15:0] note_on_count=0,note_off_count=0;
    always @(posedge usb_clk) begin
        if(usb_reset || !midi_connected) begin
            active_notes<=0;active_count<=0;
            note_on_count<=0;note_off_count<=0;
        end else if(decoded_note_valid) begin
            if(decoded_velocity!=0) begin
                note_on_count<=note_on_count+1'b1;
                if(!active_notes[decoded_note]) active_count<=active_count+1'b1;
                active_notes[decoded_note]<=1;
            end else begin
                note_off_count<=note_off_count+1'b1;
                if(active_notes[decoded_note]) active_count<=active_count-1'b1;
                active_notes[decoded_note]<=0;
            end
        end
    end
    reg [15:0] byte_count=0,packet_count=0;
    reg [7:0] last_byte=0;
    always @(posedge usb_clk) begin
        if(usb_reset || !midi_connected) begin
            byte_count<=0;packet_count<=0;last_byte<=0;
        end else begin
            if(midi_byte_valid) begin
                byte_count<=byte_count+1'b1;
                last_byte<=midi_byte;
            end
            if(midi_packet_start) packet_count<=packet_count+1'b1;
        end
    end
    assign status_led={midi_connected,connerr};

    reg [22:0] timer=0;
    reg sending=0;
    reg [4:0] index=0;
    reg [7:0] flags_snapshot=0,last_snapshot=0;
    reg [31:0] ids_snapshot=0;
    reg [15:0] bytes_snapshot=0,packets_snapshot=0;
    reg [63:0] report_snapshot=0;
    reg [7:0] held_snapshot=0;
    reg [15:0] ons_snapshot=0,offs_snapshot=0;
    always @(posedge usb_clk) begin
        if(usb_reset) begin
            timer<=0;sending<=0;index<=0;
            flags_snapshot<=0;ids_snapshot<=0;bytes_snapshot<=0;
            packets_snapshot<=0;last_snapshot<=0;report_snapshot<=0;
            held_snapshot<=0;ons_snapshot<=0;offs_snapshot<=0;
        end else begin
            if(timer==23'd5999999) timer<=0;
            else timer<=timer+1'b1;
            if(timer==0 && !sending) begin
                sending<=1;index<=0;
                flags_snapshot<={2'b0,busy,connerr,midi_connected,
                                 full_report,usb_oe,pll_lock};
                ids_snapshot<=dbg_regs[31:0];
                bytes_snapshot<=byte_count;
                packets_snapshot<=packet_count;
                last_snapshot<=last_byte;
                report_snapshot<=dbg_report;
                held_snapshot<=active_count;
                ons_snapshot<=note_on_count;
                offs_snapshot<=note_off_count;
            end else if(sending && tx_ready) begin
                if(index==5'd24) sending<=0;
                else index<=index+1'b1;
            end
        end
    end
    wire [7:0] tx_byte=index==0 ? 8'ha5 :
                       index==1 ? 8'h55 :
                       index==2 ? flags_snapshot :
                       index==3 ? ids_snapshot[7:0] :
                       index==4 ? ids_snapshot[15:8] :
                       index==5 ? ids_snapshot[23:16] :
                       index==6 ? ids_snapshot[31:24] :
                       index==7 ? bytes_snapshot[7:0] :
                       index==8 ? bytes_snapshot[15:8] :
                       index==9 ? last_snapshot :
                       index==10 ? packets_snapshot[7:0] :
                       index==11 ? packets_snapshot[15:8] :
                       index<20 ? report_snapshot[(index-5'd12)*8 +: 8] :
                       index==20 ? held_snapshot :
                       index==21 ? ons_snapshot[7:0] :
                       index==22 ? ons_snapshot[15:8] :
                       index==23 ? offs_snapshot[7:0] :
                                   offs_snapshot[15:8];
    wire tx_ready;
    uart_tx #(.CLKS_PER_BIT(521)) sender(usb_clk,!usb_reset,tx_byte,
                                        sending,uart_tx,tx_ready);
endmodule
