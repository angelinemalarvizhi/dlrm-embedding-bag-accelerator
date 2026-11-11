"""cocotb tests for the DLRM embedding-bag accelerator (ebag_top)."""
import os
import random

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

from bus import AxiLiteMaster, AxiReadSlave, AxisSink, AxisSource
from ebag_cov import COV
from ebag_model import EmbeddingTable, pool, unpack

CTRL, STATUS, BASE, NROWS, BAGS, ROWS, OOBC, PARAMS = range(0, 0x20, 4)
NUM_BAGS = int(os.environ.get("NUM_BAGS", "150"))
COV_FILE = os.environ.get("COV_FILE", "results/coverage.json")
STATS = {"bags": 0, "rows": 0, "oob": 0}


class Env:
    """Builds BFMs around the DUT, holds the table and the expected-result queue."""

    def __init__(self, dut, num_rows=64, p_gap=0.2, p_stall=0.3, p_arready=0.7, latency=(0, 8),
                 p_rgap=0.2, p_slverr=0.0, seed=None):
        self.dut = dut
        self.rng = random.Random(seed if seed is not None else random.getrandbits(32))
        self.np_rng = np.random.default_rng(self.rng.getrandbits(32))
        self.num_rows = num_rows
        self.cfg = dict(p_gap=p_gap, p_stall=p_stall, p_arready=p_arready, latency=latency,
                        p_rgap=p_rgap, p_slverr=p_slverr)

    async def start(self):
        d = self.dut
        cocotb.start_soon(Clock(d.clk, 10, unit="ns").start())
        self.axil = AxiLiteMaster(d, d.clk)
        d.rst_n.value = 0
        await ClockCycles(d.clk, 4)
        d.rst_n.value = 1
        await ClockCycles(d.clk, 2)
        params, _ = await self.axil.read(PARAMS)
        assert params >> 24 == 0xEB, f"PARAMS=0x{params:08x}"
        self.dim, self.beats, self.max_out = (params >> 16) & 0xFF, (params >> 8) & 0xFF, params & 0xFF
        assert self.dim == 8 * self.beats
        self.base = 0x4000_0000 + 0x10000 * self.rng.randint(0, 255)
        self.table = EmbeddingTable(self.np_rng, self.num_rows, self.dim)
        c = self.cfg
        self.idx = AxisSource(d, d.clk, "s_idx", self.rng, c["p_gap"])
        self.out = AxisSink(d, d.clk, "m_out", self.rng, c["p_stall"])
        self.mem = AxiReadSlave(d, d.clk, lambda a, n: self.table.read(a - self.base, n), self.rng,
                                c["p_arready"], c["latency"], c["p_rgap"], self.beats, self.max_out,
                                (self.base, self.base + self.num_rows * self.dim), c["p_slverr"])
        for bfm in (self.idx, self.out, self.mem):
            cocotb.start_soon(bfm.run())
        self.expected, self.checked = [], 0
        await self.configure(mode_max=False)

    async def configure(self, mode_max, num_rows=None):
        if num_rows is not None:
            self.num_rows = num_rows
            self.mem.window = (self.base, self.base + num_rows * self.dim)
            self.table.num_rows = num_rows
        assert await self.axil.write(BASE, self.base) == 0
        assert await self.axil.write(NROWS, self.num_rows) == 0
        assert await self.axil.write(CTRL, 1 | (int(mode_max) << 1)) == 0
        self.mode_max = mode_max

    def submit(self, bag):
        exp, n = pool(self.table, bag, self.mode_max)
        self.expected.append((list(bag), exp, n, self.mode_max))
        self.idx.send([(x, k == len(bag) - 1) for k, x in enumerate(bag)])
        STATS["bags"] += 1
        STATS["rows"] += n
        STATS["oob"] += len(bag) - n

    async def drain(self, timeout=200_000):
        """Wait until every submitted bag has come out, then check them in order."""
        for _ in range(timeout):
            await RisingEdge(self.dut.clk)
            self.check_ready()
            if self.checked == len(self.expected):
                break
        else:
            raise TimeoutError(f"only {self.checked}/{len(self.expected)} bags emitted")
        await ClockCycles(self.dut.clk, 5)
        self.check_ready()
        assert len(self.out.beats) == self.checked, f"{len(self.out.beats) - self.checked} unexpected extra bags"
        assert not self.mem.errors, "AXI read slave: " + "; ".join(self.mem.errors[:4])
        assert not self.out.errors, "output stream: " + "; ".join(self.out.errors[:4])
        st, _ = await self.axil.read(STATUS)
        assert st & 1, f"engine not IDLE after drain (STATUS=0x{st:x})"
        self.sample_flow()

    def check_ready(self):
        while self.checked < len(self.out.beats):
            bag, exp, n, mm = self.expected[self.checked]
            tdata, tuser = self.out.beats[self.checked]
            got = unpack(tdata, self.dim)
            if not np.array_equal(got, exp) or tuser != n:
                bad = np.nonzero(got != exp)[0][:6]
                raise AssertionError(
                    f"bag #{self.checked} ({'MAX' if mm else 'SUM'}, indices={bag[:12]}{'...' if len(bag) > 12 else ''}):"
                    f" TUSER exp {n} got {tuser}; element mismatches at {list(bad)}: "
                    f"exp {list(exp[bad])} got {list(got[bad])}")
            COV.sample_bag(bag, self.num_rows, mm, exp, n, self.table)
            self.checked += 1

    def sample_flow(self):
        for k, c in self.mem.outstanding_hist.items():
            if str(k) in COV.cp["outstanding_reached"]:
                COV.hit("outstanding_reached", str(k), c)
        if self.out.stalled_valid:
            COV.hit("flow_control", "out_stalled_while_valid")
        if self.idx.gaps:
            COV.hit("flow_control", "idx_gap")
        if self.cfg["latency"][1] > 0 or self.cfg["p_rgap"] > 0:
            COV.hit("flow_control", "r_gap_or_latency")
        if self.cfg["p_arready"] < 1:
            COV.hit("flow_control", "ar_not_ready")

    # ------------------------------------------------------------ stimulus
    def random_bag(self, max_len=40, p_oob=0.05):
        g, nr = self.rng, self.num_rows
        if g.random() < 0.04:
            return [nr + g.randint(0, 50) for _ in range(g.randint(1, 3))]   # no valid rows
        size = g.choices([1, g.randint(2, 4), g.randint(5, min(16, max_len)), g.randint(min(17, max_len), max_len)],
                         [15, 30, 35, 20])[0]
        hot = list(range(min(8, nr)))
        bag = []
        for _ in range(size):
            p = g.random()
            if p < p_oob:
                bag.append(g.choice([nr, nr + g.randint(1, 1000), 0xFFFFFFFF]))
            elif p < 0.45:
                bag.append(g.choice(hot))                                   # popular rows (DLRM skew)
            else:
                bag.append(g.randrange(nr))
        return bag


