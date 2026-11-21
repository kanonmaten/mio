//! The HTTP surface. Single private user, one process, loopback only: HTTPS terminates at the
//! local reverse proxy. Counters contain numbers only; no transcripts or IPs are kept, and
//! nothing about a request is logged.

use std::convert::Infallible;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use http_body_util::{BodyExt, Full};
use hyper::body::{Bytes, Incoming};
use hyper::header::{AUTHORIZATION, CONTENT_ENCODING, CONTENT_LENGTH, CONTENT_TYPE, HeaderName, HeaderValue};
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::{TokioIo, TokioTimer};
use serde_json::{Value, json};
use tokio::net::TcpListener;

use crate::analysis::{validate_analysis_payload, validate_analysis_v2_payload, validate_ask_payload, validate_lesson_payload, validate_lesson_v2_payload};
use crate::backup::{BackupError, BackupStore, MAX_BACKUP_BYTES, is_valid_export};
use crate::config::{Config, ConfigError, validate_config};
use crate::error::RequestError;
use crate::adapters::Usage;
use crate::generation::{Spent, Transport, execute_generation, generation_metadata_headers};
use crate::prompts::{ANALYSIS_V2_PROMPT_VERSION, LESSON_V2_PROMPT_VERSION, PROMPT_VERSION};
use crate::state_store::{CounterStore, Counters, MemoryCounterStore};
use crate::status::{QuotaObservation, authenticated, configuration_revision, gateway_status, gateway_status_v2, is_revision, metadata_headers};
use crate::task_profiles::task_configuration_identifiers;
use crate::tasks::Mode;
use crate::usage::{Ledger, Loaded, MemoryUsageStore, UsageStore, month_of};
use crate::time::next_utc_midnight;

const MAX_BODY_BYTES: usize = 40_000;
const MAX_CONCURRENT: u32 = 2;
/// The backup route's own deadline for waiting its turn and receiving the export.
const BACKUP_BODY_TIMEOUT_MS: u64 = 120_000;
const MINUTE_MS: i64 = 60_000;
const DAY_MS: i64 = 86_400_000;

type Reply = Response<Full<Bytes>>;
type Clock = Arc<dyn Fn() -> i64 + Send + Sync>;
type ConfigSource = Arc<dyn Fn() -> Config + Send + Sync>;

struct State {
    counters: Counters,
    active: u32,
    /// `None` when the usage file has an unknown schema: it is then never written.
    usage: Option<Ledger>,
}

struct Inner {
    config: ConfigSource,
    transport: Arc<dyn Transport>,
    clock: Clock,
    store: Arc<dyn CounterStore>,
    usage_store: Arc<dyn UsageStore>,
    state: Mutex<State>,
    /// `None` without a state directory (tests, a manual start): backups then fail with 507 and
    /// status reports none.
    backups: Option<Arc<BackupStore>>,
    /// One backup request at a time, held from before its body is read until the copy is stored
    /// or read back, so at most one export (32 MB) is in memory under the unit's 128 MB cap.
    backup_turn: tokio::sync::Mutex<()>,
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

    fn record_usage(&self, tokens: i64) {
        let mut state = self.state();
        roll_buckets(&mut state.counters, (self.clock)());
        state.counters.day_tokens = state.counters.day_tokens.saturating_add(tokens.max(0)).min(crate::js::MAX_SAFE_INTEGER);
        // The answer already exists; the next reservation retries the write.
        let _ = self.store.save(&state.counters);
    }

    /// Counts the provider answers of one request for the credit meter. Identifiers and token
    /// counts only. A failed write keeps the counts in memory; the next answer writes them again.
    fn record_answers(&self, config: &Config, mode: Mode, answers: Vec<Option<Usage>>) {
        if answers.is_empty() {
            return;
        }
        let (provider, model) = task_configuration_identifiers(config, mode.task_id());
        let wire = crate::model_profiles::provider(&provider).map_or("chat", |provider| provider.wire);
        let month = month_of((self.clock)());
        let mut state = self.state();
        let Some(ledger) = state.usage.as_mut() else { return };
        for usage in &answers {
            ledger.record(&month, mode.task_id(), &provider, &model, wire, usage.as_ref());
        }
        let _ = self.usage_store.save(ledger);
    }

