//! The AI page's model: which reviewed pair each task uses, the gateway's limits, and the list of
//! changes shown before anything is saved. The gateway checks the file again before it is
//! written (`mio-gateway kontrollera-konfiguration`); these checks only keep the form honest.

use std::collections::BTreeMap;

use serde_json::{Map, Value, json};

pub const TASKS: [(&str, &str); 3] = [("ask", "Frågor"), ("everyday", "Vardag"), ("lesson", "Lektioner")];

/// Prices per million tokens, in dollars.
#[derive(Clone, Debug, PartialEq)]
pub struct Price {
    pub input_per_million: f64,
    pub output_per_million: f64,
    pub as_of: String,
}

/// Mistral's list prices, reviewed 2026-11-20, for a gateway that does not send `prices` with its
/// model list. Matched on the model family so that the exact model ID (chosen in the gateway's
/// reviewed profiles) is not repeated here.
const REVIEWED_PRICES: [(&str, &str, f64, f64); 2] = [("mistral", "mistral-small", 0.15, 0.60), ("mistral", "mistral-large", 0.70, 2.10)];
const REVIEWED_PRICES_AS_OF: &str = "2026-11-20";

/// What "Prova" sends: one short made-up call per task the pair may serve (`mio-gateway prova`
/// tries a pair that reasons on `lesson` alone). A rough upper bound in tokens per call for the
/// estimate shown next to the button; reasoning counts as output.
pub const TRIAL_INPUT_TOKENS_PER_CALL: u64 = 1_500;
pub const TRIAL_OUTPUT_TOKENS_PER_CALL: u64 = 500;
/// `max_tokens` for a lesson on a pair that reasons: the gateway's
/// `LESSON_REASONING_MAX_OUTPUT_TOKENS` (`server/src/config.rs`), so the estimate covers a full
/// answer with its thinking.
pub const TRIAL_REASONING_OUTPUT_TOKENS: u64 = 12_000;

/// `gateway.env`'s list of candidates approved after a passed trial, written only by the panel's
/// helper: `provider=model` entries separated by commas (`server/src/config.rs`).
pub const APPROVED_CANDIDATES_KEY: &str = "MIO_APPROVED_CANDIDATES";

/// One provider and model pair from `mio-gateway granskade-modeller`.
#[derive(Clone, Debug, PartialEq)]
pub struct Pair {
    pub provider: String,
    pub model: String,
    pub secret_variable: String,
    /// `"0"`, or `"provider-default"` when the provider refuses temperature.
    pub temperature: String,
    /// Why a candidate cannot be chosen; `None` for a reviewed or approved pair.
    pub blocked: Option<String>,
    /// A candidate listed in `MIO_APPROVED_CANDIDATES`: selectable like a reviewed pair.
    pub approved: bool,
    /// `"off"` or the reviewed reasoning level; `None` from a gateway that does not say.
    pub reasoning: Option<String>,
    /// The tasks the pair may be chosen for; `None` means all of them.
    pub tasks: Option<Vec<String>>,
    /// From the model list's `prices`, or the reviewed constant above.
    pub price: Option<Price>,
}

impl Pair {
    pub fn label(&self) -> String {
        format!("{} · {}", provider_name(&self.provider), self.model)
    }

    pub fn is(&self, provider: &str, model: &str) -> bool {
        self.provider == provider && self.model == model
    }

    pub fn allows(&self, task: &str) -> bool {
        self.tasks.as_ref().is_none_or(|tasks| tasks.iter().any(|allowed| allowed == task))
    }

    /// Whether the pair reasons at all (anything but `"off"`).
    pub fn reasons(&self) -> bool {
        self.reasoning.as_deref().is_some_and(|reasoning| reasoning != "off")
    }

