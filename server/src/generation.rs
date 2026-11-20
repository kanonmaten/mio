//! One generation call: profile, sizing, quota reservation, the provider call with at most one
//! identical retry, and validation, all inside one deadline.

use std::future::Future;
use std::pin::Pin;
use std::sync::Mutex;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::adapters::{Finish, Generation, Normalized, Usage, build_for_profile, build_provider_request, normalize_provider_error, normalize_provider_response, response_usage};
use crate::config::Config;
use crate::error::RequestError;
use crate::js::{ascii_alphanumeric_or, credential_shaped};
use crate::model_profiles::Profile;
use crate::task_profiles::resolve_task_profile;
use crate::tasks::{Mode, create_task_request, validate_task_result};

const MAX_UPSTREAM_BYTES: usize = 65_536;

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// A network failure. It carries no detail: transport errors can quote URLs and headers.
#[derive(Debug)]
pub struct TransportError;

pub struct UpstreamRequest {
    pub url: String,
    /// Headers besides `Content-Type`, the provider key among them. Never logged.
    pub headers: Vec<(&'static str, String)>,
    pub body: String,
}

pub trait UpstreamResponse: Send {
    fn status(&self) -> u16;
    fn header(&self, name: &str) -> Option<String>;
    /// The next piece of the body, or `None` at its end.
    fn chunk(&mut self) -> BoxFuture<'_, Result<Option<Vec<u8>>, TransportError>>;
}

/// The seam to the provider. Dropping a returned future or response cancels the work.
pub trait Transport: Send + Sync {
    fn send(&self, request: UpstreamRequest) -> BoxFuture<'_, Result<Box<dyn UpstreamResponse>, TransportError>>;
}

enum Failure {
    Request(RequestError),
    /// A failure with no fixed category of its own; reported as provider infrastructure and never retried.
    Unclassified,
}

impl From<RequestError> for Failure {
    fn from(error: RequestError) -> Self {
        Self::Request(error)
    }
}

fn error_status(category: &str) -> u16 {
    match category {
        "provider_quota" => 429,
        "provider_request_too_large" => 413,
        "provider_model_unavailable" | "provider_parameters" => 422,
        _ => 502,
    }
}

fn provider_failure(status: u16, data: Option<&Value>, retry_after: Option<&str>, now_ms: i64) -> RequestError {
    let error = normalize_provider_error(status, data, retry_after, now_ms);
    RequestError { status: error_status(error.category), code: error.category,
        retry_after: error.retry_after.unwrap_or(60), provider_retry_after: error.retry_after }
}

// Groq's free tier admits a request only when prompt + max_tokens fit the per-minute token
// budget, and the reservation counts whether or not the answer uses it. Three UTF-8 bytes per
// token overestimates Swedish text, so a request sized here is accepted by the provider.
fn estimate_tokens(text: &str) -> i64 {
    text.len().div_ceil(3) as i64
}

pub fn fit_to_minute_budget(mut generation: Generation, task_id: &str, tokens_per_minute: Option<u64>) -> Result<Generation, RequestError> {
    let Some(budget) = tokens_per_minute else { return Ok(generation) };
    let schema = generation.structured_output.get("schema").map(Value::to_string).unwrap_or_default();
    let prompt = generation.messages.iter().map(|message| estimate_tokens(&message.content) + 8).sum::<i64>()
        + estimate_tokens(&schema) + 50;
    let room = budget as i64 - prompt;
    let minimum = match task_id { "ask" => 300, "everyday" => 500, _ => 1_200 };
    let wanted = generation.max_output_tokens as i64;
    if room < wanted.min(minimum) {
        return Err(RequestError::new(413, "provider_request_too_large"));
    }
    if room < wanted {
        generation.max_output_tokens = room as u64;
    }
    Ok(generation)
}

/// Milliseconds before the one retry, or `None` when the failure must be reported at once.
fn retry_delay(failure: &Failure, config: &Config) -> Option<u64> {
    let Failure::Request(error) = failure else { return None };
    match error.code {
        "provider_quota" => error.provider_retry_after.filter(|seconds| *seconds <= 20).map(|seconds| seconds * 1_000 + 250),
        "provider_infrastructure" | "provider_transport" => Some(config.retry_delay_ms.unwrap_or(1_000)),
        _ => None,
    }
}

/// What the provider answers of one request cost. `tokens` is the day's budget as before (answers
/// that were read, including refused, cut-off and invalid ones); `answers` holds the token counts
/// of every successful HTTP answer, whatever happened to it next, for the monthly usage counter.
/// Only numbers: no text from any answer.
#[derive(Debug, Default)]
pub struct Spent {
    pub tokens: AtomicI64,
    answers: Mutex<Vec<Option<Usage>>>,
}

impl Spent {
    fn answered(&self, usage: Option<Usage>) {
        self.answers.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).push(usage);
    }

