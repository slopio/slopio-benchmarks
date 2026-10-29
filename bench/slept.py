"""How long a server's waits on /app really took, from its `slept` lines.

    python3 bench/slept.py <server log> [from_s to_s]

Merges the lines logged between two wall-clock times (all of them without),
every thread's, and prints one CSV row: sleeps counted, then in ms what was
asked on average, and what was slept on average, at the 1st, 50th and 99th
percentiles and at most; then how far each sleep was from what it asked
(slept minus asked, signed): on average in ms, the share that ended early in
%, and at the 1st, 50th and 99th percentiles in ms. Nothing if the log has
none. Percentiles come from the servers' 100 µs buckets: each is given as
its bucket's middle.
"""

import re
import sys

BUCKET_US = 100


def slept(path, start=None, end=None):
    n = requested = total = top = err_sum = early = 0
    hist, err = {}, {}
    for line in open(path, errors="replace"):
        m = re.match(r"slept at=([\d.]+) n=(\d+) requested_us=(\d+) sum_us=(\d+) max_us=(\d+) hist=(\S*)"
                     r"(?: err_sum_us=(-?\d+) early=(\d+) err=(\S*))?", line)
        if not m:
            continue
        at = float(m.group(1))
        # A line counts the second or so before it: one logged inside the
        # window counts sleeps that ended there.
        if start is not None and not start < at <= end:
            continue
        n += int(m.group(2))
        requested += int(m.group(3))
        total += int(m.group(4))
        top = max(top, int(m.group(5)))
        for pair in filter(None, m.group(6).split(",")):
            b, c = map(int, pair.split(":"))
            hist[b] = hist.get(b, 0) + c
        # Lines from before the servers counted errors have none.
        if m.group(7) is not None:
            err_sum += int(m.group(7))
            early += int(m.group(8))
            for pair in filter(None, m.group(9).split(",")):
                b, c = map(int, pair.split(":"))
                err[b] = err.get(b, 0) + c
    if n == 0:
        return None

    def percentile(buckets, p, past):
        seen = 0
        for b in sorted(buckets):
            seen += buckets[b]
            if seen >= p * n:
                return (b + 0.5) * BUCKET_US
        return past

    ms = lambda us: f"{us / 1000:.2f}"
    row = [str(n), ms(requested / n), ms(total / n), ms(percentile(hist, 0.01, top)),
           ms(percentile(hist, 0.5, top)), ms(percentile(hist, 0.99, top)), ms(top)]
    if err:
        row += [ms(err_sum / n), f"{100 * early / n:.1f}", ms(percentile(err, 0.01, 0)),
                ms(percentile(err, 0.5, 0)), ms(percentile(err, 0.99, 0))]
    else:
        row += [""] * 5
    return row


if __name__ == "__main__":
    window = map(float, sys.argv[2:4]) if len(sys.argv) > 3 else ()
    row = slept(sys.argv[1], *window)
    if row:
        print(",".join(row))
