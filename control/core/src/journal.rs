//! Loggar: the services' journal, read as the user with `journalctl -o json`. The gateway and
//! Pianissimo never log text, keys or words, and the panel adds nothing.

use std::process::{Command, Stdio};

use serde_json::Value;

/// How many entries the page shows at most; older ones fall off the top in follow mode.
pub const MAX_LINES: usize = 1_000;
/// Entries read when the page opens.
const FIRST_READ: &str = "300";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum LogUnit {
    Gateway,
    Pianissimo,
    ModelUpdate,
}

impl LogUnit {
    pub const ALL: [LogUnit; 3] = [LogUnit::Gateway, LogUnit::Pianissimo, LogUnit::ModelUpdate];

    pub fn unit(self) -> &'static str {
        match self {
            LogUnit::Gateway => "mio-gateway.service",
            LogUnit::Pianissimo => "mio-transcription.service",
            LogUnit::ModelUpdate => "mio-pianissimo-update.service",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            LogUnit::Gateway => "AI-gatewayen",
            LogUnit::Pianissimo => "Pianissimo",
            LogUnit::ModelUpdate => "Nattuppdateringen",
        }
    }
}

/// The level filter, by syslog priority (journald's `PRIORITY`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Level {
    Errors,
    Warnings,
    Info,
    All,
}

impl Level {
    pub const ALL: [Level; 4] = [Level::Errors, Level::Warnings, Level::Info, Level::All];

    pub fn title(self) -> &'static str {
        match self {
            Level::Errors => "Fel",
            Level::Warnings => "Varningar",
            Level::Info => "Info",
            Level::All => "Allt",
        }
    }

    pub fn shows(self, priority: u8) -> bool {
        priority
            <= match self {
                Level::Errors => 3,
                Level::Warnings => 4,
                Level::Info => 6,
                Level::All => 7,
            }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub cursor: String,
    /// Seconds since the epoch.
    pub time: u64,
    pub priority: u8,
    pub message: String,
}

impl Entry {
    pub fn parse(line: &str) -> Option<Self> {
        let json: Value = serde_json::from_str(line).ok()?;
        let text = |key: &str| json.get(key).and_then(Value::as_str);
        // journald sends a message that is not valid UTF-8 as an array of bytes.
        let message = match json.get("MESSAGE")? {
            Value::String(text) => text.clone(),
            Value::Array(bytes) => String::from_utf8_lossy(&bytes.iter().filter_map(|byte| byte.as_u64().map(|byte| byte as u8)).collect::<Vec<_>>()).into_owned(),
            _ => return None,
        };
        Some(Self {
            cursor: text("__CURSOR")?.to_owned(),
            time: text("__REALTIME_TIMESTAMP").and_then(|micros| micros.parse::<u64>().ok()).map_or(0, |micros| micros / 1_000_000),
            priority: text("PRIORITY").and_then(|priority| priority.parse().ok()).unwrap_or(6),
            message,
        })
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Read {
    pub entries: Vec<Entry>,
    /// Set when journalctl says the user may not read the system journal.
    pub hint: Option<String>,
}

pub fn arguments(unit: LogUnit, after: Option<&str>) -> Vec<String> {
    let mut arguments: Vec<String> = ["-u", unit.unit(), "-o", "json", "--no-pager"].into_iter().map(str::to_owned).collect();
    match after {
        // Follow mode polls for what came after the last entry shown.
        Some(cursor) => arguments.push(format!("--after-cursor={cursor}")),
        None => arguments.extend(["-n".to_owned(), FIRST_READ.to_owned()]),
    }
    arguments
}

pub fn parse_output(stdout: &str, stderr: &str) -> Read {
    let hint = (stderr.contains("not seeing messages") || stderr.contains("insufficient permissions")).then(|| {
        "Ditt konto får inte läsa systemets journal. Lägg till det i gruppen systemd-journal (sudo usermod -aG systemd-journal $USER) och logga in igen.".to_owned()
    });
    Read { entries: stdout.lines().filter_map(Entry::parse).collect(), hint }
}

pub fn read(unit: LogUnit, after: Option<&str>) -> Result<Read, String> {
    let output = Command::new("journalctl")
        .args(arguments(unit, after))
        .stdin(Stdio::null())
        .output()
        .map_err(|_| "journalctl saknas på den här datorn.".to_owned())?;
    let read = parse_output(&String::from_utf8_lossy(&output.stdout), &String::from_utf8_lossy(&output.stderr));
    if output.status.success() || !read.entries.is_empty() {
        Ok(read)
    } else {
        Err(read.hint.unwrap_or_else(|| "journalctl kunde inte läsa journalen.".to_owned()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entries_parse_with_bytes_and_missing_priority() {
        let text = r#"{"__CURSOR":"s=1","__REALTIME_TIMESTAMP":"1763370000123456","PRIORITY":"3","MESSAGE":"Groq svarade 429"}
{"__CURSOR":"s=2","__REALTIME_TIMESTAMP":"1763370001000000","MESSAGE":[104,195,165,106]}
not json
{"__CURSOR":"s=3","MESSAGE":null}"#;
        let read = parse_output(text, "");
        assert_eq!(read.entries.len(), 2);
        assert_eq!(read.entries[0], Entry { cursor: "s=1".into(), time: 1_763_370_000, priority: 3, message: "Groq svarade 429".into() });
        assert_eq!((read.entries[1].priority, read.entries[1].message.as_str()), (6, "håj"));
        assert!(read.hint.is_none());
        assert!(parse_output("", "Hint: You are currently not seeing messages from other users and the system.").hint.is_some());
    }

    #[test]
    fn levels_and_arguments() {
        assert!(Level::Errors.shows(3) && !Level::Errors.shows(4));
        assert!(Level::Warnings.shows(4) && !Level::Info.shows(7) && Level::All.shows(7));
        assert_eq!(arguments(LogUnit::Gateway, None), ["-u", "mio-gateway.service", "-o", "json", "--no-pager", "-n", "300"]);
        assert_eq!(arguments(LogUnit::Pianissimo, Some("s=9")).last().unwrap(), "--after-cursor=s=9");
    }
}
