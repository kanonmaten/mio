//! The AI page's model: which reviewed pair each task uses, the gateway's limits, and the list of
//! changes shown before anything is saved. The gateway checks the file again before it is
//! written (`mio-gateway kontrollera-konfiguration`); these checks only keep the form honest.

use std::collections::BTreeMap;

use serde_json::{Map, Value, json};

pub const TASKS: [(&str, &str); 3] = [("ask", "Frågor"), ("everyday", "Vardag"), ("lesson", "Lektioner")];

/// One provider and model pair from `mio-gateway granskade-modeller`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pair {
    pub provider: String,
    pub model: String,
    pub secret_variable: String,
    /// `"0"`, or `"provider-default"` when the provider refuses temperature.
    pub temperature: String,
    /// Why a candidate cannot be chosen; `None` for a reviewed pair.
    pub blocked: Option<String>,
}

impl Pair {
    pub fn label(&self) -> String {
        format!("{} · {}", provider_name(&self.provider), self.model)
    }

    pub fn is(&self, provider: &str, model: &str) -> bool {
        self.provider == provider && self.model == model
    }
}

pub fn provider_name(provider: &str) -> &str {
    match provider {
        "groq" => "Groq",
        "anthropic" => "Anthropic",
        "mistral" => "Mistral",
        "nvidia" => "NVIDIA",
        other => other,
    }
}

/// The reviewed pairs (selectable) and the candidates (shown, not selectable).
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Catalog {
    pub reviewed: Vec<Pair>,
    pub candidates: Vec<Pair>,
}

impl Catalog {
    pub fn parse(json: &Value) -> Option<Self> {
        let pairs = |key: &str| -> Option<Vec<Pair>> {
            json.get(key)?
                .as_array()?
                .iter()
                .map(|pair| {
                    let text = |name: &str| pair.get(name).and_then(Value::as_str).map(str::to_owned);
                    Some(Pair {
                        provider: text("provider")?,
                        model: text("model")?,
                        secret_variable: text("secretVariable")?,
                        temperature: text("temperature").unwrap_or_else(|| "0".to_owned()),
                        blocked: text("blocked"),
                    })
                })
                .collect()
        };
        Some(Self { reviewed: pairs("models")?, candidates: pairs("candidates").unwrap_or_default() })
    }

    pub fn find(&self, provider: &str, model: &str) -> Option<&Pair> {
        self.reviewed.iter().find(|pair| pair.is(provider, model))
    }
}

/// `gateway.env` as the helper returns it: plain values, and secrets only as set or not.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct GatewayFile {
    pub values: BTreeMap<String, String>,
    pub secrets: BTreeMap<String, bool>,
}

impl GatewayFile {
    /// `None` when the file does not exist (the gateway is not installed).
    pub fn parse(json: &Value) -> Option<Self> {
        if json.get("exists") != Some(&Value::Bool(true)) {
            return None;
        }
        let map = |key: &str| json.get(key).and_then(Value::as_object).cloned().unwrap_or_default();
        Some(Self {
            values: map("values").into_iter().filter_map(|(key, value)| Some((key, value.as_str()?.to_owned()))).collect(),
            secrets: map("secrets").into_iter().filter_map(|(key, value)| Some((key, value.as_bool()?))).collect(),
        })
    }

    fn value(&self, key: &str) -> Option<&str> {
        self.values.get(key).map(String::as_str)
    }

    pub fn has_secret(&self, key: &str) -> bool {
        self.secrets.get(key).copied().unwrap_or(false)
    }
}

/// A number field with the gateway's own range. `optional` limits accept empty or 0 for "none".
pub struct Limit {
    pub key: &'static str,
    pub label: &'static str,
    pub help: &'static str,
    pub min: u64,
    pub max: u64,
    pub optional: bool,
}

