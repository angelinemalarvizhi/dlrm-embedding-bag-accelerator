# DLRM Embedding-Bag Accelerator: Design and Verification

Recommendation models (DLRM) spend most of their inference time on **embedding-bag** lookups:
gather a variable number of rows from a large table, then sum or max them. This repository contains a hardware
engine for that operation, with an **AXI4 read master**, **AXI-Stream** index/result streams and **AXI4-Lite** control.
It is verified by a **cocotb constrained-random environment** and a **UVM environment with SVA**, plus a bug-injection
campaign and a configuration matrix.

[![regression](https://github.com/angelinemalarvizhi/dlrm-embedding-bag-accelerator/actions/workflows/regression.yml/badge.svg)](https://github.com/angelinemalarvizhi/dlrm-embedding-bag-accelerator/actions)

## Architecture
```
  s_idx (AXIS)                                         AXI4 read (64-bit)
 index, TLAST=end of bag    ┌──────────────── ebag_engine ────────────────┐    AR: base + idx*DIM, INCR, DIM/8 beats
 ─────────────────────────► │ bounds check ──► AR issue ──────────────────┼──► (≤ MAX_OUT outstanding, in-order)
                            │  (idx < NUM_ROWS)    │                      │
                            │        └─► tag FIFO {last, valid} ───┐      │ ◄── R: rdata, rlast, rresp
                            │                                       ▼      │
                            │   SUM: acc += int8   /  MAX: acc = max ◄─────┤
                            │   DIM × int32 accumulators                   │
  m_out (AXIS)              │                     bag done ──► out reg ────┼──► one beat / bag
 ◄───────────────────────── │                                  TUSER = #rows pooled
                            └──────────────────────────────────────────────┘
                     AXI4-Lite ──► ebag_regs (CTRL, STATUS, TABLE_BASE, NUM_ROWS, counters, PARAMS)
```
* Out-of-range indices are **skipped** without a memory access, counted, and flagged in STATUS. A bag with no valid rows outputs zeros.
* The tag FIFO keeps bag boundaries aligned with in-order read data, so the AR side can run up to `MAX_OUT` rows ahead.
* Parameters: `DIM` (int8 elements per row, multiple of 8), `MAX_OUT` (outstanding bursts).

| Offset | Register | Access | Description |
|---|---|---|---|
| 0x00 | CTRL | RW | [0] ENABLE, [1] MODE (0 SUM / 1 MAX) |
| 0x04 | STATUS | R / W1C | [0] IDLE, [1] OOB_SEEN, [2] RRESP_ERR |
| 0x08 | TABLE_BASE | RW | byte address of row 0 |
| 0x0C | NUM_ROWS | RW | table size in rows |
| 0x10 / 0x14 / 0x18 | BAGS_DONE / ROWS_READ / OOB_COUNT | RO | event counters |
| 0x1C | PARAMS | RO | `{0xEB, DIM, ROW_BEATS, MAX_OUT}` |

## Verification
| | cocotb (`tb/`) | UVM (`uvm/`) |
|---|---|---|
| Stimulus | DLRM-like bags: 1–40 indices, 40% from 8 hot rows, 5–15% out of range | `bag_seq` with the same distribution |
| Memory | `AxiReadSlave`: random ARREADY, 0–40 cycle latency, R gaps, SLVERR injection | `axi_mem_responder` |
| Checking | NumPy model, per-bag vector + TUSER, counters, IDLE | `ebag_scoreboard` (SV model) |
| Protocol | AXI4 / AXIS / AXI-Lite rule checks in the BFMs | SVA in all 4 interfaces |
| Coverage | 39 bins (mode × bag size, OOB position, values, outstanding depth, flow control, registers) | covergroup with 2 crosses |

Plan: [`docs/testplan.md`](docs/testplan.md) · UVM: [`uvm/README.md`](uvm/README.md)

## Results
| Metric | Result |
|---|---|
| Seeds × tests | 8 × 8, all pass |
| Configurations | DIM ∈ {8, 16, 32} × MAX_OUT ∈ {1, 2, 4}: all pass |
| Bags checked | **~6,900** (~62,000 row fetches, ~4,100 out-of-range indices) |
| Functional coverage | **39/39 bins (100%)** |
| Injected bugs detected | **7/7** |

| Injected bug | Detected by |
|---|---|
| `BUG_OOB_BOUND`: index == NUM_ROWS fetched | address-window checker + data mismatch |
| `BUG_OUTSTANDING`: no outstanding limit | **AXI contract checker only**: the results are still correct |
| `BUG_EMPTY_LAST`: bag ending in OOB never completes | timeout / bag count |
| `BUG_SIGN`: int8 sign dropped | data mismatch |
| `BUG_BEAT_ORDER`: beats reversed | data mismatch |
| `BUG_MAX_INIT`: MAX seeded with 0 | all-negative MAX bags |
| `BUG_AXIL_STRB`: WSTRB ignored | partial register write test |

`BUG_OUTSTANDING` shows why protocol checkers matter: the computed results stay correct, so a scoreboard alone
would never see it. Only the interface-contract check catches the violation.

## Run it
```bash
sudo apt install -y iverilog python3-pip make
pip install -r requirements.txt

make                                     # 8 tests, DIM=16, MAX_OUT=4
make DIM=32 MAX_OUT=2 NUM_BAGS=300       # other configuration
make DEFINES=BUG_MAX_INIT                # inject a bug -> must FAIL
python3 scripts/run_all.py --seeds 8 --bags 200 --configs --bugs
cat results/REGRESSION.md
```

## Structure
```
rtl/      ebag_top.v  ebag_engine.v  ebag_regs.v  sync_fifo.v
tb/       test_ebag.py  bus.py (AXI-Lite/AXIS/AXI4 BFMs)  ebag_model.py  ebag_cov.py
uvm/      ebag_ifs.sv (SVA)  ebag_pkg.sv  tb_top.sv  files.f
scripts/  run_all.py
docs/     testplan.md
```

## Next steps
- Multiple AXI IDs with out-of-order return and a reorder buffer
- MEAN mode and per-sample weights (`per_sample_weights` in PyTorch)
- Cross-check the model against `torch.nn.functional.embedding_bag`
- Throughput study: rows/cycle against MAX_OUT and memory latency
- FPGA bring-up on PYNQ-Z2 with the table in DDR
