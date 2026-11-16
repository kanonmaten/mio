//! The provider wire: building the one request shape Mio allows and reducing any answer or
//! error to fixed, safe values. Arbitrary provider text never leaves this module.

use serde_json::{Map, Value, json};

use crate::config::Config;
use crate::js::{ascii_alphanumeric_or, credential_shaped, exact_keys, get, has_length, is_blank, safe_integer, trim, truthy};
use crate::model_profiles::{Incompatible, Profile, provider_profile};
use crate::time::http_date_ms;

#[derive(Debug, Clone, PartialEq)]
pub struct Message {
    pub role: String,
    pub content: String,
}

/// The fixed generation policy. The adapter refuses anything else instead of weakening it.
#[derive(Debug, Clone, PartialEq)]
pub struct Policy {
    pub reasoning: String,
    pub temperature: f64,
    pub tools: String,
}

impl Default for Policy {
    fn default() -> Self {
        Self { reasoning: "off".to_owned(), temperature: 0.0, tools: "none".to_owned() }
    }
}

/// A provider-neutral generation request: no task knowledge, no credentials.
#[derive(Debug, Clone, PartialEq)]
pub struct Generation {
    pub messages: Vec<Message>,
    pub structured_output: Value,
    pub max_output_tokens: u64,
    pub policy: Policy,
    pub prompt_version: &'static str,
}

#[derive(Clone, PartialEq)]
pub struct ProviderRequest {
    pub url: String,
    pub profile: Profile,
    /// `Authorization: Bearer <provider key>`. Never logged.
    pub authorization: String,
    pub body: Value,
}

/// The provider key never reaches a log or a panic message through `{:?}`.
impl std::fmt::Debug for ProviderRequest {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("ProviderRequest").field("url", &self.url).field("body", &self.body).finish_non_exhaustive()
    }
}

const SCHEMA_KEYWORDS: [&str; 7] = ["type", "properties", "required", "additionalProperties", "items", "enum", "description"];
const SCHEMA_TYPES: [&str; 7] = ["object", "array", "string", "number", "integer", "boolean", "null"];

fn ensure(condition: bool) -> Result<(), Incompatible> {
    if condition { Ok(()) } else { Err(Incompatible::Options) }
}

/// The reviewed schema subset used by the current text contract. Extensions are rejected
/// locally instead of deleting keywords or relying on SDK transforms.
fn validate_schema(schema: Option<&Value>, depth: usize) -> Result<(), Incompatible> {
    let map = schema.and_then(Value::as_object).ok_or(Incompatible::Options)?;
    ensure(depth <= 20 && map.keys().all(|key| SCHEMA_KEYWORDS.contains(&key.as_str())))?;
    let types: Vec<&Value> = match map.get("type") {
        Some(Value::Array(types)) => types.iter().collect(),
        Some(single) => vec![single],
        None => Vec::new(),
    };
    let names: Vec<&str> = types.iter().filter_map(|value| value.as_str()).collect();
    ensure(!types.is_empty() && names.len() == types.len() && names.iter().all(|name| SCHEMA_TYPES.contains(name))
        && names.iter().enumerate().all(|(index, name)| !names[..index].contains(name)))?;
    ensure(map.get("description").is_none_or(Value::is_string))?;
    if let Some(values) = map.get("enum") {
        let values = values.as_array().ok_or(Incompatible::Options)?;
        ensure(!values.is_empty() && values.iter().all(|value| !value.is_array() && !value.is_object()))?;
    }
    if names.contains(&"object") {
        let properties = map.get("properties").and_then(Value::as_object).ok_or(Incompatible::Options)?;
        let required = map.get("required").and_then(Value::as_array).ok_or(Incompatible::Options)?;
        let required: Vec<&str> = required.iter().map(|key| key.as_str().ok_or(Incompatible::Options)).collect::<Result<_, _>>()?;
        ensure(map.get("additionalProperties") == Some(&Value::Bool(false)) && required.len() == properties.len()
            && required.iter().enumerate().all(|(index, key)| !required[..index].contains(key) && properties.contains_key(*key)))?;
        for value in properties.values() {
            validate_schema(Some(value), depth + 1)?;
        }
    } else {
        ensure(!["properties", "required", "additionalProperties"].iter().any(|key| map.contains_key(*key)))?;
    }
    if names.contains(&"array") {
        validate_schema(map.get("items"), depth + 1)
    } else {
        ensure(!map.contains_key("items"))
    }
}

fn is_format_name(name: &str) -> bool {
    (1..=64).contains(&name.len()) && ascii_alphanumeric_or(name, "_-")
}

