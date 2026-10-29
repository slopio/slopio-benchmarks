//! A load generator on slopio-h2's client, to load a server without
//! h2load's closed loop: requests can be sent on a schedule of their own,
//! whatever the server's answers do.
//!
//!     URL=http://127.0.0.1:18080/ CPUS=1-4 CONNS=64 STREAMS=32 slopio-load
//!     URL=http://127.0.0.1:18080/ CPUS=1-4 CONNS=1000 RATE=200000 slopio-load
//!
//! | Variable   | Default | Meaning                                                        |
//! |------------|---------|----------------------------------------------------------------|
//! | `URL`      | -       | what every request asks for (`GET`), h2c with prior knowledge |
//! | `CPUS`     | `1`     | the client's threads, one per CPU listed (`1-4`, `2,5`)       |
//! | `CONNS`    | `16`    | connections in all, spread over the threads, each its own client |
//! | `STREAMS`  | `16`    | without `RATE`: requests in flight per connection, each sent as the last is answered (h2load's `-m`) |
//! | `RATE`     | unset   | requests per second in all, sent at Poisson times whatever the answers, each on a connection drawn at random |
//! | `DURATION` | `8`     | seconds measured                                               |
//! | `WARMUP`   | `2`     | seconds of load before                                         |
//!
//! With `RATE`, a request's latency runs from when it was due, not from when
//! it went out, so a client or server running late shows; and the client's
//! own lag, from due to sent, is reported apart, to tell the two. The
//! runtime's timer ticks every 10 ms, too coarse for that schedule: each
//! thread's pacer reads the clock and yields in a loop instead, and keeps its
//! CPU busy, so the client CPU reported means something only without `RATE`.

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use runtime::runtime::time::Sleep;
use runtime::{RingOptions, Threads, Topology, WorkerContext, spawn, yield_now};
use slopio_h2::client::PlainTextClient;

runtime::define_buf_ring!(LoadRing, bgid = 1, buffer_size = 65536, ring_size = 256);

#[derive(Clone, Debug)]
struct Config {
    url: String,
    cpus: Vec<usize>,
    conns: usize,
    streams: usize,
    rate: Option<f64>,
    duration: Duration,
    warmup: Duration,
}

impl Config {
    fn from_env() -> Self {
        let var = |name: &str| std::env::var(name).ok();
        let num = |name: &str, default: f64| var(name).map_or(default, |v| v.parse().expect(name));
        Self {
            url: var("URL").expect("URL"),
            cpus: parse_cpus(&var("CPUS").unwrap_or_else(|| "1".into())),
            conns: num("CONNS", 16.0) as usize,
            streams: num("STREAMS", 16.0) as usize,
            rate: var("RATE").map(|v| v.parse().expect("RATE")),
            duration: Duration::from_secs_f64(num("DURATION", 8.0)),
            warmup: Duration::from_secs_f64(num("WARMUP", 2.0)),
        }
    }
}

fn parse_cpus(list: &str) -> Vec<usize> {
    let mut cpus = Vec::new();
    for part in list.split(',') {
        match part.split_once('-') {
            Some((a, b)) => cpus.extend(a.parse::<usize>().unwrap()..=b.parse().unwrap()),
            None => cpus.push(part.parse().unwrap()),
        }
    }
    cpus
}

/// Latencies by log-linear bucket: 8 per power of two of microseconds, so
/// within 12.5 % of the value.
const SUB: u32 = 8;
const BUCKETS: usize = 64 * SUB as usize;

fn bucket(us: u64) -> usize {
    if us < SUB as u64 {
        return us as usize;
    }
    let e = 63 - us.leading_zeros();
    let m = (us >> (e - 3)) & (SUB as u64 - 1);
    (e * SUB + m as u32) as usize
}

fn bucket_floor(b: usize) -> u64 {
    if b < SUB as usize {
        return b as u64;
    }
    let (e, m) = (b as u32 / SUB, b as u64 % SUB as u64);
    (SUB as u64 + m) << (e - 3)
}

#[derive(Clone)]
struct Stats {
    done: u64,
    failed: u64,
    bytes: u64,
    max_us: u64,
    hist: Vec<u64>,
    /// With `RATE`: from when a request was due to when it went out.
    lag: Histogram,
    /// This thread's CPU over the measured window, user and kernel, in µs.
    cpu_user_us: u64,
    cpu_sys_us: u64,
}

#[derive(Clone)]
struct Histogram {
    n: u64,
    max_us: u64,
    hist: Vec<u64>,
}

