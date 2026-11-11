// Embedding-bag datapath: index stream -> AXI4 row fetches -> SUM / MAX pooling -> output stream.
//
// Index stream (AXI-Stream): one 32-bit row index per beat, TLAST marks the last index of a bag.
// For each in-range index one INCR burst of ROW_BEATS x 64-bit beats is issued at
// TABLE_BASE + index * DIM. Up to MAX_OUT bursts may be outstanding (single ID, in-order).
// Out-of-range indices are skipped (counted, no memory access). A bag with no valid rows
// produces all-zero output. Output: one beat per bag, DIM x int32, TUSER = valid rows pooled.
module ebag_engine #(
    parameter DIM = 16,              // int8 elements per row (multiple of 8)
    parameter MAX_OUT = 4,           // max outstanding read bursts
    parameter LOG2_TAGS = 3          // tag FIFO depth = 2**LOG2_TAGS (must be >= MAX_OUT)
) (
    input  wire              clk,
    input  wire              rst_n,
    // config
    input  wire              enable,
    input  wire              mode_max,
    input  wire [31:0]       table_base,
    input  wire [31:0]       num_rows,
    output wire              idle,
    // index stream
    input  wire              s_idx_tvalid,
    output wire              s_idx_tready,
    input  wire [31:0]       s_idx_tdata,
    input  wire              s_idx_tlast,
    // AXI4 read master
    output reg               m_arvalid,
    input  wire              m_arready,
    output reg  [31:0]       m_araddr,
    output wire [7:0]        m_arlen,
    output wire [2:0]        m_arsize,
    output wire [1:0]        m_arburst,
    output wire [3:0]        m_arid,
    input  wire              m_rvalid,
    output wire              m_rready,
    input  wire [63:0]       m_rdata,
    input  wire [1:0]        m_rresp,
    input  wire              m_rlast,
    // pooled output stream
    output reg               m_out_tvalid,
    input  wire              m_out_tready,
    output reg  [32*DIM-1:0] m_out_tdata,
    output reg  [15:0]       m_out_tuser,
    // events
    output wire              ev_bag,
    output wire              ev_row,
    output wire              ev_oob,
    output wire              ev_rresp_err,
    output reg  [3:0]        outstanding
);
    localparam ROW_BEATS = DIM / 8;
    localparam BW = (ROW_BEATS > 1) ? $clog2(ROW_BEATS) : 1;

    assign m_arlen   = ROW_BEATS - 1;
    assign m_arsize  = 3'd3;          // 8 bytes per beat
    assign m_arburst = 2'b01;         // INCR
    assign m_arid    = 4'd0;

    // ---------------------------------------------------------------- issue side
    wire        tag_full, tag_empty;
    wire [1:0]  tag_head;             // {last, valid}
    wire [LOG2_TAGS:0] tag_count;
`ifdef BUG_OOB_BOUND
    wire        idx_ok   = s_idx_tdata <= num_rows;                 // injected bug: off by one
`else
    wire        idx_ok   = s_idx_tdata < num_rows;
`endif
`ifdef BUG_OUTSTANDING
    wire        room     = 1'b1;                                     // injected bug: no limit