fn validate_generation(generation: &Generation) -> Result<(), Incompatible> {
    let policy = &generation.policy;
    ensure(policy.reasoning == "off" && policy.temperature == 0.0 && policy.tools == "none"
        && (1..=65_536).contains(&generation.max_output_tokens) && !generation.messages.is_empty())?;
    let mut ordinary = false;
    for message in &generation.messages {
        ensure(["system", "user", "assistant"].contains(&message.role.as_str()) && !is_blank(&message.content))?;
        // System messages come first; none may follow a user or assistant message.
        ensure(message.role != "system" || !ordinary)?;
        ordinary |= message.role != "system";
    }
    ensure(ordinary)?;
    let format = exact_keys(&generation.structured_output, &["type", "name", "strict", "schema"]).ok_or(Incompatible::Options)?;
    ensure(format["type"] == "json_schema" && format["strict"] == true
        && format["name"].as_str().is_some_and(is_format_name)
        && get(&format["schema"], "type").is_some_and(|kind| kind == "object"))?;
    validate_schema(format.get("schema"), 0)
}

pub fn build_provider_request(config: &Config, generation: &Generation) -> Result<ProviderRequest, Incompatible> {
    let profile = provider_profile(&config.provider, &config.model, config.adapter_options.as_ref())?;
    validate_generation(generation)?;
    ensure(profile.wire == "chat")?;
    let mut json_schema = generation.structured_output.as_object().cloned().unwrap_or_default();
    let kind = json_schema.shift_remove("type").unwrap_or(Value::Null);
    let mut body = Map::new();
    body.insert("model".to_owned(), json!(profile.requested_model));
    body.insert("temperature".to_owned(), json!(0));
    body.insert("max_tokens".to_owned(), json!(generation.max_output_tokens));
    body.insert("stream".to_owned(), json!(false));
    // Reasoning must be off, not hidden; responses that still carry reasoning are rejected below.
    if !profile.plain {
        body.insert("reasoning_effort".to_owned(), json!("none"));
    }
    body.insert("response_format".to_owned(), json!({ "type": kind, "json_schema": json_schema }));
    body.insert("messages".to_owned(), generation.messages.iter()
        .map(|message| json!({ "role": message.role, "content": message.content })).collect());
    Ok(ProviderRequest { url: format!("{}/chat/completions", profile.base),
        authorization: format!("Bearer {}", config.api_key), profile, body: Value::Object(body) })
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Finish {
    Completed,
    Refused,
    Truncated,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Usage {
    pub input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
    pub total_tokens: Option<i64>,
    pub reasoning_tokens: Option<i64>,
    pub cached_input_tokens: Option<i64>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Provenance {
    pub response_id: Option<String>,
    pub request_id: Option<String>,
}

/// What Mio keeps of a provider answer: the text, why it ended, and bounded numeric metadata.
#[derive(Debug, Clone, PartialEq)]
pub struct Normalized {
    pub text: Option<String>,
    pub finish: Finish,
    pub refusal: bool,
    pub requested_model: String,
    pub returned_model: Option<String>,
    pub usage: Option<Usage>,
    pub provenance: Option<Provenance>,
}

/// `provider_invalid_response` or `provider_parameters`; never provider text.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ResponseError(pub &'static str);

const INVALID: ResponseError = ResponseError("provider_invalid_response");
const REASONING: ResponseError = ResponseError("provider_parameters");

fn safe_id(value: Option<&Value>, model: bool) -> Option<String> {
    let id = value?.as_str()?;
    let mut characters = id.chars();
    let extra = if model { "._:/-" } else { "._:-" };
    (id.len() <= 128 && characters.next().is_some_and(|first| first.is_ascii_alphanumeric())
        && characters.all(|character| character.is_ascii_alphanumeric() || extra.contains(character))
        && !id.contains("://") && !credential_shaped(id)).then(|| id.to_owned())
}

fn token_count(value: Option<&Value>) -> Option<i64> {
    safe_integer(value?).filter(|count| (0..=1_000_000_000).contains(count))
}

pub type HeaderLookup<'a> = &'a dyn Fn(&str) -> Option<String>;

pub fn normalize_provider_response(data: &Value, profile: &Profile, headers: HeaderLookup) -> Result<Normalized, ResponseError> {
    let envelope = data.as_object().ok_or(INVALID)?;
    let usage = envelope.get("usage");
    let detail = |outer: &str, inner: &str| usage.and_then(|usage| get(usage, outer)).and_then(|details| get(details, inner));
    // Hiding reasoning text does not satisfy an explicit reasoning-off contract.
    for value in [detail("output_tokens_details", "reasoning_tokens"), detail("completion_tokens_details", "reasoning_tokens")] {
        if value.and_then(Value::as_f64).is_some_and(|tokens| tokens > 0.0) {
            return Err(REASONING);
        }
    }
    if profile.wire != "chat" {
        return Err(INVALID);
    }
    let choices = envelope.get("choices").and_then(Value::as_array).filter(|choices| choices.len() == 1).ok_or(INVALID)?;
    let choice = &choices[0];
    let message = get(choice, "message").and_then(Value::as_object).ok_or(INVALID)?;
    if message.get("role").is_none_or(|role| role != "assistant") || has_length(message.get("tool_calls"))
        || message.get("function_call").is_some_and(truthy) {
        return Err(INVALID);
    }
    if message.get("reasoning").is_some_and(truthy) || message.get("reasoning_content").is_some_and(truthy)
        || has_length(message.get("reasoning_details")) {
        return Err(REASONING);
    }
    let reason = get(choice, "finish_reason").and_then(Value::as_str);
    let finish = if message.get("refusal").is_some_and(truthy) || reason == Some("content_filter") { Finish::Refused }
        else if reason == Some("length") { Finish::Truncated }
        else if reason == Some("stop") { Finish::Completed }
        else { return Err(INVALID) };
    let text = if finish == Finish::Completed {
        let content = message.get("content").and_then(Value::as_str).ok_or(INVALID)?;
        if is_blank(content) || content.len() > 24_000 {
            return Err(INVALID);
        }
        Some(content.to_owned())
    } else {
        None
    };
    let usage = Usage {
        input_tokens: token_count(usage.and_then(|usage| get(usage, "prompt_tokens"))),
        output_tokens: token_count(usage.and_then(|usage| get(usage, "completion_tokens"))),
        total_tokens: token_count(usage.and_then(|usage| get(usage, "total_tokens"))),
        reasoning_tokens: token_count(detail("completion_tokens_details", "reasoning_tokens")),
        cached_input_tokens: token_count(detail("prompt_tokens_details", "cached_tokens")),
    };
    let request_id = headers("x-request-id").or_else(|| headers("request-id")).map(Value::String);
    let provenance = Provenance { response_id: safe_id(envelope.get("id"), false), request_id: safe_id(request_id.as_ref(), false) };
    Ok(Normalized { text, finish, refusal: finish == Finish::Refused, requested_model: profile.requested_model.clone(),
        returned_model: safe_id(envelope.get("model"), true),
        usage: (usage != Usage::default()).then_some(usage),
        provenance: (provenance != Provenance::default()).then_some(provenance) })
}

#[derive(Debug, Clone, PartialEq)]
pub struct ProviderError {
    pub category: &'static str,
    /// Seconds the provider asked the client to wait, bounded to one hour.
    pub retry_after: Option<u64>,
}

pub fn normalize_provider_error(status: u16, data: Option<&Value>, retry_after: Option<&str>, now_ms: i64) -> ProviderError {
    let error = data.and_then(|data| get(data, "error"));
    let code = ["code", "type", "status"].iter()
        .find_map(|key| error.and_then(|error| get(error, key)).filter(|value| !value.is_null()))
        .and_then(Value::as_str).unwrap_or("");
    let category = if status == 401 || ["authentication_error", "invalid_api_key", "UNAUTHENTICATED"].contains(&code) {
        "provider_authentication"
    // Exhausted billing is an account problem, not a temporary quota; retrying cannot help.
    } else if [402, 403].contains(&status) || ["permission_error", "billing_hard_limit_reached", "insufficient_quota", "PERMISSION_DENIED"].contains(&code) {
        "provider_account"
    // Groq answers 413 (code rate_limit_exceeded) when prompt + max_tokens of ONE request exceed the
    // per-minute token budget. Waiting never helps; the request must get smaller (2026-11-15).
    } else if status == 413 {
        "provider_request_too_large"
    } else if status == 404 || ["model_not_found", "model_not_available", "not_found_error", "NOT_FOUND"].contains(&code) {
        "provider_model_unavailable"
    } else if status == 429 || ["rate_limit_error", "rate_limit_exceeded", "RESOURCE_EXHAUSTED"].contains(&code) {
        "provider_quota"
    } else if [400, 422].contains(&status) || ["invalid_request_error", "unsupported_parameter"].contains(&code) {
        "provider_parameters"
    } else {
        "provider_infrastructure"
    };
    ProviderError { category, retry_after: retry_after.and_then(|value| parse_retry_after(value, now_ms)) }
}

/// Bounded seconds from `Retry-After`: a number of seconds or an HTTP date. Anything else is dropped.
fn parse_retry_after(value: &str, now_ms: i64) -> Option<u64> {
    let seconds = trim(value);
    let (whole, fraction) = seconds.split_once('.').unwrap_or((seconds, "0"));
    let digits = |part: &str, max: usize| (1..=max).contains(&part.len()) && part.bytes().all(|byte| byte.is_ascii_digit());
    if digits(whole, 12) && digits(fraction, 6) && !seconds.ends_with('.') {
        return Some((seconds.parse::<f64>().ok()?.ceil() as u64).min(3_600));
    }
    let date = http_date_ms(value)?;
    Some((((date - now_ms) as f64 / 1_000.0).ceil() as i64).clamp(0, 3_600) as u64)
}
