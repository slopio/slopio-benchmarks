# slopio-benchmarks

Benchmarks of the [slopio-h2](https://github.com/slopio/slopio-h2) HTTP/2
server, built on the [slopio](https://github.com/slopio) io_uring runtime,
against other HTTP/2 servers answering the same route.

What was measured so far, and why the numbers are what they are:
[RESULTS.md](RESULTS.md).

## The servers

Each serves HTTP/2 cleartext with prior knowledge on one port (there is no
HTTP/1.1), and implements the routes below.

| Server          | Stack                                  | Source           |
|-----------------|----------------------------------------|------------------|
| `slopio-server` | slopio-h2 on the slopio runtime        | `servers/slopio` |
| `hyper-server`  | hyper 1 on tokio                       | `servers/hyper`  |
| `h2o-server`    | libh2o (h2o's library, epoll), in C    | `servers/h2o`    |

```sh
cargo build --release
servers/h2o/build.sh           # h2o's sources at a fixed revision, into target/
PER_CORE=1 ./target/release/slopio-server
PER_CORE=1 ./target/release/hyper-server
h2load -D 10 -c 64 -m 32 -t 4 http://127.0.0.1:8080/
```

Building `slopio-server` needs SSH access to the private `slopio` and
`saucisoupe` repositories. Running it needs Linux 6.1 or later, and io_uring
allowed by seccomp if it runs in a container.

## Route

The one request every server answers, with the same bytes. Anything else is
`404`; `/` with another method, `405` with an `allow`.

| Request | Status | `content-type` | `content-length` | Body              |
|---------|--------|----------------|------------------|-------------------|
| `GET /` | 200    | `text/plain`   | `2048`           | 2048 bytes of `x` |

The query plays no part: `GET /?a=b` is `GET /`. On the wire: one HEADERS
frame of 16 bytes, then one DATA frame of 2048 carrying END_STREAM.

## What is held equal

The servers differ in their stack and nothing else. Checked with `curl` and
`nghttp -v`: the same requests get the same headers and bodies, and the same
HEADERS and DATA frames.

| What                         | Both servers                                           |
|------------------------------|--------------------------------------------------------|
| SETTINGS_MAX_CONCURRENT_STREAMS | 64 (`MAX_STREAMS`)                                  |
| SETTINGS_INITIAL_WINDOW_SIZE | 1 MiB (`STREAM_WINDOW`)                                |
| Connection window            | 2^31-1                                                 |
| SETTINGS_MAX_HEADER_LIST_SIZE | 16 KiB                                                |
| Max frame size               | 16 KiB                                                 |
| `date`, `server` headers     | none                                                   |
| Allocator                    | mimalloc 0.1.48, `local_dynamic_tls` and `v3`          |
| Listener                     | `SO_REUSEPORT`, backlog 1024, `TCP_NODELAY` per connection |
| Threads, `PER_CORE` unset    | one                                                    |
| Threads, `PER_CORE=1`        | one per CPU the process may use, worker `n` pinned to CPU `n` |
| Per stream                   | one task                                               |
| Build                        | the workspace's release profile: fat LTO, one codegen unit, `panic = "abort"` |

Worker `n` is pinned to CPU `n` whatever mask the process starts with, as
slopio's runtime does: under `taskset -c 4-7`, four workers run on CPUs 0 to 3.
Give the server CPUs 0..N and the load generator the rest.

What still differs, and is each stack's own:

- How the 2048 bytes reach the socket. slopio-h2 copies them into its output
  segments, as it does any body under 4 KiB; hyper's `h2` hands the static
  slice to `writev` beside the frame header. A 2 KiB copy is tens of
  nanoseconds.
- Defences against floods: slopio-h2's budgets, hyper's
  `max_pending_accept_reset_streams` and others, at their defaults. Neither
  matters to a well-behaved load generator.

## Configuration

Both servers read these:

| Variable        | Default      | Meaning                                              |
|-----------------|--------------|------------------------------------------------------|
| `PORT`          | `8080`       | Port to listen on, all interfaces.                   |
| `PER_CORE`      | unset        | One worker per core rather than a single one.        |
| `MAX_STREAMS`   | `64`         | SETTINGS_MAX_CONCURRENT_STREAMS.                     |
| `STREAM_WINDOW` | `1048576`    | SETTINGS_INITIAL_WINDOW_SIZE, bytes.                 |

`slopio-server` only:

| Variable        | Default      | Meaning                                              |
|-----------------|--------------|------------------------------------------------------|
| `RING`          | `64x128+512` | Receive buffers per worker, KiB × count [+ reserve]: `64x128+512`, `64x256+512`, `64x512`, `64x4096`, `16x2048`, `16x4096`, `16x16384`, `4x8192`, `4x16384`. |
| `ZERO_COPY`     | unset        | Send with `SEND_ZC`.                                 |
| `BODY_MIN_RATE` | `256`        | Slowest request body tolerated, bytes/s; `0` disables it. |

`MAX_STREAMS × STREAM_WINDOW` must stay under 2^30, or it refuses to start.

`hyper-server` only:

| Variable     | Default     | Meaning                                                  |
|--------------|-------------|----------------------------------------------------------|
| `TOKIO_MODE` | `reuseport` | With `PER_CORE`: `reuseport`, one current-thread runtime per core with its own listener, as slopio runs; or `multi`, tokio's work-stealing runtime and one listener, as tokio is usually run. |

## Running the benchmarks

```sh
bench/bench.sh single   # each server on one thread, on CPU 0
bench/bench.sh multi    # one worker per CPU, on CPUs 0..N-1 (half the machine)
bench/bench.sh conns    # one thread, many connections at a fixed rate each
```

`single` and `multi` give each server all the load it can take, so each is
measured at its own peak. `conns` gives both the same load: N connections
each sending a fixed number of requests per second (`CONFIGS="1000@1
20000@5"`), and compares what it costs them: CPU, the server's memory and the
kernel's TCP buffers, latency. h2load sends every connection's request at the
same instant, so its latency there is the time to answer a burst of N.

Each builds the servers, then runs h2load against them in turn on the CPUs
the servers do not use: for every configuration of connections × streams, a
2 s warm-up and an 8 s measured run, three times, the servers alternating
within each repetition. `multi` runs slopio and hyper in both its modes,
`reuseport` and `multi`.

Results go to `results/<date>-<mode>-<host>/`:

- `summary.txt`: per configuration and server, the median req/s and its
  spread, mean and max latency, the CPU time the server used and how it split
  between user and kernel, and how busy the load generator was.
- `raw.csv`: every run.
- `env.txt`: the CPUs, kernel, tool and crate versions the run had.
- `raw/`: every h2load output, server log and mpstat sample.

A run whose load generator is near 100 % busy measured the load generator, not
the server. The environment variables at the top of `bench/bench.sh` change
the CPUs, configurations, durations and servers.

The number of h2load threads changes the results, not only the load it can
generate: the fewer the threads for the same connections, the more requests
arrive together, and the more a server can do per wakeup. With 16 × 16 on one
server core, slopio went from 1.03M req/s with 4 client threads to 0.66M with
9, hyper from 305k to 260k. `CLIENT_THREADS` fixes it, and `env.txt` records it.

## On AWS

Two instances in one cluster placement group in `eu-west-1`: the server
(`c8gn.medium`, one vCPU) and h2load (`c8gn.xlarge`, four). Both Graviton,
so the binaries built here run there as they are, on Ubuntu 24.04 for its
glibc. `infra/config.sh` sets the region, zone and types.

```sh
infra/up.sh                  # creates them; prints their addresses
bench/bench.sh single aws    # builds here, copies to the server, runs from here
infra/ssh.sh server          # a shell on either, if needed
infra/down.sh                # deletes everything up.sh made
```

They run, and are billed, until `infra/down.sh`. Everything is tagged
`Project=slopio-bench`; `down.sh` removes all of it and says if anything
billable is left. The SSH key and the addresses stay in `infra/.state/`,
never committed. SSH is open to the address `up.sh` ran from only.

Small instances have a sustained bandwidth well under their peak, and spend
credits above it: the summary's `net capped` column counts the runs during
which the NIC queued or dropped packets for going past the instance's
allowance. Those measured AWS's limit, not the server.

## gRPC

Set aside for now: `slopio-server` only, and only built with
`cargo build --release -p slopio-server --features grpc`. The schemas are in
`servers/slopio/proto/`.

| Method                                  | Scenario                                         |
|-----------------------------------------|--------------------------------------------------|
| `slopio.bench.v1.Bench/Unary`           | One request, one response.                       |
| `slopio.bench.v1.Bench/ServerStream`    | One request, `response_count` responses.         |
| `slopio.bench.v1.Bench/ClientStream`    | Many requests, one response.                     |
| `slopio.bench.v1.Bench/Bidi`            | Each request answered as it arrives (ping-pong). |
| `helloworld.Greeter/SayHello`           | gRPC's own example (`ghz`, slopio-h2's `grpc_load`). |
| `grpc.health.v1.Health/Check`           | Health (`grpc-health-probe`, load balancers).     |

A `Bench` request sets each response's size (`response_size`, ≤ 4 MiB), how many
a `ServerStream` sends (`response_count`, ≤ 1 048 576), and a wait before each
response (`delay_ms`, ≤ 60 000). Its `payload` is read and dropped. Messages
are not compressed: the server does not decompress them.

```sh
ghz --insecure --import-paths servers/slopio/proto --proto bench.proto \
    --call slopio.bench.v1.Bench.Unary -d '{"response_size":1024}' \
    -n 300000 --connections 8 -c 128 127.0.0.1:8080
```

With `-z` instead of `-n`, ghz closes its connections when the time runs out
and counts the calls still in flight as `Unavailable` or `Canceled`; those are
not the server's errors.