    /// "Resonerar (hög) · bara Lektioner", or `None` for a plain pair.
    pub fn note(&self) -> Option<String> {
        let mut parts = Vec::new();
        if self.approved {
            parts.push("godkänd efter prov".to_owned());
        }
        if self.reasons() {
            parts.push(crate::status::reasoning_label(self.reasoning.as_deref().unwrap_or_default()));
        }
        if let Some(tasks) = self.tasks.as_ref().filter(|tasks| tasks.len() < TASKS.len()) {
            let names: Vec<&str> = TASKS.iter().filter(|(id, _)| tasks.iter().any(|task| task == id)).map(|(_, label)| *label).collect();
            parts.push(format!("går bara att välja för {}", names.join(" och ")));
        }
        (!parts.is_empty()).then(|| {
            let text = parts.join(" · ");
            let mut characters = text.chars();
            characters.next().map(|first| first.to_uppercase().chain(characters).collect()).unwrap_or_default()
        })
    }

    /// The tasks "Prova" sends a call for, as `mio-gateway prova` does: those the pair may serve,
    /// and only `lesson` for a pair that reasons.
    fn trial_tasks(&self) -> Vec<&'static str> {
        TASKS.iter().map(|(task, _)| *task).filter(|task| self.allows(task) && (!self.reasons() || *task == "lesson")).collect()
    }

    /// What pressing "Prova" sends and costs, in one sentence for the row under the pair.
    pub fn trial_estimate(&self) -> String {
        let provider = provider_name(&self.provider);
        let tasks = self.trial_tasks();
        let input = TRIAL_INPUT_TOKENS_PER_CALL * tasks.len() as u64;
        let output: u64 = tasks
            .iter()
            .map(|task| if self.reasons() && *task == "lesson" { TRIAL_REASONING_OUTPUT_TOKENS } else { TRIAL_OUTPUT_TOKENS_PER_CALL })
            .sum();
        let calls = match tasks.len() {
            1 => "ett kort påhittat anrop".to_owned(),
            2 => "två korta påhittade anrop".to_owned(),
            3 => "tre korta påhittade anrop".to_owned(),
            count => format!("{count} korta påhittade anrop"),
        };
        let thinking = if self.reasons() { " med resonemang" } else { "" };
        let tokens = crate::format::count(input + output);
        match &self.price {
            Some(price) => {
                let cost = (input as f64 * price.input_per_million + output as f64 * price.output_per_million) / 1_000_000.0;
                let size = if cost < 0.01 { ", under en cent" } else { "" };
                format!(
                    "Går till {provider}: {calls}{thinking}, högst cirka {tokens} token. Uppskattat {}{size} (priser {}).",
                    crate::credit::dollars(cost),
                    price.as_of
                )
            }
            None => format!("Går till {provider}: {calls}{thinking}, högst cirka {tokens} token, debiteras som vanliga anrop."),
        }
    }
}

