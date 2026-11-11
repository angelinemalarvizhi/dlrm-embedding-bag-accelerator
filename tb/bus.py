"""Bus-functional models: AXI4-Lite master, AXI-Stream source/sink, AXI4 read slave.

Timing convention used by every BFM:
  FallingEdge -> drive this cycle's outputs
  ReadOnly    -> sample settled valid/ready; a handshake seen here completes
                 at the next rising edge.
"""
import random
from collections import deque

from cocotb.triggers import FallingEdge, ReadOnly

_X = str.maketrans("xXzZuUwW-", "000000000")


def val(sig):
    return int(str(sig.value).translate(_X), 2)


def hi(sig):
    return str(sig.value) == "1"


# ============================================================ AXI4-Lite master
class AxiLiteMaster:
    def __init__(self, dut, clk, prefix="s_axil"):
        self.clk = clk
        self.s = {n: getattr(dut, f"{prefix}_{n}") for n in
                  ("awvalid", "awready", "awaddr", "wvalid", "wready", "wdata", "wstrb", "bvalid", "bready",
                   "bresp", "arvalid", "arready", "araddr", "rvalid", "rready", "rdata", "rresp")}
        for n in ("awvalid", "wvalid", "bready", "arvalid", "rready", "awaddr", "wdata", "wstrb", "araddr"):
            self.s[n].value = 0

    async def write(self, addr, data, strb=0xF):
        s = self.s
        aw = w = False
        while not (aw and w):
            await FallingEdge(self.clk)
            s["awvalid"].value, s["awaddr"].value = int(not aw), addr
            s["wvalid"].value, s["wdata"].value, s["wstrb"].value = int(not w), data & 0xFFFFFFFF, strb
            await ReadOnly()
            aw = aw or (hi(s["awvalid"]) and hi(s["awready"]))
            w = w or (hi(s["wvalid"]) and hi(s["wready"]))
        while True:
            await FallingEdge(self.clk)
            s["awvalid"].value = s["wvalid"].value = 0
            s["bready"].value = 1
            await ReadOnly()
            if hi(s["bvalid"]):
                resp = val(s["bresp"])
                await FallingEdge(self.clk)
                s["bready"].value = 0
                return resp

    async def read(self, addr):
        s = self.s
        while True:
            await FallingEdge(self.clk)
            s["arvalid"].value, s["araddr"].value = 1, addr
            await ReadOnly()
            if hi(s["arready"]):
                break
        while True:
            await FallingEdge(self.clk)
            s["arvalid"].value = 0
            s["rready"].value = 1
            await ReadOnly()
            if hi(s["rvalid"]):
                data, resp = val(s["rdata"]), val(s["rresp"])
                await FallingEdge(self.clk)
                s["rready"].value = 0
                return data, resp


# ============================================================ AXI-Stream
class AxisSource:
    """Sends (data, last) items; idles randomly between beats with probability p_gap."""

    def __init__(self, dut, clk, prefix, rng=random, p_gap=0.2):
        self.clk, self.rng, self.p_gap = clk, rng, p_gap
        self.tvalid, self.tready = getattr(dut, f"{prefix}_tvalid"), getattr(dut, f"{prefix}_tready")
        self.tdata, self.tlast = getattr(dut, f"{prefix}_tdata"), getattr(dut, f"{prefix}_tlast")
        self.q, self.sent, self.gaps = deque(), 0, 0
        self.tvalid.value = 0

    def send(self, items):
        self.q.extend(items)

    async def run(self):
        cur = None
        while True:
            await FallingEdge(self.clk)
            if cur is None and self.q:
                if self.rng.random() < self.p_gap:
                    self.gaps += 1
                else:
                    cur = self.q.popleft()
            self.tvalid.value = int(cur is not None)
            if cur is not None:
                self.tdata.value, self.tlast.value = cur[0] & 0xFFFFFFFF, int(cur[1])
            await ReadOnly()
            if cur is not None and hi(self.tready):
                cur = None
                self.sent += 1


class AxisSink:
    """Collects beats; drives TREADY low with probability p_stall. Checks AXI-Stream hold rules."""

    def __init__(self, dut, clk, prefix, rng=random, p_stall=0.3):
        self.clk, self.rng, self.p_stall = clk, rng, p_stall
        self.tvalid, self.tready = getattr(dut, f"{prefix}_tvalid"), getattr(dut, f"{prefix}_tready")
        self.tdata, self.tuser = getattr(dut, f"{prefix}_tdata"), getattr(dut, f"{prefix}_tuser")
        self.beats, self.errors, self.stalled_valid = [], [], 0
        self.tready.value = 0

    async def run(self):
        held = None
        while True:
            await FallingEdge(self.clk)
            self.tready.value = int(self.rng.random() >= self.p_stall)
            await ReadOnly()
            v = hi(self.tvalid)
            if held is not None:
                if not v:
                    self.errors.append("TVALID dropped before handshake")
                elif (val(self.tdata), val(self.tuser)) != held:
                    self.errors.append("TDATA/TUSER changed while stalled")
            if v and hi(self.tready):
                self.beats.append((val(self.tdata), val(self.tuser)))
                held = None
            elif v:
                held = (val(self.tdata), val(self.tuser))
                self.stalled_valid += 1
            else:
                held = None


