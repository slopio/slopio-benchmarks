#!/usr/bin/env bash
# Runs h2load against each server in turn, on a fixed split of the CPUs.
#
#   bench/bench.sh single [local|aws]   # each server on one thread, on CPU 0
#   bench/bench.sh multi [local|aws]    # one worker per CPU, on CPUs 0..N-1
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
#   SERVER_CPUS  default 0 (single); 0..N-1 (multi), N half this machine's
#                CPUs (local) or all the server's (aws). Must start at 0:
#                slopio's runtime pins worker n to CPU n whatever the mask.
#   CLIENT_CPUS  default the CPUs after SERVER_CPUS (local), all of the
#                client's (aws).
#   CLIENT_THREADS  h2load threads, at most one per connection; default 4
#                (single), one per client CPU (multi). It changes the results:
#                the fewer the threads for the same connections, the more
#                requests arrive together, and the more a server can batch.
#   CONFIGS      connections x streams per connection, default
#                "1x1 16x16 64x32" (single), "16x16 64x32 256x16" (multi).
#   SERVERS      which to run, default all of the mode's: slopio hyper
#                (single); slopio hyper-reuseport hyper-multi (multi).
#   DURATION     seconds measured per run, default 8.
#   WARMUP       seconds of load before each measured run, default 2.
#   REPS         repetitions, default 3.
#   PORT         default 18080.
#   SKIP_BUILD   set to use the binaries already in target/release.

set -euo pipefail

mode=${1:-}
where=${2:-local}
root=$(cd "$(dirname "$0")/.." && pwd)

case $mode in
    single | multi) ;;
    *)
        echo "usage: $0 single|multi [local|aws]" >&2
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
        echo "usage: $0 single|multi [local|aws]" >&2
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
esac
server_cpus=${SERVER_CPUS:-$default_server_cpus}
if [[ ! $server_cpus =~ ^0(-([0-9]+))?$ ]]; then
    echo "SERVER_CPUS=$server_cpus: must be 0 or 0-N, slopio pins worker n to CPU n" >&2
    exit 2
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
    multi) client_threads=${CLIENT_THREADS:-$client_count} ;;
esac
duration=${DURATION:-8}
warmup=${WARMUP:-2}
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
    local per_core=
    [[ $mode == multi ]] && per_core=PER_CORE=1
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

echo "server,conns,streams,rep,rps,succeeded,failed,errored,lat_mean_us,lat_max_us,lat_sd_us,server_cores,server_user_pct,server_sys_pct,client_busy_pct,nic_exceeded" > "$out/raw.csv"

run_one() {
    local name=$1 conns=$2 streams=$3 rep=$4
    local tag="$name-${conns}x$streams-$rep"
    local threads=$((conns < client_threads ? conns : client_threads))
    local load="taskset -c $client_cpus h2load -t $threads -c $conns -m $streams"
    local url="http://$target_ip:$port/"

    local pid
    pid=$(on_server "$agent start $server_cpus $bin_dir/$(server_bin "$name") $log_dir/$tag.log PORT=$port $(server_env "$name")")
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
nic = sum(na[k] - nb.get(k, 0) for k in na)
print(",".join([name, conns, streams, rep, rps, *req,
                f"{us(lat[2]):.0f}", f"{us(lat[1]):.0f}", f"{us(lat[3]):.0f}",
                f"{user + system:.2f}",
                f"{100 * user / (user + system):.0f}", f"{100 * system / (user + system):.0f}",
                f"{client:.0f}", str(nic)]))
EOF
    tail -1 "$out/raw.csv"
}

echo "$mode, $where: server on CPUs $server_cpus, h2load on $client_cpus with $client_threads threads; results in $out"
for config in $configs; do
    conns=${config%x*}
    streams=${config#*x}
    for rep in $(seq "$reps"); do
        for name in $servers; do
            run_one "$name" "$conns" "$streams" "$rep"
        done
    done
done

python3 -I "$root/bench/summarize.py" "$out/raw.csv" | tee "$out/summary.txt"
