"""One raw.csv line for a `conns` run, from what bench.sh gathered.

    parse_conns.py <h2load.txt> <mpstat.txt> <before> <after> <nic before>
        <nic after> <idle mem> <during mem> <peak mem> <server> <conns>
        <rate> <rep> [<server mpstat.txt>]

before, after: agent.sh sample, "user_s sys_s now_s".
mem: agent.sh mem, "rss_kib peak_kib tcp_kib established".
"""

import re
import sys


def us(value):
    n, unit = re.fullmatch(r"([\d.]+)(us|ms|s)", value).groups()
    return float(n) * {"us": 1, "ms": 1e3, "s": 1e6}[unit]


def counters(text):
    return {k: int(v) for k, v in (kv.split("=") for kv in text.split())}


def main(args):
    (h2load, mpstat, before, after, nic_before, nic_after, idle, during, peak,
     name, conns, rate, rep) = args[:13]
    server_mpstat = args[13] if len(args) > 13 else None
    text = open(h2load).read()

    def timing(label):
        """mean and max of h2load's "time for <label>" line, in us."""
        m = re.search(rf"^time for {label}:\s+(\S+)\s+(\S+)\s+(\S+)", text, re.M)
        return (us(m.group(3)), us(m.group(2))) if m else (0, 0)

    rps = re.search(r"finished in [\d.]+s, ([\d.]+) req/s", text).group(1)
    requests = re.search(r"(\d+) succeeded, (\d+) failed, (\d+) errored", text).groups()
    lat_min, lat_max, lat_mean, lat_sd = re.search(
        r"^time for request:\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)", text, re.M).groups()
    connect_mean, connect_max = timing("connect")

    u0, s0, t0 = map(float, before.split())
    u1, s1, t1 = map(float, after.split())
    user = (u1 - u0) / (t1 - t0)
    system = (s1 - s0) / (t1 - t0)
    busy = max(user + system, 1e-9)

    idle_rss, _, idle_tcp, _ = map(int, idle.split())
    rss, _, tcp, established = map(int, during.split())
    peak_rss = int(peak.split()[1])

    idle_cpu = [float(line.split()[-1]) for line in open(mpstat)
                if line.startswith("Average") and line.split()[1].isdigit()]
    client = 100 - sum(idle_cpu) / len(idle_cpu)

    nb, na = counters(nic_before), counters(nic_after)
    grew = {k: na[k] - nb.get(k, 0) for k in na if na[k] > nb.get(k, 0)}
    detail = " ".join(f"{k.removesuffix('_allowance_exceeded')}={v}" for k, v in grew.items())

    # The whole server machine: every CPU's time that was not idle, iowait
    # counted as idle (it is what an io_uring wait shows as), and how much of
    # it went to interrupts and softirqs, the kernel's network work.
    machine = irq = ""
    if server_mpstat:
        cols = None
        cpus_busy = cpus_irq = 0.0
        for line in open(server_mpstat):
            fields = line.split()
            # The averages' own header, whatever the clock's format above it.
            if line.startswith("Average") and fields[1] == "CPU":
                cols = {column: i for i, column in enumerate(fields)}
            elif cols and line.startswith("Average") and fields[1].isdigit():
                pct = lambda column: float(fields[cols[column]])
                cpus_busy += 100 - pct("%idle") - pct("%iowait")
                cpus_irq += pct("%irq") + pct("%soft")
        if cols:
            machine, irq = f"{cpus_busy / 100:.2f}", f"{cpus_irq / 100:.2f}"

    def mib(kib):
        return f"{kib / 1024:.1f}"

    print(",".join([
        name, conns, rate, rep, rps, *requests,
        f"{us(lat_mean):.0f}", f"{us(lat_max):.0f}", f"{us(lat_sd):.0f}",
        f"{connect_mean:.0f}", f"{connect_max:.0f}", str(established),
        f"{user + system:.2f}", f"{100 * user / busy:.0f}", f"{100 * system / busy:.0f}",
        mib(idle_rss), mib(rss), mib(peak_rss), mib(idle_tcp), mib(tcp),
        f"{client:.0f}", str(sum(grew.values())), detail, machine, irq,
    ]))


if __name__ == "__main__":
    main(sys.argv[1:])
