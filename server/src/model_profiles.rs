//! Provider seam (user decisions 2026-10-11 and 2026-11-17). Only reviewed provider and model
//! pairs run; each task uses one, chosen on the PC, with no automatic fallback. A new provider
//! means one `PROVIDERS` entry, one reviewed or candidate model with documentation sources and,
//! if its wire differs from chat completions, one adapter in `adapters.rs`. A provider prefix or
//! OpenAI-compatible URL is never proof of support.

use serde_json::Value;

use crate::js::credential_shaped;

pub struct Provider {
    pub id: &'static str,
    pub base: &'static str,
    /// Name of the environment variable that holds this provider's key.
    pub secret_variable: &'static str,
    /// `chat` (OpenAI-style chat completions) or `messages` (Anthropic's Messages API).
    pub wire: &'static str,
}

pub const PROVIDERS: [Provider; 7] = [
    Provider { id: "groq", base: "https://api.groq.com/openai/v1", secret_variable: "GROQ_API_KEY", wire: "chat" },
    Provider { id: "anthropic", base: "https://api.anthropic.com/v1", secret_variable: "ANTHROPIC_API_KEY", wire: "messages" },
    Provider { id: "mistral", base: "https://api.mistral.ai/v1", secret_variable: "MISTRAL_API_KEY", wire: "chat" },
    Provider { id: "nvidia", base: "https://integrate.api.nvidia.com/v1", secret_variable: "NVIDIA_API_KEY", wire: "chat" },
    // Added 2026-11-22 (user decision, MIO-40). Each runs only through a candidate approved after a trial.
    Provider { id: "openai", base: "https://api.openai.com/v1", secret_variable: "OPENAI_API_KEY", wire: "chat" },
    Provider { id: "openrouter", base: "https://openrouter.ai/api/v1", secret_variable: "OPENROUTER_API_KEY", wire: "chat" },
    Provider { id: "gemini", base: "https://generativelanguage.googleapis.com/v1beta/openai", secret_variable: "GEMINI_API_KEY", wire: "chat" },
];

pub const CAPABILITIES: [&str; 3] = ["reasoning-off", "temperature-zero", "strict-json"];

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Incompatible {
    Model,
    Options,
}

impl Incompatible {
    pub const fn code(self) -> &'static str {
        match self {
            Self::Model => "provider_model_incompatible",
            Self::Options => "provider_options_incompatible",
        }
    }
}

impl std::fmt::Display for Incompatible {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.code())
    }
}

/// How a model's reasoning is set. Every pair but one turns reasoning off; hiding reasoning is
/// never enough, so answers that still carry reasoning are rejected by the adapter. The one
/// exception (`Effort`) is bound to the `lesson` task (user decision 2026-11-19): its thinking
/// is thrown away in the adapter and never logged, stored or shown.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reasoning {
    /// `reasoning_effort: "none"` (Groq, Mistral Small 4).
    EffortNone,
    /// `chat_template_kwargs: {enable_thinking: false}` (NVIDIA NIM's Qwen models).
    ChatTemplate,
    /// `thinking: {type: "disabled"}` at effort `medium` (Anthropic; disabled is refused above `high`).
    ThinkingDisabled,
    /// The model has no reasoning to turn off.
    None,
    /// `reasoning_effort: <level>` with reasoning on, for a model that cannot turn it off (Mistral
    /// Large 4 takes `low`, `medium` or `high`, never `none`). Only selectable for `lesson`.
    Effort(&'static str),
}

impl Reasoning {
    /// Whether the model reasons on every call.
    pub const fn reasons(self) -> bool {
        matches!(self, Self::Effort(_))
    }

    /// `"off"`, or the reviewed level, as `/v2/status` publishes it.
    pub const fn level(self) -> &'static str {
        match self {
            Self::Effort(level) => level,
            _ => "off",
        }
    }
}

