//! The gRPC side, one method per kind of call. The schema clients need is in
//! `proto/`; the messages here are written by hand to match it.
//!
//! | Method                                  | Scenario                                     |
//! |-----------------------------------------|----------------------------------------------|
//! | `slopio.bench.v1.Bench/Unary`           | One request, one response.                   |
//! | `slopio.bench.v1.Bench/ServerStream`    | One request, `response_count` responses.     |
//! | `slopio.bench.v1.Bench/ClientStream`    | Many requests, one response.                 |
//! | `slopio.bench.v1.Bench/Bidi`            | Each request answered as it arrives.         |
//! | `helloworld.Greeter/SayHello`           | gRPC's own example, as `ghz` documents it.   |
//! | `grpc.health.v1.Health/Check`           | Health, for `grpc-health-probe` and load balancers. |
//!
//! Messages are not compressed, and are not accepted compressed: slopio-h2's
//! server does not decompress them.

use std::time::Duration;

use bytes::Bytes;
use runtime::runtime::time::Sleep;
use slopio_h2::grpc::{GrpcCall, GrpcRouter, Status};

pub fn router() -> GrpcRouter {
    GrpcRouter::new()
        .route("/slopio.bench.v1.Bench/Unary", unary)
        .route("/slopio.bench.v1.Bench/ServerStream", server_stream)
        .route("/slopio.bench.v1.Bench/ClientStream", client_stream)
        .route("/slopio.bench.v1.Bench/Bidi", bidi)
        .route("/helloworld.Greeter/SayHello", say_hello)
        .route("/grpc.health.v1.Health/Check", check)
}

/// What most gRPC clients accept by default in one message.
const MAX_RESPONSE_SIZE: u32 = 4 << 20;

/// Every response payload is a slice of it.
static FILLER: [u8; MAX_RESPONSE_SIZE as usize] = [b'x'; MAX_RESPONSE_SIZE as usize];
const MAX_RESPONSE_COUNT: u32 = 1 << 20;
const MAX_DELAY_MS: u32 = 60_000;

#[derive(Clone, PartialEq, prost::Message)]
struct Request {
    #[prost(bytes = "bytes", tag = "1")]
    payload: Bytes,
    #[prost(uint32, tag = "2")]
    response_size: u32,
    #[prost(uint32, tag = "3")]
    response_count: u32,
    #[prost(uint32, tag = "4")]
    delay_ms: u32,
}

#[derive(Clone, PartialEq, prost::Message)]
struct Response {
    /// A slice of `FILLER`, never a copy of it.
    #[prost(bytes = "bytes", tag = "1")]
    payload: Bytes,
    #[prost(uint64, tag = "2")]
    received_bytes: u64,
    #[prost(uint64, tag = "3")]
    received_messages: u64,
}

/// Payload bytes and requests received so far on one call.
#[derive(Default)]
struct Received {
    bytes: u64,
    messages: u64,
}

impl Received {
    fn count(&mut self, request: &Request) {
        self.bytes += request.payload.len() as u64;
        self.messages += 1;
    }

    fn response(&self, size: u32) -> Response {
        Response {
            payload: Bytes::from_static(&FILLER[..size as usize]),
            received_bytes: self.bytes,
            received_messages: self.messages,
        }
    }
}

async fn unary(call: &GrpcCall) -> Status {
    let request = match call.message::<Request>().await {
        Ok(Some(request)) => request,
        Ok(None) => return Status::invalid_argument("no request message"),
        Err(status) => return status,
    };
    if let Err(status) = check_request(&request) {
        return status;
    }
    let mut received = Received::default();
    received.count(&request);
    pause(request.delay_ms).await;
    call.write_message(&received.response(request.response_size))
        .await;
    Status::ok()
}