# ============================================================ AXI4 read slave
class AxiReadSlave:
    """In-order AXI4 read responder backed by a byte-addressable memory callback.

    Checks: ARLEN/ARSIZE/ARBURST, alignment, 4 KB boundary, address window, ARVALID/ARADDR hold,
    outstanding-burst limit. Randomises ARREADY, first-beat latency, inter-beat gaps, optional SLVERR."""

    def __init__(self, dut, clk, read_bytes, rng=random, p_arready=0.7, latency=(0, 8), p_rgap=0.2,
                 exp_len=1, max_out=4, window=None, p_slverr=0.0, prefix="m_axi"):
        self.clk, self.read_bytes, self.rng = clk, read_bytes, rng
        self.p_arready, self.latency, self.p_rgap, self.p_slverr = p_arready, latency, p_rgap, p_slverr
        self.exp_len, self.max_out, self.window = exp_len, max_out, window
        g = lambda n: getattr(dut, f"{prefix}_{n}")
        self.ar = {n: g(n) for n in ("arvalid", "arready", "araddr", "arlen", "arsize", "arburst", "arid")}
        self.r = {n: g(n) for n in ("rvalid", "rready", "rdata", "rresp", "rlast", "rid")}
        self.ar["arready"].value = 0
        for n in ("rvalid", "rdata", "rresp", "rlast", "rid"):
            self.r[n].value = 0
        self.errors, self.bursts, self.max_seen, self.slverr_sent = [], 0, 0, 0
        self.outstanding_hist = {}

    def _check_ar(self, addr, alen, asize, aburst):
        if alen != self.exp_len - 1:
            self.errors.append(f"ARLEN={alen} expected {self.exp_len - 1}")
        if asize != 3 or aburst != 1:
            self.errors.append(f"ARSIZE={asize} ARBURST={aburst} expected 3/INCR")
        if addr & 7:
            self.errors.append(f"unaligned ARADDR 0x{addr:08x}")
        if (addr & 0xFFF) + 8 * (alen + 1) > 0x1000:
            self.errors.append(f"burst at 0x{addr:08x} crosses 4 KB")
        if self.window and not (self.window[0] <= addr and addr + 8 * (alen + 1) <= self.window[1]):
            self.errors.append(f"read 0x{addr:08x} outside table [0x{self.window[0]:x}, 0x{self.window[1]:x})")

    async def run(self):
        bursts, cycle, beat_cur, ar_held = deque(), 0, None, None
        while True:
            await FallingEdge(self.clk)
            cycle += 1
            self.ar["arready"].value = int(self.rng.random() < self.p_arready)
            # present next R beat
            if beat_cur is None and bursts and bursts[0]["ready_at"] <= cycle and self.rng.random() >= self.p_rgap:
                b = bursts[0]
                k = b["sent"]
                data = int.from_bytes(self.read_bytes(b["addr"] + 8 * k, 8), "little")
                err = self.rng.random() < self.p_slverr
                beat_cur = (data, 2 if err else 0, int(k == b["len"] - 1))
            self.r["rvalid"].value = int(beat_cur is not None)
            if beat_cur:
                self.r["rdata"].value, self.r["rresp"].value, self.r["rlast"].value = beat_cur
            await ReadOnly()
            # AR handshake
            if hi(self.ar["arvalid"]):
                cur = val(self.ar["araddr"])
                if ar_held is not None and cur != ar_held:
                    self.errors.append("ARADDR changed while ARVALID high")
                if hi(self.ar["arready"]):
                    alen = val(self.ar["arlen"])
                    self._check_ar(cur, alen, val(self.ar["arsize"]), val(self.ar["arburst"]))
                    lo, hi_ = self.latency
                    bursts.append({"addr": cur, "len": alen + 1, "sent": 0,
                                   "ready_at": cycle + 1 + self.rng.randint(lo, hi_)})
                    self.bursts += 1
                    ar_held = None
                    if len(bursts) > self.max_out:
                        self.errors.append(f"{len(bursts)} bursts outstanding > limit {self.max_out}")
                    self.max_seen = max(self.max_seen, len(bursts))
                    self.outstanding_hist[len(bursts)] = self.outstanding_hist.get(len(bursts), 0) + 1
                else:
                    ar_held = cur
            elif ar_held is not None:
                self.errors.append("ARVALID dropped before ARREADY")
                ar_held = None
            # R handshake
            if beat_cur is not None and hi(self.r["rready"]):
                if beat_cur[1]:
                    self.slverr_sent += 1
                bursts[0]["sent"] += 1
                if bursts[0]["sent"] == bursts[0]["len"]:
                    bursts.popleft()
                beat_cur = None