/// The only task a reasoning pair may serve. Everything else needs reasoning off.
pub const REASONING_TASK: &str = "lesson";

#[derive(Debug, Clone, PartialEq)]
pub struct ContractReview {
    pub reviewed_at: &'static str,
    pub status: &'static str,
    pub sources: &'static [&'static str],
    /// Documentation was reviewed; a live call against the provider is a separate step.
    pub live_tested: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Profile {
    pub provider: &'static str,
    pub base: &'static str,
    pub wire: &'static str,
    pub requested_model: String,
    /// A model without a reasoning switch.
    pub plain: bool,
    pub reasoning: Reasoning,
    /// Whether `temperature: 0` is sent (`Reviewed::sends_zero_temperature`). When false the
    /// parameter is left out, never replaced by another value, so the provider's own default
    /// applies, and `/v2/status` says so.
    pub temperature: bool,
    pub schema_dialect: &'static str,
    pub capabilities: [&'static str; 3],
    pub contract_review: ContractReview,
}

/// A provider and model pair whose documentation was reviewed for Mio's contract.
pub struct Reviewed {
    pub provider: &'static str,
    pub model: &'static str,
    pub schema_dialect: &'static str,
    pub sources: &'static [&'static str],
    pub plain: bool,
    pub reasoning: Reasoning,
    /// Whether the provider takes a temperature at all. False when it refuses the parameter
    /// (Anthropic since API version 2026-10-21; user decision 2026-11-17).
    pub temperature: bool,
    pub reviewed_at: &'static str,
    /// Why a candidate is not selectable yet; `None` for a reviewed pair.
    pub blocked: Option<&'static str>,
}

impl Reviewed {
    /// Temperature 0 for every model that takes it and does not reason. A model that always
    /// reasons (lessons only) gets its provider's default instead (user decision 2026-11-22,
    /// MIO-43): no provider documents a value for its reasoning models (read 2026-11-23), and
    /// Gemini 3.6+ ignores the parameter and asks for it to be removed. Ask and everyday quote
    /// facts and stay at 0.
    pub const fn sends_zero_temperature(&self) -> bool {
        self.temperature && !self.reasoning.reasons()
    }
}

/// Every reviewed pair. The control panel lists exactly these (`mio-gateway granskade-modeller`).
pub const REVIEWED_MODELS: [Reviewed; 2] = [
    // Qwen 3.8 accepts reasoning_effort "none"; models that always think stay absent.
    Reviewed { provider: "groq", model: "qwen/qwen3.8-27b", schema_dialect: "strict-json-schema", plain: false,
        reasoning: Reasoning::EffortNone, temperature: true, reviewed_at: "2026-10-11", blocked: None,
        sources: &["https://console.groq.com/docs/structured-outputs", "https://console.groq.com/docs/reasoning"] },
    // Haiku 5.5 accepts thinking disabled at effort high or below and enforces output_config.format;
    // any non-default sampling parameter is a 400, so temperature is left out (rule approved 2026-11-17).
    // Opus 5.5 and Sonnet 5.5 cannot turn thinking off and stay absent.
    Reviewed { provider: "anthropic", model: "claude-haiku-5-5", schema_dialect: "strict-json-schema", plain: false,
        reasoning: Reasoning::ThinkingDisabled, temperature: false, reviewed_at: "2026-11-17", blocked: None,
        sources: &["https://platform.claude.com/docs/en/build-with-claude/structured-outputs",
            "https://platform.claude.com/docs/en/build-with-claude/thinking",
            "https://platform.claude.com/docs/en/build-with-claude/refusals-and-fallback"] },
];

