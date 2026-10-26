//! The one route every server in the comparison answers, byte for byte the
//! same: see "Routes" in the README.

use http::{HeaderMap, HeaderValue, Method, StatusCode, header};
use slopio_h2::server::{Params, Router, Stream};

pub fn http() -> Router {
    Router::new().route(Method::GET, "/", payload)
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