/// The limits the gateway reads (`server/src/config.rs`).
pub const LIMITS: [Limit; 8] = [
    Limit { key: "MIO_REQUESTS_PER_MINUTE", label: "Anrop per minut", help: "1–60. Stoppar en klient som skenar.", min: 1, max: 60, optional: false },
    Limit { key: "MIO_TOKENS_PER_MINUTE", label: "Token per minut (Groq)", help: "2 000–1 000 000, tomt eller 0 för ingen gräns. Groqs gratisnivå: 8 000.", min: 2_000, max: 1_000_000, optional: true },
    Limit { key: "MIO_TOKENS_PER_MINUTE_ANTHROPIC", label: "Token per minut (Anthropic)", help: "2 000–1 000 000, tomt för ingen gräns.", min: 2_000, max: 1_000_000, optional: true },
    Limit { key: "MIO_TOKENS_PER_MINUTE_MISTRAL", label: "Token per minut (Mistral)", help: "2 000–1 000 000, tomt för ingen gräns.", min: 2_000, max: 1_000_000, optional: true },
    Limit { key: "MIO_TOKENS_PER_MINUTE_NVIDIA", label: "Token per minut (NVIDIA)", help: "2 000–1 000 000, tomt för ingen gräns.", min: 2_000, max: 1_000_000, optional: true },
    Limit { key: "MIO_TOKENS_PER_DAY", label: "Token per dygn", help: "1–1 000 000, tomt för ingen gräns. Groqs gratisnivå: 200 000.", min: 1, max: 1_000_000, optional: true },
    Limit { key: "MIO_REQUESTS_PER_DAY", label: "Anrop per dygn", help: "1–1 000 000, tomt för ingen gräns.", min: 1, max: 1_000_000, optional: true },
    Limit { key: "MIO_LESSON_INTERVAL_SECONDS", label: "Sekunder mellan lektionsdelar", help: "60–3 600.", min: 60, max: 3_600, optional: false },
];

/// Checks one limit as the gateway would. Spaces (thousands separators) are allowed while typing.
pub fn check_limit(limit: &Limit, text: &str) -> Result<String, String> {
    let digits: String = text.chars().filter(|character| !character.is_whitespace()).collect();
    if limit.optional && (digits.is_empty() || digits == "0") {
        return Ok(String::new());
    }
    match digits.parse::<u64>() {
        Ok(value) if (limit.min..=limit.max).contains(&value) => Ok(value.to_string()),
        _ => Err(format!("{}: {}", limit.label, limit.help)),
    }
}

/// A selection per task: `None` follows the default pair.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AiForm {
    pub default_pair: (String, String),
    pub per_task: BTreeMap<String, (String, String)>,
    /// What the user typed, per limit key.
    pub limits: BTreeMap<String, String>,
    /// Task profile fields other than provider and model (`adapterOptions`), kept as they were.
    kept_options: BTreeMap<String, Value>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Change {
    pub key: String,
    pub before: Option<String>,
    pub after: Option<String>,
}

impl AiForm {
    pub fn from_file(file: &GatewayFile) -> Self {
        let default_pair = (
            file.value("MIO_AI_PROVIDER").unwrap_or("groq").to_owned(),
            file.value("MIO_AI_MODEL").unwrap_or_default().to_owned(),
        );
        let mut per_task = BTreeMap::new();
        let mut kept_options = BTreeMap::new();
        if let Some(Value::Object(profiles)) = file.value("MIO_AI_TASK_PROFILES").and_then(|raw| serde_json::from_str(raw).ok()) {
            for (task, profile) in profiles {
                let field = |name: &str, fallback: &str| profile.get(name).and_then(Value::as_str).unwrap_or(fallback).to_owned();
                per_task.insert(task.clone(), (field("provider", &default_pair.0), field("model", &default_pair.1)));
                if let Some(options) = profile.get("adapterOptions") {
                    kept_options.insert(task, options.clone());
                }
            }
        }
        let limits = LIMITS.iter().map(|limit| (limit.key.to_owned(), file.value(limit.key).unwrap_or_default().to_owned())).collect();
        Self { default_pair, per_task, limits, kept_options }
    }

    /// The pair a task runs with.
    pub fn pair_for(&self, task: &str) -> &(String, String) {
        self.per_task.get(task).unwrap_or(&self.default_pair)
    }

