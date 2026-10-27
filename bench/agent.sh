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
#   agent.sh mem <pid> <port>     "rss_kib peak_kib tcp_kib established": the
#                                 process's memory, the kernel's for all TCP
#                                 sockets, the connections open on the port
#   agent.sh nic                  the NIC's allowance counters, name=value
#   agent.sh pin-irqs <cpus>      stops irqbalance and moves the NIC's queue
#                                 interrupts onto those CPUs
#   agent.sh perf-setup           installs perf and lets it see the kernel
#   agent.sh info                 the machine, for env.txt

set -euo pipefail

cmd=${1:?usage: agent.sh start|listening|free|sample|alive|stop|mem|nic|pin-irqs|perf-setup|info}
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
    mem)
        # The kernel counts TCP buffers in pages, for every socket on the
        # machine: on one running client and server both, it is both ends.
        page=$(getconf PAGESIZE)
        awk '/^VmRSS/ { rss = $2 } /^VmHWM/ { hwm = $2 } END { printf "%d %d ", rss, hwm }' "/proc/$1/status"
        awk -v page="$page" '/^TCP:/ { for (i = 2; i < NF; i++) if ($i == "mem") printf "%d ", $(i + 1) * page / 1024 }' /proc/net/sockstat
        ss -tnH state established "sport = :$2" | wc -l
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
    pin-irqs)
        # The ENA names its queue interrupts after the interface.
        iface=$(ip route show default | awk '{ print $5; exit }')
        sudo -n systemctl stop irqbalance 2> /dev/null || true
        for irq in $(awk -F: -v i="$iface" '$0 ~ i { gsub(/ /, "", $1); print $1 }' /proc/interrupts); do
            echo "$1" | sudo -n tee "/proc/irq/$irq/smp_affinity_list" > /dev/null
        done
        ;;
    perf-setup)
        if ! perf --version > /dev/null 2>&1; then
            sudo -n DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -q \
                linux-tools-common "linux-tools-$(uname -r)" > /dev/null
        fi
        sudo -n sysctl -q kernel.perf_event_paranoid=-1 kernel.kptr_restrict=0
        perf --version
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
        echo "  page size: $(getconf PAGESIZE)"
        iface=$(ip route show default | awk '{ print $5; exit }')
        irqs=$(awk -F: -v i="$iface" '$0 ~ i { gsub(/ /, "", $1); print $1 }' /proc/interrupts)
        echo "  nic $iface: $(echo $irqs | wc -w) queue interrupts on CPUs" \
            "$(for irq in $irqs; do cat /proc/irq/$irq/smp_affinity_list; done | sort -u | paste -sd' ')," \
            "irqbalance $(systemctl is-active irqbalance 2> /dev/null || true)"
        echo "  open files: $(ulimit -Hn) hard"
        for key in net.ipv4.ip_local_port_range net.core.somaxconn net.ipv4.tcp_max_syn_backlog \
            net.ipv4.tcp_tw_reuse net.ipv4.tcp_syncookies; do
            echo "  $key: $(sysctl -n $key | tr '\t' ' ')"
        done
        ;;
    *)
        echo "unknown command $cmd" >&2
        exit 2
        ;;
esac