    /// The answers counted so far, emptied.
    pub fn take_answers(&self) -> Vec<Option<Usage>> {
        std::mem::take(&mut *self.answers.lock().unwrap_or_else(|poisoned| poisoned.into_inner()))
    }
}

/// Tokens one provider answer used, as counted against the day's budget.
pub fn usage_tokens(usage: Option<&Usage>) -> i64 {
    let usage = usage.cloned().unwrap_or_default();
    usage.total_tokens.unwrap_or(usage.input_tokens.unwrap_or(0) + usage.output_tokens.unwrap_or(0)).max(0)
}

async fn read_upstream(mut response: Box<dyn UpstreamResponse>, profile: &Profile, now_ms: i64, spent: &Spent) -> Result<Normalized, Failure> {
    let status = response.status();
    let ok = (200..300).contains(&status);
    let has_json = response.header("content-type").is_some_and(|kind| kind.to_lowercase().starts_with("application/json"));
    let retry_after = response.header("retry-after");
    // Groq and the chat providers send x-request-id; Anthropic sends request-id.
    let request_id = response.header("x-request-id").or_else(|| response.header("request-id"));
    // Error envelopes have the same limits and deadline as successful envelopes. Only
    // normalized fixed codes leave this boundary; arbitrary error bodies never do.
    // An unreadable error envelope still keeps its status category (e.g. 429 + Retry-After).
    let too_large = |code| if ok { RequestError::new(502, code) } else { provider_failure(status, None, retry_after.as_deref(), now_ms) };
    let declared = response.header("content-length").and_then(|length| length.trim().parse::<f64>().ok());
    // A successful HTTP answer is billed even when Mio cannot use it; it is counted once here
    // with whatever token counts it carries (none when it is unreadable).
    if declared.is_some_and(|length| length > MAX_UPSTREAM_BYTES as f64) {
        if ok { spent.answered(None); }
        return Err(too_large("invalid_upstream_response").into());
    }
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| Failure::Unclassified)? {
        if body.len() + chunk.len() > MAX_UPSTREAM_BYTES {
            if ok { spent.answered(None); }
            return Err(too_large("upstream_response_too_large").into());
        }
        body.extend_from_slice(&chunk);
    }
    drop(response);
    let data: Option<Value> = if has_json { serde_json::from_slice(&body).ok() } else { None };
    if ok {
        spent.answered(data.as_ref().and_then(|data| response_usage(data, profile.wire)));
    }
    if !ok {
        return Err(provider_failure(status, data.as_ref(), retry_after.as_deref(), now_ms).into());
    }
    let Some(data) = data else { return Err(RequestError::new(502, "invalid_upstream_response").into()) };
    let normalized = normalize_provider_response(&data, profile, &|name| if name == "x-request-id" { request_id.clone() } else { None })
        .map_err(|error| RequestError::new(error_status(error.0), error.0))?;
    // The provider charged this answer whatever happens to it next: cut off, refused, rejected
    // by the validator or followed by a retry (ultrareview C1; Node counted only successes).
    spent.tokens.fetch_add(usage_tokens(normalized.usage.as_ref()), Ordering::Relaxed);
    match normalized.finish {
        Finish::Refused => Err(RequestError::new(502, "provider_refusal").into()),
        Finish::Truncated => Err(RequestError::new(502, "provider_truncated").into()),
        Finish::Completed => Ok(normalized),
    }
}

