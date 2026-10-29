# Protocol: does zero-copy raise the most requests slopio can serve?

The question: on one worker, with the server's CPU as the only limit, does
sending with `SEND_ZC` let slopio answer more requests per second than
copying, from which response size, and with what batch threshold?

The first try (`results/20261027-174554-` to `-180151-single-aws`) could
not say: on a `c8gn.medium` the network was the limit. Its burst of
25 Gbit/s ran out mid-session, leaving its 3.125 Gbit/s baseline, so from
64 KiB every server was held to the same ~3.3 Gbit/s. CPU per request
still showed zero-copy saving 10-15 % from 16 KiB, and costing 15 % in one
case (256 KiB at 16 × 16), unexplained.

## What is compared

| name        | what                                                          |
|-------------|---------------------------------------------------------------|
| `slopio`    | copy: every send a plain `SENDMSG`                            |
| `slopio-zc` | the same binary with `ZERO_COPY=1`: a send of at least `ZC_MIN_BATCH` bytes goes as `SENDMSG_ZC` |
| `h2o`       | reference; copies every body twice, into its buffer and into the kernel |

Both slopio runs use the patched slopio-h2 in `/tmp/slopio-h2-zc`
(`[patch]` in `Cargo.toml`): the server's flush passes `may_hold = true`,
without which `SEND_ZC` is never used. The copy transport ignores the flag,
so `slopio` is the published behaviour. Bodies come from `/app?size_kb=N`:
from 4 KiB up slopio hands them over without copying them in user space
(`write_owned_final`), so the only copy `SEND_ZC` can save is the kernel's.

A zero-copy send hands the buffers back at the kernel's notification, once
the peer has acknowledged the data, not at the send's completion; a
connection has one send in flight. So zero-copy trades a copy for a wait of
about a round trip per batch. More connections hide the wait; the grid
below has 16, 64 and 256.

## Machines

| role   | type           | why                                                           |
|--------|----------------|---------------------------------------------------------------|
| server | `c8gn.4xlarge` | 50 Gbit/s sustained, baseline = peak: no burst credits to run out. The server runs on CPU 0 only (`SERVER_CPUS=0`). |
| client | `c8gn.4xlarge` | the same 50 Gbit/s, and 16 vCPUs for h2load to receive it without being the limit. |

`SERVER_TYPE=c8gn.4xlarge CLIENT_TYPE=c8gn.4xlarge infra/up.sh`, in one
cluster placement group as always. $1.07/h each in eu-west-1: about $3 for
the whole protocol.

One worker on a 16-vCPU host is not a `c8gn.medium`: it shares the L3 and
memory with fewer neighbours. Compare runs of this protocol with each
other, not with earlier ones.

Expected ceilings, from the CPU per request measured so far: ~200k req/s at
16 KiB (26 Gbit/s), ~50k at 64 KiB (26 Gbit/s), ~20k at 256 KiB
(42 Gbit/s). 256 KiB comes close to the 50 Gbit/s; 1 MiB is left out for
that reason (it would need a `c8gn.8xlarge`, 100 Gbit/s, $2.14/h).

## Where the NIC's interrupts go

The server's NIC has 8 queues. Two placements, each run apart:

- **A, everything on the worker's core** (the main one): every queue's
  interrupt and XPS on CPU 0 (`agent.sh pin-irqs 0` on the server). One
  core does all the work for its requests, kernel network work included,
  as on the `c8gn.medium`; what zero-copy saves anywhere in the kernel
  shows as requests.
- **B, interrupts away from the worker** (only for the sizes where A shows
  a gain): queues on CPUs 1-8 (`agent.sh pin-irqs 1-8`). The worker gets
  more requests through; what the interrupts cost lands on other CPUs and
  must be counted there too (whole-machine CPU, below).

## Changes needed first (local, free)

1. **Whole-machine CPU in `single` mode.** `run_one` records only the
   server process's CPU; `run_conns` already samples the whole server
   machine (`mpstat -P ALL`, `machine_cores`, `machine_irq_cores`). Do the
   same in `run_one`: needed for B, and to see softirq time in A.
