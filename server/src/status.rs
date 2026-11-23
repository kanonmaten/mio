//! Model-free discovery: what is configured, with which limits, and a revision of that
//! configuration. Credentials and endpoints never appear here.

use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use crate::config::{Config, ConfigError, is_gateway_token};
use crate::js::ascii_alphanumeric_or;
use crate::model_profiles::provider;
use crate::prompts::{ANALYSIS_V2_PROMPT_VERSION, PROMPT_VERSION};
use crate::task_profiles::{TASK_IDS, resolve_task_profile, safe_model_identifier, safe_provider_identifier, task_configuration_identifiers};
use crate::time::is_utc_midnight;

pub const RELEASE: &str = "2026-11-15.1";

fn published_provider(id: &str) -> &str {
    if provider(id).is_some() { id } else { "" }
}

fn status_body(configured: bool, provider: &str, model: &str) -> Value {
    json!({ "protocolVersion": 2, "release": RELEASE, "configured": configured,
        "provider": published_provider(provider), "model": model, "promptVersion": ANALYSIS_V2_PROMPT_VERSION,
        "capabilities": ["analysis-context-v2", "ask-v1", "analysis-v1", "lesson-notes-v1"] })
}

/// Older clients only call `/v1/analyze`, so v1 status describes the effective everyday task.
pub fn gateway_status(config: &Config) -> Value {
    let (provider, model) = task_configuration_identifiers(config, "everyday");
    status_body(resolve_task_profile(config, "everyday").configured, &provider, &model)
}

type Environment<'a> = &'a dyn Fn(&str) -> Option<String>;

fn unparsed(env: Environment) -> Config {
    Config { provider: env("MIO_AI_PROVIDER").unwrap_or_else(|| "groq".to_owned()),
        model: env("MIO_AI_MODEL").unwrap_or_default(), task_profiles: env("MIO_AI_TASK_PROFILES").map(Value::String),
        global_configuration_invalid: true, ..Config::default() }
}

/// Status for an environment that may not parse: safe metadata, `configured: false`.
pub fn status_from_environment(env: Environment, parsed: &Result<Config, ConfigError>) -> Value {
    match parsed {
        Ok(config) => gateway_status(config),
        Err(_) => {
            let fallback = unparsed(env);
            status_body(false, &fallback.provider, safe_model_identifier(&fallback.model))
        }
    }
}

pub fn status_v2_from_environment(env: Environment, parsed: &Result<Config, ConfigError>, quota: Option<&QuotaObservation>) -> Value {
    match parsed {
        Ok(config) => gateway_status_v2(config, quota),
        Err(_) => gateway_status_v2(&unparsed(env), None),
    }
}

fn sha256(data: &[u8]) -> [u8; 32] {
    Sha256::digest(data).into()
}

/// Compares digests, so neither length nor content of the token shapes the timing.
pub fn authenticated(supplied: Option<&str>, token: &str) -> bool {
    let Some(supplied) = supplied.filter(|supplied| supplied.len() <= 263) else { return false };
    if !is_gateway_token(token) {
        return false;
    }
    let (left, right) = (sha256(supplied.as_bytes()), sha256(format!("Bearer {token}").as_bytes()));
    left.iter().zip(right).fold(0u8, |difference, (a, b)| difference | (a ^ b)) == 0
}

fn random_uuid() -> String {
    let mut bytes = [0u8; 16];
    // A request ID is a correlation label, not a secret; an unavailable generator must not stop a reply.
    let _ = getrandom::fill(&mut bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    format!("{}-{}-{}-{}-{}", &hex[..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..])
}

pub fn is_revision(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

pub fn metadata_headers(provider: &str, model: &str, prompt_version: &str, revision: Option<&str>) -> Vec<(&'static str, String)> {
    let version = if (1..=80).contains(&prompt_version.len()) && ascii_alphanumeric_or(prompt_version, "._-") { prompt_version } else { "" };
    let mut headers = vec![("X-Mio-Release", RELEASE.to_owned()),
        ("X-Mio-Provider", safe_provider_identifier(provider).to_owned()),
        ("X-Mio-Model", safe_model_identifier(model).to_owned()),
        ("X-Mio-Prompt-Version", version.to_owned()), ("X-Mio-Request-ID", random_uuid())];
    if let Some(revision) = revision.filter(|revision| is_revision(revision)) {
        headers.push(("X-Mio-Configuration-Revision", revision.to_owned()));
    }
    headers
}

fn task_prompt_version(task: &str) -> &'static str {
    if task == "everyday" { ANALYSIS_V2_PROMPT_VERSION } else { PROMPT_VERSION }
}

/// A backlog batch (twelve sources, 16,000 bytes) cannot fit an 8,000-token minute, so it is
/// offered only without per-minute sizing or with a budget that holds it.
/// The budget is the everyday provider's: another known provider's own
/// (`MIO_TOKENS_PER_MINUTE_<PROVIDER>`, none by default for Mistral), otherwise Groq's
/// `MIO_TOKENS_PER_MINUTE` exactly as before, so a Groq configuration's revision is unchanged.
pub fn accepts_backlog(config: &Config) -> bool {
    let (everyday, _) = task_configuration_identifiers(config, "everyday");
    let budget = if everyday != "groq" && provider(&everyday).is_some() { config.minute_budget(&everyday) } else { config.tokens_per_minute };
    budget.is_none_or(|limit| limit >= 20_000)
}

fn task_capabilities(task: &str, config: &Config) -> Vec<&'static str> {
    let mut capabilities = vec!["reasoning-off", "temperature-zero", "strict-json"];
    match task {
        "ask" => capabilities.push("ask-v1"),
        "everyday" => {
            capabilities.push("analysis-context-v2");
            if accepts_backlog(config) {
                capabilities.push("analysis-backlog-v1");
            }
        }
        _ => capabilities.push("lesson-notes-v1"),
    }
    capabilities
}

