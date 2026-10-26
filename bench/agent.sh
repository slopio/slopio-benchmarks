#!/usr/bin/env bash
# What bench.sh runs on the server's machine, or the client's: this one, or
# an instance over SSH. One command per call.
#
#   agent.sh start <cpus> <binary> <log> [VAR=value...]   prints the pid
#   agent.sh listening <port>     waits up to 5 s for a listener
#   agent.sh free <port>          fails if something listens there
#   agent.sh sample <pid>         "user_s sys_s now_s" for the process
#   agent.sh alive <pid>
#   agent.sh stop <pid>           SIGINT, then SIGKILL after 5 s
#   agent.sh nic                  the NIC's allowance counters, name=value
#   agent.sh info                 the machine, for env.txt

set -euo pipefail

cmd=${1:?usage: agent.sh start|listening|free|sample|alive|stop|nic|info}
shift

case $cmd in
    start)
        cpus=$1 bin=$2 log=$3
        shift 3
        ulimit -n "$(ulimit -Hn)"
        env "$@" nohup taskset -c "$cpus" "$bin" > "$log" 2>&1 < /dev/null &
        echo $!
        ;;
    listening)
        for _ in $(seq 100); do
            ss -ltnH "sport = :$1" | grep -q . && exit 0
            sleep 0.05
        done
        exit 1
        ;;
    free)
        ! ss -ltnH "sport = :$1" | grep -q .
        ;;
    sample)
        # Every thread's time, kernel included, and when it was read: the
        # elapsed time is this machine's, not the caller's.
        awk -v tck="$(getconf CLK_TCK)" '{ printf "%.2f %.2f ", $14 / tck, $15 / tck }' "/proc/$1/stat"
        date +%s.%N
        ;;
    alive)
        kill -0 "$1" 2> /dev/null
        ;;
    stop)
        kill -INT "$1" 2> /dev/null || exit 0
        for _ in $(seq 100); do
            kill -0 "$1" 2> /dev/null || exit 0
            sleep 0.05
        done
        kill -KILL "$1" 2> /dev/null || true
        ;;
    nic)
        # An ENA's counts of packets queued or dropped for going past what
        # the instance is allowed: bandwidth in and out, packets per second,
        # tracked connections. Nothing on a machine without one.
        iface=$(ip route show default | awk '{ print $5; exit }')
        ethtool -S "$iface" 2> /dev/null |
            awk -F: '/allowance_exceeded/ { gsub(/ /, ""); printf "%s=%s ", $1, $2 }'
        echo
        ;;
    info)
        imds() {
            local token
            token=$(curl -fsS -m 1 -X PUT http://169.254.169.254/latest/api/token \
                -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2> /dev/null) || return 0
            curl -fsS -m 1 -H "X-aws-ec2-metadata-token: $token" \
                "http://169.254.169.254/latest/meta-data/$1" 2> /dev/null || true
        }
        type=$(imds instance-type)
        echo "  instance: ${type:-none}${type:+ in $(imds placement/availability-zone)}"
        echo "  kernel: $(uname -r)"
        echo "  cpus: $(nproc --all), $(lscpu | awk -F: '/^Model name/ { gsub(/^ +/, "", $2); print $2 }')"
        echo "  io_uring_disabled: $(cat /proc/sys/kernel/io_uring_disabled 2> /dev/null || echo n/a)"
        ;;
    *)
        echo "unknown command $cmd" >&2
        exit 2
        ;;
esac
