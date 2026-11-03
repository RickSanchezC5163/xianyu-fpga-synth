`timescale 1ns/1ps
// Original beginner melody: C D E G | G E D C, white keys only.
// One note at a time, held1.5beats then0.5beat rest; finalC lasts2beats.
// PPQN96,16beats total; at60BPM this is16seconds. No audio recording.
module guide_score_rom(input wire [3:0] address,
    output reg [31:0] at_tick,output reg [24:0] keys,output reg last);
    always @* begin
        last=0;
        case(address)
            0:begin at_tick=0;keys=25'd1<<0;end
            1:begin at_tick=144;keys=0;end
            2:begin at_tick=192;keys=25'd1<<2;end
            3:begin at_tick=336;keys=0;end
            4:begin at_tick=384;keys=25'd1<<4;end
            5:begin at_tick=528;keys=0;end
            6:begin at_tick=576;keys=25'd1<<7;end
            7:begin at_tick=720;keys=0;end
            8:begin at_tick=768;keys=25'd1<<7;end
            9:begin at_tick=912;keys=0;end
            10:begin at_tick=960;keys=25'd1<<4;end
            11:begin at_tick=1104;keys=0;end
            12:begin at_tick=1152;keys=25'd1<<2;end
            13:begin at_tick=1296;keys=0;end
            14:begin at_tick=1344;keys=25'd1<<0;end
            default:begin at_tick=1536;keys=0;last=1;end
        endcase
    end
endmodule