/// Pairs with an adapter but not selectable: strict schema enforcement is not documented. Each
/// needs one approved synthetic call before it runs (user decision 2026-11-17).
///
/// Mistral (checked again 2026-11-20): the structured-output page puts the schema in the system
/// prompt and does not mention `strict` (the OpenAPI spec has `strict`, default false), so both
/// stay `json-schema` and every answer is validated (user decision 2026-11-20). Medium 3.5 was
/// deprecated 2026-10-31 and removed. Large 4 always reasons (`low`/`medium`/`high`, no `none`),
/// so it is bound to `lesson`; `mistral-large-4-0` is the version-locked ID, while
/// `mistral-large-4` and `mistral-large-latest` are aliases that can move. Large 4 reasons, so it
/// is sent without temperature (`Reviewed::sends_zero_temperature`); Mistral documents no value.
pub const CANDIDATE_MODELS: [Reviewed; 14] = [
    Reviewed { provider: "mistral", model: "mistral-small-2603", schema_dialect: "json-schema", plain: false,
        reasoning: Reasoning::EffortNone, temperature: true, reviewed_at: "2026-11-20",
        blocked: Some("Strikt JSON-schema är inte bekräftat i Mistrals dokumentation; kräver ett godkänt prov."),
        sources: &["https://docs.mistral.ai/inference/conversations/reasoning",
            "https://docs.mistral.ai/inference/conversations/structured-output/custom",
            "https://docs.mistral.ai/models/mistral-small-4-0-26-03"] },
    Reviewed { provider: "mistral", model: "mistral-large-4-0", schema_dialect: "json-schema", plain: false,
        reasoning: Reasoning::Effort("medium"), temperature: true, reviewed_at: "2026-11-20",
        blocked: Some("Resonerar alltid och får bara användas för lektioner. Strikt JSON-schema är inte bekräftat i Mistrals dokumentation; kräver ett godkänt prov."),
        sources: &["https://docs.mistral.ai/inference/conversations/reasoning",
            "https://docs.mistral.ai/inference/conversations/structured-output/custom",
            "https://docs.mistral.ai/models/mistral-large-4-0"] },
    Reviewed { provider: "nvidia", model: "qwen/qwen3.8-27b", schema_dialect: "json-schema", plain: false,
        reasoning: Reasoning::ChatTemplate, temperature: true, reviewed_at: "2026-11-17",
        blocked: Some("Strikt JSON-schema och modellnamnet i NVIDIAs hostade API är inte bekräftade; kräver ett godkänt prov."),
        sources: &["https://docs.nvidia.com/nim/vision-language-models/2.1.1-variant/get-started/advanced/get-started-qwen3-8-27b.html",
            "https://docs.nvidia.com/nim/large-language-models/1.15.0/structured-generation.html"] },
    // OpenAI (read 2026-11-22). Luna and Terra take reasoning effort `none` and list
    // structured_outputs and Chat Completions on their model pages; Sol 6.2 rejects `none`, so
    // it is bound to lessons. None has a dated snapshot. Whether they take temperature 0 and
    // `max_tokens` is not documented; the request sends `max_completion_tokens` and the trial
    // settles temperature for Luna and Terra. Sol reasons and is sent without temperature.
    Reviewed { provider: "openai", model: "gpt-6-luna", schema_dialect: "strict-json-schema", plain: false,
        reasoning: Reasoning::EffortNone, temperature: true, reviewed_at: "2026-11-22",
        blocked: Some("Om modellen godtar temperatur 0 står inte i OpenAIs dokumentation; kräver ett godkänt prov."),
        sources: &["https://developers.openai.com/api/docs/models/gpt-6-luna",
            "https://developers.openai.com/api/docs/guides/structured-outputs",
            "https://developers.openai.com/api/docs/guides/reasoning"] },
    Reviewed { provider: "openai", model: "gpt-6.1-terra", schema_dialect: "strict-json-schema", plain: false,
        reasoning: Reasoning::EffortNone, temperature: true, reviewed_at: "2026-11-22",
        blocked: Some("Om modellen godtar temperatur 0 står inte i OpenAIs dokumentation; kräver ett godkänt prov."),
        sources: &["https://developers.openai.com/api/docs/models/gpt-6.1-terra",
            "https://developers.openai.com/api/docs/guides/structured-outputs",
            "https://developers.openai.com/api/docs/guides/reasoning"] },
    Reviewed { provider: "openai", model: "gpt-6.2-sol", schema_dialect: "strict-json-schema", plain: false,
        reasoning: Reasoning::Effort("medium"), temperature: true, reviewed_at: "2026-11-22",
        blocked: Some("Resonerar alltid och får bara användas för lektioner; kräver ett godkänt prov."),
        sources: &["https://developers.openai.com/api/docs/models/gpt-6.2-sol",
            "https://developers.openai.com/api/docs/guides/structured-outputs",
            "https://developers.openai.com/api/docs/guides/reasoning"] },
    // Gemini through its OpenAI-compatible endpoint (read 2026-11-22). Reasoning cannot be turned
    // off for Gemini 3 or 4; only 2.5 takes `none`, and 2.5 Flash-Lite is not deprecated. The
    // structured-output page promises syntactically valid JSON, not adherence, and does not
    // mention `strict`, so both are `json-schema` and every answer is validated. Thought text is
    // not returned by default. Gemini 3.6+ ignores temperature and asks for it to be removed
    // (text-generation page, read 2026-11-23); 3.8 Flash reasons, so none is sent. The free tier may train on content outside the EEA; inside it the
    // paid data rules apply, but the terms only allow paid services for API clients there.
    Reviewed { provider: "gemini", model: "gemini-2.5-flash-lite", schema_dialect: "json-schema", plain: false,
        reasoning: Reasoning::EffortNone, temperature: true, reviewed_at: "2026-11-22",
        blocked: Some("Gemini lovar inte att följa svarsschemat strikt; kräver ett godkänt prov."),
        sources: &["https://aistudio.google.com/docs/openai", "https://aistudio.google.com/docs/structured-output",
            "https://aistudio.google.com/docs/thinking", "https://aistudio.google.com/docs/models"] },
    Reviewed { provider: "gemini", model: "gemini-3.8-flash", schema_dialect: "json-schema", plain: false,
        reasoning: Reasoning::Effort("medium"), temperature: true, reviewed_at: "2026-11-22",
        blocked: Some("Resonerar alltid och får bara användas för lektioner. Gemini lovar inte att följa svarsschemat strikt; kräver ett godkänt prov."),
        sources: &["https://aistudio.google.com/docs/openai", "https://aistudio.google.com/docs/structured-output",
            "https://aistudio.google.com/docs/thinking", "https://aistudio.google.com/docs/models"] },
    // OpenRouter (read 2026-11-22): the request is pinned by the adapter to endpoints that support
    // every parameter sent (`require_parameters`), collect no data and retain nothing (`zdr`), with
    // reasoning set through its own `reasoning` object and excluded from the answer. Structured
    // output enforcement varies by endpoint, so every answer is validated. IDs checked against
    // https://openrouter.ai/api/v1/models?supported_parameters=structured_outputs on 2026-11-22.
    Reviewed { provider: "openrouter", model: "openai/gpt-6-luna", schema_dialect: "strict-json-schema", plain: false,
        reasoning: Reasoning::EffortNone, temperature: true, reviewed_at: "2026-11-22",
        blocked: Some("Går via OpenRouter till en underleverantör; kräver ett godkänt prov."),
        sources: OPENROUTER_SOURCES },
    Reviewed { provider: "openrouter", model: "mistralai/mistral-small-2603", schema_dialect: "json-schema", plain: false,
        reasoning: Reasoning::EffortNone, temperature: true, reviewed_at: "2026-11-22",
        blocked: Some("Går via OpenRouter till en underleverantör; kräver ett godkänt prov."),
        sources: OPENROUTER_SOURCES },
    Reviewed { provider: "openrouter", model: "qwen/qwen3.8-27b", schema_dialect: "strict-json-schema", plain: false,
        reasoning: Reasoning::EffortNone, temperature: true, reviewed_at: "2026-11-22",
        blocked: Some("Går via OpenRouter till en underleverantör; kräver ett godkänt prov."),
        sources: OPENROUTER_SOURCES },
    Reviewed { provider: "openrouter", model: "google/gemini-2.5-flash-lite", schema_dialect: "json-schema", plain: false,
        reasoning: Reasoning::EffortNone, temperature: true, reviewed_at: "2026-11-22",
        blocked: Some("Går via OpenRouter till en underleverantör; kräver ett godkänt prov."),
        sources: OPENROUTER_SOURCES },
    Reviewed { provider: "openrouter", model: "mistralai/mistral-large-4-0", schema_dialect: "json-schema", plain: false,
        reasoning: Reasoning::Effort("medium"), temperature: true, reviewed_at: "2026-11-22",
        blocked: Some("Resonerar alltid och får bara användas för lektioner. Går via OpenRouter till en underleverantör; kräver ett godkänt prov."),
        sources: OPENROUTER_SOURCES },
    Reviewed { provider: "openrouter", model: "google/gemini-3.8-flash", schema_dialect: "json-schema", plain: false,
        reasoning: Reasoning::Effort("medium"), temperature: true, reviewed_at: "2026-11-22",
        blocked: Some("Resonerar alltid och får bara användas för lektioner. Går via OpenRouter till en underleverantör; kräver ett godkänt prov."),
        sources: OPENROUTER_SOURCES },
];