/// One synthetic call for `mio-gateway prova`, started by the user in Mio Kontroll: the same
/// request, reading and validation as a real call, without the service's quota counters (they
/// live in its own process) and without the retry, so a failure shows as it is.
pub async fn trial_call(profile: Profile, api_key: &str, mode: Mode, payload: &Value, transport: &dyn Transport,
    now: Clock<'_>, minute_budget: Option<u64>) -> Result<(Value, Normalized), RequestError> {
    let generation = fit_to_minute_budget(task_request(mode, payload, &profile), mode.task_id(), minute_budget)?;
    let provider = build_for_profile(profile, api_key, &generation).map_err(|_| RequestError::new(422, "task_configuration_invalid"))?;
    let request = UpstreamRequest { url: provider.url.clone(), headers: provider.headers.clone(), body: provider.body.to_string() };
    let spent = Spent::default();
    let call = async {
        let response = transport.send(request).await.map_err(|_| RequestError::new(502, "provider_transport"))?;
        read_upstream(response, &provider.profile, now(), &spent).await.map_err(|failure| match failure {
            Failure::Request(error) => error,
            Failure::Unclassified => RequestError::new(502, "provider_infrastructure"),
        })
    };
    let normalized = tokio::time::timeout(Duration::from_secs(40), call).await.map_err(|_| RequestError::new(504, "upstream_timeout"))??;
    let result = validate_task_result(mode, normalized.text.as_deref().unwrap_or(""), payload).map_err(|code| RequestError::new(502, code))?;
    Ok((result, normalized))
}

pub struct Generated {
    pub result: Value,
    pub normalized: Normalized,
    pub prompt_version: &'static str,
    /// The effective configuration of the task that ran.
    pub config: Config,
}

pub type Reserve<'a> = &'a mut (dyn FnMut() -> Result<(), RequestError> + Send);
pub type Clock<'a> = &'a (dyn Fn() -> i64 + Send + Sync);

/// The task's request, with the answer budget its profile needs (`config::output_limit`: a
/// lesson on a reasoning profile gets room for the thinking; everything else is unchanged).
fn task_request(mode: Mode, payload: &Value, profile: &Profile) -> Generation {
    let mut generation = create_task_request(mode, payload);
    generation.max_output_tokens = crate::config::output_limit(mode.task_id(), profile, generation.max_output_tokens);
    generation
}

/// `spent` collects the tokens of every provider answer, including ones that end in an error.
#[allow(clippy::too_many_arguments)]
pub async fn execute_generation(config: &Config, mode: Mode, payload: &Value, transport: &dyn Transport,
    reserve: Reserve<'_>, now: Clock<'_>, spent: &Spent) -> Result<Generated, RequestError> {
    let started = Instant::now();
    let limit = Duration::from_millis(config.upstream_timeout_ms);
    let expired = RequestError::new(504, "upstream_timeout");
    match tokio::time::timeout(limit, run(config, mode, payload, transport, reserve, now, started, limit, spent)).await {
        Err(_) => Err(expired),
        Ok(Ok(generated)) => Ok(generated),
        Ok(Err(Failure::Request(error))) if error.code == "budget_store_failed" => Err(error),
        Ok(Err(_)) if started.elapsed() >= limit => Err(expired),
        Ok(Err(Failure::Request(error))) => Err(error),
        Ok(Err(Failure::Unclassified)) => Err(RequestError::new(502, "provider_infrastructure")),
    }
}

