// DLRM embedding-bag accelerator top level.
module ebag_top #(parameter DIM = 16, parameter MAX_OUT = 4) (
    input  wire              clk,
    input  wire              rst_n,
    // AXI4-Lite control
    input  wire              s_axil_awvalid, output wire s_axil_awready, input wire [7:0]  s_axil_awaddr,
    input  wire              s_axil_wvalid,  output wire s_axil_wready,  input wire [31:0] s_axil_wdata,
    input  wire [3:0]        s_axil_wstrb,
    output wire              s_axil_bvalid,  input  wire s_axil_bready,  output wire [1:0] s_axil_bresp,
    input  wire              s_axil_arvalid, output wire s_axil_arready, input wire [7:0]  s_axil_araddr,
    output wire              s_axil_rvalid,  input  wire s_axil_rready,  output wire [31:0] s_axil_rdata,
    output wire [1:0]        s_axil_rresp,
    // index stream
    input  wire              s_idx_tvalid, output wire s_idx_tready,
    input  wire [31:0]       s_idx_tdata,  input  wire s_idx_tlast,
    // AXI4 read master (embedding table)
    output wire              m_axi_arvalid, input wire m_axi_arready, output wire [31:0] m_axi_araddr,
    output wire [7:0]        m_axi_arlen,   output wire [2:0] m_axi_arsize, output wire [1:0] m_axi_arburst,
    output wire [3:0]        m_axi_arid,
    input  wire              m_axi_rvalid,  output wire m_axi_rready, input wire [63:0] m_axi_rdata,
    input  wire [1:0]        m_axi_rresp,   input  wire m_axi_rlast,  input wire [3:0] m_axi_rid,
    // pooled output stream
    output wire              m_out_tvalid, input wire m_out_tready,
    output wire [32*DIM-1:0] m_out_tdata,  output wire [15:0] m_out_tuser
);
    wire enable, mode_max, idle, ev_bag, ev_row, ev_oob, ev_rresp_err;
    wire [31:0] table_base, num_rows;
    wire [3:0]  outstanding;

    ebag_regs #(.DIM(DIM), .ROW_BEATS(DIM / 8), .MAX_OUT(MAX_OUT)) u_regs (
        .clk(clk), .rst_n(rst_n),
        .s_awvalid(s_axil_awvalid), .s_awready(s_axil_awready), .s_awaddr(s_axil_awaddr),
        .s_wvalid(s_axil_wvalid), .s_wready(s_axil_wready), .s_wdata(s_axil_wdata), .s_wstrb(s_axil_wstrb),
        .s_bvalid(s_axil_bvalid), .s_bready(s_axil_bready), .s_bresp(s_axil_bresp),
        .s_arvalid(s_axil_arvalid), .s_arready(s_axil_arready), .s_araddr(s_axil_araddr),
        .s_rvalid(s_axil_rvalid), .s_rready(s_axil_rready), .s_rdata(s_axil_rdata), .s_rresp(s_axil_rresp),
        .enable(enable), .mode_max(mode_max), .table_base(table_base), .num_rows(num_rows),
        .idle(idle), .ev_bag(ev_bag), .ev_row(ev_row), .ev_oob(ev_oob), .ev_rresp_err(ev_rresp_err)
    );

    ebag_engine #(.DIM(DIM), .MAX_OUT(MAX_OUT)) u_engine (
        .clk(clk), .rst_n(rst_n),
        .enable(enable), .mode_max(mode_max), .table_base(table_base), .num_rows(num_rows), .idle(idle),
        .s_idx_tvalid(s_idx_tvalid), .s_idx_tready(s_idx_tready), .s_idx_tdata(s_idx_tdata), .s_idx_tlast(s_idx_tlast),
        .m_arvalid(m_axi_arvalid), .m_arready(m_axi_arready), .m_araddr(m_axi_araddr), .m_arlen(m_axi_arlen),
        .m_arsize(m_axi_arsize), .m_arburst(m_axi_arburst), .m_arid(m_axi_arid),
        .m_rvalid(m_axi_rvalid), .m_rready(m_axi_rready), .m_rdata(m_axi_rdata), .m_rresp(m_axi_rresp),
        .m_rlast(m_axi_rlast),
        .m_out_tvalid(m_out_tvalid), .m_out_tready(m_out_tready), .m_out_tdata(m_out_tdata), .m_out_tuser(m_out_tuser),
        .ev_bag(ev_bag), .ev_row(ev_row), .ev_oob(ev_oob), .ev_rresp_err(ev_rresp_err), .outstanding(outstanding)
    );
endmodule
