//! Server configuration from the environment. Limits can be lowered, never raised past Mio's own.

use std::collections::BTreeMap;

use serde_json::Value;

use crate::js::{ascii_alphanumeric_or, trim};
use crate::model_profiles::PROVIDERS;

pub const MAX_REQUESTS_PER_DAY: u64 = 1_000_000;
pub const MAX_TOKENS_PER_DAY: u64 = 1_000_000;

#[derive(Clone, PartialEq)]
pub struct Config {
    pub provider: String,
    pub api_key: String,
    pub provider_secrets: BTreeMap<String, String>,
    /// Per-task overrides: a JSON object, or a string holding one (`MIO_AI_TASK_PROFILES`).
    pub task_profiles: Option<Value>,
    pub adapter_options: Option<Value>,
    pub lesson_interval_seconds: Option<u64>,
    pub gateway_token: String,
    pub model: String,
    pub port: u16,
    pub requests_per_minute: u64,
    /// `None` means no per-minute sizing (paid plan). Applies to Groq, whose free tier counts
    /// prompt plus reserved answer per minute.
    pub tokens_per_minute: Option<u64>,
    /// The same budget for other providers (`MIO_TOKENS_PER_MINUTE_<PROVIDER>`); absent means none.
    pub provider_tokens_per_minute: BTreeMap<String, u64>,
    /// `None` means no local daily cap. The per-minute cap, the concurrency limit and the
    /// provider's own limits still apply (user decision 2026-10-05).
    pub requests_per_day: Option<u64>,
    pub tokens_per_day: Option<u64>,
    pub upstream_timeout_ms: u64,
    pub body_timeout_ms: u64,
    pub retry_delay_ms: Option<u64>,
    /// Set when the environment could not be parsed; every task then reports the same fixed error.
    pub global_configuration_invalid: bool,
}

impl Config {
    /// The per-minute token budget for requests to `provider`.
    pub fn minute_budget(&self, provider: &str) -> Option<u64> {
        if provider == "groq" { self.tokens_per_minute } else { self.provider_tokens_per_minute.get(provider).copied() }
    }
}

impl Default for Config {
    fn default() -> Self {
        Self { provider: "groq".to_owned(), api_key: String::new(), provider_secrets: BTreeMap::new(),
            task_profiles: None, adapter_options: None, lesson_interval_seconds: None,
            gateway_token: String::new(), model: String::new(), port: 8_787, requests_per_minute: 10,
            tokens_per_minute: None, provider_tokens_per_minute: BTreeMap::new(), requests_per_day: None, tokens_per_day: None,
            upstream_timeout_ms: 40_000, body_timeout_ms: 5_000, retry_delay_ms: None,
            global_configuration_invalid: false }
    }
}

/// Credentials never reach a log or a panic message through `{:?}`.
impl std::fmt::Debug for Config {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("Config").field("provider", &self.provider).field("model", &self.model)
            .field("port", &self.port).field("requests_per_minute", &self.requests_per_minute)
            .field("tokens_per_minute", &self.tokens_per_minute).field("requests_per_day", &self.requests_per_day)
            .field("tokens_per_day", &self.tokens_per_day).finish_non_exhaustive()
    }
}

/// A Swedish message for the operator. It never contains a configured value.
#[derive(Debug, Clone, PartialEq)]
pub struct ConfigError(pub &'static str);

impl std::fmt::Display for ConfigError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.0)
    }
}

impl std::error::Error for ConfigError {}

/// Starts like a provider API key, in any case: the phone refuses such a token so a pasted Groq
/// or other key never ends up on it (`MioPairingPayload.isValidToken`; ultrareview D1).
pub fn looks_like_provider_key(token: &str) -> bool {
    let start = token.get(..4).unwrap_or(token).to_ascii_lowercase();
    ["sk-", "sk_", "gsk_", "aiza"].iter().any(|prefix| start.starts_with(prefix))
}

pub fn is_gateway_token(token: &str) -> bool {
    (32..=256).contains(&token.len()) && ascii_alphanumeric_or(token, "_-") && !looks_like_provider_key(token)
}

fn positive_integer(value: Option<&str>, fallback: u64, maximum: u64) -> Result<u64, ConfigError> {
    let Some(value) = value.filter(|value| !value.is_empty()) else { return Ok(fallback) };
    let digits = trim(value);
    let digits = digits.strip_prefix('+').unwrap_or(digits);
    let parsed = if !digits.is_empty() && digits.len() <= 15 && digits.bytes().all(|byte| byte.is_ascii_digit()) {
        digits.parse::<u64>().ok()
    } else {
        None
    };
    parsed.filter(|parsed| (1..=maximum).contains(parsed)).ok_or(ConfigError("Ogiltig numerisk serverinställning."))
}

