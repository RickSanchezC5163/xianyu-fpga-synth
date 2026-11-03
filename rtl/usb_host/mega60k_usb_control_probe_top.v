// Silent SMK-25 control inventory. Emits raw USB-MIDI events to the debug UART.
// Six bytes per event: A6 5A, USB-MIDI header, status, data1, data2.
module mega60k_usb_control_probe_top (
    input wire sys_clk,input wire rst_n,
    inout wire usb_dp,inout wire usb_dm,
    output wire uart_tx,output wire [1:0] status_led,
    output wire pa_en,output wire hp_bck,output wire hp_ws,output wire hp_din
);
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
    wire event_valid;
    wire [31:0] event_data;
    usb_midi_event_cdc event_bridge(
        .usb_clk(usb_clk),.usb_rst_n(!usb_reset),
        .audio_clk(usb_clk),.audio_rst_n(!usb_reset),
        .connected(midi_connected),.packet_start(midi_packet_start),
        .byte_valid(midi_byte_valid),.byte_data(midi_byte),
        .audio_connected(),.packet_valid(event_valid),.packet(event_data));
    assign status_led={midi_connected,connerr};

    reg [31:0] fifo [0:63];
    reg [5:0] wr_ptr=0,rd_ptr=0;
    reg [6:0] fifo_count=0;
    reg [15:0] overflow_count=0;
    reg [25:0] heartbeat=0;
    reg sending=0;
    reg [2:0] tx_index=0;
    reg [31:0] tx_event=0;
    wire tx_ready;
    wire pop_event=!sending && fifo_count!=0;
    wire push_event=event_valid && (fifo_count<7'd64 || pop_event);
    always @(posedge usb_clk or posedge usb_reset) begin
        if(usb_reset) begin
            wr_ptr<=0;rd_ptr<=0;fifo_count<=0;overflow_count<=0;
            sending<=0;tx_index<=0;tx_event<=0;heartbeat<=0;
        end else begin
            if(heartbeat==26'd59999999) heartbeat<=0;
            else heartbeat<=heartbeat+1'b1;
            if(push_event) begin
                fifo[wr_ptr]<=event_data;
                wr_ptr<=wr_ptr+1'b1;
            end else if(event_valid) overflow_count<=overflow_count+1'b1;
            if(pop_event) begin
                tx_event<=fifo[rd_ptr];
                rd_ptr<=rd_ptr+1'b1;
                sending<=1;
                tx_index<=0;
            end else if(!sending && heartbeat==26'd59999999) begin
                // Diagnostic frame: FF, connected, connection error,
                // low byte of logger FIFO overflow counter.
                tx_event<={overflow_count[7:0],7'd0,connerr,7'd0,midi_connected,8'hff};
                sending<=1;
                tx_index<=0;
            end else if(sending && tx_ready) begin
                if(tx_index==3'd5) sending<=0;
                else tx_index<=tx_index+1'b1;
            end
            case({push_event,pop_event})
                2'b10: fifo_count<=fifo_count+1'b1;
                2'b01: fifo_count<=fifo_count-1'b1;
                default: begin end
            endcase
        end
    end
    wire [7:0] tx_byte=tx_index==0 ? 8'ha6 :
                       tx_index==1 ? 8'h5a :
                       tx_index==2 ? tx_event[7:0] :
                       tx_index==3 ? tx_event[15:8] :
                       tx_index==4 ? tx_event[23:16] : tx_event[31:24];
    uart_tx #(.CLKS_PER_BIT(521)) sender(usb_clk,!usb_reset,tx_byte,
                                        sending,uart_tx,tx_ready);
endmodule
