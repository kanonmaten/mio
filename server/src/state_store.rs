//! The only state the gateway keeps: five integers. No text, credential, IP or user profile.

use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::sync::Mutex;

use serde_json::{Value, json};

use crate::js::safe_integer;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Counters {
    pub minute: i64,
    pub minute_count: i64,
    pub day: i64,
    pub day_count: i64,
    pub day_tokens: i64,
}

impl Default for Counters {
    fn default() -> Self {
        Self { minute: -1, minute_count: 0, day: -1, day_count: 0, day_tokens: 0 }
    }
}

impl Counters {
    pub fn from_json(value: &Value) -> Option<Self> {
        let field = |name: &str, minimum: i64| safe_integer(value.as_object()?.get(name)?).filter(|number| *number >= minimum);
        Some(Self { minute: field("minute", -1)?, minute_count: field("minuteCount", 0)?, day: field("day", -1)?,
            day_count: field("dayCount", 0)?, day_tokens: field("dayTokens", 0)? })
    }

    pub fn to_json(&self) -> Value {
        json!({ "minute": self.minute, "minuteCount": self.minute_count, "day": self.day,
            "dayCount": self.day_count, "dayTokens": self.day_tokens })
    }
}

#[derive(Debug)]
pub struct StoreError;

pub trait CounterStore: Send + Sync {
    fn load(&self) -> Counters;
    fn save(&self, counters: &Counters) -> Result<(), StoreError>;
}

#[derive(Default)]
pub struct MemoryCounterStore(Mutex<Counters>);

impl CounterStore for MemoryCounterStore {
    fn load(&self) -> Counters {
        *self.0.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn save(&self, counters: &Counters) -> Result<(), StoreError> {
        *self.0.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = *counters;
        Ok(())
    }
}

/// Survives gateway restarts so a restart cannot reset the daily Groq allowance.
pub struct FileCounterStore {
    path: PathBuf,
}

impl FileCounterStore {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }
}

impl CounterStore for FileCounterStore {
    /// A missing, corrupt or foreign file starts empty instead of crashing or being trusted.
    fn load(&self) -> Counters {
        std::fs::read_to_string(&self.path).ok()
            .and_then(|text| serde_json::from_str::<Value>(&text).ok())
            .and_then(|value| Counters::from_json(&value)).unwrap_or_default()
    }

    fn save(&self, counters: &Counters) -> Result<(), StoreError> {
        // Atomic replace: a crash mid-write leaves the previous counters, never a torn file.
        let mut temporary = self.path.clone().into_os_string();
        temporary.push(".tmp");
        let mut file = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600)
            .open(&temporary).map_err(|_| StoreError)?;
        file.write_all(counters.to_json().to_string().as_bytes()).map_err(|_| StoreError)?;
        drop(file);
        std::fs::rename(&temporary, &self.path).map_err(|_| StoreError)
    }
}