#[allow(clippy::too_many_arguments)]
async fn run(config: &Config, mode: Mode, payload: &Value, transport: &dyn Transport, reserve: Reserve<'_>,
    now: Clock<'_>, started: Instant, limit: Duration, spent: &Spent) -> Result<Generated, Failure> {
    let ensure_current = || if started.elapsed() >= limit { Err(RequestError::new(504, "upstream_timeout")) } else { Ok(()) };
    ensure_current()?;
    let task_id = mode.task_id();
    let invalid_task = RequestError::new(422, "task_configuration_invalid");
    let Some(selected) = resolve_task_profile(config, task_id).config else { return Err(invalid_task.into()) };
    let profile = crate::config::profile(&selected).map_err(|_| invalid_task.clone())?;
    let generation = fit_to_minute_budget(task_request(mode, payload, &profile), task_id, config.minute_budget(&selected.provider))?;
    // Options and immutable policy must be checked before consuming shared quota.
    let provider = build_provider_request(&selected, &generation).map_err(|_| invalid_task)?;
    let body = provider.body.to_string();
    ensure_current()?;
    reserve()?;
    ensure_current()?;
    let attempt = async || -> Result<Normalized, Failure> {
        let request = UpstreamRequest { url: provider.url.clone(), headers: provider.headers.clone(), body: body.clone() };
        let response = transport.send(request).await.map_err(|_| RequestError::new(502, "provider_transport"))?;
        read_upstream(response, &provider.profile, now(), spent).await
    };
    // One retry with the identical request (user decision 2026-11-15): after a short wait the
    // provider named, or a brief pause after a provider/network failure. Never a second retry,
    // never another model or other parameters, and only while the call's own deadline allows it.
    let mut retried = false;
    let normalized = loop {
        let failure = match attempt().await {
            Ok(normalized) => break normalized,
            Err(failure) => failure,
        };
        let delay = if retried { None } else { retry_delay(&failure, config) };
        let remaining = limit.as_secs_f64() * 1_000.0 - started.elapsed().as_secs_f64() * 1_000.0;
        match delay {
            Some(delay) if remaining >= delay as f64 + limit.as_secs_f64() * 200.0 => {
                tokio::time::sleep(Duration::from_millis(delay)).await;
                retried = true;
            }
            _ => return Err(failure),
        }
    };
    ensure_current()?;
    let text = normalized.text.as_deref().unwrap_or("");
    let result = validate_task_result(mode, text, payload).map_err(|code| RequestError::new(502, code))?;
    ensure_current()?;
    Ok(Generated { result, normalized, prompt_version: generation.prompt_version, config: selected })
}

/// Response headers describing the generation: identifiers and token counts only, and only
/// when they are neither URLs nor shaped like credentials.
pub fn generation_metadata_headers(normalized: &Normalized) -> Vec<(&'static str, String)> {
    let safe = |value: &str, extra: &str, max: usize| (1..=max).contains(&value.len()) && ascii_alphanumeric_or(value, extra)
        && !value.contains("://") && !credential_shaped(value);
    let mut headers = Vec::new();
    if let Some(model) = normalized.returned_model.as_deref().filter(|model| safe(model, "._:/-", 150)) {
        headers.push(("X-Mio-Returned-Model", model.to_owned()));
    }
    let request_id = normalized.provenance.as_ref().and_then(|provenance| provenance.request_id.as_deref());
    if let Some(id) = request_id.filter(|id| safe(id, "._:-", 128)) {
        headers.push(("X-Mio-Upstream-Request-ID", id.to_owned()));
    }
    let usage = normalized.usage.clone().unwrap_or_default();
    for (name, value) in [("X-Mio-Usage-Input-Tokens", usage.input_tokens), ("X-Mio-Usage-Output-Tokens", usage.output_tokens),
        ("X-Mio-Usage-Reasoning-Tokens", usage.reasoning_tokens)] {
        if let Some(count) = value.filter(|count| (0..=1_000_000_000).contains(count)) {
            headers.push((name, count.to_string()));
        }
    }
    headers
}
