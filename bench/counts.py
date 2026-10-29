"""What a request cost each server, from a COUNT run's perf stat counts.

    python3 bench/counts.py results/<run>

Per configuration and server, the median over the repetitions of each count
divided by the requests answered while it was taken: perf counted from 1 s
into the measured run to 1 s before its end, and h2load's req/s over the
whole run gives the requests in that window.
"""

import csv
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

# (column, heading, how to get it from a run's counts and requests)
READS = ["read", "readv", "recvfrom", "recvmsg"]
WRITES = ["write", "writev", "sendto", "sendmsg"]
WAITS = ["epoll_wait", "epoll_pwait", "epoll_pwait2"]


def per_request(counts, reqs, *names):
    found = [counts[n] for n in names if n in counts]
    return sum(found) / reqs if found else None


def ratio(counts, a, b):
    if a in counts and b in counts and counts[b]:
        return counts[a] / counts[b]
    return None


def read_stat(path):
    """perf stat -x, output: value,unit,event,..., by the event's short name."""
    counts = {}
    for line in open(path):
        if line.startswith("#") or "," not in line:
            continue
        value, _, event = line.split(",")[:3]
        if not re.fullmatch(r"[\d.]+", value):
            continue  # <not supported>, <not counted>
        # syscalls:sys_enter_writev as writev, io_uring:io_uring_complete as
        # io_uring_complete; cycles:u and raw_syscalls:sys_enter as they are.
        name = event.removeprefix("syscalls:sys_enter_").removeprefix("io_uring:")
        # agent.sh counts io_uring_submit_req a second time, filtered to the
        # zero-copy sends.
        if name in counts and name == "io_uring_submit_req":
            name = "zc_sends"
        counts[name] = float(value)
    return counts


def read_segs(path):
    (in0, out0, t0), (in1, out1, t1) = (map(float, l.split()) for l in open(path).read().split("\n")[:2])
    return (in1 - in0) / (t1 - t0), (out1 - out0) / (t1 - t0)


def main(out):
    out = Path(out)
    env = (out / "env.txt").read_text()
    duration = int(re.search(r"duration: (\d+)s", env).group(1))
    window = duration - 2
    local = ", local" in env

    columns = [
        ("user us", lambda c, r, row: float(row["server_cores"]) * float(row["server_user_pct"]) / 100 / float(row["rps"]) * 1e6),
        ("sys us", lambda c, r, row: float(row["server_cores"]) * float(row["server_sys_pct"]) / 100 / float(row["rps"]) * 1e6),
        ("instr u", lambda c, r, row: per_request(c, r, "instructions:u")),
        ("IPC u", lambda c, r, row: ratio(c, "instructions:u", "cycles:u")),
        ("instr k", lambda c, r, row: per_request(c, r, "instructions:k")),
        ("IPC k", lambda c, r, row: ratio(c, "instructions:k", "cycles:k")),
        ("L1i miss u", lambda c, r, row: per_request(c, r, "L1-icache-load-misses:u")),
        ("br miss u", lambda c, r, row: per_request(c, r, "branch-misses:u")),
        ("syscalls", lambda c, r, row: per_request(c, r, "raw_syscalls:sys_enter")),
        ("uring enter", lambda c, r, row: per_request(c, r, "io_uring_enter")),
        ("SQEs", lambda c, r, row: per_request(c, r, "io_uring_submit_req")),
        ("CQEs", lambda c, r, row: per_request(c, r, "io_uring_complete")),
        ("ZC sends", lambda c, r, row: per_request(c, r, "zc_sends")),
        ("reads", lambda c, r, row: per_request(c, r, *READS)),
        ("writes", lambda c, r, row: per_request(c, r, *WRITES)),
        ("epoll waits", lambda c, r, row: per_request(c, r, *WAITS)),
        ("ctx sw", lambda c, r, row: per_request(c, r, "context-switches")),
        ("segs in", lambda c, r, row: row["_segs"][0] / float(row["rps"]) if row["_segs"] else None),
        ("segs out", lambda c, r, row: row["_segs"][1] / float(row["rps"]) if row["_segs"] else None),
    ]

    runs = defaultdict(list)
    order = []
    for row in csv.DictReader(open(out / "raw.csv")):
        tag = f"{row['server']}-{row['conns']}x{row['streams']}-{row['rep']}"
        stat = out / "raw" / f"{tag}.perf-stat.txt"
        if not stat.exists():
            continue
        segs = out / "raw" / f"{tag}.segs.txt"
        row["_segs"] = read_segs(segs) if segs.exists() else None
        counts = read_stat(stat)
        reqs = float(row["rps"]) * window
        values = [f(counts, reqs, row) for _, f in columns]
        key = (int(row["conns"]), int(row["streams"]), row["server"])
        if key not in runs:
            order.append(key)
        runs[key].append(values)

    # Shown only if some run has them: a VM without a PMU has no cycles.
    shown = [i for i in range(len(columns)) if any(v[i] is not None for rs in runs.values() for v in rs)]

    def cell(values, i):
        found = [v[i] for v in values if v[i] is not None]
        if not found:
            return "-"
        m = statistics.median(found)
        return f"{m:,.0f}" if m >= 100 else f"{m:.2f}"

    print(f"{'conns x streams':>15}  {'server':<14}" + "".join(f" {columns[i][0]:>11}" for i in shown))
    print("-" * (31 + 12 * len(shown)))
    last = None
    for key in sorted(order, key=lambda k: (k[0], k[1], order.index(k))):
        conns, streams, server = key
        if last is not None and (conns, streams) != last:
            print()
        last = (conns, streams)
        print(f"{f'{conns} x {streams}':>15}  {server:<14}" + "".join(f" {cell(runs[key], i):>11}" for i in shown))
    print()
    print(
        "Per request, medians of each server's runs. user us, sys us: the server's CPU time. "
        "instr, IPC: instructions and instructions per cycle, u in the server's own code, k in the kernel on its behalf. "
        "L1i miss, br miss: instruction cache refills and mispredicted branches in its own code. "
        "syscalls: all of them; reads, writes, epoll waits: those of each kind; SQEs, CQEs: io_uring submissions and "
        "completions; ZC sends: those submitted as SENDMSG_ZC. Counts are the server process's: the kernel's network work in interrupts and softirqs is not in them."
    )
    if local:
        print("segs in, segs out: the whole machine's TCP segments; on loopback, both ends' alike.")
    else:
        print("segs in, segs out: the server machine's TCP segments.")


if __name__ == "__main__":
    main(sys.argv[1])
