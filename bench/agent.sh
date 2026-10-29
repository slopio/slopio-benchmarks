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
#   agent.sh pin-irqs <cpus>      stops irqbalance and puts NIC queue n's
#                                 interrupt, and XPS, on the nth of those CPUs
#   agent.sh perf-setup           installs perf and lets it see the kernel
#   agent.sh count <pid> <s> <out>  perf stat on the process for s seconds:
#                                 cycles and instructions, syscalls, io_uring
#                                 submissions and completions
#   agent.sh segs                 "in out now_s": the machine's TCP segments
#   agent.sh napi-irqs <n> <ns>   the NIC's napi_defer_hard_irqs and
#                                 gro_flush_timeout, which prefer_busy_poll needs
#   agent.sh info                 the machine, for env.txt

set -euo pipefail

cmd=${1:?usage: agent.sh start|listening|free|sample|alive|stop|mem|nic|pin-irqs|perf-setup|count|segs|napi-irqs|info}
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
        # One queue per CPU, in turn: queue n on the nth CPU of the list.
        cpus=()
        for part in ${1//,/ }; do
            if [[ $part == *-* ]]; then cpus+=($(seq "${part%-*}" "${part#*-}")); else cpus+=("$part"); fi
        done
        # Queue n's interrupt on the nth CPU, and XPS sending from that CPU
        # through queue n, so that a connection's packets both ways stay on
        # one core. The ENA names its queues <iface>-Tx-Rx-<n>.
        awk -v i="$iface" '$0 ~ i"-Tx-Rx-" { irq = $1; sub(/:/, "", irq); n = $NF; sub(/.*-/, "", n); print irq, n }' /proc/interrupts |
            while read -r irq queue; do
                cpu=${cpus[queue % ${#cpus[@]}]}
                echo "$cpu" | sudo -n tee "/proc/irq/$irq/smp_affinity_list" > /dev/null
                xps=/sys/class/net/$iface/queues/tx-$queue/xps_cpus
                [[ -e $xps ]] && printf '%x' $((1 << cpu)) | sudo -n tee "$xps" > /dev/null
            done
        ;;
    napi-irqs)
        iface=$(ip route show default | awk '{ print $5; exit }')
        echo "$1" | sudo -n tee "/sys/class/net/$iface/napi_defer_hard_irqs" > /dev/null
        echo "$2" | sudo -n tee "/sys/class/net/$iface/gro_flush_timeout" > /dev/null
        ;;
    perf-setup)
        if ! perf --version > /dev/null 2>&1; then
            sudo -n DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -q \
                linux-tools-common "linux-tools-$(uname -r)" > /dev/null
        fi
        sudo -n sysctl -q kernel.perf_event_paranoid=-1 kernel.kptr_restrict=0
        perf --version
        ;;
    count)
        # The CPU's own counters where the machine exposes them (none in a VM
        # without a PMU: perf says <not supported>), user and kernel apart,
        # then what the process asked of the kernel: every syscall, the ones
        # that read, write or wait, and io_uring's submissions and
        # completions. Tracepoints need tracefs: through sudo, or else
        # perf_event_paranoid -1 and a tracefs others may read. Those that
        # this kernel lacks (epoll_wait on arm64) are left out, or perf
        # would refuse them all.
        pid=$1 secs=$2 out=$3
        sudo=
        sudo -n true 2> /dev/null && sudo="sudo -n"
        events=cycles:u,instructions:u,cycles:k,instructions:k,branch-misses:u,L1-icache-load-misses:u,context-switches
        for tp in raw_syscalls:sys_enter syscalls:sys_enter_io_uring_enter \
            io_uring:io_uring_submit_req io_uring:io_uring_complete \
            syscalls:sys_enter_read syscalls:sys_enter_readv syscalls:sys_enter_recvfrom syscalls:sys_enter_recvmsg \
            syscalls:sys_enter_write syscalls:sys_enter_writev syscalls:sys_enter_sendto syscalls:sys_enter_sendmsg \
            syscalls:sys_enter_epoll_wait syscalls:sys_enter_epoll_pwait syscalls:sys_enter_epoll_pwait2; do
            $sudo test -d "/sys/kernel/tracing/events/${tp/://}" && events+=,$tp
        done
        # And, as a second io_uring_submit_req, only the zero-copy sends
        # (IORING_OP_SENDMSG_ZC, opcode 48): whether SEND_ZC is used at all.
        zc=()
        $sudo test -d /sys/kernel/tracing/events/io_uring/io_uring_submit_req &&
            zc=(-e io_uring:io_uring_submit_req --filter 'opcode == 48')
        $sudo perf stat -x, -o "$out" -e "$events" "${zc[@]}" -p "$pid" -- sleep "$secs" > /dev/null 2>&1
        [[ -n $sudo ]] && $sudo chown "$(id -u)" "$out"
        ;;
    segs)
        # Every TCP segment the machine received and sent. On loopback both
        # ends are this machine: each segment is counted once in and once
        # out, whichever end sent it.
        awk '/^Tcp:/ { if (!h) { for (i = 1; i <= NF; i++) col[$i] = i; h = 1 } else printf "%s %s ", $col["InSegs"], $col["OutSegs"] }' /proc/net/snmp
        date +%s.%N
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
            "$(for irq in $irqs; do cat /proc/irq/$irq/smp_affinity_list; done | paste -sd' ')," \
            "irqbalance $(systemctl is-active irqbalance 2> /dev/null || true)," \
            "napi_defer_hard_irqs $(cat /sys/class/net/$iface/napi_defer_hard_irqs 2> /dev/null)," \
            "gro_flush_timeout $(cat /sys/class/net/$iface/gro_flush_timeout 2> /dev/null)"
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
