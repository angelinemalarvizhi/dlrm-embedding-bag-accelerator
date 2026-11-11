# UVM environment

```
tb_top
 ├─ axil_if ─────── axil_driver  ◄── axil_sequencer ◄── ebag_vseq (configure, run bags, check counters)
 ├─ axis_src_if ─── idx_agent (driver + monitor) ◄── bag_seq (rand size/indices, OOB + hot-row dist)
 ├─ axi_rd_if ───── axi_mem_responder  (reactive AXI4 slave, random latency, outstanding check)
 ├─ axis_snk_if ─── out_sink (random TREADY + monitor)
 └─ ebag_scoreboard: bags assembled from idx monitor → SV reference model → compare with out_sink
                     + covergroup (mode × valid-rows, mode × OOB, stall)
```
All four interfaces carry SVA protocol assertions (`ebag_ifs.sv`).

Tests: `ebag_sum_test`, `ebag_max_test`, `ebag_stress_test` (heavy back-pressure, slow memory). `+NUM_BAGS=<n>` (default 200).

## Run
```bash
cd uvm
# Cadence Xcelium
xrun -uvm -sv -f files.f +UVM_TESTNAME=ebag_sum_test +NUM_BAGS=300 -access +r
# Synopsys VCS
vcs -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -f files.f -o simv && ./simv +UVM_TESTNAME=ebag_max_test
# Siemens Questa
qrun -uvm -f files.f +UVM_TESTNAME=ebag_stress_test
```
Other configuration: add `+define+EBAG_DIM=32 +define+EBAG_MAX_OUT=2`.
Bug injection: add `+define+BUG_MAX_INIT` (or any `BUG_*` in `rtl/`) and confirm `UVM_ERROR` > 0.

EDA Playground: Testbench pane = `tb_top.sv` with `` `include "ebag_ifs.sv" `` and `` `include "ebag_pkg.sv" `` at the top,
plus tabs for those two files; Design pane = the four files in `../rtl/`. Select UVM 1.2 + Xcelium or VCS.

## Results (Cadence Xcelium 25.03, UVM 1.2, run on EDA Playground)

| Run | Result |
|---|---|
| `ebag_full_test +NUM_BAGS=300` (SUM pass then MAX pass) | PASS, `UVM_ERROR: 0`; 604 bags checked, 0 mismatches, functional coverage 100% |
| `ebag_stress_test +NUM_BAGS=300` (heavy back-pressure, slow memory) | PASS, `UVM_ERROR: 0`; 302 bags checked |
| `ebag_max_test` with `+define+BUG_MAX_INIT` | FAIL (as intended): 32 mismatches, every one a bag whose column maximum is negative (hardware returns 0) |
| AXI outstanding reads | reached and never exceeded the limit (max 4, limit 4) |

Logs are in `uvm/logs/`. Coverage closure: the first full run reached 93.3%; the missing bin was "bag with all indices out of range", which random stimulus hits less than once per 600 bags, so two directed all-OOB bags were added to the sequence.
