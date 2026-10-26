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
