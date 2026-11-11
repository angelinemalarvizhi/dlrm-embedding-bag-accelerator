`timescale 1ns/1ps
`ifndef EBAG_DIM
`define EBAG_DIM 16
`endif
`ifndef EBAG_MAX_OUT
`define EBAG_MAX_OUT 4
`endif
package ebag_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    localparam int DIM = `EBAG_DIM;
    localparam int ROW_BEATS = DIM / 8;
    localparam int MAX_OUT = `EBAG_MAX_OUT;
    localparam bit [7:0] R_CTRL = 8'h00, R_STATUS = 8'h04, R_BASE = 8'h08, R_NROWS = 8'h0C,
                         R_BAGS = 8'h10, R_ROWS = 8'h14, R_OOB = 8'h18, R_PARAMS = 8'h1C;

    // =================================================================== shared state
    // Embedding table + current configuration, shared by the memory responder,
    // the scoreboard and the sequences.
    class ebag_cfg extends uvm_object;
        `uvm_object_utils(ebag_cfg)
        bit [31:0] base = 32'h4000_0000;
        int unsigned num_rows = 64;
        int unsigned alloc_rows = 68;          // 4 guard rows beyond num_rows
        bit mode_max;
        byte table_q[];                        // alloc_rows * DIM bytes
        // flow-control knobs
        int unsigned p_idx_gap = 20, p_out_stall = 30, p_arready = 70, p_rgap = 20;
        int unsigned lat_min = 0, lat_max = 8;
        function new(string name = "ebag_cfg"); super.new(name); endfunction
        function void build_table(int unsigned rows);
            num_rows = rows; alloc_rows = rows + 4;
            table_q = new[alloc_rows * DIM];
            foreach (table_q[i]) begin
                int unsigned p = $urandom_range(0, 99);
                table_q[i] = (p < 5) ? -128 : (p < 10) ? 127 : byte'($urandom());
            end
            // a few whole rows of extremes
            for (int r = 0; r < rows; r += 7)
                for (int e = 0; e < DIM; e++) table_q[r*DIM + e] = (r % 2) ? 127 : -128;
        endfunction
        function byte elem(int unsigned row, int e); return table_q[row*DIM + e]; endfunction
    endclass

    // =================================================================== AXI-Lite agent
    class axil_item extends uvm_sequence_item;
        `uvm_object_utils(axil_item)
        rand bit        write;
        rand bit [7:0]  addr;
        rand bit [31:0] data;
        rand bit [3:0]  strb;
        bit [1:0]       resp;
        constraint c_def { soft strb == 4'hF; addr[1:0] == 0; }
        function new(string name = "axil_item"); super.new(name); endfunction
    endclass
    typedef uvm_sequencer #(axil_item) axil_sequencer;

    class axil_driver extends uvm_driver #(axil_item);
        `uvm_component_utils(axil_driver)
        virtual axil_if vif;
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual axil_if)::get(this, "", "axil_vif", vif)) `uvm_fatal("VIF", "axil_vif")
        endfunction
        task run_phase(uvm_phase phase);
            vif.cb.awvalid <= 0; vif.cb.wvalid <= 0; vif.cb.bready <= 0; vif.cb.arvalid <= 0; vif.cb.rready <= 0;
            @(posedge vif.rst_n);
            forever begin
                seq_item_port.get_next_item(req);
                @(vif.cb);
                if (req.write) begin
                    vif.cb.awvalid <= 1; vif.cb.awaddr <= req.addr;
                    vif.cb.wvalid  <= 1; vif.cb.wdata  <= req.data; vif.cb.wstrb <= req.strb;
                    do @(vif.cb); while (!(vif.cb.awready && vif.cb.wready));
                    vif.cb.awvalid <= 0; vif.cb.wvalid <= 0; vif.cb.bready <= 1;
                    do @(vif.cb); while (!vif.cb.bvalid);
                    req.resp = vif.cb.bresp;
                    vif.cb.bready <= 0;
                end else begin
                    vif.cb.arvalid <= 1; vif.cb.araddr <= req.addr;
                    do @(vif.cb); while (!vif.cb.arready);
                    vif.cb.arvalid <= 0; vif.cb.rready <= 1;
                    do @(vif.cb); while (!vif.cb.rvalid);
                    req.data = vif.cb.rdata; req.resp = vif.cb.rresp;
                    vif.cb.rready <= 0;
                end
                seq_item_port.item_done();
            end
        endtask
    endclass

    // =================================================================== index stream agent
    class idx_item extends uvm_sequence_item;
        `uvm_object_utils(idx_item)
        rand bit [31:0] index;
        rand bit        last;
        function new(string name = "idx_item"); super.new(name); endfunction
    endclass
    typedef uvm_sequencer #(idx_item) idx_sequencer;

    class idx_driver extends uvm_driver #(idx_item);
        `uvm_component_utils(idx_driver)
        virtual axis_src_if #(32, 1) vif;
        ebag_cfg cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual axis_src_if #(32, 1))::get(this, "", "idx_vif", vif)) `uvm_fatal("VIF", "idx_vif")
            if (!uvm_config_db#(ebag_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("CFG", "cfg")
        endfunction
        task run_phase(uvm_phase phase);
            vif.drv_cb.tvalid <= 0;
            @(posedge vif.rst_n);
            forever begin
                seq_item_port.get_next_item(req);
                @(vif.drv_cb);
                while ($urandom_range(0, 99) < cfg.p_idx_gap) begin vif.drv_cb.tvalid <= 0; @(vif.drv_cb); end
                vif.drv_cb.tvalid <= 1; vif.drv_cb.tdata <= req.index; vif.drv_cb.tlast <= req.last;
                vif.drv_cb.tuser <= 0;
                do @(vif.drv_cb); while (!vif.drv_cb.tready);
                vif.drv_cb.tvalid <= 0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    class idx_monitor extends uvm_monitor;
        `uvm_component_utils(idx_monitor)
        virtual axis_src_if #(32, 1) vif;
        uvm_analysis_port #(idx_item) ap;
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void build_phase(uvm_phase phase);
            ap = new("ap", this);
            if (!uvm_config_db#(virtual axis_src_if #(32, 1))::get(this, "", "idx_vif", vif)) `uvm_fatal("VIF", "idx_vif")
        endfunction
        task run_phase(uvm_phase phase);
            forever begin
                @(vif.mon_cb);
                if (vif.mon_cb.tvalid && vif.mon_cb.tready) begin
                    idx_item t = idx_item::type_id::create("t");
                    t.index = vif.mon_cb.tdata; t.last = vif.mon_cb.tlast;
                    ap.write(t);
                end
            end
        endtask
    endclass

    class idx_agent extends uvm_agent;
        `uvm_component_utils(idx_agent)
        idx_sequencer sqr; idx_driver drv; idx_monitor mon;
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void build_phase(uvm_phase phase);
            sqr = idx_sequencer::type_id::create("sqr", this);
            drv = idx_driver::type_id::create("drv", this);
            mon = idx_monitor::type_id::create("mon", this);
        endfunction
        function void connect_phase(uvm_phase phase); drv.seq_item_port.connect(sqr.seq_item_export); endfunction
    endclass

    // =================================================================== output stream (sink)
    class out_item extends uvm_sequence_item;
        `uvm_object_utils(out_item)
        bit [32*DIM-1:0] data;
        bit [15:0]       nrows;
        bit              was_stalled;
        function new(string name = "out_item"); super.new(name); endfunction
    endclass

    class out_sink extends uvm_component;      // reactive TREADY driver + monitor
        `uvm_component_utils(out_sink)
        virtual axis_snk_if #(32*DIM, 16) vif;
        ebag_cfg cfg;
        uvm_analysis_port #(out_item) ap;
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void build_phase(uvm_phase phase);
            ap = new("ap", this);
            if (!uvm_config_db#(virtual axis_snk_if #(32*DIM, 16))::get(this, "", "out_vif", vif)) `uvm_fatal("VIF", "out_vif")
            if (!uvm_config_db#(ebag_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("CFG", "cfg")
        endfunction
        task run_phase(uvm_phase phase);
            bit stalled;
            vif.drv_cb.tready <= 0;
            forever begin
                @(vif.mon_cb);
                if (vif.mon_cb.tvalid && vif.mon_cb.tready) begin
                    out_item t = out_item::type_id::create("t");
                    t.data = vif.mon_cb.tdata; t.nrows = vif.mon_cb.tuser; t.was_stalled = stalled;
                    ap.write(t);
                    stalled = 0;
                end else if (vif.mon_cb.tvalid) stalled = 1;
                vif.drv_cb.tready <= ($urandom_range(0, 99) >= cfg.p_out_stall);
            end
        endtask
    endclass

    // =================================================================== AXI4 read memory responder
    class axi_mem_responder extends uvm_component;
        `uvm_component_utils(axi_mem_responder)
        virtual axi_rd_if vif;
        ebag_cfg cfg;
        typedef struct { bit [31:0] addr; int len; int sent; longint ready_at; } burst_t;
        burst_t q[$];
        int unsigned max_outstanding_seen, bursts;
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual axi_rd_if)::get(this, "", "axi_vif", vif)) `uvm_fatal("VIF", "axi_vif")
            if (!uvm_config_db#(ebag_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("CFG", "cfg")
        endfunction
        function bit [63:0] beat_data(bit [31:0] addr);
            bit [63:0] d;
            int off = int'(longint'(addr) - longint'(cfg.base));
            for (int b = 0; b < 8; b++) begin
                int i = off + b;
                d[8*b +: 8] = (i >= 0 && i < cfg.table_q.size()) ? cfg.table_q[i] : 8'hEE;
            end
            return d;
        endfunction
        task run_phase(uvm_phase phase);
            bit ar_rdy, r_pend;
            longint cyc;
            vif.slv_cb.arready <= 0; vif.slv_cb.rvalid <= 0;
            forever begin
                @(vif.slv_cb);
                cyc++;
                // R handshake completed at this edge?
                if (r_pend && vif.slv_cb.rready) begin
                    r_pend = 0;
                    q[0].sent++;
                    if (q[0].sent == q[0].len) void'(q.pop_front());
                end
                // AR handshake completed at this edge?
                if (ar_rdy && vif.slv_cb.arvalid) begin
                    burst_t b;
                    bit [31:0] a = vif.slv_cb.araddr;
                    if (vif.slv_cb.arlen != ROW_BEATS - 1) `uvm_error("AXI", $sformatf("ARLEN=%0d", vif.slv_cb.arlen))
                    if (a < cfg.base || a + 8*ROW_BEATS > cfg.base + cfg.num_rows*DIM)
                        `uvm_error("AXI", $sformatf("read 0x%08h outside table", a))
                    b.addr = a; b.len = vif.slv_cb.arlen + 1; b.sent = 0;
                    b.ready_at = cyc + $urandom_range(cfg.lat_min, cfg.lat_max);
                    q.push_back(b);
                    bursts++;
                    if (q.size() > MAX_OUT) `uvm_error("AXI", $sformatf("%0d outstanding > %0d", q.size(), MAX_OUT))
                    if (q.size() > max_outstanding_seen) max_outstanding_seen = q.size();
                end
                ar_rdy = ($urandom_range(0, 99) < cfg.p_arready);
                vif.slv_cb.arready <= ar_rdy;
                if (!r_pend && q.size() > 0 && q[0].ready_at <= cyc && $urandom_range(0, 99) >= cfg.p_rgap) begin
                    r_pend = 1;
                    vif.slv_cb.rdata <= beat_data(q[0].addr + 8 * q[0].sent);
                    vif.slv_cb.rlast <= (q[0].sent == q[0].len - 1);
                    vif.slv_cb.rresp <= 2'b00;
                    vif.slv_cb.rid   <= 0;
                end
                vif.slv_cb.rvalid <= r_pend;
            end
        endtask
        function void report_phase(uvm_phase phase);
            `uvm_info("AXI", $sformatf("bursts=%0d max outstanding=%0d (limit %0d)", bursts,
                                       max_outstanding_seen, MAX_OUT), UVM_NONE)
        endfunction
    endclass

    // =================================================================== scoreboard
    `uvm_analysis_imp_decl(_idx)
    `uvm_analysis_imp_decl(_out)
    class ebag_scoreboard extends uvm_component;
        `uvm_component_utils(ebag_scoreboard)
        uvm_analysis_imp_idx #(idx_item, ebag_scoreboard) idx_imp;
        uvm_analysis_imp_out #(out_item, ebag_scoreboard) out_imp;
        ebag_cfg cfg;
        bit [31:0] cur_bag[$];
        typedef struct { int vec[DIM]; int nrows; int size; bit mode_max; } exp_t;
        exp_t expq[$];
        int unsigned n_bags_checked, n_errors;
        // coverage of what was checked
        int bag_size, bag_valid; bit bag_mode, bag_has_oob, stalled;
        covergroup cg_bag;
            option.per_instance = 1;
            option.name = "bag";
            cp_mode:  coverpoint bag_mode;
            cp_valid: coverpoint bag_valid { bins none = {0}; bins one = {1}; bins few = {[2:4]};
                                             bins many = {[5:16]}; bins lots = {[17:$]}; }
            cp_oob:   coverpoint bag_has_oob;
            cp_stall: coverpoint stalled;
            x_mode_size: cross cp_mode, cp_valid;
            x_mode_oob:  cross cp_mode, cp_oob;
        endgroup
        function new(string n, uvm_component p); super.new(n, p); cg_bag = new(); endfunction
        function void build_phase(uvm_phase phase);
            idx_imp = new("idx_imp", this); out_imp = new("out_imp", this);
            if (!uvm_config_db#(ebag_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("CFG", "cfg")
        endfunction

        function void write_idx(idx_item t);
            cur_bag.push_back(t.index);
            if (t.last) begin
                exp_t x;
                x.nrows = 0; x.size = cur_bag.size(); x.mode_max = cfg.mode_max;
                foreach (x.vec[e]) x.vec[e] = 0;
                foreach (cur_bag[i]) begin
                    if (cur_bag[i] >= cfg.num_rows) continue;
                    for (int e = 0; e < DIM; e++) begin
                        int v = cfg.elem(cur_bag[i], e);
                        if (!cfg.mode_max) x.vec[e] += v;
                        else if (x.nrows == 0 || v > x.vec[e]) x.vec[e] = v;
                    end
                    x.nrows++;
                end
                expq.push_back(x);
                cur_bag.delete();
            end
        endfunction

        function void write_out(out_item t);
            exp_t x;
            if (expq.size() == 0) begin `uvm_error("SB", "output bag with no matching input bag") return; end
            x = expq.pop_front();
            if (t.nrows != x.nrows) begin
                n_errors++;
                `uvm_error("SB", $sformatf("bag %0d: TUSER rows exp %0d got %0d", n_bags_checked, x.nrows, t.nrows))
            end
            for (int e = 0; e < DIM; e++)
                if ($signed(t.data[32*e +: 32]) != x.vec[e]) begin
                    n_errors++;
                    `uvm_error("SB", $sformatf("bag %0d (%s) elem %0d: exp %0d got %0d", n_bags_checked,
                               x.mode_max ? "MAX" : "SUM", e, x.vec[e], $signed(t.data[32*e +: 32])))
                    break;
                end
            bag_mode = x.mode_max; bag_valid = x.nrows; bag_has_oob = (x.nrows != x.size);
            stalled = t.was_stalled;
            cg_bag.sample();
            n_bags_checked++;
        endfunction

        function void check_phase(uvm_phase phase);
            if (expq.size() != 0) `uvm_error("SB", $sformatf("%0d bags never came out", expq.size()))
            if (cur_bag.size() != 0) `uvm_error("SB", "partial bag left at end of test (missing TLAST)")
            if (n_bags_checked == 0) `uvm_error("SB", "no bags were checked")
        endfunction
        function void report_phase(uvm_phase phase);
            `uvm_info("SB", $sformatf("bags checked=%0d  mismatches=%0d  coverage=%.1f%%",
                                      n_bags_checked, n_errors, cg_bag.get_coverage()), UVM_NONE)
        endfunction
    endclass

    // =================================================================== env
    class ebag_env extends uvm_env;
        `uvm_component_utils(ebag_env)
        axil_sequencer axil_sqr; axil_driver axil_drv;
        idx_agent idx; out_sink out; axi_mem_responder mem; ebag_scoreboard sb;
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void build_phase(uvm_phase phase);
            axil_sqr = axil_sequencer::type_id::create("axil_sqr", this);
            axil_drv = axil_driver::type_id::create("axil_drv", this);
            idx = idx_agent::type_id::create("idx", this);
            out = out_sink::type_id::create("out", this);
            mem = axi_mem_responder::type_id::create("mem", this);
            sb  = ebag_scoreboard::type_id::create("sb", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            axil_drv.seq_item_port.connect(axil_sqr.seq_item_export);
            idx.mon.ap.connect(sb.idx_imp);
            out.ap.connect(sb.out_imp);
        endfunction
    endclass

    // =================================================================== sequences
    class axil_rw_seq extends uvm_sequence #(axil_item);
        `uvm_object_utils(axil_rw_seq)
        bit write; bit [7:0] addr; bit [31:0] data; bit [3:0] strb = 4'hF; bit [1:0] resp;
        function new(string name = "axil_rw_seq"); super.new(name); endfunction
        task body();
            axil_item t = axil_item::type_id::create("t");
            start_item(t);
            if (!t.randomize() with { write == local::write; addr == local::addr;
                                      data == local::data; strb == local::strb; }) `uvm_fatal("RND", "axil")
            finish_item(t);
            data = t.data; resp = t.resp;
        endtask
    endclass

    class bag_seq extends uvm_sequence #(idx_item);
        `uvm_object_utils(bag_seq)
        rand int unsigned size;
        int unsigned num_rows;     // set before randomize()
        rand bit [31:0] idx[];
        constraint c_size { size dist { 1 := 15, [2:4] := 30, [5:16] := 35, [17:40] := 20 }; }
        constraint c_arr  { idx.size() == size; }
        constraint c_idx  { foreach (idx[i]) idx[i] dist { [0:7] :/ 40, [0:num_rows-1] :/ 55,
                                                          num_rows := 2, [num_rows+1:num_rows+1000] :/ 2,
                                                          32'hFFFF_FFFF := 1 }; }
        function new(string name = "bag_seq"); super.new(name); endfunction
        task body();
            foreach (idx[i]) begin
                idx_item t = idx_item::type_id::create("t");
                start_item(t);
                t.index = idx[i]; t.last = (i == idx.size() - 1);
                finish_item(t);
            end
        endtask
    endclass

    // Configure, run N random bags, wait until idle, check counters.
    class ebag_vseq extends uvm_sequence;
        `uvm_object_utils(ebag_vseq)
        ebag_env env; ebag_cfg cfg;
        int unsigned n_bags = 200;
        function new(string name = "ebag_vseq"); super.new(name); endfunction
        task reg_wr(bit [7:0] a, bit [31:0] d);
            axil_rw_seq s = axil_rw_seq::type_id::create("w");
            s.write = 1; s.addr = a; s.data = d; s.start(env.axil_sqr);
            if (s.resp != 0) `uvm_error("REG", $sformatf("write 0x%02h resp %0d", a, s.resp))
        endtask
        task reg_rd(bit [7:0] a, output bit [31:0] d);
            axil_rw_seq s = axil_rw_seq::type_id::create("r");
            s.write = 0; s.addr = a; s.data = 0; s.start(env.axil_sqr);
            d = s.data;
        endtask
        task body();
            bit [31:0] v;
            reg_rd(R_PARAMS, v);
            if (v != {8'hEB, 8'(DIM), 8'(ROW_BEATS), 8'(MAX_OUT)}) `uvm_error("REG", $sformatf("PARAMS=0x%08h", v))
            reg_wr(R_BASE, cfg.base);
            reg_wr(R_NROWS, cfg.num_rows);
            reg_wr(R_CTRL, {30'd0, cfg.mode_max, 1'b1});
            repeat (n_bags) begin
                bag_seq b = bag_seq::type_id::create("b");
                b.num_rows = cfg.num_rows;
                if (!b.randomize()) `uvm_fatal("RND", "bag")
                b.start(env.idx.sqr);
            end
            // directed corner: bags whose indices are all out of range (output = zero vector, TUSER = 0).
            // Random stimulus hits this <1 time per 600 bags, so it is forced here.
            begin
                bag_seq b1 = bag_seq::type_id::create("oob1"), b3 = bag_seq::type_id::create("oob3");
                b1.idx = '{cfg.num_rows};
                b3.idx = '{cfg.num_rows + 7, 32'hFFFF_FFFF, cfg.num_rows};
                b1.start(env.idx.sqr);
                b3.start(env.idx.sqr);
            end
            // wait for the engine to drain
            do reg_rd(R_STATUS, v); while (!v[0] || env.sb.expq.size() != 0);
            reg_rd(R_BAGS, v);
            if (v != env.sb.n_bags_checked) `uvm_error("REG", $sformatf("BAGS_DONE=%0d, scoreboard saw %0d", v, env.sb.n_bags_checked))
        endtask
    endclass

    // =================================================================== tests
    class ebag_base_test extends uvm_test;
        `uvm_component_utils(ebag_base_test)
        ebag_env env; ebag_cfg cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction
        virtual function void tune(); endfunction
        function void build_phase(uvm_phase phase);
            cfg = ebag_cfg::type_id::create("cfg");
            cfg.build_table(64);
            tune();
            uvm_config_db#(ebag_cfg)::set(this, "*", "cfg", cfg);
            env = ebag_env::type_id::create("env", this);
        endfunction
        task run_phase(uvm_phase phase);
            ebag_vseq v = ebag_vseq::type_id::create("v");
            int unsigned n = 200;
            void'($value$plusargs("NUM_BAGS=%d", n));
            v.env = env; v.cfg = cfg; v.n_bags = n;
            phase.raise_objection(this);
            v.start(null);
            phase.drop_objection(this);
        endtask
        function void report_phase(uvm_phase phase);
            uvm_report_server rs = uvm_report_server::get_server();
            `uvm_info("TEST", (rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL)) == 0 ?
                      "*** TEST PASSED ***" : "*** TEST FAILED ***", UVM_NONE)
        endfunction
    endclass

    class ebag_sum_test extends ebag_base_test;
        `uvm_component_utils(ebag_sum_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
    endclass

    class ebag_max_test extends ebag_base_test;
        `uvm_component_utils(ebag_max_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void tune(); cfg.mode_max = 1; endfunction
    endclass

    class ebag_stress_test extends ebag_base_test;
        `uvm_component_utils(ebag_stress_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void tune();
            cfg.p_out_stall = 75; cfg.p_arready = 30; cfg.p_rgap = 50; cfg.lat_min = 5; cfg.lat_max = 30;
            cfg.p_idx_gap = 40; cfg.mode_max = $urandom_range(0, 1);
        endfunction
    endclass

    // SUM pass then MAX pass in one run (counters are cumulative), so one log shows full mode coverage.
    class ebag_full_test extends ebag_base_test;
        `uvm_component_utils(ebag_full_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        task run_phase(uvm_phase phase);
            int unsigned n = 200;
            void'($value$plusargs("NUM_BAGS=%d", n));
            phase.raise_objection(this);
            for (int m = 0; m < 2; m++) begin
                ebag_vseq v = ebag_vseq::type_id::create($sformatf("v%0d", m));
                cfg.mode_max = m;
                v.env = env; v.cfg = cfg; v.n_bags = n;
                v.start(null);
            end
            phase.drop_objection(this);
        endtask
    endclass
endpackage
