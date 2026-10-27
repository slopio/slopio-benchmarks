//! The same route as `servers/slopio`, on tokio and hyper, set up the way
//! slopio's runtime sets itself up so that only the stacks differ: mimalloc,
//! one `SO_REUSEPORT` listener per worker with a backlog of 1024, `TCP_NODELAY`
//! on every connection, worker n pinned to the nth CPU the process may run
//! on, one task per stream.
//!
//!     PER_CORE=1 cargo run --release -p hyper-server
//!     h2load -n 100000 -c 64 -m 32 http://127.0.0.1:8080/
//!
//! | Variable        | Default    | Meaning                                              |
//! |-----------------|------------|------------------------------------------------------|
//! | `PORT`          | `8080`     | Port to listen on, all interfaces.                   |
//! | `PER_CORE`      | unset      | One worker per core rather than a single one.        |
//! | `TOKIO_MODE`    | `reuseport`| With `PER_CORE`: `reuseport`, or `multi` for tokio's work-stealing runtime. |
//! | `MAX_STREAMS`   | `64`       | SETTINGS_MAX_CONCURRENT_STREAMS, as slopio-h2's.     |
//! | `STREAM_WINDOW` | `1048576`  | SETTINGS_INITIAL_WINDOW_SIZE, as slopio-h2's.        |
//! | `INCOMING_CPU`  | unset      | In `reuseport` mode, `SO_INCOMING_CPU` on each worker's listener: a connection goes to the worker on the CPU its packets arrive on. |
//!
//! In `reuseport` mode each worker logs, every 5 s, how many connections it
//! accepted and how many of them arrived on its own CPU, as the kernel's
//! `SO_INCOMING_CPU` on the accepted socket tells.

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use hyper::server::conn::http2;
use hyper::service::service_fn;
use hyper_util::rt::{TokioExecutor, TokioIo};
use socket2::{Domain, Protocol, SockRef, Socket, Type};
use tokio::net::TcpListener;

mod routes;

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

/// slopio-h2's server settings, which differ from hyper's defaults.
const MAX_STREAMS: u32 = 64;
const STREAM_WINDOW: u32 = 1024 * 1024;
const CONNECTION_WINDOW: u32 = i32::MAX as u32;
const MAX_HEADER_LIST_SIZE: u32 = 16 * 1024;

/// slopio's listener: what the kernel queues before an accept.
const BACKLOG: i32 = 1024;
/// How long the listener waits after running out of descriptors or memory,
/// as slopio-h2's does.
const ACCEPT_BACKOFF: Duration = Duration::from_millis(10);

#[derive(Clone, Copy)]
struct Config {
    port: u16,
    max_streams: u32,
    stream_window: u32,
    incoming_cpu: bool,
}

#[derive(Clone, Copy, Debug)]
enum Mode {
    /// One thread, as slopio's `main_thread`.
    Single,
    /// One current-thread runtime per core, pinned, each with its own
    /// listener: slopio's `thread_per_core`.
    Reuseport,
    /// tokio's work-stealing runtime, one listener.
    Multi,
}

fn main() {
    let config = Config {
        port: env("PORT", 8080),
        max_streams: env("MAX_STREAMS", MAX_STREAMS),
        stream_window: env("STREAM_WINDOW", STREAM_WINDOW),
        incoming_cpu: flag("INCOMING_CPU"),
    };
    let mode = match (flag("PER_CORE"), std::env::var("TOKIO_MODE").as_deref()) {
        (false, _) => Mode::Single,
        (true, Err(_) | Ok("reuseport")) => Mode::Reuseport,
        (true, Ok("multi")) => Mode::Multi,
        (true, Ok(other)) => panic!("unknown TOKIO_MODE `{other}`: reuseport, multi"),
    };
    // As slopio's runtime counts them: the CPUs this process may run on.
    let cpus = allowed_cpus();
    let threads = cpus.len();

    println!(
        "hyper-server on :{} (h2c), mode={mode:?}, threads={}, max_streams={}, stream_window={}, incoming_cpu={}",
        config.port,
        match mode {
            Mode::Single => 1,
            _ => threads,
        },
        config.max_streams,
        config.stream_window,
        config.incoming_cpu,
    );

    match mode {
        Mode::Single => current_thread().block_on(serve(config, None)),
        Mode::Reuseport => {
            let workers: Vec<_> = cpus
                .into_iter()
                .map(|cpu| {
                    std::thread::spawn(move || {
                        pin_core(cpu);
                        current_thread().block_on(serve(config, Some(cpu)));
                    })
                })
                .collect();
            for worker in workers {
                worker.join().unwrap();
            }
        }
        Mode::Multi => tokio::runtime::Builder::new_multi_thread()
            .worker_threads(threads)
            .enable_all()
            .build()
            .expect("a tokio runtime")
            .block_on(serve(config, None)),
    }
}