impl Histogram {
    fn new() -> Self {
        Self { n: 0, max_us: 0, hist: vec![0; BUCKETS] }
    }
    fn record(&mut self, d: Duration) {
        let us = d.as_micros() as u64;
        self.n += 1;
        self.max_us = self.max_us.max(us);
        self.hist[bucket(us)] += 1;
    }
    fn merge(&mut self, other: &Histogram) {
        self.n += other.n;
        self.max_us = self.max_us.max(other.max_us);
        for (a, b) in self.hist.iter_mut().zip(&other.hist) {
            *a += b;
        }
    }
    fn percentile(&self, p: f64) -> u64 {
        let target = ((p * self.n as f64).ceil() as u64).max(1);
        let mut seen = 0;
        for (b, c) in self.hist.iter().enumerate() {
            seen += c;
            if seen >= target {
                return bucket_floor(b);
            }
        }
        self.max_us
    }
}

/// This thread's CPU time so far, user and kernel, in µs.
fn thread_cpu_us() -> (u64, u64) {
    let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_THREAD, &mut usage) };
    let us = |t: libc::timeval| t.tv_sec as u64 * 1_000_000 + t.tv_usec as u64;
    (us(usage.ru_utime), us(usage.ru_stime))
}

impl Stats {
    fn new() -> Self {
        Self {
            done: 0,
            failed: 0,
            bytes: 0,
            max_us: 0,
            hist: vec![0; BUCKETS],
            lag: Histogram::new(),
            cpu_user_us: 0,
            cpu_sys_us: 0,
        }
    }

    fn record(&mut self, latency: Duration, bytes: usize) {
        let us = latency.as_micros() as u64;
        self.done += 1;
        self.bytes += bytes as u64;
        self.max_us = self.max_us.max(us);
        self.hist[bucket(us)] += 1;
    }

    fn merge(&mut self, other: &Stats) {
        self.done += other.done;
        self.failed += other.failed;
        self.bytes += other.bytes;
        self.max_us = self.max_us.max(other.max_us);
        for (a, b) in self.hist.iter_mut().zip(&other.hist) {
            *a += b;
        }
        self.lag.merge(&other.lag);
        self.cpu_user_us += other.cpu_user_us;
        self.cpu_sys_us += other.cpu_sys_us;
    }

    fn percentile(&self, p: f64) -> u64 {
        let target = (p * self.done as f64).ceil() as u64;
        let mut seen = 0;
        for (b, c) in self.hist.iter().enumerate() {
            seen += c;
            if seen >= target.max(1) {
                return bucket_floor(b);
            }
        }
        self.max_us
    }
}

/// xorshift64*: a thread's own, nothing shared.
struct Random(Cell<u64>);

impl Random {
    fn new(seed: u64) -> Self {
        Self(Cell::new(seed | 1))
    }
    fn next(&self) -> u64 {
        let mut x = self.0.get();
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0.set(x);
        x.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }
    /// Uniform in (0, 1].
    fn unit(&self) -> f64 {
        ((self.next() >> 11) as f64 + 1.0) / (1u64 << 53) as f64
    }
}

/// One request, its whole body read; the bytes, or `None` if it failed.
async fn fetch(client: &PlainTextClient, request: &http::Request<()>) -> Option<usize> {
    let stream = client.send_request(request, true).await.ok()?;
    fetch_rest(stream).await
}

async fn fetch_rest(stream: slopio_h2::client::Stream) -> Option<usize> {
    let response = stream.response().await.ok()?;
    if !response.status().is_success() {
        return None;
    }
    let mut bytes = 0;
    while let Some(chunk) = stream.read().await.ok()? {
        bytes += chunk.len();
    }
    Some(bytes)
}

