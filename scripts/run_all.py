#!/usr/bin/env python3
"""Full regression for the embedding-bag accelerator.

  python3 scripts/run_all.py --seeds 8 --bags 200 --configs --bugs

  --configs : also run DIM/MAX_OUT configuration matrix
  --bugs    : bug-injection campaign (every bug must be detected)
Writes results/REGRESSION.md and results/coverage_merged.json
"""
import argparse
import json
import os
import pathlib
import random
import subprocess
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
RES = ROOT / "results"
CONFIGS = [(8, 2), (16, 1), (16, 4), (32, 4)]
BUGS = [
    ("BUG_OOB_BOUND", "index == NUM_ROWS treated as valid (off-by-one)"),
    ("BUG_OUTSTANDING", "outstanding-burst limit not enforced"),
    ("BUG_EMPTY_LAST", "bag whose last index is out-of-range never completes"),
    ("BUG_SIGN", "int8 sign bit dropped"),
    ("BUG_BEAT_ORDER", "beats of a row written to the wrong elements"),
    ("BUG_MAX_INIT", "MAX pooling seeded with 0 instead of the first row"),
    ("BUG_AXIL_STRB", "AXI-Lite WSTRB ignored"),
]


def make(tag, seed, bags, dim=16, max_out=4, defines=""):
    xml, cov = RES / f"{tag}.xml", RES / f"{tag}_cov.json"
    xml.unlink(missing_ok=True)
    cmd = ["make", "-s", f"SEED={seed}", f"NUM_BAGS={bags}", f"DIM={dim}", f"MAX_OUT={max_out}",
           f"DEFINES={defines}", f"SIM_BUILD=sim_build_{dim}_{max_out}_{defines or 'clean'}",
           f"COCOTB_RESULTS_FILE={xml}"]
    p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, env={**os.environ, "COV_FILE": str(cov)})
    (RES / f"{tag}.log").write_text(p.stdout + p.stderr)
    if not xml.exists():
        return 0, ["<build error>"], cov
    tc = list(ET.parse(xml).getroot().iter("testcase"))
    return len(tc), [t.get("name") for t in tc if t.find("failure") is not None or t.find("error") is not None], cov


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=5)
    ap.add_argument("--bags", type=int, default=150)
    ap.add_argument("--configs", action="store_true")
    ap.add_argument("--bugs", action="store_true")
    a = ap.parse_args()
    RES.mkdir(exist_ok=True)
    md, bad, merged, stats = ["# Embedding-bag accelerator: regression", ""], 0, {}, {"bags": 0, "rows": 0, "oob": 0}

    def absorb(cov):
        if cov.exists():
            for cp, bins in json.loads(cov.read_text()).items():
                for b, c in bins.items():
                    merged.setdefault(cp, {}).setdefault(b, 0)
                    merged[cp][b] += c
            st = pathlib.Path(str(cov).replace(".json", "_stats.json"))
            if st.exists():
                for k, v in json.loads(st.read_text()).items():
                    stats[k] += v

    md += ["## Seed sweep (DIM=16, MAX_OUT=4)", "", "| seed | tests | result |", "|---|---|---|"]
    for _ in range(a.seeds):
        s = random.randint(1, 2**31 - 1)
        n, failed, cov = make(f"seed{s}", s, a.bags)
        bad += bool(failed)
        absorb(cov)
        print(f"seed {s:>10}: {n} tests {'PASS' if not failed else 'FAIL ' + str(failed)}")
        md.append(f"| {s} | {n} | {'PASS' if not failed else 'FAIL: ' + ', '.join(failed)} |")

    if a.configs:
        md += ["", "## Configuration matrix", "", "| DIM | MAX_OUT | row beats | result |", "|---|---|---|---|"]
        for dim, mo in CONFIGS:
            n, failed, cov = make(f"cfg_{dim}_{mo}", 7, a.bags // 2, dim, mo)
            bad += bool(failed)
            absorb(cov)
            print(f"DIM={dim:<3} MAX_OUT={mo}: {'PASS' if not failed else 'FAIL ' + str(failed)}")
            md.append(f"| {dim} | {mo} | {dim // 8} | {'PASS' if not failed else 'FAIL'} |")

    hit = sum(1 for d in merged.values() for c in d.values() if c)
    tot = sum(len(d) for d in merged.values())
    md += ["", f"**Checked {stats['bags']} bags, {stats['rows']} row fetches, {stats['oob']} out-of-range indices.**", "",
           f"## Functional coverage: {hit}/{tot} ({100 * hit / max(tot, 1):.1f}%)", ""]
    for cp, d in merged.items():
        holes = [b for b, c in d.items() if not c]
        md.append(f"* `{cp}` {len(d) - len(holes)}/{len(d)}" + (f" holes: {holes}" if holes else ""))
    (RES / "coverage_merged.json").write_text(json.dumps(merged, indent=2))
    print(f"coverage {hit}/{tot}; {stats['bags']} bags checked")

    if a.bugs:
        md += ["", "## Bug-injection campaign", "", "| bug | description | detected | failing tests |", "|---|---|---|---|"]
        for bug, desc in BUGS:
            n, failed, _ = make(bug, 1, 40, defines=bug)
            ok = bool(failed)
            bad += not ok
            print(f"{bug:<16} {'DETECTED' if ok else 'MISSED'}  ({len(failed)}/{n} tests fail)")
            md.append(f"| `{bug}` | {desc} | {'yes' if ok else '**NO**'} | {len(failed)}/{n}: {', '.join(failed)} |")

    (RES / "REGRESSION.md").write_text("\n".join(md) + "\n")
    print("report: results/REGRESSION.md")
    raise SystemExit(1 if bad else 0)


if __name__ == "__main__":
    main()
