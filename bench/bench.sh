#!/usr/bin/env bash
# Runs h2load against each server in turn, on a fixed split of the CPUs.
#
#   bench/bench.sh single [local|aws]   # each server on one thread, on CPU 0
#   bench/bench.sh multi [local|aws]    # one worker per CPU, on CPUs 0..N-1
#   bench/bench.sh conns [local|aws]    # many connections at a fixed rate
#                                       # each, or as fast as they can
#
# single and multi give each server all the load it can take: each is
# measured at its own peak. conns gives both the same load, N connections
# each sending a fixed number of requests per second, and compares what it
# costs them: CPU, memory, latency.
#
# local: server and h2load on this machine, the server on the first CPUs and
# h2load on the rest. aws: the server on the instance infra/up.sh made for
# it, h2load on the other, both driven from here over SSH.
#
# Servers alternate within each repetition, so that drift on the machines
# falls on all of them alike. Results go to results/<date>-<mode>-<where>/:
# raw.csv, summary.txt, env.txt, and every h2load output under raw/.
#
# Environment:
#   SERVER_CPUS  default 0 (single, conns); 0..N-1 (multi), N half this
#                machine's CPUs (local) or all the server's (aws). Must start
#                at 0: slopio's runtime pins worker n to CPU n whatever the
#                mask. conns on more than CPU 0 runs one worker per CPU, and
#                hyper in both its modes, as multi does.
#   CLIENT_CPUS  default the CPUs after SERVER_CPUS (local), all of the
#                client's (aws).
#   CLIENT_THREADS  h2load threads, at most one per connection; default 4
#                (single), one per client CPU (multi). It changes the results:
#                the fewer the threads for the same connections, the more
#                requests arrive together, and the more a server can batch.
#   CONFIGS      connections x streams per connection, default
#                "1x1 16x16 64x32" (single), "16x16 64x32 256x16" (multi).
#                For conns, connections@requests per second per connection,
#                default "1000@1 5000@1 20000@1 1000@100 20000@5" (local),
#                "1000@1 10000@1 50000@1 1000@200 10000@20 50000@4" (aws).
#   SERVERS      which to run, default all of the mode's: slopio hyper
#                (single, conns); slopio hyper-reuseport hyper-multi (multi).
#   DURATION     seconds measured per run, default 8 (10 for conns).
#   WARMUP       seconds of load before each measured run, default 2. For
#                conns 10, or one per 2,500 connections if that is longer,
#                for all the connections to be made first.
#   REPS         repetitions, default 3.
#   PORT         default 18080.
#   SERVER_ENV   more VAR=value for every server, e.g. RING=4x16384 for
#                slopio's receive buffers; recorded in env.txt.
#   PROFILE      set, for conns: perf records the server through each measured
#                run, and raw/ gets where its time went, by object and by
#                function. Costs the server some of its throughput.
#   SKIP_BUILD   set to use the binaries already in target/release.

set -euo pipefail

mode=${1:-}
where=${2:-local}
root=$(cd "$(dirname "$0")/.." && pwd)

case $mode in
    single | multi | conns) ;;
    *)
        echo "usage: $0 single|multi|conns [local|aws]" >&2
        exit 2
        ;;
esac

# The two machines: how to run a command on each, where the server's files
# live there, and the address h2load aims at.
case $where in
    local)
        on_server() { bash -c "$1"; }
        on_client() { bash -c "$1"; }
        remote_dir=$root/target/bench-remote
        target_ip=127.0.0.1
        ;;
    aws)
        source "$root/infra/config.sh"
        if [[ ! -f $HOSTS ]]; then
            echo "no instances: infra/up.sh first" >&2
            exit 1
        fi
        source "$HOSTS"
        on_server() { ssh_to "$SERVER_IP" "$1"; }
        on_client() { ssh_to "$CLIENT_IP" "$1"; }
        remote_dir=slopio-bench
        target_ip=$SERVER_PRIVATE_IP
        ;;
    *)
        echo "usage: $0 single|multi|conns [local|aws]" >&2
        exit 2
        ;;
esac
agent="bash $remote_dir/agent.sh"
[[ $where == local ]] && agent="bash $root/bench/agent.sh"

