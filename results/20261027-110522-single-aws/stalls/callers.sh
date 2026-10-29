set -euo pipefail
bin=$1 out=$2
PORT=18080 nohup taskset -c 0 "$bin" > "$out.log" 2>&1 < /dev/null &
pid=$!
sleep 4
sudo -n perf record -q -e cycles:u -F 1999 --call-graph fp -p $pid -o "$out.g.data" -- sleep 6 > /dev/null 2>&1
sudo -n perf record -q -e l2d_cache_refill:u -c 2003 --call-graph fp -p $pid -o "$out.l2.data" -- sleep 5 > /dev/null 2>&1
kill -KILL $pid
r="sudo -n perf report --stdio --no-children --inline"
$r -i "$out.g.data" --sort sym -S __aarch64_ldadd8_rel,__aarch64_ldadd8_relax -g caller,0.5,callee,function,percent --percent-limit 0.1 2>/dev/null | grep -v -e '^#' -e '^$' | head -150 > "$out.atomics.txt"
$r -i "$out.l2.data" --sort sym -g none --percent-limit 1 2>/dev/null | grep -v -e '^#' -e '^$' | head -30 > "$out.l2.txt"
$r -i "$out.l2.data" --sort sym -g caller,0.5,callee,function,percent --percent-limit 4 2>/dev/null | grep -v -e '^#' -e '^$' | head -150 > "$out.l2calls.txt"
sudo -n chown ubuntu "$out".*
