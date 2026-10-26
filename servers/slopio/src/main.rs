//! The server under test: slopio-h2 answering the README's route on one
//! port, HTTP/2 cleartext with prior knowledge.
//!
//!     PER_CORE=1 cargo run --release -p slopio-server
//!     h2load -n 100000 -c 64 -m 32 http://127.0.0.1:8080/
//!
//! Configured from the environment, so the same binary runs every scenario:
//!
//! | Variable        | Default      | Meaning                                         |
//! |-----------------|--------------|-------------------------------------------------|
//! | `PORT`          | `8080`       | Port to listen on, all interfaces.              |
//! | `PER_CORE`      | unset        | One worker per core rather than a single one.   |
//! | `RING`          | `64x128+512` | Receive buffer ring: KiB × entries [+ pool].    |
//! | `ZERO_COPY`     | unset        | Send with `SEND_ZC` (`PlainZeroCopy`).          |
//! | `MAX_STREAMS`   | library      | SETTINGS_MAX_CONCURRENT_STREAMS.                |
//! | `STREAM_WINDOW` | library      | SETTINGS_INITIAL_WINDOW_SIZE, in bytes.         |
//! | `BODY_MIN_RATE` | library      | Slowest upload tolerated, bytes/s; 0 disables.  |
//!
//! The HTTP route is in `routes.rs`. The gRPC methods, in `grpc.rs`,
//! are only built with `--features grpc`.

use runtime::net::BufRingSpec;
use runtime::{main_thread_with, thread_per_core_with};
use slopio_h2::server::{Limits, Server, ServerSettings, ServerTransport};

#[cfg(feature = "grpc")]
mod grpc;
mod routes;

// Only the ring selected is ever installed: each is its own type with its
// own thread-local. `bgid` must be below 4.
runtime::define_buf_ring!(
    Ring64x128p512,
    bgid = 1,
    buffer_size = 65536,
    ring_size = 128,
    pool_size = 512
);
runtime::define_buf_ring!(
    Ring64x256p512,
    bgid = 1,
    buffer_size = 65536,
    ring_size = 256,
    pool_size = 512
);
runtime::define_buf_ring!(Ring64x512, bgid = 1, buffer_size = 65536, ring_size = 512);
runtime::define_buf_ring!(Ring64x4096, bgid = 1, buffer_size = 65536, ring_size = 4096);
runtime::define_buf_ring!(Ring16x2048, bgid = 1, buffer_size = 16384, ring_size = 2048);
runtime::define_buf_ring!(Ring16x4096, bgid = 1, buffer_size = 16384, ring_size = 4096);

const RINGS: &str = "64x128+512, 64x256+512, 64x512, 64x4096, 16x2048, 16x4096";

#[derive(Clone, Copy)]
struct Config {
    port: u16,
    zero_copy: bool,
    limits: Limits,
}

fn main() {
    let ring = std::env::var("RING").unwrap_or_else(|_| "64x128+512".into());
    let per_core = flag("PER_CORE");
    let defaults = Limits::default();
    let config = Config {
        port: env("PORT", 8080),
        zero_copy: flag("ZERO_COPY"),
        limits: Limits {
            max_concurrent_streams: env("MAX_STREAMS", defaults.max_concurrent_streams),
            stream_window: env("STREAM_WINDOW", defaults.stream_window),
            body_min_rate: env("BODY_MIN_RATE", defaults.body_min_rate),
            ..defaults
        },
    };

    println!(
        "slopio-server on :{} (h2c), ring {ring}, per_core={per_core}, zero_copy={}, \
         max_streams={}, stream_window={}",
        config.port,
        config.zero_copy,
        config.limits.max_concurrent_streams,
        config.limits.stream_window,
    );

    match ring.as_str() {
        "64x128+512" => start::<Ring64x128p512>(config, per_core),
        "64x256+512" => start::<Ring64x256p512>(config, per_core),
        "64x512" => start::<Ring64x512>(config, per_core),
        "64x4096" => start::<Ring64x4096>(config, per_core),
        "16x2048" => start::<Ring16x2048>(config, per_core),
        "16x4096" => start::<Ring16x4096>(config, per_core),
        other => panic!("unknown RING `{other}`: {RINGS}"),
    }
}

fn start<U: BufRingSpec + 'static>(config: Config, per_core: bool) {
    if per_core {
        thread_per_core_with::<U, _>(move |_| Box::pin(serve::<U>(config)));
    } else {
        main_thread_with::<U, _>(serve::<U>(config));
    }
}

/// Per worker: the routers are `Rc`s, built on the core that uses them.
async fn serve<U: BufRingSpec + 'static>(config: Config) {
    let transport = match config.zero_copy {
        true => ServerTransport::PlainZeroCopy,
        false => ServerTransport::Plain,
    };
    let settings = ServerSettings {
        limits: config.limits,
        ..ServerSettings::new(([0, 0, 0, 0], config.port), transport)
    };
    #[cfg(feature = "grpc")]
    let handler = slopio_h2::grpc::service(grpc::router(), routes::http());
    #[cfg(not(feature = "grpc"))]
    let handler = routes::http();
    if let Err(e) = Server::new(settings).run::<U, _>(handler).await {
        eprintln!("server error: {e}");
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