`else
    wire        room     = (outstanding < MAX_OUT);
`endif
    assign s_idx_tready  = enable && !tag_full && !m_arvalid && (!idx_ok || room);
    wire        idx_fire = s_idx_tvalid && s_idx_tready;
    wire        ar_issue = idx_fire && idx_ok;
    assign ev_oob = idx_fire && !idx_ok;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_arvalid <= 1'b0; m_araddr <= 32'd0;
        end else begin
            if (m_arvalid && m_arready) m_arvalid <= 1'b0;
            if (ar_issue) begin
                m_arvalid <= 1'b1;
                m_araddr  <= table_base + s_idx_tdata * DIM;
            end
        end
    end

    // ---------------------------------------------------------------- tag FIFO
    wire tag_pop;
    sync_fifo #(.W(2), .LOG2D(LOG2_TAGS)) u_tags (
        .clk(clk), .rst_n(rst_n),
        .push(idx_fire), .din({s_idx_tlast, idx_ok}),
        .pop(tag_pop), .dout(tag_head), .empty(tag_empty), .full(tag_full), .count(tag_count)
    );
    wire head_last  = tag_head[1];
    wire head_valid = tag_head[0];

    // ---------------------------------------------------------------- consume side
    reg  [BW-1:0]      beat;
    reg                first;          // next valid row is the first of its bag
    reg  [15:0]        nrows;
    reg  signed [31:0] acc [0:DIM-1];

    wire out_busy  = m_out_tvalid && !m_out_tready;
    // process the head tag only when the output register can take a finished bag
    wire can_work  = !tag_empty && !out_busy;
    assign m_rready = can_work && head_valid;
    wire r_fire    = m_rvalid && m_rready;
    wire row_done  = r_fire && m_rlast;
    wire skip      = can_work && !head_valid;      // out-of-range entry, no data
    assign tag_pop = row_done || skip;
`ifdef BUG_EMPTY_LAST
    wire bag_done  = row_done && head_last;        // injected bug: bag ending in an OOB index never finishes
`else
    wire bag_done  = (row_done || skip) && head_last;
`endif
    assign ev_row       = row_done;
    assign ev_bag       = bag_done;
    assign ev_rresp_err = r_fire && m_rresp != 2'b00;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) outstanding <= 0;
        else outstanding <= outstanding + ar_issue - row_done;
    end

    integer k, c, ce, e;
    reg signed [31:0] nxt [0:DIM-1];
    reg signed [7:0]  v;
    always @(*) begin
        v = 8'sd0;
        ce = 0;
        for (c = 0; c < DIM; c = c + 1) nxt[c] = acc[c];
        if (r_fire) begin
            for (k = 0; k < 8; k = k + 1) begin
`ifdef BUG_SIGN
                v = $signed({1'b0, m_rdata[8*k +: 7]});                // injected bug: drops sign bit
`else
                v = m_rdata[8*k +: 8];
`endif
`ifdef BUG_BEAT_ORDER
                ce = (ROW_BEATS - 1 - beat) * 8 + k;                    // injected bug: beats reversed
`else
                ce = beat * 8 + k;
`endif
                if (!mode_max)
                    nxt[ce] = acc[ce] + v;
`ifdef BUG_MAX_INIT
                else
                    nxt[ce] = (v > acc[ce]) ? v : acc[ce];               // injected bug: max seeded with 0
`else
                else if (first || v > acc[ce])
                    nxt[ce] = v;
`endif
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            beat <= 0; first <= 1'b1; nrows <= 0;
            m_out_tvalid <= 1'b0; m_out_tdata <= 0; m_out_tuser <= 0;
            for (e = 0; e < DIM; e = e + 1) acc[e] <= 0;
        end else begin
            if (m_out_tvalid && m_out_tready) m_out_tvalid <= 1'b0;
            if (r_fire) beat <= m_rlast ? {BW{1'b0}} : beat + 1'b1;
            if (bag_done) begin
                // emit; include the final beat's contribution when the bag ends on data
                m_out_tvalid <= 1'b1;
                for (e = 0; e < DIM; e = e + 1) begin
                    m_out_tdata[32*e +: 32] <= nxt[e];
                    acc[e] <= 0;
                end
                m_out_tuser <= nrows + row_done;
                nrows <= 0;
                first <= 1'b1;
            end else begin
                for (e = 0; e < DIM; e = e + 1) acc[e] <= nxt[e];
                if (row_done) begin nrows <= nrows + 1'b1; first <= 1'b0; end
            end
        end
    end

    assign idle = tag_empty && !m_arvalid && !m_out_tvalid && outstanding == 0;
endmodule
