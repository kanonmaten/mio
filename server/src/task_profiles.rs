//! Which provider and model each task uses. A bad task profile disables only that task and
//! never falls back to the global model.

use serde_json::{Map, Value};

use crate::config::Config;
use crate::js::{ascii_alphanumeric_or, credential_shaped, is_blank};
use crate::model_profiles::Incompatible;

pub const TASK_IDS: [&str; 3] = ["ask", "everyday", "lesson"];
const PROFILE_FIELDS: [&str; 3] = ["provider", "model", "adapterOptions"];

pub fn safe_provider_identifier(value: &str) -> &str {
    if (1..=64).contains(&value.len()) && ascii_alphanumeric_or(value, "._-") && !credential_shaped(value) { value } else { "" }
}

pub fn safe_model_identifier(value: &str) -> &str {
    if (1..=150).contains(&value.len()) && ascii_alphanumeric_or(value, "._:/-") && !value.contains("://")
        && !credential_shaped(value) { value } else { "" }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Resolved {
    pub configured: bool,
    /// The effective configuration of this task, without task profiles or other providers' secrets.
    pub config: Option<Config>,
    pub configuration_error: Option<&'static str>,
}

impl Resolved {
    fn failed(error: &'static str) -> Self {
        Self { configured: false, config: None, configuration_error: Some(error) }
    }
}

/// The override table, or `None` when it is malformed or names an unknown task.
fn profile_overrides(config: &Config) -> Option<Map<String, Value>> {
    let profiles = match &config.task_profiles {
        None => return Some(Map::new()),
        Some(Value::String(raw)) => serde_json::from_str::<Value>(raw).ok()?,
        Some(other) => other.clone(),
    };
    match profiles {
        Value::Object(map) if map.keys().all(|key| TASK_IDS.contains(&key.as_str())) => Some(map),
        _ => None,
    }
}

fn effective_task_config(config: &Config, task: &str) -> Result<Config, &'static str> {
    if !TASK_IDS.contains(&task) {
        return Err("task_profile_invalid");
    }
    let profiles = profile_overrides(config).ok_or("task_profiles_invalid")?;
    let empty = Map::new();
    let overrides = match profiles.get(task) {
        None => &empty,
        Some(Value::Object(map)) if map.keys().all(|key| PROFILE_FIELDS.contains(&key.as_str())) => map,
        Some(_) => return Err("task_profile_invalid"),
    };
    let field = |name: &str, global: &str| match overrides.get(name) {
        None => Some(global.to_owned()),
        Some(value) => value.as_str().map(str::to_owned),
    };
    let provider = field("provider", &config.provider).filter(|provider| !safe_provider_identifier(provider).is_empty());
    let model = field("model", &config.model).filter(|model| !safe_model_identifier(model).is_empty());
    let (Some(provider), Some(model)) = (provider, model) else { return Err("task_profile_invalid") };
    let mut effective = config.clone();
    // Adapter options may inherit within a provider and are revalidated for the selected model.
    if let Some(options) = overrides.get("adapterOptions") {
        effective.adapter_options = Some(options.clone());
    } else if provider != config.provider {
        effective.adapter_options = None;
    }
    if provider != config.provider {
        effective.api_key = config.provider_secrets.get(&provider).cloned().unwrap_or_default();
    }
    effective.provider = provider;
    effective.model = model;
    effective.task_profiles = None;
    effective.provider_secrets.clear();
    Ok(effective)
}

/// The provider and model a task is configured for, reduced to identifiers safe to publish.
pub fn task_configuration_identifiers(config: &Config, task: &str) -> (String, String) {
    let profiles = profile_overrides(config);
    let overrides = profiles.as_ref().and_then(|profiles| profiles.get(task)).and_then(Value::as_object);
    let field = |name: &str, global: &str| match overrides.and_then(|overrides| overrides.get(name)) {
        None => global.to_owned(),
        Some(value) => value.as_str().unwrap_or("").to_owned(),
    };
    (safe_provider_identifier(&field("provider", &config.provider)).to_owned(),
        safe_model_identifier(&field("model", &config.model)).to_owned())
}

pub fn resolve_task_profile(config: &Config, task: &str) -> Resolved {
    if config.global_configuration_invalid {
        return Resolved::failed("gateway_configuration_invalid");
    }
    let selected = match effective_task_config(config, task) {
        Ok(selected) => selected,
        Err(error) => return Resolved::failed(error),
    };
    if selected.adapter_options.as_ref().is_some_and(|options| !options.is_object()) {
        return Resolved::failed("provider_options_incompatible");
    }
    match crate::config::profile(&selected) {
        Err(Incompatible::Options) => return Resolved::failed("provider_options_incompatible"),
        Err(Incompatible::Model) => return Resolved::failed("provider_model_incompatible"),
        // Only lessons may reason (user decision 2026-11-19); validate_config also refuses to start.
        Ok(profile) if profile.reasoning.reasons() && task != crate::model_profiles::REASONING_TASK => {
            return Resolved::failed("provider_options_incompatible");
        }
        Ok(_) => {}
    }
    let key = &selected.api_key;
    if is_blank(key) || key.contains(['\r', '\n']) || *key == config.gateway_token {
        return Resolved::failed("provider_secret_missing");
    }
    Resolved { configured: true, config: Some(selected), configuration_error: None }
}
