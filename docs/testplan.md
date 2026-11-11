# Verification Test Plan: DLRM Embedding-Bag Accelerator

## 1. DUT
`ebag_top`: receives a stream of row indices (bags delimited by TLAST), fetches each in-range row from an
INT8 embedding table over AXI4 (one INCR burst per row, up to MAX_OUT outstanding), pools the rows with
SUM or MAX into DIM × int32, and emits one AXI-Stream beat per bag. Configured over AXI4-Lite.

## 2. Checking strategy
| Checker | Where | What |
|---|---|---|
| Reference model | `tb/ebag_model.py`, `ebag_scoreboard` | per-bag DIM-element vector + valid-row count (TUSER), in order |
| AXI4 read contract | `AxiReadSlave`, `axi_mem_responder`, `axi_rd_if` SVA | ARLEN/ARSIZE/ARBURST, alignment, 4 KB, address inside table, ARVALID hold, **outstanding ≤ MAX_OUT** |
| AXI-Stream rules | `AxisSink`, `axis_*_if` SVA | TVALID hold, payload stable while stalled |
| AXI-Lite | tests + `axil_if` SVA | reset values, WSTRB merge, SLVERR on RO/unmapped, W1C |
| Counters | `test_counters_match_model`, `ebag_vseq` | BAGS_DONE / ROWS_READ / OOB_COUNT vs model |
| Idle | every drain | STATUS.IDLE set when all work retired |

## 3. Features
| ID | Feature | Test | Coverage |
|---|---|---|---|
| F1 | SUM pooling, signed int8 → int32 | `test_random_sum`, directed | `mode_x_bagsize.sum/*`, `value_corner.*` |
| F2 | MAX pooling incl. all-negative rows | `test_random_max`, directed | `mode_x_bagsize.max/*`, `value_corner.max_all_negative` |
| F3 | Out-of-range index skipped (incl. == NUM_ROWS, 0xFFFFFFFF) | directed, random 5–15% OOB | `oob_position.*` |
| F4 | Bag with zero valid rows → zeros, TUSER=0 | directed `[nr]`, random | `mode_x_bagsize.*/no_valid_rows` |
| F5 | Bag ending on an OOB index still completes | directed `[1,2,nr]` | `oob_position.last` |
| F6 | Repeated / hot rows (DLRM skew) | random (40% from 8 hot rows) | `index_pattern.*` |
| F7 | Outstanding-burst limit reached but never exceeded | `test_outstanding_limit` | `outstanding_reached.1..MAX_OUT` |
| F8 | Output back-pressure, slow and bursty memory | `test_backpressure_slow_memory` | `flow_control.*` |
| F9 | RRESP error → sticky RRESP_ERR, W1C | `test_rresp_error` | `registers.rresp_error_seen/w1c_rresp` |
| F10 | Register access rules | `test_registers` | `registers.*` |
| F11 | Parameterisation DIM ∈ {8,16,32}, MAX_OUT ∈ {1,2,4} | `run_all.py --configs` | — |

## 4. Bug-injection campaign
| Define | Fault | Expected detection |
|---|---|---|
| `BUG_OOB_BOUND` | `<=` instead of `<` on NUM_ROWS | address-window check + data mismatch |
| `BUG_OUTSTANDING` | outstanding limit removed | AXI contract checker (data stays correct!) |
| `BUG_EMPTY_LAST` | bag ending in OOB never finishes | timeout / merged bags |
| `BUG_SIGN` | sign bit dropped | data mismatch |
| `BUG_BEAT_ORDER` | beats reversed within a row | data mismatch (DIM ≥ 16) |
| `BUG_MAX_INIT` | MAX seeded with 0 | all-negative MAX bags |
| `BUG_AXIL_STRB` | WSTRB ignored | partial-write register test |

## 5. Exit criteria
0 failures across ≥8 seeds and all configurations · 39/39 coverage bins · all 7 bugs detected · no SVA failures in the UVM run.