def finish(dut, tag):
    hit, tot = COV.score()
    dut._log.info(f"[{tag}] bags={STATS['bags']} rows={STATS['rows']} oob={STATS['oob']} coverage={hit}/{tot}")
    COV.save(COV_FILE)
    import json
    with open(COV_FILE.replace(".json", "_stats.json"), "w") as f:
        json.dump(STATS, f)


# ===================================================================== tests
@cocotb.test()
async def test_registers(dut):
    """Reset values, R/W, WSTRB byte enables, SLVERR rules, W1C bits."""
    env = Env(dut)
    await env.start()
    a = env.axil
    for addr, exp in ((BAGS, 0), (ROWS, 0), (OOBC, 0)):
        v, r = await a.read(addr)
        assert (v, r) == (exp, 0), f"reg 0x{addr:02x} = 0x{v:x} resp {r}"
    st, _ = await a.read(STATUS)
    assert st == 1, f"STATUS after reset 0x{st:x}"
    assert await a.write(NROWS, 0xAABBCCDD) == 0
    assert await a.write(NROWS, 0x11223344, strb=0b0101) == 0
    v, _ = await a.read(NROWS)
    assert v == 0xAA22CC44, f"WSTRB merge: 0x{v:08x}"
    COV.hit("registers", "partial_wstrb")
    for ro in (BAGS, ROWS, OOBC, PARAMS):
        assert await a.write(ro, 0) == 2, f"no SLVERR writing RO 0x{ro:02x}"
    COV.hit("registers", "slverr_ro_write")
    for un in (0x20, 0x40, 0xFC):
        assert await a.write(un, 0) == 2
        assert (await a.read(un))[1] == 2, f"no SLVERR reading 0x{un:02x}"
    COV.hit("registers", "slverr_unmapped")
    # sticky OOB flag + W1C
    await env.configure(mode_max=False, num_rows=16)
    env.submit([3, 99])
    await env.drain()
    st, _ = await a.read(STATUS)
    assert st & 2, "OOB_SEEN not set"
    assert await a.write(STATUS, 2) == 0
    st, _ = await a.read(STATUS)
    assert not st & 2, "OOB_SEEN not cleared by W1C"
    COV.hit("registers", "w1c_oob")
    finish(dut, "regs")


