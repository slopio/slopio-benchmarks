#!/usr/bin/env bash
# One kernel profile of one server under load, on the AWS pair, driven from
# here: the server on CPUs 0-3 (one worker each), h2load on the client for
# 30 s, and on the server, from 6 s in: the process's CPU time over 8 s, perf
# with call chains over 6 s, every io_uring submission and completion over
# 3 s. Results in $out/<tag>.*
#
#   kprof-run.sh <out dir> <tag> <server binary name> <conns> <streams> [VAR=value...]
set -euo pipefail
out=$1 tag=$2 bin=$3 conns=$4 streams=$5
shift 5
root=/home/cedric/slopio-benchmarks
source "$root/infra/config.sh"
source "$HOSTS"
mkdir -p "$out"
S() { ssh_to "$SERVER_IP" "$@"; }
C() { ssh_to "$CLIENT_IP" "$@"; }
agent="bash slopio-bench/agent.sh"
log=slopio-bench/logs/kprof-$tag

pid=$(S "$agent start 0-3 slopio-bench/bin/$bin $log.log PORT=18080 PER_CORE=1 $*")
S "$agent listening 18080"
threads=$((conns < 32 ? conns : 32))
C "h2load -t $threads -c $conns -m $streams -D 30 http://$SERVER_PRIVATE_IP:18080/" > "$out/$tag.h2load.txt" 2>&1 &
load=$!
sleep 6
before=$(S "$agent sample $pid")
sleep 8
after=$(S "$agent sample $pid")
S "sudo perf record -q -g -F 999 -p $pid -o $log.cyc.data -- sleep 6 > /dev/null 2>&1"
S "sudo perf record -q -e io_uring:io_uring_submit_req -e io_uring:io_uring_complete -p $pid -o $log.uring.data -- sleep 3 > /dev/null 2>&1" || true
wait $load || true
S "$agent stop $pid"

# Kernel only: by symbol, by symbol inclusive of callees, and the callers of
# the costliest; then the io_uring events by opcode.
r="sudo perf report -i $log.cyc.data --stdio 2> /dev/null | grep -v -e '^#' -e '^\$'"
S "sudo perf report -i $log.cyc.data --stdio --no-children -g none --sort dso --percent-limit 0.5 2> /dev/null | grep -v -e '^#' -e '^\$'" > "$out/$tag.dso.txt" || true
S "sudo perf report -i $log.cyc.data --stdio --no-children -g none --sort sym --dsos '[kernel.kallsyms]' --percent-limit 0.4 2> /dev/null | grep -v -e '^#' -e '^\$' | head -60" > "$out/$tag.ksym.txt" || true
S "sudo perf report -i $log.cyc.data --stdio --children -g none --sort sym --percent-limit 0.8 2> /dev/null | grep -v -e '^#' -e '^\$' | grep '\[k\]' | head -80" > "$out/$tag.kincl.txt" || true
S "sudo perf script -i $log.uring.data -F event,trace 2> /dev/null | awk '/io_uring_submit_req/ { for (i = 1; i <= NF; i++) if (\$i == \"opcode\") { o = \$(i+1); sub(/,/, \"\", o); s[o]++ } } /io_uring_complete/ { c++ } END { for (o in s) printf \"submit %s %d\n\", o, s[o]; printf \"complete all %d\n\", c }'" > "$out/$tag.uring.txt" || true
printf '%s\n%s\n' "$before" "$after" > "$out/$tag.cpu.txt"
grep -E "^finished in" "$out/$tag.h2load.txt" || true
