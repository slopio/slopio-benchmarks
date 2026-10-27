# Results

slopio-h2 against hyper, answering the README's one route: `GET /`, 2048
bytes, the same headers and HTTP/2 settings from both. Every number is the
median of three 8 s runs after a 2 s warm-up, the servers alternating; the
raw data, h2load outputs and machine details are under `results/`.

## On AWS (eu-west-1, Graviton4, kernel 7.0)

The server and h2load on two instances in one cluster placement group,
talking over their private addresses. No request failed in any run.

### One core

Server `c8gn.medium` (1 vCPU), h2load on a `c8gn.xlarge` (4 vCPUs, 4
threads). `results/20261026-204458-single-aws`.

| conns × streams | slopio        | hyper         | ratio | mean latency slopio / hyper |
|-----------------|---------------|---------------|-------|-----------------------------|
| 1 × 1           | 23.9k req/s   | 23.6k req/s   | 1.0×  | 40 µs / 40 µs               |
| 16 × 16         | 637k req/s    | 261k req/s    | 2.4×  | 379 µs / 965 µs             |
| 64 × 32         | 621k req/s    | 276k req/s    | 2.3×  | 3.19 ms / 7.38 ms           |

Both servers used 0.95 of their vCPU under load; h2load 15-38 % of its own.
With one request in flight, both wait on the network round trip.

### Several cores

h2load on a `c8gn.8xlarge` (32 vCPUs, 32 threads). hyper in its two modes:
`reuseport`, one current-thread runtime per core with its own listener as
slopio runs, and `multi`, tokio's work-stealing runtime as it is usually run.

4 of the 16 CPUs of a `c8gn.4xlarge` (50 Gbit/s),
`results/20261026-205645-multi-aws`:

| conns × streams | slopio    | hyper reuseport | hyper multi   |
|-----------------|-----------|-----------------|---------------|
| 16 × 16         | 1.83M     | 945k            | 683k          |
| 64 × 32         | **2.47M** | 1.14M (2.2×)    | 826k (3.0×)   |
| 256 × 16        | **2.11M** | 1.06M (2.0×)    | 764k (2.8×)   |

8 of the 32 CPUs of a `c8gn.8xlarge` (100 Gbit/s),
`results/20261026-211756-multi-aws`:

| conns × streams | slopio    | hyper reuseport | hyper multi   |
|-----------------|-----------|-----------------|---------------|
| 16 × 16         | 2.01M     | 1.36M           | 912k          |
| 64 × 32         | **4.84M** | 2.19M (2.2×)    | 1.48M (3.3×)  |
| 256 × 16        | **3.96M** | 1.99M (2.0×)    | 1.38M (2.9×)  |

At 64 × 32 and 256 × 16 every server used all its cores (3.8 of 4, 7.5 of
8) and h2load at most 43 % of its CPUs, so these measure the servers.

The same 8 CPUs on a `c8gn.4xlarge` stopped slopio at 3.00M req/s in all
six runs, 3M responses of ~2.1 KB being the instance's 50 Gbit/s; its NIC
counted packets held back for going past the allowance, and slopio used 5
of its 8 cores. `results/20261026-210343-multi-aws` keeps that run, marked
`net capped`.

### Per core

| cores | slopio req/s per core used | hyper reuseport | hyper multi |
|-------|----------------------------|-----------------|-------------|
| 1     | 637k                       | 261k            |             |
| 4     | 648k                       | 299k            | 218k        |
| 8     | 640k                       | 287k            | 197k        |

One core at 16 × 16, several at 64 × 32. Both scale near linearly from 1 to
8 cores; the ratio stays at about 2.2×.

## Against h2o, one core, on AWS

`h2o-server` is libh2o, h2o's own library in C (`servers/h2o`, built from
h2o `8c95f06` with its release flags), set up as the other two; its
responses match slopio's byte for byte. Server on a `c8gn.medium`, h2load on
a `c8gn.xlarge` with 4 threads, the two alternating
(`results/20261027-044812-single-aws`):

| conns × streams | slopio    | h2o           | h2o / slopio | mean latency slopio / h2o |
|-----------------|-----------|---------------|--------------|---------------------------|
| 1 × 1           | 25.4k     | 26.0k         | 1.0×         | 37 µs / 36 µs             |
| 16 × 16         | 613k      | **1.08M**     | **1.77×**    | 402 µs / 216 µs           |
| 64 × 32         | 645k      | **1.19M**     | **1.85×**    | 3.08 ms / 1.67 ms         |

