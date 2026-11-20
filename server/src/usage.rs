//! The usage counter behind Mio Kontroll's credit meter: per month, task, provider and model,
//! how many provider answers came back and the provider's own token counts. Only numbers and
//! identifiers: never text, never thinking text, never a key. Kept for the current and the
//! previous UTC month in `usage.json` (`{"schemaVersion":1,"months":{"2026-11":[…]}}`).
//! A file with an unknown `schemaVersion` (or one that does not read as version 1) is never
//! overwritten: `/v2/status` then reports `usage: null` and the journal gets one line.

use std::collections::BTreeMap;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::sync::Mutex;

use serde_json::{Map, Value, json};

use crate::adapters::Usage;
use crate::js::{MAX_SAFE_INTEGER, safe_integer};
use crate::model_profiles::price;
use crate::state_store::StoreError;
use crate::task_profiles::TASK_IDS;
use crate::time::civil_from_days;

pub const SCHEMA_VERSION: i64 = 1;
const DAY_MS: i64 = 86_400_000;

/// The UTC calendar month of `time_ms` as `YYYY-MM`.
pub fn month_of(time_ms: i64) -> String {
    let (year, month, _) = civil_from_days(time_ms.div_euclid(DAY_MS));
    format!("{year:04}-{month:02}")
}

fn previous_month(month: &str) -> Option<String> {
    let (year, month) = month.split_once('-')?;
    let (year, month): (i64, i64) = (year.parse().ok()?, month.parse().ok()?);
    Some(if month == 1 { format!("{:04}-12", year - 1) } else { format!("{year:04}-{:02}", month - 1) })
}

fn is_month(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 7 && bytes[4] == b'-' && value.split_once('-').is_some_and(|(year, month)| {
        year.bytes().all(|byte| byte.is_ascii_digit()) && month.parse::<u8>().is_ok_and(|month| (1..=12).contains(&month))
    })
}

fn is_identifier(value: &str) -> bool {
    !crate::task_profiles::safe_model_identifier(value).is_empty()
}

/// One task, provider and model in one month.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Entry {
    pub task: String,
    pub provider: String,
    pub model: String,
    pub requests: i64,
    pub input_tokens: i64,
    pub cached_input_tokens: i64,
    pub output_tokens: i64,
    pub reasoning_tokens: i64,
}

const COUNTS: [&str; 5] = ["requests", "inputTokens", "cachedInputTokens", "outputTokens", "reasoningTokens"];

impl Entry {
    fn counts(&self) -> [i64; 5] {
        [self.requests, self.input_tokens, self.cached_input_tokens, self.output_tokens, self.reasoning_tokens]
    }

    fn from_json(value: &Value) -> Option<Self> {
        let map = value.as_object()?;
        let text = |name: &str| map.get(name)?.as_str().filter(|value| is_identifier(value)).map(str::to_owned);
        let count = |name: &str| safe_integer(map.get(name)?).filter(|count| *count >= 0);
        let entry = Self { task: text("task").filter(|task| TASK_IDS.contains(&task.as_str()))?, provider: text("provider")?,
            model: text("model")?, requests: count("requests")?, input_tokens: count("inputTokens")?,
            cached_input_tokens: count("cachedInputTokens")?, output_tokens: count("outputTokens")?,
            reasoning_tokens: count("reasoningTokens")? };
        (map.len() == 3 + COUNTS.len()).then_some(entry)
    }

    fn to_json(&self) -> Value {
        let mut map = Map::new();
        map.insert("task".to_owned(), json!(self.task));
        map.insert("provider".to_owned(), json!(self.provider));
        map.insert("model".to_owned(), json!(self.model));
        for (name, count) in COUNTS.iter().zip(self.counts()) {
            map.insert((*name).to_owned(), json!(count));
        }
        Value::Object(map)
    }

    fn sort_key(&self) -> (usize, &str, &str) {
        (TASK_IDS.iter().position(|task| *task == self.task).unwrap_or(TASK_IDS.len()), &self.provider, &self.model)
    }
}

/// The counters of the current and previous month.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Ledger {
    pub months: BTreeMap<String, Vec<Entry>>,
}

/// What a store found: a ledger, or a file it must not touch.
#[derive(Debug, Clone, PartialEq)]
pub enum Loaded {
    Ledger(Ledger),
    /// An unknown `schemaVersion` or an unreadable file. Never overwritten.
    Unknown,
}

impl Ledger {
    pub fn from_json(value: &Value) -> Loaded {
        let Some(map) = value.as_object() else { return Loaded::Unknown };
        if map.get("schemaVersion").and_then(safe_integer) != Some(SCHEMA_VERSION) || map.len() != 2 {
            return Loaded::Unknown;
        }
        let Some(months) = map.get("months").and_then(Value::as_object) else { return Loaded::Unknown };
        let mut ledger = Self::default();
        for (month, entries) in months {
            let Some(entries) = entries.as_array().filter(|_| is_month(month)) else { return Loaded::Unknown };
            let Some(entries) = entries.iter().map(Entry::from_json).collect::<Option<Vec<_>>>() else { return Loaded::Unknown };
            ledger.months.insert(month.clone(), entries);
        }
        Loaded::Ledger(ledger)
    }

