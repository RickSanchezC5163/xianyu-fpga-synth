`timescale 1ns/1ps
module tb_additive_lane_reuse #(parameter integer PROFILE=0,FRAMES=2000);
    reg clk=0,rst_n=0,tick=0;
    always #10 clk=~clk;
    reg [31:0] gates=0;
    reg [255:0] epochs=0;
    reg [1023:0] frequencies=0;
    reg [63:0] patches=0;
    reg [223:0] velocities=0;
    reg [63:0] adsr=0;
    wire signed [23:0] pcm4[0:3],pcm2[0:1];
    wire [3:0] valid4,overrun4;
    wire [1:0] valid2,overrun2;
    genvar l;
    generate for(l=0;l<4;l=l+1)begin:reference
        additive_core #(.VOICES(8),.OUTPUT_SHIFT(14),.LOW_VELOCITY_PROFILE(PROFILE)) synth(
            clk,rst_n,tick,gates[l*8+:8],epochs[l*64+:64],frequencies[l*256+:256],
            patches[l*16+:16],velocities[l*56+:56],adsr,pcm4[l],valid4[l],overrun4[l]);
    end endgenerate
    generate for(l=0;l<2;l=l+1)begin:candidate
        additive_core #(.VOICES(16),.OUTPUT_SHIFT(14),.LOW_VELOCITY_PROFILE(PROFILE)) synth(
            clk,rst_n,tick,gates[l*16+:16],epochs[l*128+:128],frequencies[l*512+:512],
            patches[l*32+:32],velocities[l*112+:112],adsr,pcm2[l],valid2[l],overrun2[l]);
    end endgenerate
    wire signed [25:0] mixed4={{2{pcm4[0][23]}},pcm4[0]}+{{2{pcm4[1][23]}},pcm4[1]}+
                             {{2{pcm4[2][23]}},pcm4[2]}+{{2{pcm4[3][23]}},pcm4[3]};
    wire signed [25:0] mixed2={{2{pcm2[0][23]}},pcm2[0]}+{{2{pcm2[1][23]}},pcm2[1]};
    reg [31:0] note_table[0:127];
    function [6:0] velocity_at(input integer i);
        begin case(i%10)
            0:velocity_at=1;1:velocity_at=16;2:velocity_at=31;3:velocity_at=60;4:velocity_at=63;
            5:velocity_at=64;6:velocity_at=95;7:velocity_at=96;8:velocity_at=99;default:velocity_at=127;
        endcase end
    endfunction
    integer frame,v,c,fd,lat4,lat2,max_lat4=0,max_lat2=0,delta,min_delta=2,max_delta=0;
    integer pair0,pair1,active,max_active=0,retriggers=0,releases=0,nonzero=0,maximum_abs=0,absolute;
    integer k;
    task compare_state;
        begin
            active=0;
            for(k=0;k<64;k=k+1)begin
                if(reference[0].synth.phase[k]!==candidate[0].synth.phase[k] ||
                   reference[1].synth.phase[k]!==candidate[0].synth.phase[k+64] ||
                   reference[2].synth.phase[k]!==candidate[1].synth.phase[k] ||
                   reference[3].synth.phase[k]!==candidate[1].synth.phase[k+64] ||
                   reference[0].synth.envelope[k]!==candidate[0].synth.envelope[k] ||
                   reference[1].synth.envelope[k]!==candidate[0].synth.envelope[k+64] ||
                   reference[2].synth.envelope[k]!==candidate[1].synth.envelope[k] ||
                   reference[3].synth.envelope[k]!==candidate[1].synth.envelope[k+64] ||
                   reference[0].synth.env_state[k]!==candidate[0].synth.env_state[k] ||
                   reference[1].synth.env_state[k]!==candidate[0].synth.env_state[k+64] ||
                   reference[2].synth.env_state[k]!==candidate[1].synth.env_state[k] ||
                   reference[3].synth.env_state[k]!==candidate[1].synth.env_state[k+64])
                    $fatal(1,"independent oscillator state mismatch frame%0d partial%0d",frame,k);
                if(reference[0].synth.envelope[k]!=0)active=active+1;
                if(reference[1].synth.envelope[k]!=0)active=active+1;
                if(reference[2].synth.envelope[k]!=0)active=active+1;
                if(reference[3].synth.envelope[k]!=0)active=active+1;
            end
            if(active>max_active)max_active=active;
        end
    endtask
    initial begin
        $readmemh("midi_increments.hex",note_table);
        fd=$fopen("lane_reuse_samples.csv","w");$fwrite(fd,"frame,reference4,candidate2,delta,active_oscillators\n");
        repeat(3)@(negedge clk);rst_n=1;
        for(frame=0;frame<FRAMES;frame=frame+1)begin
            for(v=0;v<32;v=v+1)begin
                frequencies[v*32+:32]=note_table[24+(v*3+frame/157)%72];
                patches[v*2+:2]=(v+frame/300)%4;
                velocities[v*7+:7]=frame<80?127:velocity_at(v+frame/37);
                gates[v]=frame>0 && (frame<300 || (frame/29+v)%5!=0) && frame<FRAMES-200;
                if(frame==1 || (frame%83==0 && v%5==frame%5))begin
                    epochs[v*8+:8]=epochs[v*8+:8]+8'd1;retriggers=retriggers+1;
                end
            end
            if(frame==FRAMES-200)releases=releases+32;
            case((frame/200)%4)
                0:adsr={16'd2048,16'd40000,16'd1000,16'd65535};
                1:adsr={16'd48,16'd40000,16'd24,16'd512};
                2:adsr={16'd4096,16'd12000,16'd4096,16'd8192};
                default:adsr={16'd65535,16'd0,16'd65535,16'd65535};
            endcase
            tick=1;lat4=-1;lat2=-1;
            for(c=0;c<1024;c=c+1)begin
                @(posedge clk);#1;
                if(|overrun4 || |overrun2)$fatal(1,"sample budget overrun frame%0d cycle%0d",frame,c);
                if(|valid4 && !(&valid4))$fatal(1,"4lane valid skew");
                if(|valid2 && !(&valid2))$fatal(1,"2lane valid skew");
                if(&valid4)begin
                    if(lat4!=-1)$fatal(1,"duplicate reference sample");lat4=c;
                end
                if(&valid2)begin
                    if(lat2!=-1)$fatal(1,"duplicate candidate sample");lat2=c;
                end
                if(c==800)begin
                    if(lat4!=384 || lat2!=768)$fatal(1,"latency mismatch ref%0d candidate%0d",lat4,lat2);
                    if(^mixed4===1'bx || ^mixed2===1'bx)$fatal(1,"unknown PCM");
                    if(mixed4>8388607 || mixed4< -8388608 || mixed2>8388607 || mixed2< -8388608)
                        $fatal(1,"clip variation/headroom violation");
                    delta=$signed(mixed2)-$signed(mixed4);
                    pair0=$signed(pcm2[0])-$signed(pcm4[0])-$signed(pcm4[1]);
                    pair1=$signed(pcm2[1])-$signed(pcm4[2])-$signed(pcm4[3]);
                    if(delta<0 || delta>2 || pair0<0 || pair0>1 || pair1<0 || pair1>1)
                        $fatal(1,"rounding bound frame%0d delta%0d pair%0d/%0d",frame,delta,pair0,pair1);
                    if(delta<min_delta)min_delta=delta;if(delta>max_delta)max_delta=delta;
                    if(mixed2!=0)nonzero=nonzero+1;
                    absolute=$signed(mixed2)<0?-$signed(mixed2):$signed(mixed2);
                    if(absolute>maximum_abs)maximum_abs=absolute;
                    compare_state();
                    $fwrite(fd,"%0d,%0d,%0d,%0d,%0d\n",frame,$signed(mixed4),$signed(mixed2),delta,active);
                end
                @(negedge clk);tick=0;
                // Values changing between ticks must not leak into a frame.
                if(c==30)begin frequencies=~frequencies;patches=~patches;velocities=~velocities;adsr=~adsr;end
            end
            if(lat4>max_lat4)max_lat4=lat4;if(lat2>max_lat2)max_lat2=lat2;
        end
        if(max_active!=256 || nonzero<500 || retriggers<100 || releases!=32 || min_delta!=0 || max_delta!=2)
            $fatal(1,"coverage incomplete active%0d nonzero%0d retriggers%0d releases%0d delta%0d..%0d",max_active,nonzero,retriggers,releases,min_delta,max_delta);
        $fclose(fd);
        $display("PASS additive_lane_reuse profile=%0d frames=%0d max_valid4=%0d max_valid2=%0d frame_cycles=1024 delta=%0d..%0d max_active_oscillators=%0d peak=%0d retriggers=%0d releases=%0d overrun=0",PROFILE,FRAMES,max_lat4,max_lat2,min_delta,max_delta,max_active,maximum_abs,retriggers,releases);
        $finish;
    end
    initial begin #100000000;$fatal(1,"lane reuse test timeout");end
endmodule