2. **The threshold as an environment variable** in the patched copy:
   `SLOPIO_ZC_MIN_BATCH` (bytes), read once, default 64 KiB, so that one
   binary can be swept (`SERVER_ENV=SLOPIO_ZC_MIN_BATCH=...`).
3. **Check locally** that `slopio-zc` still counts `SENDMSG_ZC` (`COUNT`'s
   `ZC sends`), and that `slopio` counts none.

## Runs

Fixed throughout: `CLIENT_THREADS=16`, 3 repetitions, 8 s measured after
2 s of warm-up, servers alternating within each repetition.

### 1. Check the ceilings (~10 min)

- **The link and the client:** h2o with `PER_CORE=1` on all 16 server CPUs
  (`SERVER_CPUS=0-15`), `/app?size_kb=256`, 64 × 32. It must reach
  ~45-50 Gbit/s with the client under ~70 % busy, else the client or the
  link is the limit and the grid's large sizes measure it.
- **What `COUNT` costs:** `slopio` and `slopio-zc` at 16 KiB, 64 × 32, with
  and without `COUNT=1`. If req/s differ by less than the spread (~2 %),
  passes 2 and 3 below can be one.

### 2. Most requests served (~30 min)

Placement A. Sizes 2, 8, 16, 32, 64, 128, 256 KiB; 16 × 16 and 64 × 32;
`slopio`, `slopio-zc`, `h2o`; without `COUNT`.

```sh
export SERVER_CPUS=0 CLIENT_THREADS=16 SKIP_BUILD=1 SERVERS="slopio slopio-zc h2o" CONFIGS="16x16 64x32"
for kb in 2 8 16 32 64 128 256; do URL_PATH="/app?size_kb=$kb" bench/bench.sh single aws; done
```

### 3. What a request costs (~20 min)

The same grid with `COUNT=1`, two repetitions: user and kernel time,
kernel instructions, SQEs, CQEs and `ZC sends` per request. Merged into
pass 2 if `COUNT` proved free in pass 1.

### 4. The threshold (~15 min)

`slopio` against `slopio-zc` at 8, 16 and 32 KiB, 64 × 32, with
`SLOPIO_ZC_MIN_BATCH` at 16, 32, 64 and 128 KiB: from which batch size
zero-copy stops costing more than it saves. One `bench.sh` call per
threshold.

### 5. Interrupts away (~15 min, if 2 showed a gain)

Placement B, for the two sizes with the largest gain in 2, both connection
counts, with the whole-machine CPU.

### 6. Also: 256 KiB at 16 × 16 and 256 × 16

The case where zero-copy cost more in the first try, now unthrottled, and
with 256 connections to see whether more connections hide the wait for
the notification. With `COUNT=1`: more SQEs per request than in the copy
run would mean partial sends, each pinning pages again.

## A run counts only if

- the server process used ≥ 0.95 of its core (`server cores`): else
  something other than its CPU held it back, and the run says nothing
  about the most it can serve;
- `net capped` is empty and the bandwidth served stays under ~40 Gbit/s
  (80 % of 50); above, mark it and compare CPU per request only;
- the client is under ~70 % busy (`client busy`);
- no request failed;
- the spread of the three repetitions is under ~5 %.

## What decides

Zero-copy improves slopio at a size if `slopio-zc`'s median req/s is above
`slopio`'s by more than both spreads, in placement A, with every run
valid. Reported per size and connection count: req/s and their ratio,
Gbit/s, CPU per request user and kernel, `ZC sends` per request; then the
smallest size where it wins, and the threshold pass 4 points to. If it
never wins in A but saves CPU in B, it is worth it only where interrupts
run elsewhere, and that is the answer.

## After

`infra/down.sh`, and check it says nothing is left. Results go to
`RESULTS.md`; the threshold found, if any, to slopio-h2's `ZC_MIN_BATCH`
(marked provisional there), and the `may_hold` question back to
slopio-h2: whether the server's flush should pass `true`, and whether a
second send in flight would hide the wait for the notification.
