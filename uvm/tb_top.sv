`timescale 1ns/1ps
module tb_top;
    import uvm_pkg::*;
    import ebag_pkg::*;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    initial begin repeat (5) @(posedge clk); rst_n <= 1; end

    axil_if                    axil (clk, rst_n);
    axis_src_if #(32, 1)       idx  (clk, rst_n);
    axis_snk_if #(32*ebag_pkg::DIM, 16) outs (clk, rst_n);
    axi_rd_if                  axi  (clk, rst_n);

    ebag_top #(.DIM(ebag_pkg::DIM), .MAX_OUT(ebag_pkg::MAX_OUT)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axil_awvalid(axil.awvalid), .s_axil_awready(axil.awready), .s_axil_awaddr(axil.awaddr),
        .s_axil_wvalid(axil.wvalid), .s_axil_wready(axil.wready), .s_axil_wdata(axil.wdata), .s_axil_wstrb(axil.wstrb),
        .s_axil_bvalid(axil.bvalid), .s_axil_bready(axil.bready), .s_axil_bresp(axil.bresp),
        .s_axil_arvalid(axil.arvalid), .s_axil_arready(axil.arready), .s_axil_araddr(axil.araddr),
        .s_axil_rvalid(axil.rvalid), .s_axil_rready(axil.rready), .s_axil_rdata(axil.rdata), .s_axil_rresp(axil.rresp),
        .s_idx_tvalid(idx.tvalid), .s_idx_tready(idx.tready), .s_idx_tdata(idx.tdata), .s_idx_tlast(idx.tlast),
        .m_axi_arvalid(axi.arvalid), .m_axi_arready(axi.arready), .m_axi_araddr(axi.araddr), .m_axi_arlen(axi.arlen),
        .m_axi_arsize(axi.arsize), .m_axi_arburst(axi.arburst), .m_axi_arid(axi.arid),
        .m_axi_rvalid(axi.rvalid), .m_axi_rready(axi.rready), .m_axi_rdata(axi.rdata), .m_axi_rresp(axi.rresp),
        .m_axi_rlast(axi.rlast), .m_axi_rid(axi.rid),
        .m_out_tvalid(outs.tvalid), .m_out_tready(outs.tready), .m_out_tdata(outs.tdata), .m_out_tuser(outs.tuser)
    );
    assign outs.tlast = 1'b1;

    initial begin
        uvm_config_db#(virtual axil_if)::set(null, "*", "axil_vif", axil);
        uvm_config_db#(virtual axis_src_if #(32, 1))::set(null, "*", "idx_vif", idx);
        uvm_config_db#(virtual axis_snk_if #(32*ebag_pkg::DIM, 16))::set(null, "*", "out_vif", outs);
        uvm_config_db#(virtual axi_rd_if)::set(null, "*", "axi_vif", axi);
        run_test("ebag_sum_test");
    end
endmodule
