# Runs on the server: start one server on CPU 0, wait for the load, count.
# usage: stalls.sh <binary> <secs> <out prefix>
set -euo pipefail
bin=$1 secs=$2 out=$3
PORT=18080 nohup taskset -c 0 "$bin" > "$out.log" 2>&1 < /dev/null &
pid=$!
sleep 4   # the client starts its load meanwhile
ev=cycles:u,instructions:u,stall_frontend:u,stall_backend:u,stall_backend_mem:u,l1d_cache_refill:u,l2d_cache_refill:u,ll_cache_miss_rd:u,l1d_tlb_refill:u,dtlb_walk:u,itlb_walk:u,br_mis_pred_retired:u,inst_spec:u,mem_access:u
sudo -n perf stat -x, -o "$out.stat" -e "$ev" -p $pid -- sleep "$secs" > /dev/null 2>&1
sudo -n perf record -q -e cycles:u -F 1999 -p $pid -o "$out.cyc.data" -- sleep 4 > /dev/null 2>&1
sudo -n perf record -q -e stall_backend:u -c 20011 -p $pid -o "$out.stb.data" -- sleep 4 > /dev/null 2>&1
kill -INT $pid; sleep 1; kill -KILL $pid 2>/dev/null || true
for k in cyc stb; do
  sudo -n perf report -i "$out.$k.data" --stdio --no-children --sort sym --percent-limit 0.7 2>/dev/null | grep -v -e '^#' -e '^$' | head -45 > "$out.$k.txt"
done
sudo -n chown ubuntu "$out".*