Both servers at 0.95 of their core, h2load at most 57 % of its own. At
16 × 16, a request costs slopio 0.96 µs of user time and 0.59 µs of kernel
time, h2o 0.45 and 0.43: h2o is cheaper in both, the kernel included,
though it reads and writes with plain syscalls on epoll. Where, a profile of
the two side by side is to say. Locally, on loopback, h2o led by 9 to 42 %
(`results/20261027-044214-single-local-vm`).

## Many connections, on AWS

`bench/bench.sh conns`: N connections, each sending one request at a time.

### As fast as they can, 8 cores

Both on a `c8gn.8xlarge` (64 GiB, 100 Gbit/s), the servers on 8 of its CPUs;
each connection sends its next request as soon as it has the answer.
`results/20261026-223131-conns-aws`.

| connections | slopio        | hyper reuseport | hyper multi   | memory at 50,000: slopio / hyper |
|-------------|---------------|-----------------|---------------|----------------------------------|
| 1,000       | **1.72M req/s** | 1.20M (1.44×)   | 1.02M (1.69×) |                                  |
| 10,000      | **1.03M**     | 709k (1.46×)    | 792k (1.30×)  |                                  |
| 50,000      | **894k**      | 592k (1.51×)    | 712k (1.26×)  | 745 MiB / 1.25 GiB               |

Every server used 7.8 of its 8 cores, h2load at most 51 % of its own; no
request failed, no run was capped. With one request in flight per
connection there is little left to batch per connection: slopio did 4.84M
req/s on the same cores with 64 connections of 32 streams, 1.72M with 1,000
of one. That is where its lead was largest, hence the smaller gap here.
hyper's `multi` mode overtakes `reuseport` from 10,000 connections.

### At a fixed rate, one core

The server on a `c8gn.medium` (1 vCPU, 1.8 GiB), h2load on a
`c8gn.xlarge`; both get the same load, N connections at so many requests a
second each. `results/20261026-214840-conns-aws`,
`results/20261026-221046-conns-aws`.

| connections × req/s each | slopio                          | hyper                                 |
|--------------------------|---------------------------------|---------------------------------------|
| 10,000 × 1               | 124 MiB, 0.09 core              | 224 MiB, 0.12 core                    |
| 50,000 × 1               | 522 MiB, 0.53 core              | 1.12 GiB, 0.71 core                   |
| 1,000 × 200              | 200k req/s, 0.72 core           | 156k, core saturated                  |
| 10,000 × 20              | 200k req/s, 0.88 core           | 141k, core saturated                  |
| 50,000 × 4               | 167k, saturated, 752 MiB        | 113k, saturated, 1.33 GiB; killed by the kernel for want of memory on the next run |

Per connection, slopio's memory grew by ~10 KiB, hyper's by ~23 KiB.
h2load sends every connection's request at the same instant at a fixed
rate, so the latency there is that of answering a burst of N, and is left
out here; it is in the summaries.

### slopio's receive buffers make no difference at 50,000 connections

slopio alone, as fast as 50,000 connections can go on 8 cores of a
`c8gn.8xlarge`, with each of six receive rings per worker
(`results/20261026-231455-conns-aws` to `20261026-232315-conns-aws`):

| `RING`        | buffers | req/s | µs per request, user + kernel | memory  |
|---------------|---------|-------|-------------------------------|---------|
| `64x128+512`  | 640     | 888k  | 3.81 + 5.05                   | 742 MiB |
| `4x8192`      | 8,192   | 885k  | 3.83 + 5.07                   | 733 MiB |
| `4x16384`     | 16,384  | 888k  | 3.79 + 5.02                   | 990 MiB |
| `16x4096`     | 4,096   | 870k  | 3.89 + 5.15                   | 986 MiB |
| `16x16384`    | 16,384  | 885k  | 3.82 + 5.06                   | 2.5 GiB |
| `64x4096`     | 4,096   | 881k  | 3.84 + 5.09                   | 2.5 GiB |

All within 2 %. A buffer is held from the moment data lands to the moment it
is decoded, not while a receive waits; with one request in flight per
connection, arriving spread out, few are in use at once. Where the 8.9 µs
per request go at 50,000 connections, against 1.6 at 64, is for a profile
to say.

### Where the time goes at 50,000 connections, and the NIC's interrupts

Same load, slopio and hyper `reuseport` on 8 of the 32 CPUs of a
`c8gn.8xlarge`, h2load on another. The NIC has 8 queues; where their
interrupts are handled changes the results:

