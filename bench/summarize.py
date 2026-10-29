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

    # /app with a delay: how long each server's waits really took, and how
    # far each was from what it asked.
    slept = {k: [r for r in rows if r.get("slept_n")] for k, rows in runs.items()}
    if any(slept.values()):
        # Runs from before the servers counted each sleep's error have none.
        errors = all(r.get("slept_early_pct") for rows in slept.values() for r in rows)
        columns = [("asked", "asked"), ("mean", "slept")]
        if errors:
            columns += [("err_mean", "err mean"), ("err_p1", "err p1"), ("err_p50", "err p50"), ("err_p99", "err p99")]
        else:
            columns += [("p1", "p1"), ("p50", "p50"), ("p99", "p99")]
        columns += [("max", "max")]
        print()
        header = (
            f"{'conns x streams':>15}  {'server':<16}"
            + "".join(f" {title:>9}" for _, title in columns)
            + (f" {'early':>6}" if errors else "")
            + f"  {'lat - slept':>11}"
        )
        print(header)
        print("-" * len(header))
        previous = None
        for conns, streams, server in sorted(order, key=lambda k: (k[0], k[1])):
            rows = slept[(conns, streams, server)]
            if not rows:
                continue
            if previous is not None and previous != (conns, streams):
                print()
            previous = (conns, streams)
            print(
                f"{f'{conns} x {streams}':>15}  {server:<16}"
                + "".join(f" {f'{median(rows, f'slept_{c}_ms'):.2f}ms':>9}" for c, _ in columns)
                + (f" {f'{median(rows, 'slept_early_pct'):.1f}%':>6}" if errors else "")
                + f"  {duration(median(rows, 'lat_mean_us') - 1000 * median(rows, 'slept_mean_ms')):>11}"
            )
        print()
        print(
            "How long each server's waits on /app really took, on its own clock,"
            " over the measured run: asked and slept on average, and at most."
            + (
                " err: how far each sleep was from what it asked, slept minus"
                " asked, negative when it ended early: on average, and at the"
                " 1st, 50th and 99th percentiles (to 100 µs); early: the share"
                " of sleeps that ended before their time."
                if errors
                else " p1, p50, p99: the 1st, 50th and 99th percentiles of the"
                " time slept (to 100 µs)."
            )
            + " Medians of the runs. Each sleeps on its own runtime's timer:"
            " slopio's ticks every 10 ms, tokio's and h2o's every millisecond."
            " h2load keeps as many requests in flight as it has streams, so a"
            " server that sleeps less answers more per second for it: lat -"
            " slept, the mean latency less the mean sleep, is what the server"
            " itself took."
        )


def summarize_conns(path):
    """A conns run: the same load for every server, so what each spent on it."""
    runs = defaultdict(list)
    for row in csv.DictReader(open(path)):
        # "max": as fast as each connection gets its answers.
        runs[(int(row["conns"]), row["rate"], row["server"])].append(row)

    def median(rows, field):
        return statistics.median(float(r[field]) for r in rows)

    def optional(rows, field):
        """A column older runs do not have."""
        values = [float(r[field]) for r in rows if r.get(field)]
        return f"{statistics.median(values):.2f}" if values else ""

    header = (
        f"{'conns':>7} {'req/s each':>10} {'asked':>9}  {'server':<15}"
        f" {'req/s':>9} {'open':>7}  {'lat mean':>9} {'lat max':>9}"
        f"  {'cores':>5} {'machine':>7} {'irq':>5}  {'RSS':>8} {'per conn':>8}"
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
            f"  {median(rows, 'server_cores'):>5.2f} {optional(rows, 'machine_cores'):>7} {optional(rows, 'machine_irq_cores'):>5}"
            f"  {f'{rss:.1f}M':>8} {f'{per_conn:.1f}K':>8} {f'{tcp:.1f}M':>10}"
            f"  {f'{median(rows, 'client_busy_pct'):.0f}%':>6}  {failed:>6}  {len(rows):>4}"
            f"  {f'{capped}/{len(rows)}' if capped else '':>10}"
        )
    print()
    print(
        "machine: the server machine's CPUs busy, every one, the kernel's"
        " network work included, which cores (the server process alone) leaves"
        " out; irq: how much of it went to interrupts and softirqs. Both count"
        " the client too when it runs on the same machine. "
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