    /// The `usage` object of `/v2/status` for the current UTC month, or null for a usage file
    /// this gateway must not touch.
    fn usage_report(&self) -> Value {
        let month = month_of((self.clock)());
        self.state().usage.as_ref().map_or(Value::Null, |ledger| ledger.report(&month))
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
    read_limited(body, declared, timeout_ms, MAX_BODY_BYTES, 0).await
}

/// The body, at most `limit` bytes within `timeout_ms`. `reserve` preallocates from the declared
/// length (backups), so a 32 MB export is not copied while the vector grows.
async fn read_limited(body: &mut Incoming, declared: Option<f64>, timeout_ms: u64, limit: usize, reserve: usize) -> Result<Vec<u8>, RequestError> {
    let too_large = RequestError::new(413, "request_too_large");
    if declared.is_some_and(|length| length > limit as f64) {
        return Err(too_large);
    }
    let collect = async {
        let mut bytes = Vec::with_capacity(reserve.min(limit));
        while let Some(frame) = body.frame().await {
            let frame = frame.map_err(|_| RequestError::new(400, "invalid_json"))?;
            if let Some(data) = frame.data_ref() {
                if bytes.len() + data.len() > limit {
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
        Mode::LessonV2 => validate_lesson_v2_payload(&value).map_err(|_| invalid)?,
    }
    Ok(value)
}

fn loaded_usage(store: &dyn UsageStore) -> Option<Ledger> {
    match store.load() {
        Loaded::Ledger(ledger) => Some(ledger),
        Loaded::Unknown => {
            // One journal line; the file is left exactly as it is.
            eprintln!("Mio-servern: användningsfilen har ett okänt format och lämnas orörd; kreditmätaren visar inget.");
            None
        }
    }
}

enum BackupRoute {
    Put,
    List,
    Get(String),
}

fn backup_route(method: &Method, target: &str) -> Option<BackupRoute> {
    match (method, target) {
        (&Method::PUT, "/v2/backup") => Some(BackupRoute::Put),
        (&Method::GET, "/v2/backups") => Some(BackupRoute::List),
        (&Method::GET, _) => target.strip_prefix("/v2/backups/").map(|id| BackupRoute::Get(id.to_owned())),
        _ => None,
    }
}

impl Gateway {
    pub fn new(config: Config, transport: Arc<dyn Transport>) -> Result<Self, ConfigError> {
        validate_config(&config)?;
        let store: Arc<dyn CounterStore> = Arc::new(MemoryCounterStore::default());
        let counters = store.load();
        Ok(Self { inner: Arc::new(Inner { config: Arc::new(move || config.clone()), transport,
            clock: Arc::new(system_clock), store, usage_store: Arc::new(MemoryUsageStore::default()),
            state: Mutex::new(State { counters, active: 0, usage: Some(Ledger::default()) }),
            backups: None, backup_turn: tokio::sync::Mutex::new(()) }) })
    }

    /// Stores the nightly backups and their key in `store`'s directory (`/var/lib/mio-gateway`).
    pub fn with_backup_store(self, store: Arc<BackupStore>) -> Self {
        self.rebuild(|inner| inner.backups = Some(store))
    }

    fn rebuild(self, change: impl FnOnce(&mut Inner)) -> Self {
        let Ok(mut inner) = Arc::try_unwrap(self.inner) else { panic!("configure the gateway before it serves") };
        change(&mut inner);
        Self { inner: Arc::new(inner) }
    }

    /// Keeps the counters across restarts. Loads them at once.
    pub fn with_store(self, store: Arc<dyn CounterStore>) -> Self {
        self.rebuild(|inner| {
            let usage = inner.state().usage.take();
            inner.state = Mutex::new(State { counters: store.load(), active: 0, usage });
            inner.store = store;
        })
    }

    /// Keeps the monthly usage counter across restarts (`usage.json`). Loads it at once.
    pub fn with_usage_store(self, store: Arc<dyn UsageStore>) -> Self {
        self.rebuild(|inner| {
            inner.state().usage = loaded_usage(store.as_ref());
            inner.usage_store = store;
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
            "/v2/lesson-notes" => Some(Mode::LessonV2),
            _ => None,
        };
        let is_status = matches!(target.as_str(), "/v1/status" | "/v2/status");
        let prompt_version = match mode {
            _ if is_status => ANALYSIS_V2_PROMPT_VERSION,
            Some(Mode::AnalyzeV2) => ANALYSIS_V2_PROMPT_VERSION,
            Some(Mode::LessonV2) => LESSON_V2_PROMPT_VERSION,
            _ => PROMPT_VERSION,
        };
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
            let mut status = gateway_status_v2(&config, inner.quota_snapshot(&config).as_ref());
            status["usage"] = inner.usage_report();
            // Always present on this gateway; an app or panel without it sees an older one.
            status["backup"] = inner.backups.as_ref().map_or_else(|| crate::backup::summary(&[]), |store| store.summary());
            return reply(&headers, 200, &status, 60);
        }
        if parts.method == Method::GET && target == "/health" {
            return reply(&headers, 200, &json!({ "status": "ok" }), 60);
        }
        if let Some(route) = backup_route(&parts.method, &target) {
            if !authorized {
                return reply(&headers, 401, &unauthorized, 60);
            }
            return self.backup(route, parts, body, finished, &headers).await;
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
        let spent = Spent::default();
        let outcome = execute_generation(&config, mode, &payload, inner.transport.as_ref(), &mut reserve,
            inner.clock.as_ref(), &spent).await;
        // Every answer the provider billed counts in the month's usage, failed or not.
        inner.record_answers(&config, mode, spent.take_answers());
        let generated = match outcome {
            Ok(generated) => generated,
            Err(error) => {
                // A failed call can still have used tokens; they count against the day (ultrareview C1).
                let tokens = spent.tokens.load(Ordering::Relaxed);
                if tokens > 0 {
                    inner.record_usage(tokens);
                }
                return failure(&headers, &error);
            }
        };
        inner.record_usage(spent.tokens.load(Ordering::Relaxed));
        headers.set("X-Mio-Provider", generated.config.provider.clone());
        headers.set("X-Mio-Model", generated.config.model.clone());
        headers.set("X-Mio-Prompt-Version", generated.prompt_version.to_owned());
        headers.set("X-Mio-Configuration-Revision", revision);
        for (name, value) in generation_metadata_headers(&generated.normalized) {
            headers.set(name, value);
        }
        let mut result = generated.result;
        if matches!(mode, Mode::Lesson | Mode::LessonV2) && let Some(notes) = result.as_object_mut() {
            notes.insert("metadata".to_owned(), json!({ "provider": generated.config.provider, "model": generated.config.model,
                "promptVersion": generated.prompt_version,
                "lessonIntervalSeconds": config.lesson_interval_seconds.unwrap_or(60).max(60) }));
        }
        drop(slot);
        reply(&headers, 200, &result, 60)
    }

    /// The backup routes: outside the AI quota, the token budget and the two generation slots,
    /// and never in contact with a provider. Nothing about the export is logged.
    async fn backup(&self, route: BackupRoute, parts: &hyper::http::request::Parts, body: &mut Incoming,
        finished: &mut bool, headers: &Headers) -> Reply {
        let inner = &self.inner;
        let storage_failed = || reply(headers, 507, &json!({ "error": "backup_storage_failed" }), 60);
        match route {
            BackupRoute::Put => {
                let header = |name: &HeaderName| parts.headers.get(name).and_then(|value| value.to_str().ok());
                let media_type = header(&CONTENT_TYPE).and_then(|value| value.split(';').next()).map(|kind| crate::js::trim(kind).to_lowercase());
                if media_type.as_deref() != Some("application/json") || parts.headers.get(CONTENT_ENCODING).is_some_and(|value| !value.is_empty()) {
                    return reply(headers, 415, &json!({ "error": "json_required" }), 60);
                }
                let declared = header(&CONTENT_LENGTH).and_then(|length| length.trim().parse::<f64>().ok());
                if declared.is_some_and(|length| length > MAX_BACKUP_BYTES as f64) {
                    return reply(headers, 413, &json!({ "error": "request_too_large" }), 60);
                }
                let reserve = declared.filter(|length| *length >= 0.0).map_or(0, |length| length as usize);
                let started = std::time::Instant::now();
                let deadline = Duration::from_millis(BACKUP_BODY_TIMEOUT_MS);
                let Ok(turn) = tokio::time::timeout(deadline, inner.backup_turn.lock()).await else {
                    return reply(headers, 408, &json!({ "error": "request_timeout" }), 60);
                };
                let remaining = deadline.saturating_sub(started.elapsed()).as_millis() as u64;
                let export = match read_limited(body, declared, remaining.max(1), MAX_BACKUP_BYTES, reserve).await {
                    Ok(export) => export,
                    Err(error) if error.code == "invalid_json" => return reply(headers, 400, &json!({ "error": "invalid_backup" }), 60),
                    Err(error) => return failure(headers, &error),
                };
                *finished = true;
                if !is_valid_export(&export) {
                    return reply(headers, 400, &json!({ "error": "invalid_backup" }), 60);
                }
                let Some(store) = inner.backups.clone() else { return storage_failed() };
                let now = (inner.clock)();
                // Encryption and disk writes run off the request thread; the turn is held until done.
                let saved = tokio::task::spawn_blocking(move || store.save(export, now)).await;
                drop(turn);
                match saved {
                    Ok(Ok((entry, kept))) => {
                        let mut created = entry.to_json();
                        created["kept"] = json!(kept);
                        reply(headers, 201, &created, 60)
                    }
                    _ => storage_failed(),
                }
            }
            BackupRoute::List => {
                let entries = inner.backups.as_ref().map(|store| store.list()).unwrap_or_default();
                let listed: Vec<Value> = entries.iter().map(crate::backup::Entry::to_json).collect();
                reply(headers, 200, &json!({ "backups": listed }), 60)
            }
            BackupRoute::Get(id) => {
                let Some(store) = inner.backups.clone() else {
                    return reply(headers, 404, &json!({ "error": "backup_not_found" }), 60);
                };
                let turn = inner.backup_turn.lock().await;
                let read = tokio::task::spawn_blocking(move || store.read(&id)).await;
                drop(turn);
                match read {
                    Ok(Ok(export)) => {
                        let mut response = reply(headers, 200, &Value::Null, 60);
                        *response.body_mut() = Full::new(Bytes::from(export));
                        response.headers_mut().insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
                        response
                    }
                    Ok(Err(BackupError::NotFound)) => reply(headers, 404, &json!({ "error": "backup_not_found" }), 60),
                    Ok(Err(BackupError::Unreadable)) => reply(headers, 500, &json!({ "error": "backup_unreadable" }), 60),
                    _ => storage_failed(),
                }
            }
        }
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