| NIC interrupts                                   | slopio     | hyper reuseport | ratio |
|--------------------------------------------------|------------|-----------------|-------|
| spread by irqbalance (CPUs 5, 7, 9, 11, 16, 18, 21, 26) | 896k req/s | 596k     | 1.50× |
| on the workers' CPUs, one queue each (0-7)       | 644k (−28 %) | 493k (−17 %)  | 1.31× |
| away from the workers, one queue each (8-15)     | **1.00M (+12 %)** | 631k (+6 %) | 1.59× |

`results/20261027-003018-conns-aws`, `-003355-`, `-003731-`. irqbalance
had put two queues on worker CPUs (5 and 7), and those two workers shared
their core with the network's interrupts; every run before this one ran
so. Kept off the workers, the interrupts let slopio pass 1M req/s. The
server's own CPU time stays at 7.85 cores whatever the placement: time
spent in interrupts is not the process's, it is taken from it.

perf on the server, interrupts spread by irqbalance
(`results/20261027-003240-conns-aws/raw/*.perf-*.txt`; perf costs ~6 %):

| share of the server's samples              | slopio | hyper reuseport |
|--------------------------------------------|--------|-----------------|
| kernel                                     | 56 %   | 42 %            |
| NIC driver (ena)                           | 4 %    | 4 %             |
| the server's own code                      | 37 %   | 52 %            |
| of which out-of-line atomics (`__aarch64_*`) | 5 %  | 17 %            |
| AppArmor's checks on every send and receive | 7 %   | 5 %             |
| file descriptor lookup (`fget`, `sock_from_file`) | 5 % | 3 %         |
| socket locks                               | 5 %    | 5 %             |

What it says, to be followed up:

- **Atomics are calls.** Built for generic aarch64, Rust reaches every
  atomic through an `__aarch64_*` function that picks LSE instructions at
  run time. They take 17 % of hyper's time and 5 % of slopio's. Building
  both for the CPU they run on (`-C target-cpu=neoverse-v2`, or
  `+lse`) would inline them; hyper would gain more. And slopio, one thread
  per core, should hardly need atomics on this path: which ones it takes
  is worth finding.
- **The kernel looks up the socket's file on every operation.** io_uring's
  registered (fixed) files would spare slopio `fget`, ~5 % of its time.
- **AppArmor** checks every socket send and receive on Ubuntu: 7 % of
  slopio's time, 5 % of hyper's. A cost of the platform, the same for
  both, left on.
- slopio's largest single function is `SharedConnection::write_response`,
  5 %: encoding each response's head.

### Steering connections to the CPU their packets arrive on

The NIC hashes each connection to one of its 8 queues, and `SO_REUSEPORT`
hashes it to a worker; the two hashes are unrelated, so a connection's
packets are handled by the kernel on one core and read by its worker on
another. hyper-server's `INCOMING_CPU=1` sets `SO_INCOMING_CPU` on each
worker's listener, and the kernel then hands a connection to the listener of
the CPU that received it. Same load as above, 8 worker CPUs, now with the
whole server machine's CPU measured, interrupts and softirqs included
(`results/20261027-011933-conns-aws` to `20261027-012432-conns-aws`):

| hyper reuseport                       | on their worker's CPU | req/s | machine CPUs busy (interrupts) | req/s per busy CPU |
|---------------------------------------|-----------------------|-------|--------------------------------|--------------------|
| irqbalance                            | 3 %                   | 625k  | 9.29 (1.72)                    | 67k                |
| queue n on CPU n, 0-7, no steering    | 12 %                  | 559k  | 8.01 (1.56)                    | 70k                |
| **queue n on CPU n, `SO_INCOMING_CPU`** | **100 %**           | 603k  | **8.01 (1.25)**                | **75k**            |
| queues on 8-15, away from the workers | 0 %                   | 659k  | 9.72 (1.71)                    | 68k                |

Steered, every connection is served on the core its packets arrive on: 8 %
more than unsteered on the same 8 CPUs, a quarter less time in interrupts,
and the most requests per CPU busy. Interrupts kept off the workers give
the most requests, by spending 1.7 more CPUs on them.

slopio, its listeners made by the runtime, cannot be steered yet. Counting
the whole machine, it serves ~1.4× hyper's requests per CPU busy at 50,000
connections: 92k with irqbalance (944k req/s on 10.2 CPUs), 95k with the
interrupts on 8-15 (1.07M on 11.3).

### slopio steered: SO_INCOMING_CPU in the runtime

