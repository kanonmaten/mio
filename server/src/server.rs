//! The HTTP surface. Single private user, one process, loopback only: HTTPS terminates at the
//! local reverse proxy. Counters contain numbers only; no transcripts or IPs are kept, and
//! nothing about a request is logged.

use std::convert::Infallible;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use http_body_util::{BodyExt, Full};
use hyper::body::{Bytes, Incoming};
use hyper::header::{AUTHORIZATION, CONTENT_ENCODING, CONTENT_LENGTH, CONTENT_TYPE, HeaderName, HeaderValue};
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::{TokioIo, TokioTimer};
use serde_json::{Value, json};
use tokio::net::TcpListener;

use crate::adapters::Normalized;
use crate::analysis::{validate_analysis_payload, validate_analysis_v2_payload, validate_ask_payload, validate_lesson_payload};
use crate::config::{Config, ConfigError, validate_config};
use crate::error::RequestError;
use crate::generation::{Transport, execute_generation, generation_metadata_headers};
use crate::prompts::{ANALYSIS_V2_PROMPT_VERSION, PROMPT_VERSION};
use crate::state_store::{CounterStore, Counters, MemoryCounterStore};
use crate::status::{QuotaObservation, authenticated, configuration_revision, gateway_status, gateway_status_v2, is_revision, metadata_headers};
use crate::task_profiles::task_configuration_identifiers;
use crate::tasks::Mode;
use crate::time::next_utc_midnight;

const MAX_BODY_BYTES: usize = 40_000;
const MAX_CONCURRENT: u32 = 2;
const MINUTE_MS: i64 = 60_000;
const DAY_MS: i64 = 86_400_000;

type Reply = Response<Full<Bytes>>;
type Clock = Arc<dyn Fn() -> i64 + Send + Sync>;
type ConfigSource = Arc<dyn Fn() -> Config + Send + Sync>;

struct State {
    counters: Counters,
    active: u32,
}

struct Inner {
    config: ConfigSource,
    transport: Arc<dyn Transport>,
    clock: Clock,
    store: Arc<dyn CounterStore>,
    state: Mutex<State>,
}

#[derive(Clone)]
pub struct Gateway {
    inner: Arc<Inner>,
}

/// One of the two concurrent generation slots; released when the request ends for any reason,
/// including a client that disconnects.
struct Slot(Arc<Inner>);

impl Drop for Slot {
    fn drop(&mut self) {
        self.0.state().active -= 1;
    }
}

fn system_clock() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_millis() as i64)
}

fn roll_buckets(counters: &mut Counters, time: i64) {
    if counters.minute != time.div_euclid(MINUTE_MS) {
        counters.minute = time.div_euclid(MINUTE_MS);
        counters.minute_count = 0;
    }
    if counters.day != time.div_euclid(DAY_MS) {
        counters.day = time.div_euclid(DAY_MS);
        counters.day_count = 0;
        counters.day_tokens = 0;
    }
}

fn seconds_until_next_day(time: i64) -> u64 {
    let next = (time.div_euclid(DAY_MS) + 1) * DAY_MS;
    ((next - time) as u64).div_ceil(1_000).max(1)
}

impl Inner {
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Counts the request against the local limits and persists the counters before any
    /// provider traffic.
    fn reserve(self: &Arc<Self>, config: &Config) -> Result<Slot, RequestError> {
        let time = (self.clock)();
        let mut state = self.state();
        roll_buckets(&mut state.counters, time);
        if state.active >= MAX_CONCURRENT {
            return Err(RequestError::new(429, "local_concurrency_limit"));
        }
        if config.tokens_per_day.is_some_and(|limit| state.counters.day_tokens >= limit as i64) {
            return Err(RequestError::with_retry_after(429, "local_token_limit", seconds_until_next_day(time)));
        }
        if config.requests_per_day.is_some_and(|limit| state.counters.day_count >= limit as i64) {
            return Err(RequestError::with_retry_after(429, "local_day_limit", seconds_until_next_day(time)));
        }
        if state.counters.minute_count >= config.requests_per_minute as i64 {
            return Err(RequestError::new(429, "local_minute_limit"));
        }
        state.counters.minute_count += 1;
        state.counters.day_count += 1;
        // A failed write must never turn into a provider call without accounting; the
        // request is refused instead and the in-memory counters still apply.
        self.store.save(&state.counters).map_err(|_| RequestError::new(503, "budget_store_failed"))?;
        state.active += 1;
        Ok(Slot(self.clone()))
    }

