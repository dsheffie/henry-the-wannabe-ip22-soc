#!/usr/bin/env python3
"""txnfollow.py -- follow every L2 coherence transaction end to end.

The RTL (l2.sv, `ifdef VERILATOR) stamps each back-invalidate with a monotonically
increasing id and prints it at four stages:

    [txn N] ISSUE   cyc=.. addr=..            probe sent to the L1s
    [txn N] ACK     cyc=.. addr=.. dirty=B held=B data=XXXXXXXX
    [txn N] MERGE   cyc=.. idx=..  data=XXXXXXXX      recovered line written into the L2
    [txn N] WRITEBK cyc=.. idx=..  addr=.. data=XXXXXXXX   that line evicted to DRAM

Every stage carries its own address, so a single record is self-contained and the
id is only needed to tie stages of the SAME transaction together across time.

THE QUESTION IT ANSWERS.  rmw_snoop.S only ever increments a line, so for any
address the values merged into the L2 and the values written back to DRAM must both
be monotonic, and the highest value merged must eventually reach memory.  An address
where max(merged) > max(written back) is a LOST STORE, named precisely, with the
transaction that carried it.

usage: txnfollow.py <logfile> [--addr 0xPA] [--top N]
"""
import sys, re
from collections import defaultdict

RE_ISSUE = re.compile(r"^\[txn (\d+)\] ISSUE   cyc=(\d+) addr=([0-9a-f]+)")
RE_ACK   = re.compile(r"^\[txn (\d+)\] ACK     cyc=(\d+) addr=([0-9a-f]+) dirty=(\d) held=(\d) data=([0-9a-f]+)")
RE_MERGE = re.compile(r"^\[txn (\d+)\] MERGE   cyc=(\d+) idx=(\d+) addr=([0-9a-f]+) data=([0-9a-f]+)")
RE_WB    = re.compile(r"^\[txn (\d+)\] WRITEBK cyc=(\d+) idx=(\d+) addr=([0-9a-f]+) data=([0-9a-f]+)")

def val(h):
    """the line's first word, byte-swapped: the CPU stores big-endian, so the
    counter 4 appears in the log as 04000000."""
    return int.from_bytes(bytes.fromhex(h.zfill(8)), "little")

def main():
    if len(sys.argv) < 2:
        print(__doc__); return 1
    path = sys.argv[1]
    want = None
    if "--addr" in sys.argv:
        want = int(sys.argv[sys.argv.index("--addr") + 1], 0) & ~15
    top = 20
    if "--top" in sys.argv:
        top = int(sys.argv[sys.argv.index("--top") + 1])

    txn_addr = {}                       # id -> address (from ISSUE/ACK)
    merged   = defaultdict(int)         # address -> highest value merged in
    merged_txn = {}                     # address -> id that merged that value
    written  = defaultdict(int)         # address -> highest value written back
    written_txn = {}
    n_issue = n_ack = n_merge = n_wb = 0
    ack_dirty_no_merge = 0
    timeline = []                       # for --addr

    for line in open(path, errors="replace"):
        if not line.startswith("[txn "):
            continue
        m = RE_ACK.match(line)
        if m:
            n_ack += 1
            tid, cyc, addr, dirty, held, data = m.groups()
            a = int(addr, 16) & ~15
            txn_addr[int(tid)] = a
            if want is not None and a == want:
                timeline.append((int(cyc), int(tid), "ACK",
                                 f"dirty={dirty} held={held} data={val(data)}"))
            continue
        m = RE_MERGE.match(line)
        if m:
            n_merge += 1
            tid, cyc, idx, addr, data = m.groups()
            tid = int(tid); v = val(data)
            a = int(addr, 16) & ~15          # self-contained now; no join needed
            if True:
                if v > merged[a]:
                    merged[a] = v; merged_txn[a] = tid
                if want is not None and a == want:
                    timeline.append((int(cyc), tid, "MERGE", f"idx={idx} value={v}"))
            continue
        m = RE_WB.match(line)
        if m:
            n_wb += 1
            tid, cyc, idx, addr, data = m.groups()
            a = int(addr, 16) & ~15; v = val(data)
            if v > written[a]:
                written[a] = v; written_txn[a] = int(tid)
            if want is not None and a == want:
                timeline.append((int(cyc), int(tid), "WRITEBK", f"idx={idx} value={v}"))
            continue
        m = RE_ISSUE.match(line)
        if m:
            n_issue += 1
            tid, cyc, addr = m.groups()
            a = int(addr, 16) & ~15
            txn_addr[int(tid)] = a
            if want is not None and a == want:
                timeline.append((int(cyc), int(tid), "ISSUE", ""))

    print(f"records: issue={n_issue} ack={n_ack} merge={n_merge} writeback={n_wb}")
    print(f"distinct addresses: merged={len(merged)} written_back={len(written)}")

    if want is not None:
        print(f"\n--- timeline for 0x{want:x} ---")
        for cyc, tid, stage, extra in sorted(timeline):
            print(f"  cyc={cyc:<10} [txn {tid:<8}] {stage:<8} {extra}")
        print(f"  highest merged   : {merged.get(want, 0)} (txn {merged_txn.get(want)})")
        print(f"  highest writtenbk: {written.get(want, 0)} (txn {written_txn.get(want)})")
        return 0

    # the money query: a value reached the L2 but never reached memory
    lost = [(a, merged[a], written.get(a, 0)) for a in merged
            if merged[a] > written.get(a, 0)]
    lost.sort(key=lambda t: t[1] - t[2], reverse=True)
    print(f"\nADDRESSES WHERE max(merged) > max(written back): {len(lost)}")
    print(f"{'address':>12}  {'merged':>7} {'written':>8}  {'gap':>4}  merging txn")
    for a, mv, wv in lost[:top]:
        print(f"  0x{a:09x}  {mv:>7} {wv:>8}  {mv-wv:>4}  {merged_txn.get(a)}")
    if lost:
        tot = sum(mv - wv for _, mv, wv in lost)
        print(f"\n  total increments that reached the L2 but not DRAM: {tot}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