/// With a `delay_ms`, a stream that stays open: `response_count` responses
/// paced `delay_ms` apart.
async fn server_stream(call: &GrpcCall) -> Status {
    let request = match call.message::<Request>().await {
        Ok(Some(request)) => request,
        Ok(None) => return Status::invalid_argument("no request message"),
        Err(status) => return status,
    };
    if let Err(status) = check_request(&request) {
        return status;
    }
    if request.response_count > MAX_RESPONSE_COUNT {
        return Status::invalid_argument("response_count: at most 1048576");
    }
    let mut received = Received::default();
    received.count(&request);
    let response = received.response(request.response_size);
    for _ in 0..request.response_count.max(1) {
        pause(request.delay_ms).await;
        call.write_message(&response).await;
    }
    Status::ok()
}

async fn client_stream(call: &GrpcCall) -> Status {
    let mut received = Received::default();
    let mut last = None;
    loop {
        match call.message::<Request>().await {
            Ok(Some(request)) => {
                received.count(&request);
                last = Some(request);
            }
            Ok(None) => break,
            Err(status) => return status,
        }
    }
    let (size, delay) = last.map_or((0, 0), |r| (r.response_size, r.delay_ms));
    if size > MAX_RESPONSE_SIZE {
        return Status::invalid_argument("response_size: at most 4194304");
    }
    if delay > MAX_DELAY_MS {
        return Status::invalid_argument("delay_ms: at most 60000");
    }
    pause(delay).await;
    call.write_message(&received.response(size)).await;
    Status::ok()
}

/// The next request is not read until this one is answered: a client that
/// stops reading responses stops its own requests.
async fn bidi(call: &GrpcCall) -> Status {
    let mut received = Received::default();
    loop {
        let request = match call.message::<Request>().await {
            Ok(Some(request)) => request,
            Ok(None) => return Status::ok(),
            Err(status) => return status,
        };
        if let Err(status) = check_request(&request) {
            return status;
        }
        received.count(&request);
        pause(request.delay_ms).await;
        call.write_message(&received.response(request.response_size))
            .await;
    }
}

fn check_request(request: &Request) -> Result<(), Status> {
    if request.response_size > MAX_RESPONSE_SIZE {
        return Err(Status::invalid_argument("response_size: at most 4194304"));
    }
    if request.delay_ms > MAX_DELAY_MS {
        return Err(Status::invalid_argument("delay_ms: at most 60000"));
    }
    Ok(())
}

/// The runtime's timers tick every 10 ms: below that, the pause is anywhere
/// up to the next tick.
async fn pause(ms: u32) {
    if ms > 0 {
        Sleep::during(Duration::from_millis(ms.into())).await;
    }
}

#[derive(Clone, PartialEq, prost::Message)]
struct HelloRequest {
    #[prost(string, tag = "1")]
    name: String,
}

#[derive(Clone, PartialEq, prost::Message)]
struct HelloReply {
    #[prost(string, tag = "1")]
    message: String,
}

async fn say_hello(call: &GrpcCall) -> Status {
    let request = match call.message::<HelloRequest>().await {
        Ok(Some(request)) => request,
        Ok(None) => return Status::invalid_argument("no request message"),
        Err(status) => return status,
    };
    call.write_message(&HelloReply {
        message: format!("Hello {}", request.name),
    })
    .await;
    Status::ok()
}

#[derive(Clone, PartialEq, prost::Message)]
struct HealthCheckRequest {
    #[prost(string, tag = "1")]
    service: String,
}

#[derive(Clone, PartialEq, prost::Message)]
struct HealthCheckResponse {
    #[prost(int32, tag = "1")]
    status: i32,
}

const SERVING: i32 = 1;

/// The server as a whole, `""`, or one of its services by name.
async fn check(call: &GrpcCall) -> Status {
    let request = match call.message::<HealthCheckRequest>().await {
        Ok(Some(request)) => request,
        Ok(None) => return Status::invalid_argument("no request message"),
        Err(status) => return status,
    };
    match request.service.as_str() {
        "" | "slopio.bench.v1.Bench" | "helloworld.Greeter" => {
            call.write_message(&HealthCheckResponse { status: SERVING })
                .await;
            Status::ok()
        }
        _ => Status::not_found("unknown service"),
    }
}
