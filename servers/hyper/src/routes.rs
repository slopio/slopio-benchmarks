//! The README's one route, as `servers/slopio/src/routes.rs` answers it:
//! same status, same headers, same body, and the 404 and 405 slopio-h2's
//! router writes.

use std::convert::Infallible;
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Instant;

use bytes::Bytes;
use http::{HeaderValue, Method, Request, Response, StatusCode, header};
use http_body::{Frame, SizeHint};
use http_body_util::{BodyExt, Limited};
use hyper::body::Incoming;

const PAYLOAD_LEN: usize = 2048;
static PAYLOAD: [u8; PAYLOAD_LEN] = [b'x'; PAYLOAD_LEN];

/// slopio-h2's router matches the path without its query.
pub async fn route(request: Request<Incoming>) -> Result<Response<Body>, Infallible> {
    let response = match (request.uri().path(), request.method()) {
        ("/", &Method::GET) => payload(),
        // Parsed before the wait: the request is not held across it.
        ("/app", &Method::GET) => match app_work::parse(
            request
                .uri()
                .path_and_query()
                .map_or("/app", |p| p.as_str()),
        ) {
            Some(work) => app(work).await,
            None => fallback(StatusCode::BAD_REQUEST, None, b"bad request\n"),
        },
        // The whole body first, as a route that parses one does.
        ("/app", &Method::POST) => match app_work::parse(
            request
                .uri()
                .path_and_query()
                .map_or("/app", |p| p.as_str()),
        ) {
            Some(work) => match read_body(request.into_body()).await {
                Some(body) => {
                    app_work::digest(&body);
                    app(work).await
                }
                None => fallback(StatusCode::PAYLOAD_TOO_LARGE, None, b"payload too large\n"),
            },
            None => fallback(StatusCode::BAD_REQUEST, None, b"bad request\n"),
        },
        ("/", _) => fallback(
            StatusCode::METHOD_NOT_ALLOWED,
            Some("GET"),
            b"method not allowed\n",
        ),
        // slopio-h2's router lists a path's methods in the order routed.
        ("/app", _) => fallback(
            StatusCode::METHOD_NOT_ALLOWED,
            Some("GET, POST"),
            b"method not allowed\n",
        ),
        _ => fallback(StatusCode::NOT_FOUND, None, b"not found\n"),
    };
    Ok(response)
}

fn payload() -> Response<Body> {
    let mut response = Response::new(Body::Sized(Some(Bytes::from_static(&PAYLOAD))));
    let headers = response.headers_mut();
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static("text/plain"));
    headers.insert(header::CONTENT_LENGTH, HeaderValue::from(PAYLOAD_LEN));
    response
}

/// The whole request body, gathered as an application gathers it to parse
/// it, or `None` past `MAX_BODY` (or if the client broke off).
async fn read_body(body: Incoming) -> Option<Bytes> {
    let limited = Limited::new(body, app_work::MAX_BODY);
    limited
        .collect()
        .await
        .ok()
        .map(|collected| collected.to_bytes())
}

/// The work its query asks for (`servers/work`), then `/`'s answer, of
/// `size_kb` if asked, from static memory as `/`'s payload. The wait
/// is on tokio's timer, which ticks every millisecond: how long it really
/// took is counted.
async fn app(work: app_work::Work) -> Response<Body> {
    let held = work.begin();
    let wait = work.wait();
    if !wait.is_zero() {
        let start = Instant::now();
        tokio::time::sleep(wait).await;
        app_work::record_sleep(wait, start.elapsed());
    }
    held.end(work.cpu);
    let body = work.body();
    let mut response = Response::new(Body::Sized(Some(Bytes::from_static(body))));
    let headers = response.headers_mut();
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static("text/plain"));
    headers.insert(header::CONTENT_LENGTH, HeaderValue::from(body.len()));
    response
}

/// slopio-h2's router writes these with `allow` first and without a
/// `content-length`; a body of unknown length keeps hyper from adding one.
fn fallback(
    status: StatusCode,
    allow: Option<&'static str>,
    body: &'static [u8],
) -> Response<Body> {
    let mut response = Response::new(Body::Unsized(Some(Bytes::from_static(body))));
    *response.status_mut() = status;
    let headers = response.headers_mut();
    if let Some(allow) = allow {
        headers.insert(header::ALLOW, HeaderValue::from_static(allow));
    }
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static("text/plain"));
    response
}

/// One body, sent in one frame, with or without telling hyper its length.
pub enum Body {
    Sized(Option<Bytes>),
    Unsized(Option<Bytes>),
}

impl http_body::Body for Body {
    type Data = Bytes;
    type Error = Infallible;

    fn poll_frame(
        self: Pin<&mut Self>,
        _: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, Infallible>>> {
        let (Body::Sized(body) | Body::Unsized(body)) = self.get_mut();
        Poll::Ready(body.take().map(|b| Ok(Frame::data(b))))
    }

    fn is_end_stream(&self) -> bool {
        let (Body::Sized(body) | Body::Unsized(body)) = self;
        body.is_none()
    }

    fn size_hint(&self) -> SizeHint {
        match self {
            Body::Sized(body) => SizeHint::with_exact(body.as_ref().map_or(0, |b| b.len() as u64)),
            Body::Unsized(_) => SizeHint::default(),
        }
    }
}
