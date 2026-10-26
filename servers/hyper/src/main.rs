//! The same route as `servers/slopio`, on tokio and hyper, set up the way
//! slopio's runtime sets itself up so that only the stacks differ: mimalloc,
//! one `SO_REUSEPORT` listener per worker with a backlog of 1024, `TCP_NODELAY`
//! on every connection, workers pinned to cores 0..N, one task per stream.
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

use std::net::SocketAddr;
use std::time::Duration;

use hyper::server::conn::http2;
use hyper::service::service_fn;
use hyper_util::rt::{TokioExecutor, TokioIo};
use socket2::{Domain, Protocol, Socket, Type};
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
    };
    let mode = match (flag("PER_CORE"), std::env::var("TOKIO_MODE").as_deref()) {
        (false, _) => Mode::Single,
        (true, Err(_) | Ok("reuseport")) => Mode::Reuseport,
        (true, Ok("multi")) => Mode::Multi,
        (true, Ok(other)) => panic!("unknown TOKIO_MODE `{other}`: reuseport, multi"),
    };
    // As slopio's runtime counts them: the CPUs this process may run on.
    let threads: usize = std::thread::available_parallelism().unwrap().into();

    println!(
        "hyper-server on :{} (h2c), mode={mode:?}, threads={}, max_streams={}, stream_window={}",
        config.port,
        match mode {
            Mode::Single => 1,
            _ => threads,
        },
        config.max_streams,
        config.stream_window,
    );

    match mode {
        Mode::Single => current_thread().block_on(serve(config)),
        Mode::Reuseport => {
            let workers: Vec<_> = (0..threads)
                .map(|core| {
                    std::thread::spawn(move || {
                        pin_core(core);
                        current_thread().block_on(serve(config));
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
            .block_on(serve(config)),
    }
}

fn current_thread() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("a tokio runtime")
}

async fn serve(config: Config) {
    let listener = listen(config.port).expect("the listener binds");
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
        let connection = http.serve_connection(TokioIo::new(socket), service_fn(routes::route));
        tokio::spawn(async move {
            let _ = connection.await;
        });
    }
}

/// As slopio's `MultiAccept::bind`.
fn listen(port: u16) -> std::io::Result<TcpListener> {
    let socket = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP))?;
    socket.set_reuse_port(true)?;
    socket.set_nonblocking(true)?;
    socket.bind(&SocketAddr::from(([0, 0, 0, 0], port)).into())?;
    socket.listen(BACKLOG)?;
    TcpListener::from_std(socket.into())
}

/// As slopio's runtime does it: worker `n` on CPU `n`, whatever mask the
/// process was started with.
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