    /// `MIO_AI_TASK_PROFILES` for the current choices, or empty when every task follows the default.
    fn task_profiles(&self) -> String {
        let mut profiles = Map::new();
        for (task, _) in TASKS {
            let options = self.kept_options.get(task);
            if let Some((provider, model)) = self.per_task.get(task).filter(|pair| **pair != self.default_pair) {
                let mut profile = json!({ "provider": provider, "model": model });
                if let Some(options) = options {
                    profile["adapterOptions"] = options.clone();
                }
                profiles.insert(task.to_owned(), profile);
            } else if let Some(options) = options {
                profiles.insert(task.to_owned(), json!({ "adapterOptions": options }));
            }
        }
        if profiles.is_empty() { String::new() } else { Value::Object(profiles).to_string() }
    }

    /// Problems that stop saving, in Swedish, one per field.
    pub fn problems(&self, catalog: &Catalog, file: &GatewayFile) -> Vec<String> {
        let mut problems = Vec::new();
        for (task, label) in TASKS {
            let (provider, model) = self.pair_for(task);
            match catalog.find(provider, model) {
                None => problems.push(format!("{label}: {provider} · {model} är inte en granskad modell.")),
                Some(pair) if !file.has_secret(&pair.secret_variable) => {
                    problems.push(format!("{label}: nyckel saknas för {} ({}).", provider_name(provider), pair.secret_variable));
                }
                Some(_) => {}
            }
        }
        for limit in &LIMITS {
            if let Err(message) = check_limit(limit, self.limits.get(limit.key).map(String::as_str).unwrap_or("")) {
                problems.push(message);
            }
        }
        problems
    }

    /// Every setting that differs from the file: what the preview shows and what is saved.
    pub fn changes(&self, file: &GatewayFile) -> Vec<Change> {
        let mut wanted: Vec<(String, String)> = vec![
            ("MIO_AI_PROVIDER".to_owned(), self.default_pair.0.clone()),
            ("MIO_AI_MODEL".to_owned(), self.default_pair.1.clone()),
            ("MIO_AI_TASK_PROFILES".to_owned(), self.task_profiles()),
        ];
        for limit in &LIMITS {
            let text = self.limits.get(limit.key).map(String::as_str).unwrap_or("");
            wanted.push((limit.key.to_owned(), check_limit(limit, text).unwrap_or_else(|_| text.to_owned())));
        }
        wanted
            .into_iter()
            .filter_map(|(key, after)| {
                let before = file.value(&key).filter(|value| !value.is_empty()).map(str::to_owned);
                let after = Some(after).filter(|value| !value.is_empty());
                (before != after).then_some(Change { key, before, after })
            })
            .collect()
    }