for tool in python3 cargo; do
    command -v $tool > /dev/null || { echo "$tool is needed here" >&2; exit 2; }
done
on_client "command -v h2load && command -v mpstat && command -v taskset" > /dev/null ||
    { echo "the client needs h2load, mpstat and taskset" >&2; exit 2; }

server_ncpu=$(on_server "nproc --all")
client_ncpu=$(on_client "nproc --all")

case $mode in
    single)
        default_server_cpus=0
        configs=${CONFIGS:-"1x1 16x16 64x32"}
        servers=${SERVERS:-"slopio hyper"}
        ;;
    multi)
        if [[ $where == local ]]; then
            default_server_cpus=0-$((server_ncpu / 2 - 1))
        else
            default_server_cpus=0-$((server_ncpu - 1))
        fi
        configs=${CONFIGS:-"16x16 64x32 256x16"}
        servers=${SERVERS:-"slopio hyper-reuseport hyper-multi"}
        ;;
    conns)
        default_server_cpus=0
        if [[ $where == local ]]; then
            configs=${CONFIGS:-"1000@1 5000@1 20000@1 1000@100 20000@5"}
        else
            configs=${CONFIGS:-"1000@1 10000@1 50000@1 1000@200 10000@20 50000@4"}
        fi
        servers=${SERVERS:-"slopio hyper"}
        ;;
esac
server_cpus=${SERVER_CPUS:-$default_server_cpus}
if [[ ! $server_cpus =~ ^0(-([0-9]+))?$ ]]; then
    echo "SERVER_CPUS=$server_cpus: must be 0 or 0-N, slopio pins worker n to CPU n" >&2
    exit 2
fi
# conns on more than one CPU runs the servers as multi does: one worker per
# CPU, and hyper in both its modes.
per_core=
if [[ $mode == multi || ($mode == conns && $server_cpus != 0) ]]; then
    per_core=PER_CORE=1
    [[ $mode == conns ]] && servers=${SERVERS:-"slopio hyper-reuseport hyper-multi"}
fi
server_last=${BASH_REMATCH[2]:-0}
if [[ $where == local ]]; then
    client_cpus=${CLIENT_CPUS:-$((server_last + 1))-$((client_ncpu - 1))}
else
    client_cpus=${CLIENT_CPUS:-0-$((client_ncpu - 1))}
fi

# How many CPUs a list like 2-5,8 names.
count_cpus() {
    local n=0 part
    for part in ${1//,/ }; do
        if [[ $part == *-* ]]; then
            n=$((n + ${part#*-} - ${part%-*} + 1))
        else
            n=$((n + 1))
        fi
    done
    echo $n
}
client_count=$(count_cpus "$client_cpus")
case $mode in
    single) client_threads=${CLIENT_THREADS:-$((client_count < 4 ? client_count : 4))} ;;
    multi | conns) client_threads=${CLIENT_THREADS:-$client_count} ;;
esac
if [[ $mode == conns ]]; then
    duration=${DURATION:-10}
    warmup=${WARMUP:-10}
else
    duration=${DURATION:-8}
    warmup=${WARMUP:-2}
fi
reps=${REPS:-3}
port=${PORT:-18080}

# name -> binary and environment.
server_bin() {
    case $1 in
        slopio) echo slopio-server ;;
        hyper | hyper-reuseport | hyper-multi) echo hyper-server ;;
        *) echo "unknown server $1" >&2; exit 2 ;;
    esac
}
server_env() {
    case $1 in
        slopio | hyper) echo "$per_core" ;;
        hyper-reuseport) echo "$per_core TOKIO_MODE=reuseport" ;;
        hyper-multi) echo "$per_core TOKIO_MODE=multi" ;;
    esac
}

if [[ -z ${SKIP_BUILD:-} ]]; then
    cargo build --release --workspace --manifest-path "$root/Cargo.toml"
fi

# The binaries and the agent, where the server runs them.
if [[ $where == local ]]; then
    bin_dir=$root/target/release
    log_dir=$remote_dir/logs
    mkdir -p "$log_dir"
