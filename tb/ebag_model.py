"""Reference model for the embedding-bag engine.

Semantics follow torch.nn.EmbeddingBag(mode='sum' | 'max') with two additions
that the hardware defines: out-of-range indices are skipped, and a bag with
no valid rows produces zeros. Accumulation is int32."""
import numpy as np


class EmbeddingTable:
    def __init__(self, rng, num_rows, dim, guard_rows=4, special=0.15):
        self.num_rows, self.dim = num_rows, dim
        total = num_rows + guard_rows                       # guard rows catch off-by-one reads
        w = rng.integers(-128, 128, size=(total, dim), dtype=np.int16)
        for r in range(total):
            p = rng.random()
            if p < special / 3:
                w[r, :] = -128
            elif p < 2 * special / 3:
                w[r, :] = 127
            elif p < special:
                w[r, :] = rng.choice([-128, -1, 0, 1, 127], size=dim)
        self.w = w.astype(np.int8)
        self.blob = self.w.tobytes()

    def read(self, offset, n):
        return self.blob[offset:offset + n]


def pool(table, bag, mode_max):
    """bag: list of indices. Returns (int32 vector, number of valid rows)."""
    rows = [i for i in bag if 0 <= i < table.num_rows]
    if not rows:
        return np.zeros(table.dim, dtype=np.int64), 0
    m = table.w[rows].astype(np.int64)
    return (m.max(axis=0) if mode_max else m.sum(axis=0)), len(rows)


def unpack(tdata, dim):
    out = np.empty(dim, dtype=np.int64)
    for e in range(dim):
        v = (tdata >> (32 * e)) & 0xFFFFFFFF
        out[e] = v - (1 << 32) if v & 0x80000000 else v
    return out
