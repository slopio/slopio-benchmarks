//! What `GET /app` asks of a server, done alike by the Rust servers through
//! this crate, and by `servers/h2o/server.c` by hand:
//!
//! ```text
//! GET /app?delay_ms=20&jitter_ms=5&cpu_us=50&touch_kb=64&size_kb=16
//! ```
//!
//! In order: `touch_kb` KiB of the request's own memory, allocated and
//! filled; a wait of `delay_ms`, on the server's own timer, as a call to a
//! database would be; `cpu_us` of computation; the memory read back and
//! freed; then the README's answer, 2048 bytes of `x`, or `size_kb` KiB of
//! them, from static memory the server may send without copying. The memory
//! is held across the wait, as an application holds a request's state while
//! it waits.
//!
//! `POST /app` first reads the whole request body, as an application that
//! parses JSON needs it, and goes over every byte of it ([`digest`]); then
//! the same work and answer. Past [`MAX_BODY`], a 413.
//!
//! With `jitter_ms`, each request waits a whole number of milliseconds drawn
//! evenly from `delay_ms - jitter_ms` to `delay_ms + jitter_ms`, as calls to a
//! database do not all take the same time: requests that arrived together
//! do not all wake together. Whole milliseconds, the finest h2o's timer
//! takes. `jitter_ms` above `delay_ms` is a 400.
//!
//! Each server sleeps on its own runtime's timer, and those differ: slopio's
//! ticks every 10 ms, tokio's and h2o's every millisecond. So each measures
//! how long it really slept, on the monotonic clock, and [`record_sleep`]
//! logs it once a second per thread:
//!
//! ```text
//! slept at=1761562800.123 n=1000 requested_us=20000000 sum_us=15100000 max_us=20480 hist=99:12,100:31,... err_sum_us=-4900000 early=412 err=-97:3,-96:8,...,4:20
//! ```
//!
//! Since the previous line of the thread: `at` is the wall-clock time of the
//! line; `hist` counts the sleeps by 100 µs bucket of how long they took
//! (bucket b: b×100 µs up to (b+1)×100 µs, the last one holding everything
//! past it); `err` counts them by 100 µs bucket of how far each was from
//! what it asked, signed (bucket -3: 300 to 200 µs early; from 20 ms early
//! to 180 ms late, the end buckets holding the rest), `err_sum_us` adds
//! those up, and `early` counts the sleeps that ended before their time.

use std::cell::{Cell, RefCell};
use std::hint::black_box;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Bounds on what a request may ask: past them, a 400.
pub const MAX_DELAY_MS: u64 = 60_000;
pub const MAX_CPU_US: u64 = 1_000_000;
pub const MAX_TOUCH_KB: usize = 65_536;
pub const MAX_SIZE_KB: usize = 1024;

/// The answer's body: `/`'s 2048 bytes by default.
pub const DEFAULT_SIZE: usize = 2048;
/// Every body is a prefix of this, so a server can hand it out without
/// copying, as `/`'s static payload.
pub static BODY: [u8; MAX_SIZE_KB * 1024] = [b'x'; MAX_SIZE_KB * 1024];

/// The largest request body `POST /app` reads: past it, a 413.
pub const MAX_BODY: usize = 16 * 1024 * 1024;

/// Goes over every byte of a request body, as a parser would, so that no
/// server can skip reading it.
pub fn digest(body: &[u8]) {
    let sum = body.iter().fold(0u64, |a, &b| a.wrapping_add(u64::from(b)));
    black_box(sum);
}

/// A cache line: the request's memory is written whole, read a line at a time.
const LINE: usize = 64;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Work {
    pub delay: Duration,
    pub jitter: Duration,
    pub cpu: Duration,
    pub touch: usize,
    /// The answer's body, in bytes.
    pub size: usize,
}

impl Default for Work {
    fn default() -> Self {
        Self {
            delay: Duration::ZERO,
            jitter: Duration::ZERO,
            cpu: Duration::ZERO,
            touch: 0,
            size: DEFAULT_SIZE,
        }
    }
}

