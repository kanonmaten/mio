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

/// systemd's `SD_MESSAGE_UNIT_STARTING`: logged by PID 1 each time a start job for a unit begins,
/// whether the user, the panel or `Restart=` started it.
pub const UNIT_STARTING: &str = "7d4958e842da4a758f6c1cdc7b36dcc5";

/// Arguments for the services' start entries since `since` (seconds since the epoch). Field
/// matches on different fields are ANDed, so this reads only PID 1's "Starting …" lines.
pub fn start_arguments(unit: LogUnit, since: u64) -> Vec<String> {
    vec![
        "_PID=1".to_owned(),
        format!("UNIT={}", unit.unit()),
        format!("MESSAGE_ID={UNIT_STARTING}"),
        format!("--since=@{since}"),
        "-o".to_owned(),
        "json".to_owned(),
        "--no-pager".to_owned(),
    ]
}

/// The start times in `journalctl -o json` output, oldest first. `None` when the user may not
/// read the system journal, because then an empty list would mean nothing.
pub fn parse_starts(stdout: &str, stderr: &str) -> Option<Vec<u64>> {
    let read = parse_output(stdout, stderr);
    if read.hint.is_some() {
        return None;
    }
    let mut starts = stdout
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(|json| json.get("MESSAGE_ID").and_then(Value::as_str) == Some(UNIT_STARTING))
        .filter_map(|json| json.get("__REALTIME_TIMESTAMP")?.as_str()?.parse::<u64>().ok())
        .map(|micros| micros / 1_000_000)
        .collect::<Vec<_>>();
    starts.sort_unstable();
    Some(starts)
}

/// When `unit` was started since `since`; `None` when the journal could not be read.
pub fn recent_starts(unit: LogUnit, since: u64) -> Option<Vec<u64>> {
    let output = Command::new("journalctl").args(start_arguments(unit, since)).stdin(Stdio::null()).output().ok()?;
    let starts = parse_starts(&String::from_utf8_lossy(&output.stdout), &String::from_utf8_lossy(&output.stderr))?;
    (output.status.success() || !starts.is_empty()).then_some(starts)
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

    #[test]
    fn start_entries_are_read_as_times() {
        let arguments = start_arguments(LogUnit::Gateway, 1_763_370_000);
        assert_eq!(arguments[..4], ["_PID=1", "UNIT=mio-gateway.service", "MESSAGE_ID=7d4958e842da4a758f6c1cdc7b36dcc5", "--since=@1763370000"]);
        let text = r#"{"__CURSOR":"s=2","__REALTIME_TIMESTAMP":"1763370300000000","MESSAGE_ID":"7d4958e842da4a758f6c1cdc7b36dcc5","MESSAGE":"Starting Mio AI-gateway..."}
{"__CURSOR":"s=1","__REALTIME_TIMESTAMP":"1763370100000000","MESSAGE_ID":"7d4958e842da4a758f6c1cdc7b36dcc5","MESSAGE":"Starting Mio AI-gateway..."}
{"__CURSOR":"s=3","__REALTIME_TIMESTAMP":"1763370400000000","MESSAGE_ID":"39f53479d3a045ac8e11786248231fbf","MESSAGE":"Started Mio AI-gateway."}"#;
        assert_eq!(parse_starts(text, ""), Some(vec![1_763_370_100, 1_763_370_300]));
        assert_eq!(parse_starts("", ""), Some(vec![]));
        assert_eq!(parse_starts("", "Hint: You are currently not seeing messages from other users and the system."), None);
    }
}
