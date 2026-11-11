// Simple synchronous FIFO (power-of-two depth), first-word-fall-through.
module sync_fifo #(parameter W = 8, parameter LOG2D = 3) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         push,
    input  wire [W-1:0] din,
    input  wire         pop,
    output wire [W-1:0] dout,
    output wire         empty,
    output wire         full,
    output reg  [LOG2D:0] count
);
    reg [W-1:0] mem [0:(1<<LOG2D)-1];
    reg [LOG2D-1:0] wp, rp;
    assign empty = (count == 0);
    assign full  = (count == (1 << LOG2D));
    assign dout  = mem[rp];
    wire do_push = push && !full;
    wire do_pop  = pop && !empty;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wp <= 0; rp <= 0; count <= 0;
        end else begin
            if (do_push) begin mem[wp] <= din; wp <= wp + 1'b1; end
            if (do_pop)  rp <= rp + 1'b1;
            count <= count + do_push - do_pop;
        end
    end
endmodule