    pub fn to_json(&self) -> Value {
        let months: Map<String, Value> = self.months.iter()
            .map(|(month, entries)| (month.clone(), entries.iter().map(Entry::to_json).collect())).collect();
        json!({ "schemaVersion": SCHEMA_VERSION, "months": months })
    }

    /// Counts one provider answer. `usage` is `None` when the answer carried no token counts: the
    /// request is still counted. `wire` is the provider's wire: Anthropic's `input_tokens`
    /// leave cache reads out, so they are added to make cached input a part of the input.
    /// Months other than this one and the one before are dropped.
    pub fn record(&mut self, month: &str, task: &str, provider: &str, model: &str, wire: &str, usage: Option<&Usage>) {
        let keep = previous_month(month);
        self.months.retain(|known, _| known == month || keep.as_deref() == Some(known.as_str()));
        let entries = self.months.entry(month.to_owned()).or_default();
        let index = match entries.iter().position(|entry| entry.task == task && entry.provider == provider && entry.model == model) {
            Some(index) => index,
            None => {
                entries.push(Entry { task: task.to_owned(), provider: provider.to_owned(), model: model.to_owned(), ..Entry::default() });
                entries.sort_by(|left, right| left.sort_key().cmp(&right.sort_key()));
                entries.iter().position(|entry| entry.task == task && entry.provider == provider && entry.model == model).unwrap_or(0)
            }
        };
        let entry = &mut entries[index];
        let usage = usage.cloned().unwrap_or_default();
        let cached = usage.cached_input_tokens.unwrap_or(0);
        let input = usage.input_tokens.unwrap_or(0) + if wire == "messages" { cached } else { 0 };
        let add = |counter: &mut i64, value: i64| *counter = counter.saturating_add(value.max(0)).min(MAX_SAFE_INTEGER);
        add(&mut entry.requests, 1);
        add(&mut entry.input_tokens, input);
        add(&mut entry.cached_input_tokens, cached.min(input.max(0)));
        add(&mut entry.output_tokens, usage.output_tokens.unwrap_or(0));
        add(&mut entry.reasoning_tokens, usage.reasoning_tokens.unwrap_or(0).min(usage.output_tokens.unwrap_or(0).max(0)));
    }

    /// The `usage` object of `/v2/status` for `month`.
    pub fn report(&self, month: &str) -> Value {
        let round = |value: f64| (value * 10_000.0).round() / 10_000.0;
        let mut total = 0.0;
        let entries: Vec<Value> = self.months.get(month).map(Vec::as_slice).unwrap_or_default().iter().map(|entry| {
            let mut value = entry.to_json();
            let priced = price(&entry.provider, &entry.model);
            let cost = priced.map(|price| {
                let uncached = (entry.input_tokens - entry.cached_input_tokens).max(0) as f64;
                (uncached * price.input + entry.cached_input_tokens as f64 * price.cached_input
                    + entry.output_tokens as f64 * price.output) / 1_000_000.0
            });
            total += cost.unwrap_or(0.0);
            value["estimatedCost"] = json!(cost.map(round));
            value["pricesAsOf"] = json!(priced.map(|price| price.as_of));
            value
        }).collect();
        json!({ "month": month, "currency": "USD", "estimatedCost": round(total), "entries": entries })
    }
}

pub trait UsageStore: Send + Sync {
    fn load(&self) -> Loaded;
    fn save(&self, ledger: &Ledger) -> Result<(), StoreError>;
}

#[derive(Default)]
pub struct MemoryUsageStore(Mutex<Option<Ledger>>);

impl UsageStore for MemoryUsageStore {
    fn load(&self) -> Loaded {
        Loaded::Ledger(self.0.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).clone().unwrap_or_default())
    }

    fn save(&self, ledger: &Ledger) -> Result<(), StoreError> {
        *self.0.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(ledger.clone());
        Ok(())
    }
}

/// `/var/lib/mio-gateway/usage.json`, 0600, replaced atomically.
pub struct FileUsageStore {
    path: PathBuf,
}

impl FileUsageStore {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }
}

impl UsageStore for FileUsageStore {
    /// A missing file starts empty. Anything else that is not a version-1 ledger is left alone.
    fn load(&self) -> Loaded {
        match std::fs::read(&self.path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Loaded::Ledger(Ledger::default()),
            Err(_) => Loaded::Unknown,
            Ok(bytes) => serde_json::from_slice::<Value>(&bytes).map_or(Loaded::Unknown, |value| Ledger::from_json(&value)),
        }
    }

    fn save(&self, ledger: &Ledger) -> Result<(), StoreError> {
        let mut temporary = self.path.clone().into_os_string();
        temporary.push(".tmp");
        let mut file = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600)
            .open(&temporary).map_err(|_| StoreError)?;
        file.write_all(ledger.to_json().to_string().as_bytes()).map_err(|_| StoreError)?;
        drop(file);
        std::fs::rename(&temporary, &self.path).map_err(|_| StoreError)
    }
}
