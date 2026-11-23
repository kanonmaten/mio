//! Server configuration from the environment. Limits can be lowered, never raised past Mio's own.

use std::collections::BTreeMap;

use serde_json::Value;

use crate::js::{ascii_alphanumeric_or, trim};
use crate::model_profiles::{CANDIDATE_MODELS, Incompatible, PROVIDERS, Profile, REASONING_TASK, Reasoning, approved_profile, pair_reasoning, reasoning_levels};

pub const MAX_REQUESTS_PER_DAY: u64 = 1_000_000;
pub const MAX_TOKENS_PER_DAY: u64 = 1_000_000;

/// `max_tokens` for a lesson part on a profile that reasons (Mistral Large 4, medium). The
/// thinking is billed as output and counts against `max_tokens`, so the 3,000 tokens the notes
/// themselves get on every other profile would leave little or nothing for the answer. Mistral's
/// documentation (read 2026-11-20) gives no output limit for Large 4 (1M context) and no advice
/// on `max_tokens` with reasoning, so this keeps the notes' 3,000 and adds 9,000 for thinking.
/// Mistral has no per-minute reservation like Groq's free tier, so an unused margin costs
/// nothing; a full answer costs at most 12,000 × $2.10/M ≈ $0.025. The user measures with the
/// trial (Prova) and the limit is adjusted after that. Other tasks keep their own limits.
pub const LESSON_REASONING_MAX_OUTPUT_TOKENS: u64 = 12_000;

/// The longest a whole lesson call may take on a profile that reasons (contract in
/// `docs/DATAMODELL.md`, "Tidsgräns (tillägg efter våg 2)"): up to 12,000 tokens of thinking
/// do not fit in the 40 s every other call keeps. The app waits 200 s for lesson notes, so the
/// gateway's own error (`upstream_timeout` and the rest) reaches it before the app gives up.
/// The retry rule and every other limit are unchanged; they scale with the call's limit.
pub const LESSON_REASONING_TIMEOUT_MS: u64 = 180_000;

/// The limit for a whole call of `task` on `profile`, in milliseconds: `base_ms` (40 s, or
/// lower when configured) unless a lesson runs on a profile that reasons. Keyed on the task, not
/// the route, so every lesson route gets the same limit.
pub fn call_limit_ms(task: &str, profile: &Profile, base_ms: u64) -> u64 {
    if task == REASONING_TASK && profile.reasoning.reasons() { LESSON_REASONING_TIMEOUT_MS } else { base_ms }
}

/// The answer budget for `task` on `profile`: the task's own unless the profile reasons.
pub fn output_limit(task: &str, profile: &Profile, task_limit: u64) -> u64 {
    if task == REASONING_TASK && profile.reasoning.reasons() { LESSON_REASONING_MAX_OUTPUT_TOKENS } else { task_limit }
}

/// The answer budgets the user may choose per task (`MIO_MAX_OUTPUT_TOKENS_<TASK>`, user decision
/// 2026-11-22, MIO-45), as (task, smallest, largest). The smallest is the gateway's own floor in
/// `fit_to_minute_budget`, below which a schema-valid answer does not fit. The largest is about
/// three times today's budget for ask and everyday, and for lessons what a reasoning model can
/// write within the 180 s lesson limit; the per-minute budget still shrinks any of them.
pub const OUTPUT_RANGES: [(&str, u64, u64); 3] = [("ask", 300, 4_000), ("everyday", 500, 6_000), ("lesson", 1_200, 32_000)];

/// The answer budget for `task` on `profile` with the user's choice: the chosen value when one is
/// set, otherwise `output_limit`.
pub fn answer_limit(chosen: Option<u64>, task: &str, profile: &Profile, task_limit: u64) -> u64 {
    chosen.unwrap_or_else(|| output_limit(task, profile, task_limit))
}

/// True when a pair that always reasons stands for a task other than `lesson` (user decision
/// 2026-11-19: only lessons may reason). The gateway then refuses to start.
pub fn reasoning_outside_lesson(config: &Config) -> bool {
    crate::task_profiles::TASK_IDS.iter().filter(|task| **task != REASONING_TASK).any(|task| {
        let (provider, model) = crate::task_profiles::task_configuration_identifiers(config, task);
        pair_reasoning(&provider, &model).is_some_and(|reasoning| reasoning.reasons())
    })
}

