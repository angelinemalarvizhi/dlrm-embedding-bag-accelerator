"""Functional coverage for the embedding-bag engine."""
import json
import os

SIZE_BINS = [(0, "no_valid_rows"), (1, "1"), (4, "2-4"), (16, "5-16"), (10**9, "17+")]


class EbagCoverage:
    def __init__(self, max_out=4):
        self.cp = {
            "mode_x_bagsize": {f"{m}/{s}": 0 for m in ("sum", "max") for _, s in SIZE_BINS},
            "oob_position": dict.fromkeys(["first", "middle", "last", "only", "boundary_eq_num_rows",
                                           "index_0xffffffff"], 0),
            "index_pattern": dict.fromkeys(["repeated_in_bag", "row_0", "last_row", "hot_row_reuse"], 0),
            "value_corner": dict.fromkeys(["sum_all_127", "sum_all_neg128", "max_all_negative",
                                           "result_neg_large", "result_pos_large"], 0),
            "outstanding_reached": {str(k): 0 for k in range(1, max_out + 1)},
            "flow_control": dict.fromkeys(["out_stalled_while_valid", "idx_gap", "r_gap_or_latency",
                                           "ar_not_ready"], 0),
            "registers": dict.fromkeys(["slverr_unmapped", "slverr_ro_write", "partial_wstrb",
                                        "w1c_oob", "w1c_rresp", "rresp_error_seen"], 0),
        }
        self.prev_valid = set()

    def hit(self, p, b, n=1):
        self.cp[p][b] += n

    def sample_bag(self, bag, num_rows, mode_max, result, nvalid, table):
        m = "max" if mode_max else "sum"
        self.hit("mode_x_bagsize", f"{m}/{next(s for lim, s in SIZE_BINS if nvalid <= lim)}")
        oob = [i for i, x in enumerate(bag) if not 0 <= x < num_rows]
        for i in oob:
            if len(bag) == 1:
                self.hit("oob_position", "only")
            elif i == 0:
                self.hit("oob_position", "first")
            elif i == len(bag) - 1:
                self.hit("oob_position", "last")
            else:
                self.hit("oob_position", "middle")
            if bag[i] == num_rows:
                self.hit("oob_position", "boundary_eq_num_rows")
            if bag[i] == 0xFFFFFFFF:
                self.hit("oob_position", "index_0xffffffff")
        valid = [x for x in bag if 0 <= x < num_rows]
        if len(set(valid)) < len(valid):
            self.hit("index_pattern", "repeated_in_bag")
        if 0 in valid:
            self.hit("index_pattern", "row_0")
        if num_rows - 1 in valid:
            self.hit("index_pattern", "last_row")
        if self.prev_valid & set(valid):
            self.hit("index_pattern", "hot_row_reuse")      # row re-fetched by the next bag
        self.prev_valid = set(valid)
        if valid:
            rows = table.w[valid]
            if not mode_max and (rows == 127).all():
                self.hit("value_corner", "sum_all_127")
            if not mode_max and (rows == -128).all():
                self.hit("value_corner", "sum_all_neg128")
            if mode_max and (rows < 0).all(axis=0).any():
                self.hit("value_corner", "max_all_negative")
            if result.min() < -2000:
                self.hit("value_corner", "result_neg_large")
            if result.max() > 2000:
                self.hit("value_corner", "result_pos_large")

    def score(self):
        b = [c for d in self.cp.values() for c in d.values()]
        return sum(1 for c in b if c), len(b)

    def holes(self):
        return [f"{p}:{k}" for p, d in self.cp.items() for k, c in d.items() if not c]

    def save(self, path):
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "w") as f:
            json.dump(self.cp, f, indent=2)


COV = EbagCoverage()
