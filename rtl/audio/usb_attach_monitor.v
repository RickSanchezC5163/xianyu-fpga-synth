// Passive USB-A2 line monitor for board bring-up. It never drives D+/D- and
// does not enumerate USB devices. J state 10 means full-speed pull-up seen.
module usb_attach_monitor #(
    parameter integer STABLE_CYCLES=50000
) (
    input wire clk,input wire rst_n,input wire dp,input wire dm,
    output reg stable_dp,output reg stable_dm
);
    reg [1:0] sync_dp,sync_dm;
    reg [1:0] candidate;
    reg [31:0] count;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            sync_dp<=0;sync_dm<=0;candidate<=0;count<=0;
            stable_dp<=0;stable_dm<=0;
        end else begin
            sync_dp<={sync_dp[0],dp};
            sync_dm<={sync_dm[0],dm};
            if(candidate!={sync_dp[1],sync_dm[1]}) begin
                candidate<={sync_dp[1],sync_dm[1]};count<=0;
            end else if(count<STABLE_CYCLES) count<=count+1'b1;
            else {stable_dp,stable_dm}<=candidate;
        end
    end
endmodule