const OPENROUTER_SOURCES: &[&str] = &["https://openrouter.ai/docs/features/structured-outputs",
    "https://openrouter.ai/docs/features/provider-routing", "https://openrouter.ai/docs/use-cases/reasoning-tokens",
    "https://openrouter.ai/docs/features/privacy-and-logging"];

/// A reviewed price in USD per million tokens. Only pairs listed here get a cost in `/v2/status`;
/// any other (Groq's free tier) gets `estimatedCost: null`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Price {
    pub provider: &'static str,
    pub model: &'static str,
    pub input: f64,
    pub cached_input: f64,
    pub output: f64,
    pub as_of: &'static str,
    pub source: &'static str,
}

/// Read 2026-11-20 on Mistral's pricing page. Reasoning is billed as output (the usage counter
/// counts it inside `outputTokens`). The page names Small 4 `mistral-small-4-0-26-03`; its model
/// page gives `mistral-small-2603` as the API ID.
pub const PRICES: [Price; 5] = [
    Price { provider: "mistral", model: "mistral-small-2603", input: 0.15, cached_input: 0.015, output: 0.6,
        as_of: "2026-11-20", source: "https://docs.mistral.ai/inference/pricing" },
    Price { provider: "mistral", model: "mistral-large-4-0", input: 0.7, cached_input: 0.07, output: 2.1,
        as_of: "2026-11-20", source: "https://docs.mistral.ai/inference/pricing" },
    // Read 2026-11-22. OpenRouter's prices depend on the endpoint it routes to, so it has none.
    // Gemini has none yet: its cached-input price and 2.5 Flash-Lite's price were not read.
    Price { provider: "openai", model: "gpt-6-luna", input: 0.10, cached_input: 0.01, output: 0.50,
        as_of: "2026-11-22", source: "https://developers.openai.com/api/docs/pricing" },
    Price { provider: "openai", model: "gpt-6.1-terra", input: 1.00, cached_input: 0.05, output: 5.00,
        as_of: "2026-11-22", source: "https://developers.openai.com/api/docs/pricing" },
    Price { provider: "openai", model: "gpt-6.2-sol", input: 2.00, cached_input: 0.10, output: 10.00,
        as_of: "2026-11-22", source: "https://developers.openai.com/api/docs/pricing" },
];

