# Leads to try

What the measurements so far point at, in slopio-h2 and the runtime, with
where each shows and how to tell whether a change helped. Numbers and the
runs they come from are in [RESULTS.md](RESULTS.md) and `results/`.

## Where things stand

On one Graviton4 core (`c8gn.medium`), runtime `8f24304`, slopio-h2
`6f0b366`, `GET /` (`results/20261027-141349-single-aws`):

| per request, 16 × 16       | slopio  | h2o     |
|----------------------------|---------|---------|
| req/s                      | 681k    | 981k    |
| req/s at 64 × 32           | 722k    | 1.10M   |
| user time                  | 0.79 µs | 0.45 µs |
| kernel time                | 0.52 µs | 0.48 µs |
| user cycles                | 2,171   | 1,321   |
| user instructions          | 6,130   | 5,215   |
| IPC, user                  | 2.82    | 3.95    |
| back-end stall cycles      | 431     | 169     |
| of which waiting on memory | 90      | 1.5     |
| L2 refills                 | 9.8     | 0.34    |

Times from the bench's `COUNT` run; cycles and below from a separate 16 × 16
run under `perf stat`, the same session (`stalls/` in that directory).

The rest of the gap is in slopio's own code; the kernel's share is within
7 % of h2o's. Locally, with work in the handler, the two are level when the
CPU is the limit (`/app?cpu_us=20&touch_kb=64`: 44.6k req/s both), and
slopio is behind once handlers wait and compute
(`/app?delay_ms=20&cpu_us=20&touch_kb=64`, 64 × 32: 29.4k against 39.1k,
slopio's core 27 % idle; `results/20261027-134756-single-local-vm`).

Done: `Bytes` without atomics and the http types on it (runtime `2971dc7`,
`8f24304`; slopio-h2 `e470af8` to `6f0b366`): +21 % at 16 × 16 and +23 % at
64 × 32 on AWS, user cycles per request down from 2,868 to 2,171, no atomic
left in the profile.

## Runtime

### 1. Submit I/O during a long run of tasks

The event loop (`runtime-core/src/runtime/mod.rs`) polls every task queued
before the pass, then calls `io_driver.submit()`. When handlers compute,
a pass takes milliseconds and no response leaves until it ends. With
`delay_ms=20&cpu_us=20&touch_kb=64` at 64 × 32, every one of the 2,048
responses left in one burst every ~69 ms (h2load `--log-file`): ~45 ms
computing with nothing sent, then all requests asleep together and the
core idle. Under real traffic this is latency: a response finished at the
start of a pass waits for the pass to end.

Submitting more often is not enough by itself: a stream task only writes
into its connection's output and wakes the connection's task
(`write_frame`), which runs on the *next* pass and only then issues the
send (`Connection::flush`, one send in flight per connection). So today
the 2,048 responses wait for the pass of stream tasks (~45 ms), then for
the connection tasks' pass, then for its submit. For a response to leave
soon after it is written, three things must happen during a long pass:
the woken connection task runs, its SQE is submitted, and completions are
reaped so that its next send can go. Cutting passes shorter does not do
it: woken tasks queue behind the rest of the pass.

Try, in the runtime: once a pass has run past ~100-200 µs, run the tasks
woken meanwhile (the connections), submit and reap, then resume; or a
LIFO slot as tokio has, where a task woken by the running one runs next.
Or, in slopio-h2: let a stream's write issue the send itself when its
connection has none in flight. The cost to watch is batching: today all of
a connection's responses go in one send, part of why `/` is cheap. A time
threshold should leave `/` alone (a pass of 256 cheap tasks takes
~0.3 ms), but check it does not regress. Measure: that case's core use
(0.73 now, h2o 0.99), its req/s, the burst sizes from h2load's per-request
log, and `/` against the previous build (`SERVERS="slopio-prev slopio"`).

### 2. The timer's 10 ms tick: what it means here

The wheel (`async_timers/src/wheel/mod.rs`, `init_timer`) ticks every 10 ms
and arms `floor(ms / 10) - 1` ticks: a 29 ms sleep ends after 10 to 20 ms,
a 19 ms one after 0 to 10, and under 10 ms it overshoots instead. That is by
design: the timer is there for timeouts, seconds long, where a tick or two
either way does not matter, and a coarse tick is cheap. Not a lead in
itself, then, but two things follow. With waits drawn at random, as
`jitter_ms` does, at light load (16 × 16, ~0.1 core;
`results/20261027-160552-` to `-160810-single-local-vm`):

| asked              | slopio: err mean, p1, early   | hyper              | h2o                    |
|--------------------|-------------------------------|--------------------|------------------------|
| 20 ms              | +1.4 ms, -9.0 ms, 4.5 %       | +2.4, +0.6, 0 %    | +1.1, -0.5, 13 %       |
| 10-30 ms, at random | **-3.4 ms, -16.7 ms, 74 %**  | +1.0, +0.1, 0 %    | +0.04, -0.9, 47 %      |
| 1-9 ms, at random  | **+6.2 ms** (11.2 for 5), -4.1, 1.9 % | +1.0, +0.2, 0 % | +0.04, -0.9, 40 % |

(err: slept minus asked; early: share of sleeps that ended before their
time.) A fixed delay hides it: requests then arm their timers at the same
phase of the tick, just after one, and wake ~20 ms later. hyper rounds up
to the millisecond, never early; h2o arms on the loop's cached time in
whole milliseconds, up to ~0.9 ms early.

First, for the bench: `/app?delay_ms=` stands for a call to a database on
each server's own timer, so with waits of tens of milliseconds part of a
req/s gap is the timers' granularity, not the stack. Use `jitter_ms`, read
`lat - slept` rather than req/s alone, and prefer longer waits (50-200 ms,
with more streams in flight) where a tick is small beside the wait. A real
network wait on an upstream would be closest to an application, but needs
an HTTP client in each server.

Second, the 10 ms slots make timers armed together fire together, which
feeds lead 1's bursts; random delays shorter than a tick cannot undo that,
the tick gathers them again. Lead 1 is the fix for what that costs.

### 2b. Latency on top of the wait: explained, not pursued

With waits drawn at random (`/app?delay_ms=25&jitter_ms=25`, 0-50 ms),
slopio adds 2-3.4 ms to a request beyond the time it really slept, h2o
0-0.5 ms (`results/20261029-024219-single-local-vm`). The timer's own
error is already taken out (each server measures its real sleep). What is
left is the 10 ms tick firing every timer of a slot at once: at 152k req/s
some 1,500 handlers resume in one pass, and the connections send at its
end, so a response that finished early waits for the pass (~2-4 ms, which
matches). It is the other side of slopio's CPU efficiency there: 2.5 µs of
CPU per request against h2o's 6.0, whose millisecond timer wakes it ten
times as often. In an application whose waits come from the network
rather than a timer, wakeups are spread and the effect is smaller. Left as
is by choice; lead 1 would shorten it if it ever mattered.

### 3. Recycle task allocations last-in first-out

Each stream's task is a fresh allocation (488 bytes for `payload`) through
mimalloc, which hands a freed block back only after the rest of its page:
memory comes back cold. h2o reuses the block freed last (its pools'
recycler, glibc's tcache). Allocation and freeing are ~9 % of slopio's user
cycles, and the places that stall on memory are where a stream's memory is
first or last touched.

Try: a per-thread free list per task size. Measure: L2 refills and cycles
per request (`stalls.sh` beside each AWS run's results).

### 4. Registered files

Every SQE resolves its socket's file (`io_file_get_normal` → `fget`):
3.3 % of the server's samples at 50,000 connections
(`results/20261027-041244-conns-aws`). Fixed files would spare it.

## slopio-h2

### 5. Fewer allocations per stream, reused per connection

A stream allocates its task, `Rc<StreamState>` (216 bytes), `Box<Headers>`
(184 bytes), the handler's `HeaderMap`, and an entry in the stream map: 4-5
allocations, ~1 KiB, all freed when it ends. The total is not large (256
streams in flight are ~250 KiB, and h2o's stream alone is 1,200 bytes); how
it is allocated is the suspect. Back-end stalls land in
`retire_if_closed` (7.4 %), `Rc<StreamState>::drop_slow`,
`StreamToken::drop`, `mi_free`.

Try: a per-connection slab for `StreamState` and `Headers`, slots reused
last-freed first; or one allocation per stream holding them. Measure: as
lead 3. First tell size from pattern: L2 refills per request at 1 × 1,
16 × 16 and 64 × 32. If they grow with the streams in flight, the footprint
matters; if not, the pattern does.

### 6. HPACK decoding

~20 % of user cycles: `Headers::load_hpack` 9.2 %, `HeaderBlock::load`
4.8 %, `hpack::decoder::Table::get` 3.9 %, `Header::clone` 1.5 %, also
among the costliest in back-end stalls. The largest piece of code by
itself.

### 7. Writing the response head

`SharedConnection::write_response` is 11.7 % on its own: it clones every
name and value of the handler's `HeaderMap` into a `Header::Field`, then
encodes. Encoding straight from the map would spare the clones.

### 8. A cheaper way to give response headers

The benchmark's handler builds a `HeaderMap` per request:
`HeaderMap::insert` 3.5 % and the handler 2.8 %. h2o adds its two headers
into the request's pool. Applications would pay the same: a way to pass a
static list, or a slice of pairs, would avoid the map.

### 9. Smaller stream futures

The `payload` handler's future is 320 bytes and its task 488: it holds
`stream` (32 bytes) and `Params` (88 bytes) twice, once captured and once
moved into a local (rustc's layout of `async fn` arguments); `Params` even
for a route without parameters; and `write_data_final`'s 136-byte future
inline. ~300 bytes would do. A line or two per request: worth it with
lead 5, not alone. `RUSTFLAGS=-Zprint-type-sizes cargo +nightly build`
prints the layouts.

## The kernel's side: what more connections cost

**Read this first: in an open-loop load the kernel's cost is the same for
slopio and h2o.** Everything below lead 10's tables was measured with
h2load's closed loop, which sends a request the moment an answer lands, so
the client's packets copy the server's sends and h2o's "read late, write
once" looks far better than it is. With `bench/loadgen` (slopio-h2's client,
Poisson arrivals, latency from when a request was due), on 4 aligned
workers of a `c8gn.8xlarge` (`results/20261029-open-loop-kernel-4workers`,
`results/20261029-open-loop-many-conns`):

| µs per request, open loop      | slopio user | slopio kernel | h2o user | h2o kernel |
|--------------------------------|-------------|---------------|----------|------------|
| 600k req/s, 64 conns           | 1.19        | 2.13          | 0.86     | 2.29       |
| 600k req/s, 1,024 conns        | 1.63        | 2.89          | 1.20     | 2.90       |
| 300k req/s, 1,024 conns        | 1.83        | 3.02          | 1.32     | 3.06       |
| 300k req/s, 50,000 conns       | 3.59        | 4.76          | 2.13     | 4.81       |

Both send about once per request when arrivals are independent, with as
many packets each way; the kernel is two thirds of the CPU per request for
both, the TCP stack's cost per small packet, and grows with connections for
both (fewer ACKs ride on requests). slopio's gap is in user space: +30-40 %
at 64-1,024 connections, +70 % at 50,000, where each request finds its
connection's state cold. Memory per connection: slopio 9.4-14 KiB, h2o
4.6-7.3. That per-connection state is by design: streams are independent,
and the connection carries the protocol's protections (budgets, rates,
Rapid Reset); not a lead. So lead 10 is a closed-loop artifact, parked;
the leads worth effort are in user space (3, 5 to 9).

### 10. Send a connection's responses in fewer, larger batches

Parked: a closed-loop artifact, see above. Kept for the record. Low
priority, and mostly a benchmark's case: it matters when handlers
answer at once, as `/` does. slopio is built for a stream to do async
work, and then what decides how responses group is when they finish, not
when requests arrive: h2o too then writes each from its callback, in the
loop turn it finishes in, and its advantage of reading late is gone, while
slopio's connection already sends everything its streams wrote in a pass.
With a 20 ms wait per request and 4,096 in flight (`/app`, case A above),
slopio had the lowest CPU per request of the three. Answers at once do
exist (health checks, cached responses, refusals, 304s, in-memory
lookups), and the first fix below holds nothing back, so it can stay as a
small gain; but optimisations are better judged on `/app` with jitter and
work than on `/`.

On 4 workers aligned with 4 NIC queues (`c8gn.8xlarge`, `GET /`), going
from 16 to 64 connections per worker (64 × 32 to 256 × 16) costs slopio
29 % of its requests per second and h2o 9 %. Steering is not it: slopio
without it (`-hash`) loses as much. Most of the extra is in the kernel
(`results/20261028-kernel-profile-4workers`):

| µs per request                         | slopio 64×32 | slopio 256×16 | h2o 64×32 | h2o 256×16 |
|----------------------------------------|--------------|---------------|-----------|------------|
| TCP send (`tcp_sendmsg` and below)     | 0.37         | 0.54          | 0.24      | 0.29       |
| receive softirq (`net_rx_action`)      | 0.25         | 0.40          | 0.15      | 0.20       |
| kernel in all                          | 0.63         | 1.00          | 0.41      | 0.50       |
| user                                   | 0.63         | 0.79          | 0.48      | 0.49       |

The TCP stack is the cost for both; io_uring's own machinery is small
(submission outside `sendmsg` 2-4 %, `fget` ~0.9 %). The multishot receive
never pauses: no `ASYNC_CANCEL`, no `RECV` submitted again, so pausing
(`RECV_QUEUE_LIMIT`) is not it either. What differs is how many operations
carry the same bytes:

| per request              | slopio 64×32 | slopio 256×16 | h2o 64×32 | h2o 256×16 |
|--------------------------|--------------|---------------|-----------|------------|
| sends                    | 0.089 (~11 responses each) | 0.246 (~4) | 0.031 (32) | 0.062 (16) |
| receives                 | ~0.086 (~11 requests each) | ~0.23 (~4) | 0.031 (32) | 0.062 (16) |
| TCP segments in          | 0.14         | 0.25          | 0.08      | 0.13       |
| TCP segments out         | 0.26         | 0.25          | 0.26      | 0.25       |

h2o writes every response a connection has in flight in one `sendmsg`, all
32 streams' at 64 × 32 and all 16 at 256 × 16, and reads all its requests
in one `read`. slopio cuts the same groups into 3 or 4 pieces, a send and a
receive each. Every send pays a fixed cost in the kernel (the socket's
lock, building the packet, pushing TCP), and smaller pieces bring back
twice the segments from the client, requests and ACKs, hence the dearer
receive. The bytes out are the same: it is the count of operations.

slopio does accumulate: a flush sends everything written since the last
one. But it flushes right after each piece it receives: the connection's
loop (`src/server/connection/mod.rs`) decodes a chunk, then `drain()`s,
which flushes, yields so that the chunk's stream tasks run and write, and
flushes again. Only the answers to requests already received are ready by
then. A copy send completes within microseconds, at the next
`io_uring_enter`, too soon for the next piece to land and join it; and
when two pieces of one connection are already queued, the loop still
decodes the first, drains, then decodes the second. The counts match: at
256 × 16, ~0.23 receives and 0.246 sends per request, one send per piece
received.

h2o accumulates the same way but reads late: by the time its loop comes
back to a connection, the client's packets have all arrived, one `read`
takes all 16 requests and one `write` answers them. The client sends its
next requests in the groups the answers came in, so slopio's groups stay
cut, and more connections per worker interleave the arrivals more, and
the pieces shrink. This part is inferred from the counts, not measured
directly.

A chunk is not a packet, though: a multishot receive reads everything the
socket holds into one ring buffer (up to 64 KiB), and with
`DEFER_TASKRUN` completions are only made and reaped between passes, at
`io_uring_enter`. So a connection usually gets one chunk per pass, holding
all that arrived since the last; two chunks queued at once should be the
rarer case (more than a buffer's worth, or two reaps before the
connection's turn). The groups are cut by time more than by queueing:
what lands during a pass is not seen until the next `io_uring_enter`.
With `spawn_next`, a round trip finishes sooner, less arrives between two
reaps, and the pieces shrink further (the +50 % sends at 64 × 32).

Try, in slopio-h2 or the runtime, measuring first:

- **Count how often a connection finds a second chunk already queued**
  when it decodes one: a counter in its loop, logged as the `slept` lines
  are. Only if it is frequent does the next item pay.
- **Decode every chunk a connection has already received before
  flushing**, rather than flushing after each one. It holds nothing back,
  since those chunks are there already. In slopio-h2 alone: after
  `decode_with`, poll the transport with `Waker::noop()` (a chunk if one is
  queued, `Pending` if not; `next_event` registers the real waker again
  before it parks), decode up to `RECV_QUEUE_LIMIT` more, keep any error or
  end in a field for `next_event` to return first, then `drain()` once. A
  `try_next` on `MultiRecv` that leaves errors queued would be neater.
- **If chunks are rarely queued, gathering more means waiting a little**:
  reap what arrived during the pass before flushing (one more
  `io_uring_enter`, in the runtime), or hold a connection's flush for a
  few tens of µs (`MSG_MORE` / `TCP_CORK` with a short bound). This is where
  it meets lead 1's bound on batching for latency.
- **Bound it in time.** This pulls against lead 1, which bounds batching for
  latency. The two meet in batching per connection held for at most a few
  tens of µs: long enough to gather what is about to come, never long
  enough to hold a response back for a pass.

Measure first, directly: counters in slopio-h2 of requests per receive
completion and responses per send, logged as the `slept` lines are, to
confirm the mechanism rather than infer it. Then, for a change: sends and
segments per request (`kprof-run.sh` and the segment count beside it, in
that directory), kernel µs per request, req/s at 256 × 16, and `/` at
64 × 32 and 16 × 16 against the previous build so the few-connection case
does not regress.

## Measurements still to make

- slopio's latency outliers at 20,000 connections as fast as they go: 8 to
  15 s at most on one core (`results/20261028-191835-` and
  `-192713-conns-aws`), as the ~18 s stalls noted in `RESULTS.md`; h2load's
  per-request log would show which requests wait and on which connections.
- Memory per connection at 20,000 connections: slopio 9.4-10.9 KiB, h2o
  4.8, hyper 23.6-27.8; and slopio's kernel TCP buffers 77 MB against 30-37
  as fast as they go, data left waiting in the sockets.
- L2 refills per request against streams in flight (lead 5's question).
- Whether Graviton instances expose SPE, which would give the data address
  of each miss.
- `/app` on AWS, and with an open-loop load (`h2load --rps`), where leads 1
  and 2 show as latency rather than idle time.
- `COUNT` with the stall and cache events `stalls.sh` counts, rather than
  beside it.
- h2o at 50,000 connections: every `conns` run so far is slopio against
  hyper, and older than h2o in the bench and than `Bytes` without atomics.
  One core first (`CONFIGS="50000@1 50000@4 50000@max"`), then 8 cores with
  the NIC's queues pinned and connections steered, as the reference runs.
