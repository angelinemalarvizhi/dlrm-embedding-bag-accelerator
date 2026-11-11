# Embedding-bag accelerator: regression

## Seed sweep (DIM=16, MAX_OUT=4)

| seed | tests | result |
|---|---|---|
| 2056203223 | 8 | PASS |
| 536599639 | 8 | PASS |
| 1094434982 | 8 | PASS |
| 618976340 | 8 | PASS |
| 1032409210 | 8 | PASS |
| 423905265 | 8 | PASS |
| 44677053 | 8 | PASS |
| 1188293323 | 8 | PASS |

## Configuration matrix

| DIM | MAX_OUT | row beats | result |
|---|---|---|---|
| 8 | 2 | 1 | PASS |
| 16 | 1 | 2 | PASS |
| 16 | 4 | 2 | PASS |
| 32 | 4 | 4 | PASS |

**Checked 6884 bags, 62018 row fetches, 4155 out-of-range indices.**

## Functional coverage: 39/39 (100.0%)

* `mode_x_bagsize` 10/10
* `oob_position` 6/6
* `index_pattern` 4/4
* `value_corner` 5/5
* `outstanding_reached` 4/4
* `flow_control` 4/4
* `registers` 6/6

## Bug-injection campaign

| bug | description | detected | failing tests |
|---|---|---|---|
| `BUG_OOB_BOUND` | index == NUM_ROWS treated as valid (off-by-one) | yes | 5/8: test_directed_bags, test_random_sum, test_random_max, test_backpressure_slow_memory, test_counters_match_model |
| `BUG_OUTSTANDING` | outstanding-burst limit not enforced | yes | 7/8: test_directed_bags, test_random_sum, test_random_max, test_backpressure_slow_memory, test_outstanding_limit, test_rresp_error, test_counters_match_model |
| `BUG_EMPTY_LAST` | bag whose last index is out-of-range never completes | yes | 7/8: test_registers, test_directed_bags, test_random_sum, test_random_max, test_backpressure_slow_memory, test_rresp_error, test_counters_match_model |
| `BUG_SIGN` | int8 sign bit dropped | yes | 8/8: test_registers, test_directed_bags, test_random_sum, test_random_max, test_backpressure_slow_memory, test_outstanding_limit, test_rresp_error, test_counters_match_model |
| `BUG_BEAT_ORDER` | beats of a row written to the wrong elements | yes | 8/8: test_registers, test_directed_bags, test_random_sum, test_random_max, test_backpressure_slow_memory, test_outstanding_limit, test_rresp_error, test_counters_match_model |
| `BUG_MAX_INIT` | MAX pooling seeded with 0 instead of the first row | yes | 3/8: test_directed_bags, test_random_max, test_backpressure_slow_memory |
| `BUG_AXIL_STRB` | AXI-Lite WSTRB ignored | yes | 1/8: test_registers |
