`timescale 1ns/1ps
// ----------------------------------------------------------------- AXI4-Lite
interface axil_if (input logic clk, input logic rst_n);
    logic        awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
    logic [7:0]  awaddr, araddr;
    logic [31:0] wdata, rdata;
    logic [3:0]  wstrb;
    logic [1:0]  bresp, rresp;
    clocking cb @(posedge clk);
        default input #1step output #1;
        output awvalid, awaddr, wvalid, wdata, wstrb, bready, arvalid, araddr, rready;
        input  awready, wready, bvalid, bresp, arready, rvalid, rdata, rresp;
    endclocking
    a_aw_hold: assert property (@(posedge clk) disable iff (!rst_n) awvalid && !awready |=> awvalid && $stable(awaddr));
    a_w_hold:  assert property (@(posedge clk) disable iff (!rst_n) wvalid && !wready |=> wvalid && $stable(wdata));
    a_b_hold:  assert property (@(posedge clk) disable iff (!rst_n) bvalid && !bready |=> bvalid && $stable(bresp));
    a_r_hold:  assert property (@(posedge clk) disable iff (!rst_n) rvalid && !rready |=> rvalid && $stable(rdata));
endinterface

// ----------------------------------------------------------------- AXI-Stream
// Two flavours so that each signal has exactly one driver: the TB drives the
// payload of axis_src_if and only TREADY of axis_snk_if.
`define AXIS_CHECKS \
    a_valid_hold:  assert property (@(posedge clk) disable iff (!rst_n) tvalid && !tready |=> tvalid); \
    a_data_stable: assert property (@(posedge clk) disable iff (!rst_n) \
                                    tvalid && !tready |=> $stable(tdata) && $stable(tlast) && $stable(tuser)); \
    a_no_x:        assert property (@(posedge clk) disable iff (!rst_n) tvalid |-> !$isunknown(tdata)); \
    c_stall:       cover property  (@(posedge clk) tvalid && !tready ##1 tvalid && tready);

interface axis_src_if #(parameter int DW = 32, parameter int UW = 1) (input logic clk, input logic rst_n);
    logic          tvalid, tready, tlast;
    logic [DW-1:0] tdata;
    logic [UW-1:0] tuser;
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output tvalid, tdata, tlast, tuser;
        input  tready;
    endclocking
    clocking mon_cb @(posedge clk);
        default input #1step;
        input tvalid, tready, tdata, tlast, tuser;
    endclocking
    `AXIS_CHECKS
endinterface

interface axis_snk_if #(parameter int DW = 32, parameter int UW = 1) (input logic clk, input logic rst_n);
    logic          tvalid, tready, tlast;
    logic [DW-1:0] tdata;
    logic [UW-1:0] tuser;
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output tready;
    endclocking
    clocking mon_cb @(posedge clk);
        default input #1step;
        input tvalid, tready, tdata, tlast, tuser;
    endclocking
    `AXIS_CHECKS
endinterface

// ----------------------------------------------------------------- AXI4 read
interface axi_rd_if (input logic clk, input logic rst_n);
    logic        arvalid, arready, rvalid, rready, rlast;
    logic [31:0] araddr;
    logic [7:0]  arlen;
    logic [2:0]  arsize;
    logic [1:0]  arburst, rresp;
    logic [3:0]  arid, rid;
    logic [63:0] rdata;
    clocking slv_cb @(posedge clk);
        default input #1step output #1;
        output arready, rvalid, rdata, rresp, rlast, rid;
        input  arvalid, araddr, arlen, arsize, arburst, arid, rready;
    endclocking
    a_ar_hold:   assert property (@(posedge clk) disable iff (!rst_n)
                                  arvalid && !arready |=> arvalid && $stable(araddr) && $stable(arlen));
    a_ar_size:   assert property (@(posedge clk) disable iff (!rst_n) arvalid |-> arsize == 3'd3 && arburst == 2'b01);
    a_ar_align:  assert property (@(posedge clk) disable iff (!rst_n) arvalid |-> araddr[2:0] == 3'b000);
    a_ar_4k:     assert property (@(posedge clk) disable iff (!rst_n)
                                  arvalid |-> ({1'b0, araddr[11:0]} + ((arlen + 13'd1) << 3)) <= 13'h1000);
    a_r_hold:    assert property (@(posedge clk) disable iff (!rst_n) rvalid && !rready |=> rvalid && $stable(rdata));
    c_ar_wait:   cover property  (@(posedge clk) arvalid && !arready);
endinterface