async fn worker(config: Config, context: WorkerContext, results: Arc<Mutex<Vec<Stats>>>) {
    let index = context.thread_id - context.group.start;
    let threads = context.group.len();
    let conns = config.conns / threads + usize::from(index < config.conns % threads);
    let request = Rc::new(
        http::Request::builder()
            .method("GET")
            .uri(&config.url)
            .body(())
            .expect("URL"),
    );
    let mut clients = Vec::with_capacity(conns);
    for _ in 0..conns {
        let client = Rc::new(PlainTextClient::plaintext::<LoadRing>().with_max_connections(1));
        client.preconnect(request.uri()).await.expect("connect");
        clients.push(client);
    }

    let stats = Rc::new(RefCell::new(Stats::new()));
    let start = Instant::now();
    let from = start + config.warmup;
    let end = from + config.duration;

    // This thread's CPU over the measured window.
    {
        let stats = stats.clone();
        spawn(async move {
            Sleep::during(from.saturating_duration_since(Instant::now())).await;
            let (u0, s0) = thread_cpu_us();
            Sleep::during(end.saturating_duration_since(Instant::now())).await;
            let (u1, s1) = thread_cpu_us();
            let mut stats = stats.borrow_mut();
            stats.cpu_user_us = u1 - u0;
            stats.cpu_sys_us = s1 - s0;
        });
    }

    match config.rate {
        // h2load's closed loop: each stream sends again once answered.
        None => {
            for client in &clients {
                for _ in 0..config.streams {
                    let (client, request, stats) = (client.clone(), request.clone(), stats.clone());
                    spawn(async move {
                        loop {
                            let sent = Instant::now();
                            if sent >= end {
                                break;
                            }
                            let got = fetch(&client, &request).await;
                            if sent >= from {
                                match got {
                                    Some(bytes) => stats.borrow_mut().record(sent.elapsed(), bytes),
                                    None => stats.borrow_mut().failed += 1,
                                }
                            }
                        }
                    });
                }
            }
        }
        // Open loop: Poisson arrivals, this thread's share of the rate, each
        // on a connection drawn at random, timed from when it was due.
        Some(rate) => {
            let rate = rate / threads as f64;
            let random = Random::new(0x9e37_79b9_7f4a_7c15 ^ (index as u64 + 1).wrapping_mul(0xbf58_476d_1ce4_e5b9));
            let gap = |r: &Random| Duration::from_secs_f64(-r.unit().ln() / rate);
            let mut due = start + gap(&random);
            loop {
                let now = Instant::now();
                if now >= end {
                    break;
                }
                while due <= now {
                    let client = clients[(random.next() % clients.len() as u64) as usize].clone();
                    let (request, stats, at) = (request.clone(), stats.clone(), due);
                    spawn(async move {
                        let opened = client.send_request(&request, true).await.ok();
                        let sent = Instant::now();
                        let got = match opened {
                            Some(stream) => fetch_rest(stream).await,
                            None => None,
                        };
                        if at >= from && at < end {
                            stats.borrow_mut().lag.record(sent.saturating_duration_since(at));
                            match got {
                                Some(bytes) => stats.borrow_mut().record(at.elapsed(), bytes),
                                None => stats.borrow_mut().failed += 1,
                            }
                        }
                    });
                    due += gap(&random);
                }
                yield_now().await;
            }
        }
    }

    let left = end.saturating_duration_since(Instant::now()) + Duration::from_millis(500);
    Sleep::during(left).await;
    results.lock().unwrap().push(stats.borrow().clone());
    for client in &clients {
        client.close();
    }
}

fn main() {
    let config = Config::from_env();
    let results = Arc::new(Mutex::new(Vec::new()));
    let mut topology = Topology::new();
    topology.steer_connections(false);
    let (c, r) = (config.clone(), results.clone());
    topology.group::<LoadRing, _, _>(Threads::Fixed(config.cpus.clone()), RingOptions::default(), move |ctx| {
        worker(c.clone(), ctx, r.clone())
    });
    topology.run();

    let mut all = Stats::new();
    for s in results.lock().unwrap().iter() {
        all.merge(s);
    }
    let secs = config.duration.as_secs_f64();
    let ms = |us: u64| us as f64 / 1000.0;
    let cpu = (all.cpu_user_us + all.cpu_sys_us) as f64 / 1e6;
    println!(
        "{} req/s{}, {} conns{}, {} threads: {} done, {} failed, {:.0} MB/s | latency ms p50 {:.3} p90 {:.3} p99 {:.3} p99.9 {:.3} max {:.3}",
        (all.done as f64 / secs).round(),
        config.rate.map_or(String::new(), |r| format!(" (asked {r})")),
        config.conns,
        config.rate.map_or(format!(" x {} streams", config.streams), |_| String::new()),
        config.cpus.len(),
        all.done,
        all.failed,
        all.bytes as f64 / secs / 1e6,
        ms(all.percentile(0.5)),
        ms(all.percentile(0.9)),
        ms(all.percentile(0.99)),
        ms(all.percentile(0.999)),
        ms(all.max_us),
    );
    println!(
        "  client CPU: {:.2} cores ({:.0}% user), {:.2} µs per request{}",
        cpu / secs,
        100.0 * all.cpu_user_us as f64 / (all.cpu_user_us + all.cpu_sys_us).max(1) as f64,
        cpu * 1e6 / all.done.max(1) as f64,
        if config.rate.is_some() { " (pacers spin: not the cost of the requests)" } else { "" },
    );
    if config.rate.is_some() {
        println!(
            "  client lag, due to sent: p50 {:.3} p99 {:.3} p99.9 {:.3} max {:.3} ms",
            ms(all.lag.percentile(0.5)),
            ms(all.lag.percentile(0.99)),
            ms(all.lag.percentile(0.999)),
            ms(all.lag.max_us),
        );
    }
}
