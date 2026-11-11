// AXI4-Lite control/status register block for the embedding-bag engine.
//
//  0x00 CTRL        RW  [0] ENABLE  [1] MODE (0 = SUM, 1 = MAX)
//  0x04 STATUS      R/W1C [0] IDLE (RO)  [1] OOB_SEEN (W1C)  [2] RRESP_ERR (W1C)
//  0x08 TABLE_BASE  RW  byte address of row 0 (must be ROW_BYTES aligned)
//  0x0C NUM_ROWS    RW  rows in the table; index >= NUM_ROWS is out of bounds (skipped)
//  0x10 BAGS_DONE   RO  bags emitted
//  0x14 ROWS_READ   RO  rows fetched from memory
//  0x18 OOB_COUNT   RO  indices skipped as out of bounds
//  0x1C PARAMS      RO  {8'hEB, DIM[7:0], ROW_BEATS[7:0], MAX_OUT[7:0]}
// Writes honour WSTRB. Unmapped addresses and writes to RO registers return SLVERR.
module ebag_regs #(parameter DIM = 16, parameter ROW_BEATS = 2, parameter MAX_OUT = 4) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        s_awvalid, output wire s_awready, input wire [7:0] s_awaddr,
    input  wire        s_wvalid,  output wire s_wready,  input wire [31:0] s_wdata, input wire [3:0] s_wstrb,
    output reg         s_bvalid,  input  wire s_bready,  output reg [1:0] s_bresp,
    input  wire        s_arvalid, output wire s_arready, input wire [7:0] s_araddr,
    output reg         s_rvalid,  input  wire s_rready,  output reg [31:0] s_rdata, output reg [1:0] s_rresp,
    // to/from datapath
    output reg         enable,
    output reg         mode_max,
    output reg  [31:0] table_base,
    output reg  [31:0] num_rows,
    input  wire        idle,
    input  wire        ev_bag,
    input  wire        ev_row,
    input  wire        ev_oob,
    input  wire        ev_rresp_err
);
    reg [31:0] bags_done, rows_read, oob_count;
    reg        oob_seen, rresp_err;

    // ---------------- write channel (accept AW and W together)
    wire wr_fire = s_awvalid && s_wvalid && !s_bvalid;
    assign s_awready = wr_fire;
    assign s_wready  = wr_fire;
    wire [7:0] wa = s_awaddr & 8'hFC;

    function [31:0] merge(input [31:0] old, input [31:0] nw, input [3:0] strb);
        integer b;
        begin
            merge = old;
            for (b = 0; b < 4; b = b + 1)
`ifdef BUG_AXIL_STRB
                merge[8*b +: 8] = nw[8*b +: 8];            // injected bug: WSTRB ignored
`else
                if (strb[b]) merge[8*b +: 8] = nw[8*b +: 8];
`endif
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_bvalid <= 0; s_bresp <= 0;
            enable <= 0; mode_max <= 0; table_base <= 0; num_rows <= 0;
            oob_seen <= 0; rresp_err <= 0;
            bags_done <= 0; rows_read <= 0; oob_count <= 0;
        end else begin
            if (ev_bag) bags_done <= bags_done + 1;
            if (ev_row) rows_read <= rows_read + 1;
            if (ev_oob) begin oob_count <= oob_count + 1; oob_seen <= 1; end
            if (ev_rresp_err) rresp_err <= 1;
            if (s_bvalid && s_bready) s_bvalid <= 0;
            if (wr_fire) begin
                s_bvalid <= 1;
                s_bresp  <= 2'b00;
                case (wa)
                    8'h00: begin
                        if (s_wstrb[0]) begin enable <= s_wdata[0]; mode_max <= s_wdata[1]; end
                    end
                    8'h04: begin                                    // W1C
                        if (s_wstrb[0] && s_wdata[1] && !ev_oob)        oob_seen  <= 0;
                        if (s_wstrb[0] && s_wdata[2] && !ev_rresp_err)  rresp_err <= 0;
                    end
                    8'h08: table_base <= merge(table_base, s_wdata, s_wstrb);
                    8'h0C: num_rows   <= merge(num_rows, s_wdata, s_wstrb);
                    default: s_bresp <= 2'b10;                      // RO or unmapped: SLVERR
                endcase
            end
        end
    end

    // ---------------- read channel
    assign s_arready = !s_rvalid;
    wire [7:0] ra = s_araddr & 8'hFC;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_rvalid <= 0; s_rdata <= 0; s_rresp <= 0;
        end else begin
            if (s_rvalid && s_rready) s_rvalid <= 0;
            if (s_arvalid && s_arready) begin
                s_rvalid <= 1;
                s_rresp  <= 2'b00;
                case (ra)
                    8'h00: s_rdata <= {30'd0, mode_max, enable};
                    8'h04: s_rdata <= {29'd0, rresp_err, oob_seen, idle};
                    8'h08: s_rdata <= table_base;
                    8'h0C: s_rdata <= num_rows;
                    8'h10: s_rdata <= bags_done;
                    8'h14: s_rdata <= rows_read;
                    8'h18: s_rdata <= oob_count;
                    8'h1C: s_rdata <= {8'hEB, DIM[7:0], ROW_BEATS[7:0], MAX_OUT[7:0]};
                    default: begin s_rdata <= 32'd0; s_rresp <= 2'b10; end
                endcase
            end
        end
    end
endmodule
