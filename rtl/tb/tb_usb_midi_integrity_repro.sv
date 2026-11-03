`timescale 1ns/1ps

// Receive-path regression at the recovered USB line/timing boundary.
// NRZI bits, bit stuffing, byte counting and EOP run through the actual ukp
// receive logic. Only attach state, recovered di/eop/timing and entry into RX
// are steered: the electrical filter and ROM/IN/ACK sequencer are NOT tested.
// In particular this is not evidence of ACK timing or endpoint isolation.
// Default reproduces bad CRC and duplicate delivery; EXPECT_FIXED requires
// both to be rejected without swallowing the corrected retry or next toggle.
module tb_usb_midi_integrity_repro;
    reg clk = 0;
    reg reset = 1;
    wire ready, valid, packet_start, connected;
    wire [7:0] byte_data;
    reg [7:0] observed [0:255];
    integer observed_count = 0;
    integer i;
    reg [15:0] crc_note100;
    reg [15:0] crc_note101;
    reg [15:0] crc_note102;

    always #8 clk = ~clk;

    ukp dut (
        .clk(clk), .reset(reset), .cs(1'b1),
        .usb_dm_i(1'b0), .usb_dp_i(1'b1),
        .usb_dm_o(), .usb_dp_o(), .usb_oe(),
        .ukprdy(ready), .ukpstb(valid), .ukpstart(packet_start), .ukpdat(byte_data),
        .addra(), .addrb(), .save(), .load(),
        .load_data(8'h00), .midi_mode(1'b1),
        .rom_addr(), .rom_dout(4'h0), .rom_en(),
        .connected(connected), .full_speed(), .connerr(), .busy()
    );

    reg audio_clk=0;
    always #10 audio_clk=~audio_clk;
    wire audio_packet_valid;
    wire [31:0] audio_packet;
    integer audio_packet_count=0;
    usb_midi_event_cdc bridge(
        .usb_clk(clk),.usb_rst_n(!reset),.audio_clk(audio_clk),
        .audio_rst_n(!reset),.connected(connected),.packet_start(packet_start),
        .byte_valid(valid),.byte_data(byte_data),.audio_connected(),
        .packet_valid(audio_packet_valid),.packet(audio_packet));
    always @(posedge audio_clk) begin
        if(audio_packet_valid) begin
            if(audio_packet!=={observed[audio_packet_count*4+3],
                observed[audio_packet_count*4+2],observed[audio_packet_count*4+1],
                observed[audio_packet_count*4]})
                $fatal(1,"CONTRACT_FAILURE:tb_usb_midi_integrity_repro: CDC lost or reordered event %0d",audio_packet_count);
            audio_packet_count=audio_packet_count+1;
        end
    end

    always @(posedge clk) begin
        if (valid) begin
            if (observed_count >= 256)
                $fatal(1, "Unexpected extra MIDI byte %02x", byte_data);
            observed[observed_count] = byte_data;
            observed_count = observed_count + 1;
        end
    end

    // USB CRC16: reflected polynomial, initial FFFF, complemented result.
    function automatic [15:0] crc16_4(
        input [7:0] b0, input [7:0] b1,
        input [7:0] b2, input [7:0] b3
    );
        reg [15:0] crc;
        reg [7:0] b;
        integer k, bit_no;
        begin
            crc = 16'hffff;
            for (k = 0; k < 4; k = k + 1) begin
                case (k)
                    0: b = b0;
                    1: b = b1;
                    2: b = b2;
                    default: b = b3;
                endcase
                crc = crc ^ {8'h00, b};
                for (bit_no = 0; bit_no < 8; bit_no = bit_no + 1)
                    crc = crc[0] ? (crc >> 1) ^ 16'ha001 : (crc >> 1);
            end
            crc16_4 = ~crc;
        end
    endfunction

    reg rx_level = 1;
    integer tx_ones = 0;
    integer packet_bits = 0;
    reg corrupt_next_stuffed_bit=0;

    task raw_bit(input bit value);
        begin
            @(negedge clk);
            if (!value) rx_level = !rx_level;
            force dut.timing_rx = 1'b1;
            @(negedge clk);
            force dut.timing_rx = 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask

    task send_byte(input [7:0] value);
        integer k;
        begin
            for (k=0; k<8; k=k+1) begin
                raw_bit(value[k]);
                packet_bits = packet_bits + 1;
                tx_ones = value[k] ? tx_ones + 1 : 0;
                if (tx_ones == 6) begin
                    raw_bit(corrupt_next_stuffed_bit ? 1'b1 : 1'b0);
                    corrupt_next_stuffed_bit=0; // corrupt only one mandatory zero
                    tx_ones = 0;
                end
            end
        end
    endtask

    task send_packet(
        input [7:0] data_pid,
        input [7:0] b0, input [7:0] b1,
        input [7:0] b2, input [7:0] b3,
        input [15:0] crc
    );
        begin
            @(negedge clk);
            force dut.eop = 1'b0;
            rx_level = 1;
            force dut.state = 5'd10; // RX0 resets actual receive counters
            repeat (2) @(negedge clk);
            dut.wk = 10'd512; // endpoint max size supplied by skipped LDI
            force dut.state = 5'd11;
            tx_ones = 0;
            packet_bits = 0;
            send_byte(8'h80); // SYNC
            send_byte(data_pid);
            send_byte(b0); send_byte(b1); send_byte(b2); send_byte(b3);
            send_byte(crc[7:0]); send_byte(crc[15:8]);
            if (dut.bitaddr !== packet_bits)
                $fatal(1,"receive bit accounting: got %0d expected %0d",dut.bitaddr,packet_bits);
            // Final byte is consumed on the next sampling edge. EOP permits
            // a buffered receiver to validate and commit the whole packet.
            @(negedge clk);
            force dut.eop = 1'b1;
            force dut.timing_rx = 1'b1;
            release dut.state;
            @(negedge clk);
            force dut.timing_rx = 1'b0;
            if (dut.state !== 5'd1)
                $fatal(1,"receiver did not leave RX1 on EOP");
            repeat (2) @(negedge clk);
            force dut.eop = 1'b0;
            rx_level = 1;
            // Allow up to one complete 64-byte packet to drain after EOP.
            repeat (640) @(negedge clk);
        end
    endtask

    // Edge cases using the same recovered-bit receiver, not direct byte injection.
    reg [7:0] test_payload [0:63];
    task edge_packet(input [7:0] pid, input integer length,
                     input bit bad_crc, input bit bad_stuff);
        reg [15:0] crc;
        integer n,k;
        begin
            @(negedge clk); force dut.eop=0; rx_level=1;
            force dut.state=5'd10; repeat(2) @(negedge clk);
            dut.wk=512; force dut.state=5'd11;
            tx_ones=0;packet_bits=0;
            corrupt_next_stuffed_bit=bad_stuff;
            send_byte(8'h80);send_byte(pid);
            crc=16'hffff;
            for(n=0;n<length;n=n+1) begin
                send_byte(test_payload[n]);
                for(k=0;k<8;k=k+1)
                    crc=(crc>>1)^((crc[0]^test_payload[n][k]) ? 16'ha001 : 0);
            end
            crc=~crc;
            if(bad_crc) crc=crc^16'h0100;
            send_byte(crc[7:0]);send_byte(crc[15:8]);
            @(negedge clk);force dut.eop=1;force dut.timing_rx=1;
            release dut.state;
            @(negedge clk);force dut.timing_rx=0;
            repeat(2) @(negedge clk);force dut.eop=0;rx_level=1;
            repeat(640) @(negedge clk);
        end
    endtask

    // Each accepted USB-MIDI event packet carries four MIDI bytes; check one.
    task check_block(input integer block, input [7:0] velocity);
        begin
            if (observed[4*block] !== 8'h09 || observed[4*block+1] !== 8'h90 ||
                observed[4*block+2] !== 8'h3c || observed[4*block+3] !== velocity)
                $fatal(1, "MIDI block %0d mismatch: got %02x %02x %02x %02x, expected 09 90 3c %02x",
                       block, observed[4*block], observed[4*block+1],
                       observed[4*block+2], observed[4*block+3], velocity);
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        reset = 0;
        force dut.connected = 1'b1;
        force dut.di = rx_level;
        force dut.eop = 1'b0;
        force dut.timing_rx = 1'b0;

        crc_note100 = crc16_4(8'h09, 8'h90, 8'h3c, 8'h64);
        crc_note101 = crc16_4(8'h09, 8'h90, 8'h3c, 8'h65);
        crc_note102 = crc16_4(8'h09, 8'h90, 8'h3c, 8'h66);
        if (crc_note100 == crc_note101 || crc_note101 == crc_note102)
            $fatal(1, "CRC test stimulus is accidentally degenerate");

        // P1: DATA0, valid note-on, middle C, velocity 100.
        send_packet(8'hc3, 8'h09, 8'h90, 8'h3c, 8'h64, crc_note100);
        if (observed_count != 4)
            $fatal(1, "Valid DATA0 packet yielded %0d bytes, expected 4", observed_count);

        // P2: DATA1 whose payload is corrupted (velocity 101) but whose CRC is
        // still the one computed for velocity 100.  Must be discarded.
        send_packet(8'h4b, 8'h09, 8'h90, 8'h3c, 8'h65, crc_note100);
`ifdef EXPECT_FIXED
        if (observed_count != 4)
            $fatal(1, "CONTRACT_FAILURE:tb_usb_midi_integrity_repro: bad-CRC DATA1 was still delivered: %0d bytes, expected 4",
                   observed_count);
