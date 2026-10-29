#!/usr/bin/env bash
# The kernel's cost per request of one server under an open-loop load from
# slopio-load, on the AWS pair, driven from here: the server on CPUs 0-3 (one
# worker each), slopio-load on the client's CPUs 0-15 at RATE requests per
# second over CONNS connections. On the server, over 6 s of the measured
# run: the process's CPU time, its sends, reads and io_uring operations, and
# the machine's TCP segments; and its memory idle and under the load, with
# the kernel's TCP buffers. One line per run on stdout, raw files in $out.
#
#   kernel-run.sh <out dir> <tag> <server binary name> <conns> <rate> [VAR=value...]
set -euo pipefail
out=$1 tag=$2 bin=$3 conns=$4 rate=$5
shift 5
root=/home/cedric/slopio-benchmarks
source "$root/infra/config.sh"
source "$HOSTS"
mkdir -p "$out"
S() { ssh_to "$SERVER_IP" "$@"; }
C() { ssh_to "$CLIENT_IP" "$@"; }
agent="bash slopio-bench/agent.sh"

pid=$(S "$agent start 0-3 slopio-bench/bin/$bin slopio-bench/logs/$tag.log PORT=18080 PER_CORE=1 $*")
S "$agent listening 18080"
idle=$(S "$agent mem $pid 18080")
C "ulimit -n \$(ulimit -Hn); URL=http://$SERVER_PRIVATE_IP:18080/ CPUS=0-15 CONNS=$conns RATE=$rate DURATION=12 WARMUP=${WARMUP:-4} timeout 120 ./slopio-load" > "$out/$tag.load.txt" 2>&1 &
load=$!
# Until every connection is open and the warm-up is over: the client opens
# its connections first, then starts its clock.
until [[ $(S "ss -tnH state established '( sport = :18080 )' | wc -l") -ge $conns ]]; do sleep 1; done
sleep $(( ${WARMUP:-4} + 1 ))
measured=$(S "s0=\$($agent segs); c0=\$($agent sample $pid);
  sudo perf stat -x, -e syscalls:sys_enter_sendmsg,syscalls:sys_enter_writev,syscalls:sys_enter_read,syscalls:sys_enter_io_uring_enter,io_uring:io_uring_submit_req,io_uring:io_uring_complete -p $pid -- sleep 6 2>&1 > /dev/null | grep -v '^#' | cut -d, -f1,3 | tr '\n' ' ';
  echo; echo \$s0; echo \$($agent segs); echo \$c0; echo \$($agent sample $pid); echo \$($agent mem $pid 18080)")
wait $load || true
S "$agent stop $pid"
printf '%s\n%s\n' "$measured" "$idle" > "$out/$tag.server.txt"

python3 - "$tag" "$out/$tag.load.txt" "$out/$tag.server.txt" << 'EOF'
import re, sys
tag, load, server = sys.argv[1:]
text = open(load).read()
m = re.search(r"^(\d+) req/s .* failed.*?p50 ([\d.]+) p90 [\d.]+ p99 ([\d.]+)", text, re.M)
rps, p50, p99 = float(m.group(1)), m.group(2), m.group(3)
failed = re.search(r"(\d+) failed", text).group(1)
lines = open(server).read().split("\n")
counts = {}
for item in lines[0].split():
    v, e = item.split(",", 1)
    if re.fullmatch(r"[\d.]+", v):
        counts[e.split(":")[-1].removeprefix("sys_enter_")] = float(v)
(i0, o0, t0), (i1, o1, t1) = (map(float, l.split()) for l in lines[1:3])
(u0, s0, w0), (u1, s1, w1) = (map(float, l.split()) for l in lines[3:5])
rss, _, tcp, open_ = map(float, lines[5].split())
rss0, _, tcp0, _ = map(float, lines[6].split())
mem = f" | RSS {rss/1024:.0f} MiB ({(rss-rss0)/max(open_,1):.1f} KiB/conn over {open_:.0f} open) TCP {(tcp-tcp0)/1024:.0f} MiB"
per = lambda n: n / (rps * 6)
user, kern = (u1 - u0) / (w1 - w0), (s1 - s0) / (w1 - w0)
ops = " ".join(f"{k} {per(v):.3f}" for k, v in counts.items() if v)
print(f"{tag:22} {rps/1e6:4.2f}M req/s failed {failed:>6} | cores {user+kern:4.2f} user {user/rps*1e6:5.3f} kernel {kern/rps*1e6:5.3f} µs/req"
      f" | {ops} | segs in {(i1-i0)/(t1-t0)/rps:.3f} out {(o1-o0)/(t1-t0)/rps:.3f} | lat p50 {p50} p99 {p99} ms{mem}")
EOF