fn current_thread() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("a tokio runtime")
}

/// `cpu`: the one this worker is pinned to, in `reuseport` mode.
async fn serve(config: Config, cpu: Option<usize>) {
    let steer = cpu.filter(|_| config.incoming_cpu);
    let listener = listen(config.port, steer).expect("the listener binds");
    let placed = cpu.map(|cpu| Placement::report(cpu));
    let mut http = http2::Builder::new(TokioExecutor::new());
    http.max_concurrent_streams(config.max_streams)
        .initial_stream_window_size(config.stream_window)
        .initial_connection_window_size(CONNECTION_WINDOW)
        .max_header_list_size(MAX_HEADER_LIST_SIZE)
        // slopio-h2 sends no `date`: neither does this.
        .auto_date_header(false);

    loop {
        let socket = match listener.accept().await {
            Ok((socket, _)) => socket,
            Err(e) => {
                eprintln!("accept: {e}");
                tokio::time::sleep(ACCEPT_BACKOFF).await;
                continue;
            }
        };
        let _ = socket.set_nodelay(true);
        if let Some(placed) = &placed {
            placed.count(&socket);
        }
        let connection = http.serve_connection(TokioIo::new(socket), service_fn(routes::route));
        tokio::spawn(async move {
            let _ = connection.await;
        });
    }
}

/// How many of a worker's connections arrive on its own CPU: counted at
/// accept, logged every 5 s while it changes.
struct Placement {
    cpu: usize,
    accepted: Arc<AtomicU64>,
    here: Arc<AtomicU64>,
}

impl Placement {
    fn report(cpu: usize) -> Self {
        let placement = Self {
            cpu,
            accepted: Arc::default(),
            here: Arc::default(),
        };
        let (accepted, here) = (placement.accepted.clone(), placement.here.clone());
        tokio::spawn(async move {
            let mut last = 0;
            loop {
                tokio::time::sleep(Duration::from_secs(5)).await;
                let n = accepted.load(Ordering::Relaxed);
                if n != last {
                    last = n;
                    let h = here.load(Ordering::Relaxed);
                    eprintln!("worker on CPU {cpu}: {n} accepted, {h} arrived on this CPU");
                }
            }
        });
        placement
    }

    /// The kernel records on each socket the CPU that last handled its
    /// packets: at accept, the one that took the handshake's last ACK.
    fn count(&self, socket: &tokio::net::TcpStream) {
        self.accepted.fetch_add(1, Ordering::Relaxed);
        if SockRef::from(socket).cpu_affinity().ok() == Some(self.cpu) {
            self.here.fetch_add(1, Ordering::Relaxed);
        }
    }
}

/// As slopio's `MultiAccept::bind`. With `incoming_cpu`, `SO_INCOMING_CPU`:
/// in a `SO_REUSEPORT` group the kernel then hands a connection to the
/// listener whose CPU is the one that received it.
fn listen(port: u16, incoming_cpu: Option<usize>) -> std::io::Result<TcpListener> {
    let socket = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP))?;
    socket.set_reuse_port(true)?;
    if let Some(cpu) = incoming_cpu {
        socket.set_cpu_affinity(cpu)?;
    }
    socket.set_nonblocking(true)?;
    socket.bind(&SocketAddr::from(([0, 0, 0, 0], port)).into())?;
    socket.listen(BACKLOG)?;
    TcpListener::from_std(socket.into())
}

/// The CPUs this process may run on, in ascending order, as slopio's runtime
/// reads them (`runtime/src/topology/cpus.rs`): not `0..n`, a mask such as
/// `0-2,4` leaves holes.
fn allowed_cpus() -> Vec<usize> {
    // SAFETY: a zeroed `cpu_set_t` is an empty set for the kernel to fill.
    unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        let result = libc::sched_getaffinity(0, size_of::<libc::cpu_set_t>(), &mut set);
        assert_eq!(result, 0, "sched_getaffinity failed");
        (0..libc::CPU_SETSIZE as usize)
            .filter(|&cpu| libc::CPU_ISSET(cpu, &set))
            .collect()
    }
}

/// As slopio's runtime does it: each worker on one CPU of the mask.
fn pin_core(core: usize) {
    // SAFETY: a zeroed `cpu_set_t` is an empty set, and the call only reads it.
    unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        libc::CPU_SET(core, &mut set);
        let result = libc::sched_setaffinity(0, size_of::<libc::cpu_set_t>(), &set);
        assert_eq!(result, 0, "sched_setaffinity failed for core {core}");
    }
}

fn env<T: std::str::FromStr>(name: &str, default: T) -> T {
    match std::env::var(name) {
        Ok(v) => v
            .parse()
            .unwrap_or_else(|_| panic!("{name}={v}: not a valid value")),
        Err(_) => default,
    }
}

fn flag(name: &str) -> bool {
    std::env::var(name).is_ok_and(|v| v != "0")
}