#[derive(Clone, PartialEq)]
pub struct Config {
    pub provider: String,
    pub api_key: String,
    pub provider_secrets: BTreeMap<String, String>,
    /// Per-task overrides: a JSON object, or a string holding one (`MIO_AI_TASK_PROFILES`).
    pub task_profiles: Option<Value>,
    pub adapter_options: Option<Value>,
    pub lesson_interval_seconds: Option<u64>,
    /// The reasoning level for a lesson model that always reasons (`MIO_LESSON_REASONING`);
    /// `None` keeps the level the pair was reviewed at. Only a level reviewed for the selected
    /// pair runs: any other makes `profile` refuse, which disables only that task.
    pub lesson_reasoning: Option<String>,
    /// The chosen answer budget per task (`MIO_MAX_OUTPUT_TOKENS_<TASK>`), within `OUTPUT_RANGES`;
    /// a task missing here keeps its own budget.
    pub max_output_tokens: BTreeMap<String, u64>,
    pub gateway_token: String,
    pub model: String,
    pub port: u16,
    pub requests_per_minute: u64,
    /// `None` means no per-minute sizing (paid plan). Applies to Groq, whose free tier counts
    /// prompt plus reserved answer per minute.
    pub tokens_per_minute: Option<u64>,
    /// The same budget for other providers (`MIO_TOKENS_PER_MINUTE_<PROVIDER>`); absent means none.
    pub provider_tokens_per_minute: BTreeMap<String, u64>,
    /// Candidates the user approved after a passed `mio-gateway prova`, as `provider=model`.
    pub approved_candidates: Vec<String>,
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

/// `provider=model,provider=model`; every entry must name a known candidate.
fn approved_candidates(value: Option<&str>) -> Result<Vec<String>, ConfigError> {
    let entries: Vec<String> = value.unwrap_or("").split(',').map(|entry| trim(entry).to_owned()).filter(|entry| !entry.is_empty()).collect();
    let known = |entry: &String| CANDIDATE_MODELS.iter().any(|candidate| *entry == format!("{}={}", candidate.provider, candidate.model));
    if entries.iter().all(known) { Ok(entries) } else { Err(ConfigError("Ogiltig godkänd kandidatmodell.")) }
}

/// `low`, `medium` or `high`; empty or absent means the pair's reviewed level.
fn lesson_reasoning(value: Option<&str>) -> Result<Option<String>, ConfigError> {
    match value.map(trim).filter(|value| !value.is_empty()) {
        None => Ok(None),
        Some(level) if ["low", "medium", "high"].contains(&level) => Ok(Some(level.to_owned())),
        Some(_) => Err(ConfigError("Ogiltig resonemangsnivå för lektioner (low, medium eller high).")),
    }
}

/// The profile for a config's provider and model, honouring approved candidates.
pub fn profile(config: &Config) -> Result<Profile, Incompatible> {
    let mut profile = approved_profile(&config.provider, &config.model, config.adapter_options.as_ref(), &config.approved_candidates)?;
    // Only a pair that always reasons serves lessons alone, so the level never reaches ask or everyday.
    if let (Reasoning::Effort(_), Some(level)) = (profile.reasoning, config.lesson_reasoning.as_deref()) {
        let chosen = reasoning_levels(&config.provider, &config.model).iter().find(|each| **each == level).ok_or(Incompatible::Options)?;
        profile.reasoning = Reasoning::Effort(chosen);
    }
    Ok(profile)
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
            task_profiles: None, adapter_options: None, lesson_interval_seconds: None, lesson_reasoning: None, max_output_tokens: BTreeMap::new(),
            gateway_token: String::new(), model: String::new(), port: 8_787, requests_per_minute: 10,
            tokens_per_minute: None, provider_tokens_per_minute: BTreeMap::new(), approved_candidates: Vec::new(), requests_per_day: None, tokens_per_day: None,
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
/// `MIO_MAX_OUTPUT_TOKENS_<TASK>`: empty or absent keeps the task's own budget. Unlike the other
/// limits, 0 is not "no limit" but an error, as is anything outside `OUTPUT_RANGES`; the message
/// names the key.
fn answer_budgets(env: &dyn Fn(&str) -> Option<String>) -> Result<BTreeMap<String, u64>, ConfigError> {
    let mut budgets = BTreeMap::new();
    for (task, smallest, largest) in OUTPUT_RANGES {
        let error = ConfigError(match task {
            "ask" => "Ogiltig MIO_MAX_OUTPUT_TOKENS_ASK (300–4000 token, eller tom).",
            "everyday" => "Ogiltig MIO_MAX_OUTPUT_TOKENS_EVERYDAY (500–6000 token, eller tom).",
            _ => "Ogiltig MIO_MAX_OUTPUT_TOKENS_LESSON (1200–32000 token, eller tom).",
        });
        let Some(value) = env(&format!("MIO_MAX_OUTPUT_TOKENS_{}", task.to_uppercase())).filter(|value| !trim(value).is_empty()) else { continue };
        let limit = trim(&value).parse::<u64>().ok().filter(|limit| (smallest..=largest).contains(limit)).ok_or(error)?;
        budgets.insert(task.to_owned(), limit);
    }
    Ok(budgets)
}

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
        lesson_reasoning: lesson_reasoning(env("MIO_LESSON_REASONING").as_deref())?,
        max_output_tokens: answer_budgets(env)?,
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
        approved_candidates: approved_candidates(env("MIO_APPROVED_CANDIDATES").as_deref())?,
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
    if config.max_output_tokens.iter().any(|(task, limit)| !OUTPUT_RANGES.iter()
        .any(|(each, smallest, largest)| each == task && (smallest..=largest).contains(&limit))) {
        return Err(ConfigError("Ogiltig svarslängd (ask 300–4000, everyday 500–6000, lesson 1200–32000 token)."));
    }
    if reasoning_outside_lesson(config) {
        return Err(ConfigError("En modell som alltid resonerar får bara användas för lektioner (provider_options_incompatible)."));
    }
    Ok(())
}