else
    bin_dir=$remote_dir/bin
    log_dir=$remote_dir/logs
    for host in "$SERVER_IP" "$CLIENT_IP"; do
        ssh_to "$host" "mkdir -p $bin_dir $log_dir"
        scp -q "${SSH_OPTS[@]}" "$root/bench/agent.sh" "ubuntu@$host:$remote_dir/"
    done
    scp -q "${SSH_OPTS[@]}" "$root/target/release/slopio-server" \
        "$root/target/release/hyper-server" "ubuntu@$SERVER_IP:$bin_dir/"
fi

if [[ -n ${PROFILE:-} ]] && ! on_server "$agent perf-setup" > /dev/null; then
    echo "perf could not be set up on the server" >&2
    exit 1
fi

if ! on_server "$agent free $port"; then
    echo "port $port is already in use on the server" >&2
    exit 1
fi

out="$root/results/$(date +%Y%m%d-%H%M%S)-$mode-$where"
[[ $where == local ]] && out+="-$(hostname -s)"
mkdir -p "$out/raw"

{
    echo "date: $(date -Iseconds)"
    echo "mode: $mode, $where"
    echo "server cpus: $server_cpus"
    echo "client cpus: $client_cpus"
    echo "client threads: $client_threads (at most one per connection)"
    echo "configs: $configs"
    echo "servers: $servers"
    echo "server environment: ${SERVER_ENV:-none}"
    echo "duration: ${duration}s, warmup: ${warmup}s, reps: $reps"
    echo "server machine:"
    on_server "$agent info"
    if [[ $where == aws ]]; then
        echo "client machine:"
        on_client "bash $remote_dir/agent.sh info"
    fi
    echo "h2load: $(on_client "h2load --version | head -1")"
    echo "rustc: $(rustc -V)"
    echo "benchmarks: $(git -C "$root" rev-parse --short HEAD 2> /dev/null || echo none)$(git -C "$root" diff --quiet 2> /dev/null || echo ' (dirty)')"
    python3 -I - "$root/Cargo.lock" << 'EOF'
import sys, tomllib
lock = tomllib.load(open(sys.argv[1], "rb"))
for p in lock["package"]:
    if p["name"] in ("slopio-h2", "runtime", "hyper", "h2", "tokio", "mimalloc"):
        source = p.get("source", "")
        rev = source.split("#")[1][:7] if "#" in source else ""
        print(f"{p['name']}: {p['version']} {rev}".rstrip())
EOF
} > "$out/env.txt"

if [[ $mode == conns ]]; then
    echo "server,conns,rate,rep,rps,succeeded,failed,errored,lat_mean_us,lat_max_us,lat_sd_us,connect_mean_us,connect_max_us,established,server_cores,server_user_pct,server_sys_pct,idle_mib,rss_mib,peak_mib,tcp_idle_mib,tcp_mib,client_busy_pct,nic_exceeded,nic_detail" > "$out/raw.csv"
else
    echo "server,conns,streams,rep,rps,succeeded,failed,errored,lat_mean_us,lat_max_us,lat_sd_us,server_cores,server_user_pct,server_sys_pct,client_busy_pct,nic_exceeded,nic_detail" > "$out/raw.csv"
fi