fn positive(limit: Option<u64>) -> Option<u64> {
    limit.filter(|limit| *limit > 0)
}

fn canonical(value: &Value) -> Value {
    match value {
        Value::Array(items) => items.iter().map(canonical).collect(),
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            Value::Object(keys.into_iter().map(|key| (key.clone(), canonical(&map[key]))).collect())
        }
        other => other.clone(),
    }
}

/// A fingerprint of the public configuration. Clients send it back, and a changed
/// configuration is refused with 409 before quota and model calls. Secrets never enter it.
pub fn configuration_revision(config: &Config) -> String {
    let mut tasks = Map::new();
    for task in TASK_IDS {
        let selected = resolve_task_profile(config, task);
        let (provider, model) = task_configuration_identifiers(config, task);
        // The endpoint identity affects review even though neither it nor credentials
        // are published. Only the profile's validated credential-free base is used.
        let profile = selected.config.as_ref().and_then(|config| crate::config::profile(config).ok());
        let endpoint = profile.as_ref().map(|profile| profile.base);
        let mut entry = json!({ "provider": provider, "model": model, "configured": selected.configured,
            "configurationError": selected.configuration_error, "promptVersion": task_prompt_version(task),
            "capabilities": task_capabilities(task, config), "options": {}, "endpoint": endpoint });
        // A new lesson reasoning level is a new configuration. Only a pair that reasons carries
        // the key, so every other revision stays what it was.
        if let Some(profile) = profile.filter(|profile| profile.reasoning.reasons()) {
            entry["reasoning"] = json!(profile.reasoning.level());
        }
        tasks.insert(task.to_owned(), entry);
    }
    let public = json!({ "protocolVersion": 2, "release": RELEASE, "tasks": tasks, "limits": {
        "requestsPerMinute": config.requests_per_minute, "requestsPerDay": positive(config.requests_per_day),
        "tokensPerDay": positive(config.tokens_per_day), "tokensPerMinute": positive(config.tokens_per_minute),
        "lessonIntervalSeconds": config.lesson_interval_seconds.unwrap_or(60),
        "upstreamTimeoutMs": config.upstream_timeout_ms, "bodyTimeoutMs": config.body_timeout_ms, "concurrency": 2 } });
    sha256(canonical(&public).to_string().as_bytes()).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// What the counters say about today's quota. Values outside the limit are not reported.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct QuotaObservation {
    pub remaining: Option<i64>,
    pub reset_at: Option<String>,
}

pub fn gateway_status_v2(config: &Config, quota: Option<&QuotaObservation>) -> Value {
    let mut tasks = Map::new();
    for task in TASK_IDS {
        let selected = resolve_task_profile(config, task);
        let (provider, model) = task_configuration_identifiers(config, task);
        let mut capabilities = task_capabilities(task, config);
        // Contract after the grilling: `/v2/lesson-notes` beside v1. Published here only, not in
        // the configuration revision, so the revision of an unchanged configuration stays the
        // same across this upgrade (the recorded parity cases cover it).
        if task == "lesson" {
            capabilities.push("lesson-notes-v2");
        }
        let mut entry = json!({ "configured": selected.configured, "provider": provider, "model": model,
            "promptVersion": task_prompt_version(task), "capabilities": capabilities,
            "configurationError": selected.configuration_error });
        let profile = selected.config.as_ref().and_then(|config| crate::config::profile(config).ok());
        // A model whose provider refuses temperature, or a lesson model that reasons, runs without
        // it; that is never silent (rules approved 2026-11-17 and 2026-11-22). Absent for every
        // model that gets temperature 0.
        if profile.as_ref().is_some_and(|profile| !profile.temperature) {
            entry["temperature"] = json!("provider-default");
        }
        // Contract after the grilling (DATAMODELL.md): the reviewed reasoning level ("off" unless a
        // lesson runs on a model that always reasons) and the schema dialect, null without a
        // valid configuration. The capability list stays as older apps expect it.
        entry["reasoning"] = json!(profile.as_ref().map_or("off", |profile| profile.reasoning.level()));
        entry["schemaDialect"] = json!(profile.as_ref().map(|profile| profile.schema_dialect));
        tasks.insert(task.to_owned(), entry);
    }
    // null means no daily cap; status then reports quota as null instead of an invented limit.
    // A token cap (the binding Groq free-tier limit) takes precedence over a request cap.
    let (limit, unit) = match (positive(config.tokens_per_day), positive(config.requests_per_day)) {
        (Some(limit), _) => (Some(limit), "tokens"),
        (None, Some(limit)) => (Some(limit), "requests"),
        (None, None) => (None, ""),
    };
    let quota = limit.map(|limit| json!({ "limit": limit,
        "remaining": quota.and_then(|quota| quota.remaining).filter(|remaining| (0..=limit as i64).contains(remaining)),
        "resetAt": quota.and_then(|quota| quota.reset_at.as_deref()).filter(|reset| is_utc_midnight(reset)),
        "unit": unit }));
    json!({ "protocolVersion": 2, "release": RELEASE, "configurationRevision": configuration_revision(config),
        "tasks": tasks, "quota": quota })
}