/// Unset, empty or `0` means no limit.
fn optional_limit(value: Option<&str>, maximum: u64) -> Result<Option<u64>, ConfigError> {
    match value {
        None | Some("" | "0") => Ok(None),
        Some(_) => positive_integer(value, 0, maximum).map(Some),
    }
}

pub fn load_config(env: &dyn Fn(&str) -> Option<String>) -> Result<Config, ConfigError> {
    let provider = env("MIO_AI_PROVIDER").unwrap_or_else(|| "groq".to_owned());
    let provider_secrets: BTreeMap<String, String> = PROVIDERS.iter()
        .map(|entry| (entry.id.to_owned(), env(entry.secret_variable).unwrap_or_default())).collect();
    let tokens_per_minute = env("MIO_TOKENS_PER_MINUTE");
    let config = Config {
        api_key: provider_secrets.get(&provider).cloned().unwrap_or_default(),
        provider, provider_secrets,
        task_profiles: env("MIO_AI_TASK_PROFILES").map(Value::String),
        adapter_options: None,
        lesson_interval_seconds: Some(positive_integer(env("MIO_LESSON_INTERVAL_SECONDS").as_deref(), 60, 3_600)?),
        gateway_token: env("MIO_GATEWAY_TOKEN").unwrap_or_default(),
        model: env("MIO_AI_MODEL").unwrap_or_default(),
        port: positive_integer(env("PORT").as_deref(), 8_787, 65_535)? as u16,
        // Groq's free tier allows 30 requests and 8,000 tokens per minute. The token budget is what
        // binds, and each request is sized against it, so the request cap only stops a runaway client.
        requests_per_minute: positive_integer(env("MIO_REQUESTS_PER_MINUTE").as_deref(), 10, 60)?,
        tokens_per_minute: match tokens_per_minute {
            None => Some(8_000),
            Some(value) => optional_limit(Some(&value), MAX_TOKENS_PER_DAY)?,
        },
        provider_tokens_per_minute: PROVIDERS.iter().filter(|entry| entry.id != "groq")
            .map(|entry| Ok((entry.id.to_owned(), optional_limit(env(&format!("MIO_TOKENS_PER_MINUTE_{}", entry.id.to_uppercase())).as_deref(), MAX_TOKENS_PER_DAY)?)))
            .collect::<Result<Vec<_>, ConfigError>>()?.into_iter()
            .filter_map(|(id, limit)| limit.map(|limit| (id, limit))).collect(),
        requests_per_day: optional_limit(env("MIO_REQUESTS_PER_DAY").as_deref(), MAX_REQUESTS_PER_DAY)?,
        tokens_per_day: optional_limit(env("MIO_TOKENS_PER_DAY").as_deref(), MAX_TOKENS_PER_DAY)?,
        upstream_timeout_ms: 40_000,
        body_timeout_ms: 5_000,
        retry_delay_ms: None,
        global_configuration_invalid: false,
    };
    validate_config(&config)?;
    Ok(config)
}

pub fn validate_config(config: &Config) -> Result<(), ConfigError> {
    // Generation configuration belongs to each task profile. An unavailable task
    // must not prevent protected model-free discovery or unrelated configured tasks.
    if !is_gateway_token(&config.gateway_token) {
        return Err(ConfigError("Konfigurera en separat MIO_GATEWAY_TOKEN."));
    }
    if config.lesson_interval_seconds.is_some_and(|seconds| !(60..=3_600).contains(&seconds)) {
        return Err(ConfigError("Lektionsintervallet måste vara 60–3600 sekunder."));
    }
    if config.requests_per_minute > 60 || config.upstream_timeout_ms > 40_000 || config.body_timeout_ms > 5_000 {
        return Err(ConfigError("Servergränserna får inte höja Mios minutkvot eller tidsgränser."));
    }
    if config.requests_per_day.is_some_and(|limit| !(1..=MAX_REQUESTS_PER_DAY).contains(&limit)) {
        return Err(ConfigError("Ogiltig dagsgräns."));
    }
    if config.tokens_per_day.is_some_and(|limit| !(1..=MAX_TOKENS_PER_DAY).contains(&limit)) {
        return Err(ConfigError("Ogiltig tokengräns."));
    }
    if config.tokens_per_minute.into_iter().chain(config.provider_tokens_per_minute.values().copied())
        .any(|limit| !(2_000..=MAX_TOKENS_PER_DAY).contains(&limit)) {
        return Err(ConfigError("Ogiltig tokengräns per minut."));
    }
    if config.retry_delay_ms.is_some_and(|delay| delay > 5_000) {
        return Err(ConfigError("Ogiltig väntetid före nytt försök."));
    }
    if config.requests_per_minute < 1 || config.upstream_timeout_ms < 1 || config.body_timeout_ms < 1 {
        return Err(ConfigError("Ogiltig servergräns."));
    }
    Ok(())
}