run_one() {
    local name=$1 conns=$2 streams=$3 rep=$4
    local tag="$name-${conns}x$streams-$rep"
    local threads=$((conns < client_threads ? conns : client_threads))
    local load="taskset -c $client_cpus h2load -t $threads -c $conns -m $streams"
    local url="http://$target_ip:$port/"

    local pid
    pid=$(on_server "$agent start $server_cpus $bin_dir/$(server_bin "$name") $log_dir/$tag.log PORT=$port $(server_env "$name") ${SERVER_ENV:-}")
    if ! on_server "$agent listening $port"; then
        on_server "cat $log_dir/$tag.log" > "$out/raw/$tag.server.log" || true
        echo "$tag: the server never listened, see $out/raw/$tag.server.log" >&2
        exit 1
    fi

    on_client "$load -D $warmup $url" > /dev/null 2>&1 || true

    local before after nic_before nic_after
    nic_before=$(on_server "$agent nic")
    before=$(on_server "$agent sample $pid")
    on_client "mpstat -P $client_cpus $((duration > 2 ? duration - 1 : 1)) 1" > "$out/raw/$tag.mpstat.txt" &
    local mp=$!
    on_client "$load -D $duration $url" > "$out/raw/$tag.h2load.txt" 2>&1 || true
    after=$(on_server "$agent sample $pid")
    nic_after=$(on_server "$agent nic")
    wait $mp || true

    if ! on_server "$agent alive $pid"; then
        on_server "cat $log_dir/$tag.log" > "$out/raw/$tag.server.log" || true
        echo "$tag: the server died, see $out/raw/$tag.server.log" >&2
        exit 1
    fi
    on_server "$agent stop $pid"
    on_server "cat $log_dir/$tag.log" > "$out/raw/$tag.server.log" || true

    python3 -I - "$out/raw/$tag.h2load.txt" "$out/raw/$tag.mpstat.txt" \
        "$before" "$after" "$nic_before" "$nic_after" \
        "$name" "$conns" "$streams" "$rep" >> "$out/raw.csv" << 'EOF'
import re, sys
h2load, mpstat, before, after, nic_before, nic_after, name, conns, streams, rep = sys.argv[1:]
text = open(h2load).read()

def us(v):
    n, unit = re.fullmatch(r"([\d.]+)(us|ms|s)", v).groups()
    return float(n) * {"us": 1, "ms": 1e3, "s": 1e6}[unit]

def counters(s):
    return {k: int(v) for k, v in (kv.split("=") for kv in s.split())}

rps = re.search(r"finished in [\d.]+s, ([\d.]+) req/s", text).group(1)
req = re.search(r"(\d+) succeeded, (\d+) failed, (\d+) errored", text).groups()
lat = re.search(r"^time for request:\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)", text, re.M).groups()
u0, s0, t0 = map(float, before.split())
u1, s1, t1 = map(float, after.split())
user = (u1 - u0) / (t1 - t0)
system = (s1 - s0) / (t1 - t0)
idle = [float(l.split()[-1]) for l in open(mpstat)
        if l.startswith("Average") and l.split()[1].isdigit()]
client = 100 - sum(idle) / len(idle)
nb, na = counters(nic_before), counters(nic_after)
grew = {k: na[k] - nb.get(k, 0) for k in na if na[k] > nb.get(k, 0)}
nic = sum(grew.values())
# Which limit it was: bandwidth out or in, packets per second, connections.
detail = " ".join(f"{k.removesuffix('_allowance_exceeded')}={v}" for k, v in grew.items())
print(",".join([name, conns, streams, rep, rps, *req,
                f"{us(lat[2]):.0f}", f"{us(lat[1]):.0f}", f"{us(lat[3]):.0f}",
                f"{user + system:.2f}",
                f"{100 * user / (user + system):.0f}", f"{100 * system / (user + system):.0f}",
                f"{client:.0f}", str(nic), detail]))
EOF
    tail -1 "$out/raw.csv"
}