    fn record_usage(&self, normalized: &Normalized) {
        let usage = normalized.usage.clone().unwrap_or_default();
        let tokens = usage.total_tokens.unwrap_or(usage.input_tokens.unwrap_or(0) + usage.output_tokens.unwrap_or(0));
        let mut state = self.state();
        roll_buckets(&mut state.counters, (self.clock)());
        state.counters.day_tokens = state.counters.day_tokens.saturating_add(tokens.max(0)).min(crate::js::MAX_SAFE_INTEGER);
        // The answer already exists; the next reservation retries the write.
        let _ = self.store.save(&state.counters);
    }

    /// Status observes counters only; it never reserves capacity or calls the provider.
    fn quota_snapshot(&self, config: &Config) -> Option<QuotaObservation> {
        let time = (self.clock)();
        let mut state = self.state();
        roll_buckets(&mut state.counters, time);
        let used = if config.tokens_per_day.is_some() { state.counters.day_tokens } else { state.counters.day_count };
        let limit = config.tokens_per_day.or(config.requests_per_day)?;
        Some(QuotaObservation { remaining: Some((limit as i64 - used).max(0)), reset_at: Some(next_utc_midnight(time)) })
    }
}

struct Headers(Vec<(&'static str, String)>);

impl Headers {
    fn set(&mut self, name: &'static str, value: String) {
        match self.0.iter_mut().find(|(known, _)| known.eq_ignore_ascii_case(name)) {
            Some(entry) => entry.1 = value,
            None => self.0.push((name, value)),
        }
    }
}

fn reply(headers: &Headers, status: u16, body: &Value, retry_after: u64) -> Reply {
    let mut response = Response::new(Full::new(Bytes::from(body.to_string())));
    *response.status_mut() = StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    let fixed = [("Content-Type", "application/json; charset=utf-8".to_owned()), ("Cache-Control", "no-store".to_owned()),
        ("X-Content-Type-Options", "nosniff".to_owned())];
    let retry = (status == 429).then(|| ("Retry-After", retry_after.to_string()));
    for (name, value) in headers.0.iter().map(|(name, value)| (*name, value.clone())).chain(fixed).chain(retry) {
        if let (Ok(name), Ok(value)) = (HeaderName::from_bytes(name.as_bytes()), HeaderValue::from_str(&value)) {
            response.headers_mut().insert(name, value);
        }
    }
    response
}

fn failure(headers: &Headers, error: &RequestError) -> Reply {
    // Arbitrary upstream bodies, credentials, source text and full URLs stay private.
    reply(headers, error.status, &json!({ "error": error.code }), error.retry_after)
}

async fn read_body(body: &mut Incoming, declared: Option<f64>, timeout_ms: u64) -> Result<Vec<u8>, RequestError> {
    let too_large = RequestError::new(413, "request_too_large");
    if declared.is_some_and(|length| length > MAX_BODY_BYTES as f64) {
        return Err(too_large);
    }
    let collect = async {
        let mut bytes = Vec::new();
        while let Some(frame) = body.frame().await {
            let frame = frame.map_err(|_| RequestError::new(400, "invalid_json"))?;
            if let Some(data) = frame.data_ref() {
                if bytes.len() + data.len() > MAX_BODY_BYTES {
                    return Err(too_large.clone());
                }
                bytes.extend_from_slice(data);
            }
        }
        Ok(bytes)
    };
    tokio::time::timeout(Duration::from_millis(timeout_ms), collect).await
        .unwrap_or(Err(RequestError::new(408, "request_timeout")))
}

fn parse_payload(bytes: &[u8], mode: Mode) -> Result<Value, RequestError> {
    let invalid = RequestError::new(400, "invalid_json");
    let text = std::str::from_utf8(bytes).map_err(|_| invalid.clone())?;
    let value: Value = serde_json::from_str(text.strip_prefix('\u{FEFF}').unwrap_or(text)).map_err(|_| invalid.clone())?;
    match mode {
        Mode::Ask => validate_ask_payload(&value).map_err(|code| RequestError::new(400, code))?,
        Mode::Analyze => validate_analysis_payload(&value).map_err(|_| invalid)?,
        Mode::AnalyzeV2 => validate_analysis_v2_payload(&value).map_err(|_| invalid)?,
        Mode::Lesson => validate_lesson_payload(&value).map_err(|_| invalid)?,
    }
    Ok(value)
}

impl Gateway {
    pub fn new(config: Config, transport: Arc<dyn Transport>) -> Result<Self, ConfigError> {
        validate_config(&config)?;
        let store: Arc<dyn CounterStore> = Arc::new(MemoryCounterStore::default());
        let counters = store.load();
        Ok(Self { inner: Arc::new(Inner { config: Arc::new(move || config.clone()), transport,
            clock: Arc::new(system_clock), store, state: Mutex::new(State { counters, active: 0 }) }) })
    }

    fn rebuild(self, change: impl FnOnce(&mut Inner)) -> Self {
        let Ok(mut inner) = Arc::try_unwrap(self.inner) else { panic!("configure the gateway before it serves") };
        change(&mut inner);
        Self { inner: Arc::new(inner) }
    }

    /// Keeps the counters across restarts. Loads them at once.
    pub fn with_store(self, store: Arc<dyn CounterStore>) -> Self {
        self.rebuild(|inner| {
            inner.state = Mutex::new(State { counters: store.load(), active: 0 });
            inner.store = store;
        })
    }

    pub fn with_clock(self, clock: impl Fn() -> i64 + Send + Sync + 'static) -> Self {
        self.rebuild(|inner| inner.clock = Arc::new(clock))
    }

    /// Each request then captures the configuration current at that moment, including rotated credentials.
    pub fn with_configuration_source(self, source: impl Fn() -> Config + Send + Sync + 'static) -> Self {
        self.rebuild(|inner| inner.config = Arc::new(source))
    }

    pub async fn handle(&self, request: Request<Incoming>) -> Reply {
        let (parts, mut body) = request.into_parts();
        let mut finished = false;
        let response = self.respond(&parts, &mut body, &mut finished).await;
        if !finished {
            // Answer first, then let a client that is still sending finish: closing a socket with
            // unread data can reset the connection before the client has read the reply.
            let drain = async {
                let mut seen = 0;
                while let Some(Ok(frame)) = body.frame().await {
                    seen += frame.data_ref().map_or(0, Bytes::len);
                    if seen > 2 * MAX_BODY_BYTES {
                        break;
                    }
                }
            };
            let _ = tokio::time::timeout(Duration::from_millis(200), drain).await;
        }
        response
    }

    async fn respond(&self, parts: &hyper::http::request::Parts, body: &mut Incoming, finished: &mut bool) -> Reply {
        let inner = &self.inner;
        let config = (inner.config)();
        let mut headers = Headers(Vec::new());
        if validate_config(&config).is_err() {
            return reply(&headers, 500, &json!({ "error": "request_failed" }), 60);
        }
        let header = |name: &HeaderName| parts.headers.get(name).and_then(|value| value.to_str().ok());
        let revision = configuration_revision(&config);
        let target = parts.uri.to_string();
        let mode = match target.as_str() {
            "/v1/ask" => Some(Mode::Ask),
            "/v1/analyze" => Some(Mode::Analyze),
            "/v2/analyze" => Some(Mode::AnalyzeV2),
            "/v1/lesson-notes" => Some(Mode::Lesson),
            _ => None,
        };
        let is_status = matches!(target.as_str(), "/v1/status" | "/v2/status");
        let prompt_version = if is_status || mode == Some(Mode::AnalyzeV2) { ANALYSIS_V2_PROMPT_VERSION } else { PROMPT_VERSION };
        let (provider, model) = task_configuration_identifiers(&config, mode.map_or("everyday", Mode::task_id));
        headers.0 = metadata_headers(&provider, &model, prompt_version, Some(&revision));
        let authorized = authenticated(header(&AUTHORIZATION), &config.gateway_token);
        let unauthorized = json!({ "error": "unauthorized" });
        if parts.method == Method::GET && is_status {
            if !authorized {
                return reply(&headers, 401, &unauthorized, 60);
            }
            if target == "/v1/status" {
                return reply(&headers, 200, &gateway_status(&config), 60);
            }
            return reply(&headers, 200, &gateway_status_v2(&config, inner.quota_snapshot(&config).as_ref()), 60);
        }
        if parts.method == Method::GET && target == "/health" {
            return reply(&headers, 200, &json!({ "status": "ok" }), 60);
        }
        let Some(mode) = mode.filter(|_| parts.method == Method::POST) else {
            return reply(&headers, 404, &json!({ "error": "not_found" }), 60);
        };
        if !authorized {
            return reply(&headers, 401, &unauthorized, 60);
        }
        let mut observed = parts.headers.get_all("x-mio-configuration-revision").iter();
        if let Some(first) = observed.next() {
            if observed.next().is_some() || !first.to_str().is_ok_and(is_revision) {
                return reply(&headers, 400, &json!({ "error": "invalid_configuration_revision" }), 60);
            }
            if first.to_str().ok() != Some(revision.as_str()) {
                return reply(&headers, 409, &json!({ "error": "configuration_changed" }), 60);
            }
        }
        let media_type = header(&CONTENT_TYPE).and_then(|value| value.split(';').next()).map(|kind| crate::js::trim(kind).to_lowercase());
        if media_type.as_deref() != Some("application/json") || parts.headers.get(CONTENT_ENCODING).is_some_and(|value| !value.is_empty()) {
            return reply(&headers, 415, &json!({ "error": "json_required" }), 60);
        }
        let declared = header(&CONTENT_LENGTH).and_then(|length| length.trim().parse::<f64>().ok());
        let payload = match read_body(body, declared, config.body_timeout_ms).await
            .and_then(|bytes| { *finished = true; parse_payload(&bytes, mode) }) {
            Ok(payload) => payload,
            Err(error) => return failure(&headers, &error),
        };
        let mut slot = None;
        let mut reserve = || inner.reserve(&config).map(|reserved| slot = Some(reserved));
        let generated = match execute_generation(&config, mode, &payload, inner.transport.as_ref(), &mut reserve, inner.clock.as_ref()).await {
            Ok(generated) => generated,
            Err(error) => return failure(&headers, &error),
        };
        inner.record_usage(&generated.normalized);
        headers.set("X-Mio-Provider", generated.config.provider.clone());
        headers.set("X-Mio-Model", generated.config.model.clone());
        headers.set("X-Mio-Prompt-Version", generated.prompt_version.to_owned());
        headers.set("X-Mio-Configuration-Revision", revision);
        for (name, value) in generation_metadata_headers(&generated.normalized) {
            headers.set(name, value);
        }
        let mut result = generated.result;
        if mode == Mode::Lesson && let Some(notes) = result.as_object_mut() {
            notes.insert("metadata".to_owned(), json!({ "provider": generated.config.provider, "model": generated.config.model,
                "promptVersion": generated.prompt_version,
                "lessonIntervalSeconds": config.lesson_interval_seconds.unwrap_or(60).max(60) }));
        }
        drop(slot);
        reply(&headers, 200, &result, 60)
    }

    /// Serves until the future is dropped. Every connection carries one request and is closed.
    pub async fn serve(self, listener: TcpListener) {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                // Out of descriptors or a reset during accept: pause instead of spinning.
                tokio::time::sleep(Duration::from_millis(50)).await;
                continue;
            };
            let gateway = self.clone();
            tokio::spawn(async move {
                let service = hyper::service::service_fn(move |request| {
                    let gateway = gateway.clone();
                    async move { Ok::<_, Infallible>(gateway.handle(request).await) }
                });
                // A client that goes away mid-request ends the connection, which drops the
                // handler and with it the provider call and the concurrency slot.
                let _ = hyper::server::conn::http1::Builder::new().keep_alive(false).max_buf_size(8_192)
                    .timer(TokioTimer::new()).header_read_timeout(Duration::from_secs(5))
                    .serve_connection(TokioIo::new(stream), service).await;
            });
        }
    }
}