/// The work a `:path` asks for, or `None` if its query names anything else
/// or a value past its bound. Without a query, none.
pub fn parse(path: &str) -> Option<Work> {
    let mut work = Work::default();
    let Some((_, query)) = path.split_once('?') else {
        return Some(work);
    };
    for pair in query.split('&').filter(|p| !p.is_empty()) {
        let (key, value) = pair.split_once('=')?;
        let value: u64 = value.parse().ok()?;
        match key {
            "delay_ms" if value <= MAX_DELAY_MS => work.delay = Duration::from_millis(value),
            "jitter_ms" if value <= MAX_DELAY_MS => work.jitter = Duration::from_millis(value),
            "cpu_us" if value <= MAX_CPU_US => work.cpu = Duration::from_micros(value),
            "touch_kb" if value as usize <= MAX_TOUCH_KB => work.touch = value as usize * 1024,
            "size_kb" if (1..=MAX_SIZE_KB as u64).contains(&value) => {
                work.size = value as usize * 1024
            }
            _ => return None,
        }
    }
    (work.jitter <= work.delay).then_some(work)
}

/// The request's memory, from before its wait to after.
pub struct Held(Vec<u8>);

impl Work {
    /// The answer's body.
    pub fn body(&self) -> &'static [u8] {
        &BODY[..self.size]
    }

    /// How long this request waits: `delay`, or with a `jitter`, a whole
    /// number of milliseconds drawn evenly within it either side.
    pub fn wait(&self) -> Duration {
        if self.jitter.is_zero() {
            return self.delay;
        }
        let (delay, jitter) = (
            self.delay.as_millis() as u64,
            self.jitter.as_millis() as u64,
        );
        Duration::from_millis(delay - jitter + next_random() % (2 * jitter + 1))
    }

    /// Allocates and fills the request's memory: call before the wait.
    pub fn begin(&self) -> Held {
        // Not zero: a zeroed allocation may be pages the kernel has not
        // given yet, touched by nothing.
        Held(vec![0x5a; self.touch])
    }
}

impl Held {
    /// The computation, then the memory read back and freed: call after the
    /// wait.
    pub fn end(self, cpu: Duration) {
        if !cpu.is_zero() {
            let start = Instant::now();
            while start.elapsed() < cpu {
                std::hint::spin_loop();
            }
        }
        let sum = self
            .0
            .iter()
            .step_by(LINE)
            .fold(0u64, |a, &b| a + u64::from(b));
        black_box(sum);
    }
}

thread_local! {
    // xorshift64*, per thread: nothing shared, nothing atomic. Seeded from
    // the clock and the thread's own address, so threads differ.
    static RANDOM: Cell<u64> = Cell::new({
        let t = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
        let here = &t as *const _ as u64;
        (t.as_nanos() as u64 ^ here.rotate_left(32)) | 1
    });
}

fn next_random() -> u64 {
    RANDOM.with(|r| {
        let mut x = r.get();
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        r.set(x);
        x.wrapping_mul(0x2545_f491_4f6c_dd1d)
    })
}

const BUCKET_US: u64 = 100;
/// 200 ms of 100 µs buckets; anything longer lands in the last.
const BUCKETS: usize = 2000;
/// How far from its time a sleep was, signed: from 20 ms early to 180 ms late
/// in 100 µs buckets, anything further in the end ones.
const ERR_FROM_US: i64 = -20_000;
const ERR_BUCKETS: usize = 2000;
const EVERY: Duration = Duration::from_secs(1);

struct Slept {
    n: u64,
    requested_us: u64,
    sum_us: u64,
    max_us: u64,
    hist: Box<[u32; BUCKETS]>,
    err_sum_us: i64,
    early: u64,
    err: Box<[u32; ERR_BUCKETS]>,
    since: Instant,
}