    /// What `mio-control-helper write installningar gateway` reads on stdin.
    pub fn request(changes: &[Change]) -> Value {
        let set: Map<String, Value> = changes.iter().filter_map(|change| Some((change.key.clone(), Value::String(change.after.clone()?)))).collect();
        let remove: Vec<Value> = changes.iter().filter(|change| change.after.is_none()).map(|change| Value::String(change.key.clone())).collect();
        json!({ "set": set, "remove": remove })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn catalog() -> Catalog {
        Catalog::parse(&json!({ "providers": ["groq", "anthropic"],
            "models": [
                { "provider": "groq", "model": "qwen/qwen3.8-27b", "secretVariable": "GROQ_API_KEY", "temperature": "0" },
                { "provider": "anthropic", "model": "claude-haiku-5-5", "secretVariable": "ANTHROPIC_API_KEY", "temperature": "provider-default" }],
            "candidates": [{ "provider": "mistral", "model": "mistral-small-2603", "secretVariable": "MISTRAL_API_KEY", "blocked": "Kräver prov." }] }))
        .unwrap()
    }

    fn file() -> GatewayFile {
        GatewayFile::parse(&json!({ "exists": true,
            "values": { "MIO_AI_PROVIDER": "groq", "MIO_AI_MODEL": "qwen/qwen3.8-27b", "MIO_REQUESTS_PER_MINUTE": "10",
                "MIO_TOKENS_PER_MINUTE": "8000", "MIO_TOKENS_PER_DAY": "190000", "MIO_REQUESTS_PER_DAY": "", "MIO_LESSON_INTERVAL_SECONDS": "60", "PORT": "8787" },
            "secrets": { "GROQ_API_KEY": true, "MIO_GATEWAY_TOKEN": true } }))
        .unwrap()
    }

    #[test]
    fn an_unchanged_form_changes_nothing() {
        let form = AiForm::from_file(&file());
        assert_eq!(form.changes(&file()), []);
        assert_eq!(form.problems(&catalog(), &file()), Vec::<String>::new());
        assert_eq!(catalog().candidates[0].blocked.as_deref(), Some("Kräver prov."));
    }

    #[test]
    fn a_lesson_on_another_provider_becomes_a_task_profile_and_needs_its_key() {
        let mut form = AiForm::from_file(&file());
        form.per_task.insert("lesson".into(), ("anthropic".into(), "claude-haiku-5-5".into()));
        let changes = form.changes(&file());
        assert_eq!((changes.len(), changes[0].key.as_str(), changes[0].before.as_deref()), (1, "MIO_AI_TASK_PROFILES", None));
        // Key order depends on serde_json's features in the build; the gateway parses either.
        let profiles: Value = serde_json::from_str(changes[0].after.as_deref().unwrap()).unwrap();
        assert_eq!(profiles, json!({ "lesson": { "provider": "anthropic", "model": "claude-haiku-5-5" } }));
        assert_eq!(form.problems(&catalog(), &file()), ["Lektioner: nyckel saknas för Anthropic (ANTHROPIC_API_KEY)."]);
        let mut with_key = file();
        with_key.secrets.insert("ANTHROPIC_API_KEY".into(), true);
        assert!(form.problems(&catalog(), &with_key).is_empty());
        // Choosing the default again removes the profile.
        form.per_task.insert("lesson".into(), ("groq".into(), "qwen/qwen3.8-27b".into()));
        assert_eq!(form.changes(&file()), []);
    }

    #[test]
    fn existing_profiles_and_adapter_options_survive() {
        let mut existing = file();
        existing.values.insert("MIO_AI_TASK_PROFILES".into(), r#"{"ask":{"provider":"anthropic","model":"claude-haiku-5-5","adapterOptions":{}}}"#.into());
        let form = AiForm::from_file(&existing);
        assert_eq!(form.pair_for("ask"), &("anthropic".to_owned(), "claude-haiku-5-5".to_owned()));
        assert_eq!(form.pair_for("lesson"), &("groq".to_owned(), "qwen/qwen3.8-27b".to_owned()));
        let profiles: Value = serde_json::from_str(&form.task_profiles()).unwrap();
        assert_eq!(profiles, json!({ "ask": { "provider": "anthropic", "model": "claude-haiku-5-5", "adapterOptions": {} } }));
    }

    #[test]
    fn limits_follow_the_gateways_ranges() {
        let mut form = AiForm::from_file(&file());
        form.limits.insert("MIO_REQUESTS_PER_MINUTE".into(), "61".into());
        form.limits.insert("MIO_TOKENS_PER_DAY".into(), "150 000".into());
        form.limits.insert("MIO_TOKENS_PER_MINUTE".into(), "0".into());
        assert_eq!(form.problems(&catalog(), &file()), ["Anrop per minut: 1–60. Stoppar en klient som skenar."]);
        form.limits.insert("MIO_REQUESTS_PER_MINUTE".into(), "20".into());
        let changes = form.changes(&file());
        let keys: Vec<(&str, Option<&str>)> = changes.iter().map(|change| (change.key.as_str(), change.after.as_deref())).collect();
        assert_eq!(keys, [("MIO_REQUESTS_PER_MINUTE", Some("20")), ("MIO_TOKENS_PER_MINUTE", None), ("MIO_TOKENS_PER_DAY", Some("150000"))]);
        assert_eq!(AiForm::request(&changes), json!({ "set": { "MIO_REQUESTS_PER_MINUTE": "20", "MIO_TOKENS_PER_DAY": "150000" }, "remove": ["MIO_TOKENS_PER_MINUTE"] }));
    }

    #[test]
    fn an_unreviewed_choice_is_named() {
        let mut form = AiForm::from_file(&file());
        form.default_pair = ("mistral".into(), "mistral-small-2603".into());
        assert_eq!(form.problems(&catalog(), &file()).len(), 3);
        assert!(form.problems(&catalog(), &file())[0].contains("inte en granskad modell"));
        assert_eq!(GatewayFile::parse(&json!({ "exists": false })), None);
    }
}