The runtime's `incoming-cpu` branch (`1ff8b85`, in `~/runtime`, not yet
published) sets `SO_INCOMING_CPU` on each worker's listener to the CPU the
worker is pinned to, on by default (`Topology::steer_connections`).
slopio-server's `STEER=0` turns it off. Same machine, the NIC's queue n and
its XPS on CPU n (0-7), 50,000 connections as fast as they can go, the two
alternating (`results/20261027-013958-conns-aws` to
`20261027-014258-conns-aws`, built against that branch):

| slopio              | runs              | median    | machine CPUs busy | of it in interrupts |
|---------------------|-------------------|-----------|-------------------|---------------------|
| steered (`STEER=1`) | 777k, 786k, 794k  | **786k**  | 8.01              | **1.54**            |
| hash (`STEER=0`)    | 743k, 743k, 732k  | 743k      | 8.01              | 1.84                |

+5.7 %, every steered run above every unsteered one, and a sixth less time
in interrupts, on the same 8 CPUs with nothing spilling onto others. Per CPU
busy, network included, it is the most efficient placement measured: 98k
req/s, against 95k with the interrupts kept on other CPUs (1.07M on 11.3)
and 92k with irqbalance (944k on 10.2), those from other sessions. Steered
the same way on the same 8 CPUs, hyper did 603k: slopio 1.30×.

### NAPI busy polling, at full load

The runtime's `RingOptions::napi_busy_poll` (`f2c6e71`, off by default)
registers each worker's ring for NAPI busy polling; slopio-server's
`NAPI_BUSY_POLL_US` and `NAPI_PREFER` turn it on. Same machine, the NIC's
queue n and XPS on CPU n (0-7), connections steered, 50,000 connections as
fast as they can go, the three alternating
(`results/20261027-033835-conns-aws` to `20261027-034137-conns-aws`):

| slopio                                                   | runs        | median | machine CPUs busy | of it in interrupts |
|----------------------------------------------------------|-------------|--------|-------------------|---------------------|
| no NAPI                                                  | 728k, 729k  | 729k   | 8.01              | 1.68                |
| NAPI, 50 µs                                              | 727k, 729k  | 728k   | 8.01              | 1.67                |
| NAPI, 50 µs, `prefer_busy_poll`, `napi_defer_hard_irqs` 2, `gro_flush_timeout` 200 µs | 706k, 708k | 707k | 8.01 | 2.15 |

No effect, then a small loss. io_uring busy-polls only while a thread
waits for completions, and saturated workers hardly wait: they never poll.
With `prefer_busy_poll` the kernel trades the queue's interrupts for a timer,
counting on the workers to poll; they do not, and packets wait for the
timer. NAPI is for load below saturation, where workers wait between
packets and latency is the point: still to measure, and with a load
generator that does not send every connection's request at the same instant.

The baseline here, 729k, is 7 % under the same setup an hour and a half
earlier (786k), on another pair of instances: comparisons hold within a
session, where the cases alternate, not across sessions.

### Where slopio's time goes at 50,000 connections, call chains

perf with call chains on both servers, built for it with frame pointers
and line tables, the NIC's queues on the workers' CPUs and connections
steered (`results/20261027-041244-conns-aws/raw/*.perf-*.txt`; the
profiling costs ~5 %: 690k req/s for slopio, 547k for hyper). Shares of
each server's own samples:

| where                                                        | slopio | hyper reuseport |
|--------------------------------------------------------------|--------|-----------------|
| kernel, NIC driver included                                  | 60 %   | 48 %            |
| HPACK, decoding requests' headers (`load_hpack`)             | 6.9 %  | 5.8 %           |
| HPACK, encoding responses' heads (`encode`, `into_encoding`) | 5.8 %  | 5.6 %           |
| out-of-line atomics, spread over many callers, none above 0.5 % | 5.0 % | 15.4 %        |
| AppArmor, inclusive (`apparmor_socket_recvmsg` and below)    | 7.9 %  |                 |
| the socket's file looked up on every io_uring submission (`fget` from `io_submit_sqes`) | 2.7 % | 3.0 % (`__fget_files`, from `writev` and `recvfrom`) |

- **HPACK is the largest thing in slopio's own code**: 12.7 % of its time,
  about 1.4 µs a request, against 1.65 µs in hyper's `h2`. Encoding a
  three-field response head looks each name up in the dynamic table
  (`index_dynamic`, 1.5 %); decoding a request walks `Table::get` (1.6 %)
  and `on_headers` (2 %). Both servers pay it alike, and it is where slopio
  could most cut its own cost.