`else
        if (observed_count != 8)
            $fatal(1, "bad-CRC DATA1 was not delivered: %0d bytes, expected 8",
                   observed_count);
`endif

`ifdef EXPECT_FIXED
        if(dut.nak!==1) $fatal(1,"CONTRACT_FAILURE:tb_usb_midi_integrity_repro: CRC error did not skip ACK branch");
`endif
        // P3: the corrected retry of DATA1; the CRC now matches its payload.
        send_packet(8'h4b, 8'h09, 8'h90, 8'h3c, 8'h65, crc_note101);
`ifdef EXPECT_FIXED
        if (observed_count != 8)
            $fatal(1, "CONTRACT_FAILURE:tb_usb_midi_integrity_repro: valid DATA1 retry yielded %0d bytes, expected 8",
                   observed_count);
`else
        if (observed_count != 12)
            $fatal(1, "valid DATA1 retry yielded %0d bytes, expected 12",
                   observed_count);
`endif

        // P4: the identical, valid DATA1 again - the device repeated it because
        // the ACK was lost.  It must not be delivered twice (ACK is outside this bench).
        send_packet(8'h4b, 8'h09, 8'h90, 8'h3c, 8'h65, crc_note101);
`ifdef EXPECT_FIXED
        if (observed_count != 8)
            $fatal(1, "CONTRACT_FAILURE:tb_usb_midi_integrity_repro: duplicate DATA1 was delivered again: %0d bytes, expected 8",
                   observed_count);
`else
        if (observed_count != 16)
            $fatal(1, "duplicate DATA1 was not delivered: %0d bytes, expected 16",
                   observed_count);
`endif

`ifdef EXPECT_FIXED
        if(dut.nak!==0) $fatal(1,"CONTRACT_FAILURE:tb_usb_midi_integrity_repro: valid duplicate was not ACK eligible");
`endif
        // P5: a genuinely new DATA0 (toggle flipped, new payload).  De-duplication
        // must not swallow it, otherwise a fixed receiver would drop real notes.
        send_packet(8'hc3, 8'h09, 8'h90, 8'h3c, 8'h66, crc_note102);
`ifdef EXPECT_FIXED
        if (observed_count != 12)
            $fatal(1, "CONTRACT_FAILURE:tb_usb_midi_integrity_repro: new DATA0 after the duplicate was not delivered: %0d bytes, expected 12",
                   observed_count);
        check_block(0, 8'h64);
        check_block(1, 8'h65);
        check_block(2, 8'h66);
        for(i=0;i<64;i=i+1) test_payload[i]=8'hff; // abundant stuffed bits
        edge_packet(8'h0b,4,0,0); // bad PID complement, DATA1 low nibble
        if(observed_count!=12 || dut.nak!==1 || dut.midi_expected_toggle!==1)
            $fatal(1,"CONTRACT_FAILURE:tb_usb_midi_integrity_repro: malformed PID accepted");
        edge_packet(8'h4b,0,0,0); // valid zero-length DATA1 advances toggle
        if(observed_count!=12 || dut.nak!==0 || dut.midi_expected_toggle!==0)
            $fatal(1,"CONTRACT_FAILURE:tb_usb_midi_integrity_repro: zero-length packet mishandled");
        edge_packet(8'hc3,64,0,0);
        if(observed_count!=76 || dut.nak!==0)
            $fatal(1,"CONTRACT_FAILURE:tb_usb_midi_integrity_repro: full-size stuffed packet lost bytes");
        for(i=12;i<76;i=i+1)
            if(observed[i]!==8'hff) $fatal(1,"CONTRACT_FAILURE:tb_usb_midi_integrity_repro: full packet byte %0d wrong",i);
        edge_packet(8'h4b,4,0,1);
        if(observed_count!=76 || dut.nak!==1 || dut.midi_expected_toggle!==1)
            $fatal(1,"CONTRACT_FAILURE:tb_usb_midi_integrity_repro: bad stuffing accepted");
        edge_packet(8'h4b,4,0,0);
        if(observed_count!=80 || dut.nak!==0)
            $fatal(1,"CONTRACT_FAILURE:tb_usb_midi_integrity_repro: retry after bad stuffing lost");
        // Disconnect resets the endpoint sequence to DATA0.
        force dut.connected=0;repeat(4) @(negedge clk);force dut.connected=1;
        edge_packet(8'hc3,4,0,0);
        if(observed_count!=84 || dut.midi_expected_toggle!==1)
            $fatal(1,"CONTRACT_FAILURE:tb_usb_midi_integrity_repro: reconnect toggle was not reset");
        if(audio_packet_count!=21)
            $fatal(1,"CONTRACT_FAILURE:tb_usb_midi_integrity_repro: CDC delivered %0d events expected 21",audio_packet_count);
        $display("PASS:tb_usb_midi_integrity_repro: bad-CRC DATA1 dropped and duplicate DATA1 delivered exactly once");
`else
        if (observed_count != 20)
            $fatal(1, "duplicate DATA1 was not delivered: %0d bytes, expected 20",
                   observed_count);
        check_block(0, 8'h64);
        check_block(1, 8'h65);
        check_block(2, 8'h65);
        check_block(3, 8'h65);
        check_block(4, 8'h66);
        $display("EXPECTED_BUG:tb_usb_midi_integrity_repro: bad-CRC DATA1 and duplicate DATA1 both emitted four MIDI bytes");
`endif
        $finish;
    end

    initial begin
        #3000000;
        $fatal(1, "USB integrity test timeout");
    end
endmodule
