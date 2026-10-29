//! The routes every server in the comparison answers, byte for byte the
//! same: see "Routes" in the README.

use std::time::Instant;

use http::{HeaderMap, HeaderValue, Method, StatusCode, header};
use runtime::bytes::Bytes;
use runtime::runtime::time::Sleep;
use slopio_h2::server::{BodyTooLarge, Params, Router, Stream};

pub fn http() -> Router {
    Router::new()
        .route(Method::GET, "/", payload)
        .route(Method::GET, "/app", app)
        .route(Method::POST, "/app", app)
}

/// Under slopio-h2's `ATTACH_MIN` (4 KiB), so copied into the output as any
/// small body is: there is no copy-free path for it to be denied.
const PAYLOAD_LEN: usize = 2048;
static PAYLOAD: [u8; PAYLOAD_LEN] = [b'x'; PAYLOAD_LEN];

async fn payload(stream: Stream, _: Params) {
    let mut fields = HeaderMap::new();
    fields.insert(header::CONTENT_TYPE, HeaderValue::from_static("text/plain"));
    fields.insert(header::CONTENT_LENGTH, HeaderValue::from(PAYLOAD_LEN));
    stream.write_headers(StatusCode::OK, &fields);
    stream.write_data_final(&PAYLOAD).await;
}

/// The work its query asks for (`servers/work`), then `/`'s answer, of
/// `size_kb` if asked. The wait is on the runtime's timer, which ticks every
/// 10 ms: how long it really took is counted. The body is handed over
/// rather than lent: from `ATTACH_MIN` (4 KiB) up slopio-h2 sends it as it
/// is, without copying it into its output; below, it copies it, as `/`.
///
/// A `POST` reads its whole body first (`Stream::body`), as a route that
/// parses one does.
async fn app(stream: Stream, _: Params) {
    let Some(work) = stream.path().and_then(app_work::parse) else {
        return refuse(stream, StatusCode::BAD_REQUEST, b"bad request\n").await;
    };
    if stream.method() == Some(&Method::POST) {
        match stream.body(app_work::MAX_BODY).await {
            Ok(body) => app_work::digest(&body),
            Err(BodyTooLarge) => {
                return refuse(
                    stream,
                    StatusCode::PAYLOAD_TOO_LARGE,
                    b"payload too large\n",
                )
                .await;
            }
        }
    }
    let held = work.begin();
    let wait = work.wait();
    if !wait.is_zero() {
        let start = Instant::now();
        Sleep::during(wait).await;
        app_work::record_sleep(wait, start.elapsed());
    }
    held.end(work.cpu);
    let body = work.body();
    let mut fields = HeaderMap::new();
    fields.insert(header::CONTENT_TYPE, HeaderValue::from_static("text/plain"));
    fields.insert(header::CONTENT_LENGTH, HeaderValue::from(body.len()));
    stream.write_headers(StatusCode::OK, &fields);
    stream.write_owned_final(Bytes::from_static(body)).await;
}

/// As slopio-h2 writes its own refusals: `content-type`, no `content-length`.
async fn refuse(stream: Stream, status: StatusCode, body: &[u8]) {
    let mut fields = HeaderMap::new();
    fields.insert(header::CONTENT_TYPE, HeaderValue::from_static("text/plain"));
    stream.write_headers(status, &fields);
    stream.write_data_final(body).await;
}