pub fn price(provider: &str, model: &str) -> Option<&'static Price> {
    PRICES.iter().find(|price| price.provider == provider && price.model == model)
}

/// The reasoning setting of a reviewed or candidate pair, approved or not.
pub fn pair_reasoning(provider: &str, model: &str) -> Option<Reasoning> {
    REVIEWED_MODELS.iter().chain(CANDIDATE_MODELS.iter())
        .find(|entry| entry.provider == provider && entry.model == model).map(|entry| entry.reasoning)
}

fn reviewed_model(provider: &str, model: &str) -> Option<&'static Reviewed> {
    REVIEWED_MODELS.iter().find(|reviewed| reviewed.provider == provider && reviewed.model == model)
}

pub fn provider(id: &str) -> Option<&'static Provider> {
    PROVIDERS.iter().find(|provider| provider.id == id)
}

fn profile_for(provider: &'static Provider, reviewed: &'static Reviewed, model: &str) -> Profile {
    Profile { provider: provider.id, base: provider.base, wire: provider.wire, requested_model: model.to_owned(),
        plain: reviewed.plain, reasoning: reviewed.reasoning, temperature: reviewed.sends_zero_temperature(),
        schema_dialect: reviewed.schema_dialect, capabilities: CAPABILITIES,
        contract_review: ContractReview { reviewed_at: reviewed.reviewed_at,
            status: if reviewed.blocked.is_some() { "candidate" } else { "documentation-reviewed" },
            sources: reviewed.sources, live_tested: false } }
}