# N connections at a fixed rate each, the same for both servers: what it
# costs each to hold them and answer them.
run_conns() {
    local name=$1 conns=$2 rate=$3 rep=$4
    local tag="$name-${conns}c-${rate}rps-$rep"
    local threads=$((conns < client_threads ? conns : client_threads))
    local url="http://$target_ip:$port/"

    local pid
    pid=$(on_server "$agent start $server_cpus $bin_dir/$(server_bin "$name") $log_dir/$tag.log PORT=$port $(server_env "$name") ${SERVER_ENV:-}")
    if ! on_server "$agent listening $port"; then
        on_server "cat $log_dir/$tag.log" > "$out/raw/$tag.server.log" || true
        echo "$tag: the server never listened, see $out/raw/$tag.server.log" >&2
        exit 1
    fi
    local idle
    idle=$(on_server "$agent mem $pid $port")

    # h2load makes its connections all at once, then sends. The warm-up is
    # left out of its figures and out of the server's CPU time below, and
    # grows with the connections: past the listen backlog, handshakes are
    # retried, and the last of 50,000 took 10 s. A connection made after the
    # measured time has ended is never stopped, and h2load waits on it for
    # ever: the timeout ends that. At a fixed rate, up to 8 streams per
    # connection, so that one slow answer does not hold the rate back; at
    # max, one request at a time per connection, each sent as soon as the
    # last is answered, as as many separate clients would.
    local run_warmup=$((conns / 2500 > warmup ? conns / 2500 : warmup))
    local pace="-m 8 --rps $rate"
    [[ $rate == max ]] && pace="-m 1"
    on_client "ulimit -n \$(ulimit -Hn); timeout -s KILL $((run_warmup + duration + 30)) taskset -c $client_cpus h2load -t $threads -c $conns $pace --warm-up-time ${run_warmup}s -D $duration $url" \
        > "$out/raw/$tag.h2load.txt" 2>&1 &
    local load=$!
    sleep "$run_warmup"

    # Any of these fails once the server has died; that is told below.
    local before after during peak nic_before nic_after
    nic_before=$(on_server "$agent nic") || true
    before=$(on_server "$agent sample $pid") || true
    on_client "mpstat -P $client_cpus $((duration > 2 ? duration - 1 : 1)) 1" > "$out/raw/$tag.mpstat.txt" &
    local mp=$!
    # perf's own cost lowers what it measures: a profiled run's figures are
    # not to be set beside an unprofiled one's.
    local prof=
    if [[ -n ${PROFILE:-} ]]; then
        on_server "perf record -q -F 999 -g -p $pid -o $log_dir/$tag.perf.data -- sleep $((duration - 2)) > /dev/null 2>&1" &
        prof=$!
    fi
    sleep $((duration / 2))
    during=$(on_server "$agent mem $pid $port") || true
    wait $load || true
    [[ -n $prof ]] && { wait "$prof" || true; }
    after=$(on_server "$agent sample $pid") || true
    nic_after=$(on_server "$agent nic") || true
    peak=$(on_server "$agent mem $pid $port") || true
    wait $mp || true

    # A server that died under the load is a result, not a reason to stop:
    # what the kernel said goes to events.txt, and the next run goes on.
    if ! on_server "$agent alive $pid"; then
        {
            echo "$tag: the server died"
            on_server "cat $log_dir/$tag.log; sudo -n dmesg -T 2> /dev/null | grep -i -E 'out of memory|killed process' | tail -2"
        } >> "$out/events.txt" 2>&1 || true
        echo "$tag: the server died, see $out/events.txt" >&2
        return
    fi
    on_server "$agent stop $pid"
    on_server "cat $log_dir/$tag.log" > "$out/raw/$tag.server.log" || true

    # Where the time went: by object (the kernel, the server, libc), then by
    # function, each by the samples taken in it rather than below it.
    if [[ -n ${PROFILE:-} ]]; then
        local report="perf report -i $log_dir/$tag.perf.data --no-children -g none --stdio --percent-limit 0.5"
        on_server "$report --sort dso 2> /dev/null | grep -v -e '^#' -e '^$'" > "$out/raw/$tag.perf-dso.txt" || true
        on_server "$report --sort dso,sym 2> /dev/null | grep -v -e '^#' -e '^$' | head -60" > "$out/raw/$tag.perf-sym.txt" || true
    fi

    if ! grep -q "^finished in" "$out/raw/$tag.h2load.txt"; then
        echo "$tag: h2load printed no figures (killed after hanging); run left out" | tee -a "$out/events.txt" >&2
        return
    fi
    python3 -I "$root/bench/parse_conns.py" "$out/raw/$tag.h2load.txt" "$out/raw/$tag.mpstat.txt" \
        "$before" "$after" "$nic_before" "$nic_after" "$idle" "$during" "$peak" \
        "$name" "$conns" "$rate" "$rep" >> "$out/raw.csv"
    tail -1 "$out/raw.csv"
}

echo "$mode, $where: server on CPUs $server_cpus, h2load on $client_cpus with $client_threads threads; results in $out"
for config in $configs; do
    for rep in $(seq "$reps"); do
        for name in $servers; do
            if [[ $mode == conns ]]; then
                run_conns "$name" "${config%@*}" "${config#*@}" "$rep"
            else
                run_one "$name" "${config%x*}" "${config#*x}" "$rep"
            fi
        done
    done
done

{
    python3 -I "$root/bench/summarize.py" "$out/raw.csv"
    if [[ -f $out/events.txt ]]; then
        echo
        echo "Runs left out:"
        cat "$out/events.txt"
    fi
} | tee "$out/summary.txt"
