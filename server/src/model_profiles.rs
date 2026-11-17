//! Provider seam: one reviewed provider today (Groq, user decision 2026-10-11).
//! Adding a provider later means one `PROVIDERS` entry, one `reviewed_model` case with
//! documentation sources and, if its wire differs from chat completions, one adapter
//! in `adapters.rs`. A provider prefix or OpenAI-compatible URL is never proof of support.

use serde_json::Value;

use crate::js::credential_shaped;

pub struct Provider {
    pub id: &'static str,
    pub base: &'static str,
    /// Name of the environment variable that holds this provider's key.
    pub secret_variable: &'static str,
    pub wire: &'static str,
}

pub const PROVIDERS: [Provider; 1] = [
    Provider { id: "groq", base: "https://api.groq.com/openai/v1", secret_variable: "GROQ_API_KEY", wire: "chat" },
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
    /// A model without a reasoning switch. No reviewed model is plain today.
    pub plain: bool,
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
}

/// Every reviewed pair. The control panel lists exactly these (`mio-gateway granskade-modeller`).
pub const REVIEWED_MODELS: [Reviewed; 1] = [
    // Qwen 3.8 accepts reasoning_effort "none"; models that always think stay absent.
    Reviewed { provider: "groq", model: "qwen/qwen3.8-27b", schema_dialect: "strict-json-schema", plain: false,
        sources: &["https://console.groq.com/docs/structured-outputs", "https://console.groq.com/docs/reasoning"] },
];

fn reviewed_model(provider: &str, model: &str) -> Option<&'static Reviewed> {
    REVIEWED_MODELS.iter().find(|reviewed| reviewed.provider == provider && reviewed.model == model)
}

pub fn provider(id: &str) -> Option<&'static Provider> {
    PROVIDERS.iter().find(|provider| provider.id == id)
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
    // Groq has no reviewed routing or retention options; any option is a configuration error.
    if adapter_options.is_some_and(|options| !options.as_object().is_some_and(serde_json::Map::is_empty)) {
        return Err(Incompatible::Options);
    }
    Ok(Profile { provider: provider.id, base: provider.base, wire: provider.wire, requested_model: model.to_owned(),
        plain: reviewed.plain, schema_dialect: reviewed.schema_dialect, capabilities: CAPABILITIES,
        contract_review: ContractReview { reviewed_at: "2026-10-11", status: "documentation-reviewed",
            sources: reviewed.sources, live_tested: false } })
}
