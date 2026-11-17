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

pub const PROVIDERS: [Provider; 4] = [
    Provider { id: "groq", base: "https://api.groq.com/openai/v1", secret_variable: "GROQ_API_KEY", wire: "chat" },
    Provider { id: "anthropic", base: "https://api.anthropic.com/v1", secret_variable: "ANTHROPIC_API_KEY", wire: "messages" },
    Provider { id: "mistral", base: "https://api.mistral.ai/v1", secret_variable: "MISTRAL_API_KEY", wire: "chat" },
    Provider { id: "nvidia", base: "https://integrate.api.nvidia.com/v1", secret_variable: "NVIDIA_API_KEY", wire: "chat" },
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

/// How a model is told not to reason. Hiding reasoning is never enough: answers that still
/// carry reasoning are rejected by the adapter.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReasoningOff {
    /// `reasoning_effort: "none"` (Groq, Mistral).
    EffortNone,
    /// `chat_template_kwargs: {enable_thinking: false}` (NVIDIA NIM's Qwen models).
    ChatTemplate,
    /// `thinking: {type: "disabled"}` at effort `medium` (Anthropic; disabled is refused above `high`).
    ThinkingDisabled,
    /// The model has no reasoning to turn off.
    None,
}

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
    pub reasoning_off: ReasoningOff,
    /// Whether `temperature: 0` is sent. False only for a reviewed model whose provider refuses
    /// the parameter (Anthropic since API version 2026-10-21; user decision 2026-11-17). It is
    /// then left out, never replaced by another value, and `/v2/status` says so.
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
    pub reasoning_off: ReasoningOff,
    pub temperature: bool,
    pub reviewed_at: &'static str,
    /// Why a candidate is not selectable yet; `None` for a reviewed pair.
    pub blocked: Option<&'static str>,
}

/// Every reviewed pair. The control panel lists exactly these (`mio-gateway granskade-modeller`).
pub const REVIEWED_MODELS: [Reviewed; 2] = [
    // Qwen 3.8 accepts reasoning_effort "none"; models that always think stay absent.
    Reviewed { provider: "groq", model: "qwen/qwen3.8-27b", schema_dialect: "strict-json-schema", plain: false,
        reasoning_off: ReasoningOff::EffortNone, temperature: true, reviewed_at: "2026-10-11", blocked: None,
        sources: &["https://console.groq.com/docs/structured-outputs", "https://console.groq.com/docs/reasoning"] },
    // Haiku 5.5 accepts thinking disabled at effort high or below and enforces output_config.format;
    // any non-default sampling parameter is a 400, so temperature is left out (rule approved 2026-11-17).
    // Opus 5.5 and Sonnet 5.5 cannot turn thinking off and stay absent.
    Reviewed { provider: "anthropic", model: "claude-haiku-5-5", schema_dialect: "strict-json-schema", plain: false,
        reasoning_off: ReasoningOff::ThinkingDisabled, temperature: false, reviewed_at: "2026-11-17", blocked: None,
        sources: &["https://platform.claude.com/docs/en/build-with-claude/structured-outputs",
            "https://platform.claude.com/docs/en/build-with-claude/thinking",
            "https://platform.claude.com/docs/en/build-with-claude/refusals-and-fallback"] },
];

/// Pairs with an adapter but not selectable: reasoning-off is documented, strict schema
/// enforcement is not. Each needs one approved synthetic call before it moves to
/// `REVIEWED_MODELS` (user decision 2026-11-17).
pub const CANDIDATE_MODELS: [Reviewed; 3] = [
    Reviewed { provider: "mistral", model: "mistral-small-2603", schema_dialect: "json-schema", plain: false,
        reasoning_off: ReasoningOff::EffortNone, temperature: true, reviewed_at: "2026-11-17",
        blocked: Some("Strikt JSON-schema är inte bekräftat i Mistrals dokumentation; kräver ett godkänt prov."),
        sources: &["https://docs.mistral.ai/inference/conversations/reasoning",
            "https://docs.mistral.ai/inference/conversations/structured-output/custom"] },
    Reviewed { provider: "mistral", model: "mistral-medium-3-5", schema_dialect: "json-schema", plain: false,
        reasoning_off: ReasoningOff::EffortNone, temperature: true, reviewed_at: "2026-11-17",
        blocked: Some("Strikt JSON-schema är inte bekräftat i Mistrals dokumentation; kräver ett godkänt prov."),
        sources: &["https://docs.mistral.ai/inference/conversations/reasoning",
            "https://docs.mistral.ai/inference/conversations/structured-output/custom"] },
    Reviewed { provider: "nvidia", model: "qwen/qwen3.8-27b", schema_dialect: "json-schema", plain: false,
        reasoning_off: ReasoningOff::ChatTemplate, temperature: true, reviewed_at: "2026-11-17",
        blocked: Some("Strikt JSON-schema och modellnamnet i NVIDIAs hostade API är inte bekräftade; kräver ett godkänt prov."),
        sources: &["https://docs.nvidia.com/nim/vision-language-models/2.1.1-variant/get-started/advanced/get-started-qwen3-8-27b.html",
            "https://docs.nvidia.com/nim/large-language-models/1.15.0/structured-generation.html"] },
];

fn reviewed_model(provider: &str, model: &str) -> Option<&'static Reviewed> {
    REVIEWED_MODELS.iter().find(|reviewed| reviewed.provider == provider && reviewed.model == model)
}

pub fn provider(id: &str) -> Option<&'static Provider> {
    PROVIDERS.iter().find(|provider| provider.id == id)
}

fn profile_for(provider: &'static Provider, reviewed: &'static Reviewed, model: &str) -> Profile {
    Profile { provider: provider.id, base: provider.base, wire: provider.wire, requested_model: model.to_owned(),
        plain: reviewed.plain, reasoning_off: reviewed.reasoning_off, temperature: reviewed.temperature,
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