/// `provider_profile`, but a candidate the user has approved after a passed test
/// (`MIO_APPROVED_CANDIDATES`, written only by the panel's helper after `mio-gateway prova`)
/// also resolves, marked as live tested.
pub fn approved_profile(provider_id: &str, model: &str, adapter_options: Option<&Value>, approved: &[String]) -> Result<Profile, Incompatible> {
    match provider_profile(provider_id, model, adapter_options) {
        Err(Incompatible::Model) if approved.iter().any(|entry| *entry == format!("{provider_id}={model}")) => {
            if adapter_options.is_some_and(|options| !options.as_object().is_some_and(serde_json::Map::is_empty)) {
                return Err(Incompatible::Options);
            }
            let mut profile = candidate_profile(provider_id, model).ok_or(Incompatible::Model)?;
            profile.contract_review.status = "approved-after-test";
            profile.contract_review.live_tested = true;
            Ok(profile)
        }
        other => other,
    }
}

pub fn provider_profile(provider_id: &str, model: &str, adapter_options: Option<&Value>) -> Result<Profile, Incompatible> {
    let provider = provider(provider_id).ok_or(Incompatible::Model)?;
    let mut characters = model.chars();
    let well_formed = model.len() <= 128 && characters.next().is_some_and(|first| first.is_ascii_alphanumeric())
        && characters.all(|character| character.is_ascii_alphanumeric() || "._:/-".contains(character));
    if !well_formed || model.contains("://") || credential_shaped(model) {
        return Err(Incompatible::Model);
    }
    let reviewed = reviewed_model(provider.id, model).ok_or(Incompatible::Model)?;
    // No provider has reviewed routing or retention options; any option is a configuration error.
    if adapter_options.is_some_and(|options| !options.as_object().is_some_and(serde_json::Map::is_empty)) {
        return Err(Incompatible::Options);
    }
    Ok(profile_for(provider, reviewed, model))
}

/// The profile a candidate would get once approved, for the adapter's synthetic tests only.
/// `provider_profile` refuses candidates, so no request to them is built in production.
pub fn candidate_profile(provider_id: &str, model: &str) -> Option<Profile> {
    let provider = provider(provider_id)?;
    let candidate = CANDIDATE_MODELS.iter().find(|candidate| candidate.provider == provider_id && candidate.model == model)?;
    Some(profile_for(provider, candidate, model))
}