@cocotb.test()
async def test_directed_bags(dut):
    """Single rows, boundaries, repeated rows, all-OOB bags, OOB at every position, both modes."""
    env = Env(dut, num_rows=32, p_stall=0.0, p_gap=0.0)
    await env.start()
    t, nr = env.table, 32
    t.w[5, :], t.w[6, :], t.w[7, :] = 127, -128, -1
    t.w[8, :] = np.arange(env.dim) - 100
    t.blob = t.w.tobytes()
    bags = [[0], [nr - 1], [nr], [0xFFFFFFFF], [5] * 40, [6] * 40, [5, 6, 7], [6, 7, 8],
            [nr, 1, 2], [1, nr + 5, 2], [1, 2, nr], [nr, nr + 1, 0xFFFFFFFF], [0, nr - 1, 0, nr - 1]]
    for mode in (False, True):
        await env.configure(mode_max=mode)
        for b in bags:
            env.submit(b)
        await env.drain()
    v, _ = await env.axil.read(BAGS)
    assert v == 2 * len(bags), f"BAGS_DONE={v}"
    finish(dut, "directed")


@cocotb.test()
async def test_random_sum(dut):
    """Random bags (DLRM-like skew, 5% OOB), SUM pooling, random flow control."""
    env = Env(dut, num_rows=256)
    await env.start()
    for _ in range(NUM_BAGS):
        env.submit(env.random_bag())
    await env.drain()
    finish(dut, "rand-sum")


@cocotb.test()
async def test_random_max(dut):
    """Random bags, MAX pooling."""
    env = Env(dut, num_rows=200)
    await env.start()
    await env.configure(mode_max=True)
    for _ in range(NUM_BAGS):
        env.submit(env.random_bag())
    await env.drain()
    finish(dut, "rand-max")


@cocotb.test()
async def test_backpressure_slow_memory(dut):
    """Heavy output back-pressure + slow, gappy memory."""
    env = Env(dut, num_rows=100, p_stall=0.75, p_arready=0.3, latency=(5, 30), p_rgap=0.5, p_gap=0.4)
    await env.start()
    for k in range(NUM_BAGS // 2):
        if k == NUM_BAGS // 4:
            await env.drain()
            await env.configure(mode_max=True)
        env.submit(env.random_bag(max_len=20))
    await env.drain()
    finish(dut, "backpressure")


@cocotb.test()
async def test_outstanding_limit(dut):
    """AR always ready, long read latency: the engine must reach, and never exceed, MAX_OUT."""
    env = Env(dut, num_rows=64, p_arready=1.0, latency=(20, 40), p_rgap=0.0, p_stall=0.0, p_gap=0.0)
    await env.start()
    for _ in range(30):
        env.submit([env.rng.randrange(64) for _ in range(16)])
    await env.drain()
    assert env.mem.max_seen == env.max_out, f"max outstanding seen {env.mem.max_seen}, limit {env.max_out}"
    v, _ = await env.axil.read(ROWS)
    assert v == 30 * 16, f"ROWS_READ={v}"
    finish(dut, "outstanding")


@cocotb.test()
async def test_rresp_error(dut):
    """SLVERR on read data sets the sticky RRESP_ERR flag; W1C clears it; data path keeps going."""
    env = Env(dut, num_rows=64, p_slverr=0.05)
    await env.start()
    for _ in range(40):
        env.submit(env.random_bag(max_len=8, p_oob=0.0))
    await env.drain()
    st, _ = await env.axil.read(STATUS)
    assert env.mem.slverr_sent > 0
    assert st & 4, "RRESP_ERR not set after SLVERR beats"
    COV.hit("registers", "rresp_error_seen")
    await env.axil.write(STATUS, 4)
    st, _ = await env.axil.read(STATUS)
    assert not st & 4, "RRESP_ERR not cleared by W1C"
    COV.hit("registers", "w1c_rresp")
    finish(dut, "rresp")


@cocotb.test()
async def test_counters_match_model(dut):
    """BAGS_DONE / ROWS_READ / OOB_COUNT agree with the model after a random run."""
    env = Env(dut, num_rows=50)
    await env.start()
    bags = [env.random_bag(p_oob=0.15) for _ in range(60)]
    for b in bags:
        env.submit(b)
    await env.drain()
    nvalid = sum(1 for b in bags for x in b if 0 <= x < 50)
    got = [(await env.axil.read(r))[0] for r in (BAGS, ROWS, OOBC)]
    assert got == [60, nvalid, sum(map(len, bags)) - nvalid], f"counters {got}"
    hit, tot = COV.score()
    if COV.holes():
        dut._log.warning(f"coverage holes: {COV.holes()}")
    finish(dut, "counters")
