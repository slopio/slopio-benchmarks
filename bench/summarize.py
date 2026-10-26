"""The median of each server's repetitions, per configuration, from raw.csv.

    python3 bench/summarize.py results/<run>/raw.csv
"""

import csv
import statistics
import sys
from collections import defaultdict


def main(path):
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


def duration(us):
    if us >= 1000:
        return f"{us / 1000:.2f}ms"
    return f"{us:.0f}us"


if __name__ == "__main__":
    main(sys.argv[1])
