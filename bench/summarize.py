"""The median of each server's repetitions, per configuration, from raw.csv.

    python3 bench/summarize.py results/<run>/raw.csv
"""

import csv
import statistics
import sys
from collections import defaultdict


def main(path):
    with open(path) as f:
        if "rate" in next(csv.reader(f)):
            return summarize_conns(path)

    runs = defaultdict(list)
    order = []
    for row in csv.DictReader(open(path)):
        key = (int(row["conns"]), int(row["streams"]), row["server"])
        if key not in runs:
            order.append(key)
        runs[key].append(row)

    def median(rows, field):
        return statistics.median(float(r[field]) for r in rows)

    header = (
        f"{'conns x streams':>15}  {'server':<16} {'req/s':>11} {'spread':>7}"
        f"  {'lat mean':>9} {'lat max':>9}  {'server cores':>12}"
        f" {'user/sys':>9}  {'client busy':>11}  {'failed':>6}  {'net capped':>10}"
    )
    print(header)
    print("-" * len(header))
    previous = None
    for conns, streams, server in sorted(order, key=lambda k: (k[0], k[1])):
        rows = runs[(conns, streams, server)]
        rps = [float(r["rps"]) for r in rows]
        spread = (max(rps) - min(rps)) / statistics.median(rps) * 100
        failed = sum(int(r["failed"]) + int(r["errored"]) for r in rows)
        # Older runs have no such column.
        capped = sum(int(r.get("nic_exceeded") or 0) > 0 for r in rows)
        if previous is not None and previous != (conns, streams):
            print()
        previous = (conns, streams)
        print(
            f"{f'{conns} x {streams}':>15}  {server:<16} {statistics.median(rps):>11,.0f}"
            f" {f'±{spread / 2:.0f}%':>7}"
            f"  {duration(median(rows, 'lat_mean_us')):>9}"
            f" {duration(median(rows, 'lat_max_us')):>9}"
            f"  {median(rows, 'server_cores'):>12.2f}"
            f" {f'{median(rows, 'server_user_pct'):.0f}/{median(rows, 'server_sys_pct'):.0f}':>9}"
            f"  {f'{median(rows, 'client_busy_pct'):.0f}%':>11}  {failed:>6}"
            f"  {f'{capped}/{len(rows)}' if capped else '':>10}"
        )
    print()
    print(
        f"Medians of {len(next(iter(runs.values())))} runs. spread: half the range"
        " of req/s over the median. server cores: CPU time used per second"
        " of wall time. client busy: the load generator's CPUs. net capped:"
        " runs during which the NIC queued or dropped packets for going past"
        " the instance's allowance; their req/s measured AWS's limit."
    )


def summarize_conns(path):
    """A conns run: the same load for every server, so what each spent on it."""
    runs = defaultdict(list)
    for row in csv.DictReader(open(path)):
        # "max": as fast as each connection gets its answers.
        runs[(int(row["conns"]), row["rate"], row["server"])].append(row)

    def median(rows, field):
        return statistics.median(float(r[field]) for r in rows)

    header = (
        f"{'conns':>7} {'req/s each':>10} {'asked':>9}  {'server':<15}"
        f" {'req/s':>9} {'open':>7}  {'lat mean':>9} {'lat max':>9}"
        f"  {'cores':>5}  {'RSS':>8} {'per conn':>8}"
        f" {'kernel TCP':>10}  {'client':>6}  {'failed':>6}  {'runs':>4}  {'net capped':>10}"
    )
    print(header)
    print("-" * len(header))
    previous = None
    def asked(n, rate):
        return n * int(rate) if rate.isdigit() else None

    def order(key):
        n, rate, _ = key
        # Fixed rates by the load they ask for, then the unbounded ones.
        return (asked(n, rate) is None, asked(n, rate) or 0, n)

    for (n, rate, server), rows in sorted(runs.items(), key=lambda kv: order(kv[0])):
        if previous is not None and previous != (n, rate):
            print()
        previous = (n, rate)
        rss = median(rows, "rss_mib")
        open_ = median(rows, "established")
        per_conn = (rss - median(rows, "idle_mib")) * 1024 / open_ if open_ else 0
        tcp = median(rows, "tcp_mib") - median(rows, "tcp_idle_mib")
        failed = sum(int(r["failed"]) + int(r["errored"]) for r in rows)
        capped = sum(int(r.get("nic_exceeded") or 0) > 0 for r in rows)
        print(
            f"{n:>7} {rate:>10} {f'{asked(n, rate):,}' if asked(n, rate) else 'max':>9}  {server:<15}"
            f" {median(rows, 'rps'):>9,.0f} {open_:>7,.0f}"
            f"  {duration(median(rows, 'lat_mean_us')):>9} {duration(median(rows, 'lat_max_us')):>9}"
            f"  {median(rows, 'server_cores'):>5.2f}"
            f"  {f'{rss:.1f}M':>8} {f'{per_conn:.1f}K':>8} {f'{tcp:.1f}M':>10}"
            f"  {f'{median(rows, 'client_busy_pct'):.0f}%':>6}  {failed:>6}  {len(rows):>4}"
            f"  {f'{capped}/{len(rows)}' if capped else '':>10}"
        )
    print()
    print(
        "Medians of each case's runs; runs: how many there were, fewer when"
        " some were left out (see below). asked: connections"
        " times the rate each, what h2load aimed for; max: each connection sends"
        " its next request as soon as it has the answer. open: connections"
        " established, read half way through. cores: the server's CPU time per"
        " second. RSS: the server's resident memory under the load; per conn:"
        " what it grew by from idle, over the connections open. kernel TCP:"
        " what the machine's TCP buffers grew by, both ends if the client runs"
        " there too. client: the load generator's CPUs. Latency at a fixed rate:"
        " h2load sends every connection's request at the same instant, so it is"
        " the time to answer a burst of as many requests as there are"
        " connections."
    )


def duration(us):
    if us >= 1000:
        return f"{us / 1000:.2f}ms"
    return f"{us:.0f}us"


if __name__ == "__main__":
    main(sys.argv[1])