fn reviewed_price(provider: &str, model: &str) -> Option<Price> {
    REVIEWED_PRICES.iter().find(|(known, family, _, _)| *known == provider && model.starts_with(family)).map(|(_, _, input, output)| Price {
        input_per_million: *input,
        output_per_million: *output,
        as_of: REVIEWED_PRICES_AS_OF.to_owned(),
    })
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

/// The reviewed pairs (selectable, with approved candidates once `with_approved` has run) and the
/// candidates (shown, not selectable).
#[derive(Clone, Debug, PartialEq, Default)]
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
                    let (provider, model) = (text("provider")?, text("model")?);
                    let listed_price = pair.get("prices").and_then(|prices| {
                        let per_million = |name: &str| prices.get(name).and_then(Value::as_f64).filter(|price| price.is_finite() && *price >= 0.0);
                        Some(Price {
                            input_per_million: per_million("inputPerMillion")?,
                            output_per_million: per_million("outputPerMillion")?,
                            as_of: prices.get("asOf").and_then(Value::as_str)?.to_owned(),
                        })
                    });
                    Some(Pair {
                        secret_variable: text("secretVariable")?,
                        temperature: text("temperature").unwrap_or_else(|| "0".to_owned()),
                        blocked: text("blocked"),
                        approved: false,
                        reasoning: text("reasoning"),
                        tasks: pair.get("tasks").and_then(Value::as_array).map(|tasks| tasks.iter().filter_map(Value::as_str).map(str::to_owned).collect()),
                        price: listed_price.or_else(|| reviewed_price(&provider, &model)),
                        provider,
                        model,
                    })
                })
                .collect()
        };
        Some(Self { reviewed: pairs("models")?, candidates: pairs("candidates").unwrap_or_default() })
    }

    /// Moves the candidates `file` lists in `MIO_APPROVED_CANDIDATES` (passed a trial; the
    /// gateway then accepts them, `approved_profile` in `server/src/model_profiles.rs`) to the
    /// selectable pairs. Each keeps its `tasks`, so an approved pair that reasons stays lesson-only.
    /// A candidate that is not listed stays unselectable.
    pub fn with_approved(mut self, file: &GatewayFile) -> Self {
        let approved: Vec<&str> = file.value(APPROVED_CANDIDATES_KEY).unwrap_or_default().split(',').map(str::trim).filter(|entry| !entry.is_empty()).collect();
        let (passed, waiting): (Vec<Pair>, Vec<Pair>) = std::mem::take(&mut self.candidates)
            .into_iter()
            .partition(|pair| approved.iter().any(|entry| *entry == format!("{}={}", pair.provider, pair.model)));
        self.candidates = waiting;
        self.reviewed.extend(passed.into_iter().map(|pair| Pair { blocked: None, approved: true, ..pair }));
        self
    }

    pub fn find(&self, provider: &str, model: &str) -> Option<&Pair> {
        self.reviewed.iter().find(|pair| pair.is(provider, model))
    }

    /// The reviewed pairs a select offers: for one task, those allowed for it; for the default
    /// (`None`), those allowed for every task, since the default covers every task left on it.
    pub fn choices(&self, task: Option<&str>) -> Vec<&Pair> {
        self.reviewed
            .iter()
            .filter(|pair| match task {
                Some(task) => pair.allows(task),
                None => TASKS.iter().all(|(task, _)| pair.allows(task)),
            })
            .collect()
    }

    /// The "Prova" list: Mistral first (candidates before reviewed), then the rest as listed.
    pub fn trial_order(&self) -> Vec<&Pair> {
        let all: Vec<&Pair> = self.candidates.iter().chain(&self.reviewed).collect();
        let mistral = all.iter().copied().filter(|pair| pair.provider == "mistral");
        let rest = self.reviewed.iter().chain(&self.candidates).filter(|pair| pair.provider != "mistral");
        mistral.chain(rest).collect()
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
                Some(pair) if !pair.allows(task) => {
                    problems.push(format!("{label}: {} går bara att välja för en annan uppgift.", pair.label()));
                }
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

    /// A model list from a gateway after the grilling: a reasoning pair only for lessons. The
    /// field names (`reasoning`, `tasks`, `prices`) are what the panel reads; values are made up.
    fn catalog_with_lesson_only() -> Catalog {
        Catalog::parse(&json!({ "models": [
                { "provider": "groq", "model": "qwen/qwen3.8-27b", "secretVariable": "GROQ_API_KEY", "reasoning": "off" },
                { "provider": "mistral", "model": "mistral-small-x", "secretVariable": "MISTRAL_API_KEY", "reasoning": "off" },
                { "provider": "mistral", "model": "mistral-large-x", "secretVariable": "MISTRAL_API_KEY", "reasoning": "high", "tasks": ["lesson"],
                  "prices": { "inputPerMillion": 0.7, "outputPerMillion": 2.1, "asOf": "2026-11-21" } }],
            "candidates": [{ "provider": "nvidia", "model": "nemotron", "secretVariable": "NVIDIA_API_KEY", "blocked": "Kräver prov." },
                { "provider": "mistral", "model": "mistral-medium-x", "secretVariable": "MISTRAL_API_KEY", "blocked": "Kräver prov." }] }))
        .unwrap()
    }

    #[test]
    fn a_lesson_only_pair_is_offered_and_accepted_only_for_lessons() {
        let catalog = catalog_with_lesson_only();
        let models = |task: Option<&str>| catalog.choices(task).iter().map(|pair| pair.model.clone()).collect::<Vec<_>>();
        assert_eq!(models(None), ["qwen/qwen3.8-27b", "mistral-small-x"]);
        assert_eq!(models(Some("ask")), ["qwen/qwen3.8-27b", "mistral-small-x"]);
        assert_eq!(models(Some("lesson")), ["qwen/qwen3.8-27b", "mistral-small-x", "mistral-large-x"]);
        let large = catalog.find("mistral", "mistral-large-x").unwrap();
        assert_eq!(large.note().as_deref(), Some("Resonerar (hög) · går bara att välja för Lektioner"));
        assert_eq!(catalog.find("mistral", "mistral-small-x").unwrap().note(), None);
        let mut with_key = file();
        with_key.secrets.insert("MISTRAL_API_KEY".into(), true);
        let mut form = AiForm::from_file(&with_key);
        form.per_task.insert("lesson".into(), ("mistral".into(), "mistral-large-x".into()));
        assert!(form.problems(&catalog, &with_key).is_empty());
        form.per_task.insert("ask".into(), ("mistral".into(), "mistral-large-x".into()));
        assert_eq!(form.problems(&catalog, &with_key), ["Frågor: Mistral · mistral-large-x går bara att välja för en annan uppgift."]);
    }

    #[test]
    fn mistral_comes_first_in_the_trial_list_with_what_it_costs() {
        let catalog = catalog_with_lesson_only();
        let order: Vec<&str> = catalog.trial_order().iter().map(|pair| pair.model.as_str()).collect();
        assert_eq!(order, ["mistral-medium-x", "mistral-small-x", "mistral-large-x", "qwen/qwen3.8-27b", "nemotron"]);
        // The listed price wins over the reviewed constant; Small falls back to the constant.
        // Large reasons, so it is tried on lessons alone, with room for a full answer and its
        // thinking: 1 500 + 12 000 token, 1 500 × $0,70/M + 12 000 × $2,10/M.
        let large = catalog.find("mistral", "mistral-large-x").unwrap();
        assert_eq!(large.trial_estimate(), "Går till Mistral: ett kort påhittat anrop med resonemang, högst cirka 13\u{202F}500 token. Uppskattat $0,0262 (priser 2026-11-21).");
        let small = catalog.find("mistral", "mistral-small-x").unwrap();
        assert_eq!(small.price.as_ref().map(|price| (price.input_per_million, price.as_of.as_str())), Some((0.15, "2026-11-20")));
        assert_eq!(small.trial_estimate(), "Går till Mistral: tre korta påhittade anrop, högst cirka 6\u{202F}000 token. Uppskattat $0,0016, under en cent (priser 2026-11-20).");
        // No price known: no amount is made up.
        let groq = catalog.find("groq", "qwen/qwen3.8-27b").unwrap();
        assert_eq!(groq.trial_estimate(), "Går till Groq: tre korta påhittade anrop, högst cirka 6\u{202F}000 token, debiteras som vanliga anrop.");
        // A plain pair limited to two tasks is tried on those two.
        let two = Pair { tasks: Some(vec!["ask".into(), "lesson".into()]), ..groq.clone() };
        assert_eq!(two.trial_estimate(), "Går till Groq: två korta påhittade anrop, högst cirka 4\u{202F}000 token, debiteras som vanliga anrop.");
        assert_eq!(catalog.candidates[1].price.as_ref(), None, "mistral-medium has no reviewed price");
    }

    /// The panel's model list comes from `mio-gateway granskade-modeller`, run without
    /// `gateway.env`, so an approved candidate is still listed under `candidates`. Made-up names.
    fn catalog_with_candidates() -> Catalog {
        Catalog::parse(&json!({ "models": [
                { "provider": "groq", "model": "qwen/qwen3.8-27b", "secretVariable": "GROQ_API_KEY", "reasoning": "off" }],
            "candidates": [
                { "provider": "mistral", "model": "mistral-small-x", "secretVariable": "MISTRAL_API_KEY", "reasoning": "off",
                  "tasks": ["ask", "everyday", "lesson"], "blocked": "Kräver prov." },
                { "provider": "mistral", "model": "mistral-large-x", "secretVariable": "MISTRAL_API_KEY", "reasoning": "high",
                  "tasks": ["lesson"], "blocked": "Kräver prov." },
                { "provider": "nvidia", "model": "nemotron-x", "secretVariable": "NVIDIA_API_KEY", "reasoning": "off", "blocked": "Kräver prov." }] }))
        .unwrap()
    }

    fn file_with_approved(approved: &str) -> GatewayFile {
        let mut file = file();
        file.values.insert(APPROVED_CANDIDATES_KEY.into(), approved.into());
        file.secrets.insert("MISTRAL_API_KEY".into(), true);
        file.secrets.insert("NVIDIA_API_KEY".into(), true);
        file
    }

    #[test]
    fn an_approved_candidate_becomes_selectable_for_its_own_tasks() {
        // The helper writes `provider=model` joined by commas; spaces are tolerated as by the gateway.
        let file = file_with_approved("mistral=mistral-small-x, mistral=mistral-large-x");
        let catalog = catalog_with_candidates().with_approved(&file);
        let models = |task: Option<&str>| catalog.choices(task).iter().map(|pair| pair.model.clone()).collect::<Vec<_>>();
        assert_eq!(models(None), ["qwen/qwen3.8-27b", "mistral-small-x"]);
        assert_eq!(models(Some("everyday")), ["qwen/qwen3.8-27b", "mistral-small-x"]);
        assert_eq!(models(Some("lesson")), ["qwen/qwen3.8-27b", "mistral-small-x", "mistral-large-x"]);
        let small = catalog.find("mistral", "mistral-small-x").unwrap();
        assert_eq!((small.blocked.as_deref(), small.approved, small.note().as_deref()), (None, true, Some("Godkänd efter prov")));
        assert_eq!(catalog.find("mistral", "mistral-large-x").unwrap().note().as_deref(), Some("Godkänd efter prov · Resonerar (hög) · går bara att välja för Lektioner"));
        // The unapproved candidate stays where it was and cannot be chosen.
        assert_eq!(catalog.candidates.iter().map(|pair| pair.model.as_str()).collect::<Vec<_>>(), ["nemotron-x"]);
        assert_eq!(catalog.find("nvidia", "nemotron-x"), None);

        // A fresh install that runs Mistral: default Small, lessons on Large. Nothing to fix.
        let mut mistral = file.clone();
        mistral.values.insert("MIO_AI_PROVIDER".into(), "mistral".into());
        mistral.values.insert("MIO_AI_MODEL".into(), "mistral-small-x".into());
        mistral.values.insert("MIO_AI_TASK_PROFILES".into(), r#"{"lesson":{"provider":"mistral","model":"mistral-large-x"}}"#.into());
        let mut form = AiForm::from_file(&mistral);
        assert_eq!(form.problems(&catalog, &mistral), Vec::<String>::new());
        assert!(!form.changes(&mistral).iter().any(|change| change.key == APPROVED_CANDIDATES_KEY), "the form never rewrites the approvals");
        // Large stays lesson-only after approval.
        form.per_task.insert("ask".into(), ("mistral".into(), "mistral-large-x".into()));
        assert_eq!(form.problems(&catalog, &mistral), ["Frågor: Mistral · mistral-large-x går bara att välja för en annan uppgift."]);
    }

    #[test]
    fn an_unapproved_candidate_still_cannot_be_chosen() {
        // A Groq install switching to Mistral before any passed trial, or with another pair approved.
        for approved in ["", "nvidia=nemotron-x", "mistral=mistral-small", "mistral-small-x", "groq=mistral-small-x"] {
            let file = file_with_approved(approved);
            let catalog = catalog_with_candidates().with_approved(&file);
            assert_eq!(catalog.find("mistral", "mistral-small-x"), None, "{approved:?}");
            let mut form = AiForm::from_file(&file);
            form.default_pair = ("mistral".into(), "mistral-small-x".into());
            let problems = form.problems(&catalog, &file);
            assert_eq!(problems.len(), 3, "{approved:?}");
            assert!(problems[0].contains("inte en granskad modell"));
        }
        // Without the setting at all (an older gateway.env), nothing moves.
        assert_eq!(catalog_with_candidates().with_approved(&file()), catalog_with_candidates());
        // Once approved, the same switch from Groq is accepted.
        let file = file_with_approved("mistral=mistral-small-x");
        let mut form = AiForm::from_file(&file);
        form.default_pair = ("mistral".into(), "mistral-small-x".into());
        assert!(form.problems(&catalog_with_candidates().with_approved(&file), &file).is_empty());
    }
}