impl Slept {
    fn new() -> Self {
        Self {
            n: 0,
            requested_us: 0,
            sum_us: 0,
            max_us: 0,
            hist: Box::new([0; BUCKETS]),
            err_sum_us: 0,
            early: 0,
            err: Box::new([0; ERR_BUCKETS]),
            since: Instant::now(),
        }
    }

    fn log(&mut self) {
        let at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        let hist: Vec<String> = (self.hist.iter().enumerate())
            .filter(|(_, c)| **c > 0)
            .map(|(b, c)| format!("{b}:{c}"))
            .collect();
        let first = ERR_FROM_US / BUCKET_US as i64;
        let err: Vec<String> = (self.err.iter().enumerate())
            .filter(|(_, c)| **c > 0)
            .map(|(b, c)| format!("{}:{c}", first + b as i64))
            .collect();
        eprintln!(
            "slept at={}.{:03} n={} requested_us={} sum_us={} max_us={} hist={} err_sum_us={} early={} err={}",
            at.as_secs(),
            at.subsec_millis(),
            self.n,
            self.requested_us,
            self.sum_us,
            self.max_us,
            hist.join(","),
            self.err_sum_us,
            self.early,
            err.join(",")
        );
        *self = Self::new();
    }
}

thread_local! {
    // Per thread, so that counting costs no server an atomic.
    static SLEPT: RefCell<Slept> = RefCell::new(Slept::new());
}

/// Counts one sleep: what was asked, and how long it really took.
pub fn record_sleep(requested: Duration, slept: Duration) {
    SLEPT.with_borrow_mut(|s| {
        let us = slept.as_micros() as u64;
        let asked = requested.as_micros() as u64;
        s.n += 1;
        s.requested_us += asked;
        s.sum_us += us;
        s.max_us = s.max_us.max(us);
        s.hist[((us / BUCKET_US) as usize).min(BUCKETS - 1)] += 1;
        let err = us as i64 - asked as i64;
        s.err_sum_us += err;
        s.early += u64::from(err < 0);
        let bucket = (err - ERR_FROM_US).div_euclid(BUCKET_US as i64);
        s.err[bucket.clamp(0, ERR_BUCKETS as i64 - 1) as usize] += 1;
        if s.since.elapsed() >= EVERY {
            s.log();
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses() {
        assert_eq!(parse("/app"), Some(Work::default()));
        assert_eq!(
            parse("/app?delay_ms=20&cpu_us=50&touch_kb=4"),
            Some(Work {
                delay: Duration::from_millis(20),
                cpu: Duration::from_micros(50),
                touch: 4096,
                ..Work::default()
            })
        );
        assert_eq!(parse("/app?delay_ms=5&jitter_ms=6"), None);
        assert_eq!(parse("/app").unwrap().body().len(), 2048);
        assert_eq!(parse("/app?size_kb=16").unwrap().body().len(), 16384);
        assert_eq!(parse("/app?size_kb=0"), None);
        assert_eq!(parse("/app?size_kb=1025"), None);
        assert_eq!(parse("/app?delay=20"), None);
        assert_eq!(parse("/app?delay_ms=x"), None);
        assert_eq!(parse("/app?delay_ms=60001"), None);
    }

    #[test]
    fn jitters_within_bounds_in_whole_ms() {
        let work = parse("/app?delay_ms=20&jitter_ms=5").unwrap();
        let waits: Vec<_> = (0..10_000).map(|_| work.wait()).collect();
        assert!(
            waits
                .iter()
                .all(|w| (15..=25).contains(&w.as_millis()) && w.subsec_micros() % 1000 == 0)
        );
        // Every value is drawn, the ends included.
        for ms in 15..=25 {
            assert!(
                waits.iter().any(|w| w.as_millis() == ms),
                "{ms} never drawn"
            );
        }
        assert_eq!(
            parse("/app?delay_ms=20").unwrap().wait(),
            Duration::from_millis(20)
        );
    }
}