- **Every io_uring submission resolves the socket's file** (`io_issue_sqe`
  → `io_file_get_normal` → `fget`): what registered (fixed) files would
  spare.
- **The atomics have no main caller**: `Bytes` and `BytesMut` reference
  counts, cloned and dropped all over, rather than one site to fix.

### Not explained yet

- **Stalls of ~18 s in slopio.** At 50,000 connections × 1 request a
  second, in 2 of 3 runs, a few requests on connections long established
  waited 18.4 to 18.8 s; hyper's worst was 0.64 s. The server logged
  nothing. One guess, unverified: at a fixed rate the 50,000 requests of
  each second arrive together and can empty the receive ring, and a
  connection that finds it empty waits in 10 ms sleeps with no order among
  them (`DryRing` in slopio-h2). It does not cost throughput when requests
  arrive spread out (above); whether it causes the stalls needs the
  fixed-rate run again with `RING=4x16384`.
- **h2load hangs** when a connection is made after its measured time has
  ended: it never stops it, and waits on it for ever. `bench.sh` gives
  large runs a longer warm-up and kills h2load past its time.

## Locally (10-CPU aarch64 VM, loopback)

`results/20261026-195722-single-vm`, `results/20261026-200200-multi-vm`.

| one core, conns × streams | slopio  | hyper  | ratio |
|---------------------------|---------|--------|-------|
| 16 × 16                   | 1.04M   | 317k   | 3.3×  |
| 64 × 32                   | 1.33M   | 346k   | 3.8×  |

On 5 cores, h2load on the 5 others ran out before slopio did (97-99 % busy),
so the multi-core local numbers are a floor for slopio.

## Memory (locally)

Resident memory of the server process, kernel socket buffers not included.

| situation                          | slopio   | hyper        |
|------------------------------------|----------|--------------|
| idle, 1 core                       | 34.8 MiB | 2.5 MiB      |
| under load, 1 core, 64 × 32        | 42.3 MiB | 9.7 MiB      |
| idle, 5 cores                      | 165 MiB  | 2.7-3.0 MiB  |
| under load, 5 cores, 64 × 32       | 174 MiB  | 10-12 MiB    |
| 2000 idle connections, 1 core      | 52.7 MiB | 47.2 MiB     |
| per connection                     | ~9 KiB   | ~23 KiB      |

slopio's idle memory is its io_uring receive pool, allocated and touched
up front, per worker: 32 MiB with every `RING` preset but the two largest
(`16x4096` 67 MiB, `64x4096` 259 MiB). All of a worker's connections
receive into that pool, where hyper holds buffers per connection: the two
cross near 1,700 connections per core. Neither gives memory back after a
load; mimalloc keeps it.

## What explains the numbers

- **One `writev` per response in hyper.** h2 0.4 sends a DATA frame over
  256 bytes (`CHAIN_THRESHOLD`) from the caller's buffer rather than
  copying it, and holds one such frame at a time
  (`src/codec/framed_write.rs`): every 2 KiB response is flushed before the
  next is encoded. 200,000 requests at 16 × 16 cost hyper 200,032 `writev`;
  slopio made 2,335 `io_uring_enter` calls in all. Under 256 bytes, h2
  copies and batches: with a 13-byte body hyper did 731k req/s on one local
  core, slopio 1.66M (2.3×).
- **Batching depends on how the load arrives.** For the same connections,
  more h2load threads spread the requests out: on one local core at
  16 × 16, slopio fell from 1.03M req/s with 4 client threads to 0.66M with
  9, hyper from 305k to 260k. `CLIENT_THREADS` fixes the number.
- **Smaller gap on AWS than on loopback**: 2.3× on a `c8gn.medium` against
  3.3-3.8× locally. A real NIC adds kernel work per request that both
  servers pay alike, and on one vCPU that work lands on the server's core.
  A hypothesis, not yet measured.
- **Few connections, uneven workers.** `SO_REUSEPORT` spreads connections
  by a hash of their ports: 16 connections over 5 workers left slopio's
  workers between 1.8 and 3.8 s of CPU in one 6 s run. It is why slopio
  did not use all its cores at 16 × 16, and the source of most spread at
  that size; hyper's `multi` mode rebalances and does not suffer it.
- **More connections cost slopio more.** From 64 × 32 to 256 × 16 on 8
  cores slopio lost 18 %, hyper `reuseport` 9 %.
