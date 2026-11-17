//! The latest `mio-verify verify` receipt, which the panel's verification page writes.

use std::io::{BufRead as _, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::Stdio;

use serde_json::Value;

/// Where the panel keeps the verifier's logs and receipt: `$XDG_STATE_HOME/mio-control/verifiering`.
pub fn logs_dir() -> Option<PathBuf> {
    let state = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state")))?;
    Some(state.join("mio-control/verifiering"))
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GateResult {
    pub gate: String,
    pub result: String,
    pub seconds: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Receipt {
    /// `PASS (Linux synthetic gates)`, `PARTIAL` or `FAIL`.
    pub result: String,
    pub finished_at: Option<String>,
    pub commit: Option<String>,
    pub dirty: bool,
    pub gates: Vec<GateResult>,
}

impl Receipt {
    pub fn parse(json: &Value) -> Option<Self> {
        let text = |value: Option<&Value>| value.and_then(Value::as_str).map(str::to_owned);
        Some(Self {
            result: text(json.get("result"))?,
            finished_at: text(json.get("finishedAt")),
            commit: text(json.get("baseCommit")),
            dirty: json.get("dirtyWorktree").and_then(Value::as_bool).unwrap_or(false),
            gates: json
                .get("gates")
                .and_then(Value::as_array)
                .map(|gates| {
                    gates
                        .iter()
                        .filter_map(|gate| {
                            Some(GateResult {
                                gate: text(gate.get("gate"))?,
                                result: text(gate.get("result"))?,
                                seconds: gate.get("seconds").and_then(Value::as_f64).map(|seconds| format!("{seconds:.0} s")),
                            })
                        })
                        .collect()
                })
                .unwrap_or_default(),
        })
    }

    pub fn passed(&self) -> bool {
        self.result.starts_with("PASS")
    }

    /// The latest receipt in [`logs_dir`], if the panel has run the verifier.
    pub fn latest() -> Option<Self> {
        let bytes = std::fs::read(logs_dir()?.join("verification.json")).ok()?;
        Self::parse(&serde_json::from_slice(&bytes).ok()?)
    }
}

/// The command the verification page runs, as the user, in the repo the panel was built from.
pub fn verify_command(repo: &Path, logs: &Path) -> std::process::Command {
    let mut command = std::process::Command::new("cargo");
    command
        .current_dir(repo)
        .args(["run", "--locked", "--manifest-path", "tools/Cargo.toml", "--", "verify", "--logs-dir"])
        .arg(logs)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    command
}

/// Runs `command`, handing each line of stdout and stderr to `line` as it comes, and returns
/// whether it succeeded.
pub fn run_streaming(mut command: std::process::Command, line: &mut dyn FnMut(String)) -> Result<bool, String> {
    let mut child = command.spawn().map_err(|_| "cargo saknas. Installera Rust för att köra verifieringen.".to_owned())?;
    let (sender, receiver) = std::sync::mpsc::channel();
    let readers: Vec<_> = [child.stdout.take().map(|out| Box::new(out) as Box<dyn Read + Send>), child.stderr.take().map(|err| Box::new(err) as Box<dyn Read + Send>)]
        .into_iter()
        .flatten()
        .map(|stream| {
            let sender = sender.clone();
            std::thread::spawn(move || {
                for text in BufReader::new(stream).lines().map_while(Result::ok) {
                    let _ = sender.send(text);
                }
            })
        })
        .collect();
    drop(sender);
    for text in receiver {
        line(text);
    }
    readers.into_iter().for_each(|reader| drop(reader.join()));
    child.wait().map(|status| status.success()).map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_receipt_from_the_verifier() {
        let receipt = Receipt::parse(&json!({"result": "PASS (Linux synthetic gates)", "finishedAt": "2026-11-17T14:03:12Z",
            "baseCommit": "1759bf5", "dirtyWorktree": false,
            "gates": [{"gate": "structure", "result": "PASS", "seconds": 0.452}, {"gate": "Swift core/capture/concurrency", "result": "SKIPPED"}]}))
        .unwrap();
        assert!(receipt.passed());
        assert_eq!(receipt.gates.len(), 2);
        assert_eq!(receipt.gates[0].seconds.as_deref(), Some("0 s"));
        assert_eq!(receipt.gates[1].seconds, None);
        assert!(!Receipt::parse(&json!({"result": "FAIL"})).unwrap().passed());
        assert_eq!(Receipt::parse(&json!({})), None);
    }

    #[test]
    fn output_is_streamed_line_by_line_from_both_streams() {
        let mut command = std::process::Command::new("sh");
        command.args(["-c", "echo RUN structure; echo varning >&2; echo PASS structure; exit 3"]).stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut lines = Vec::new();
        assert_eq!(run_streaming(command, &mut |line| lines.push(line)), Ok(false));
        lines.sort();
        assert_eq!(lines, ["PASS structure", "RUN structure", "varning"]);
        let command = verify_command(Path::new("/repo"), Path::new("/logs"));
        let arguments: Vec<_> = command.get_args().map(|argument| argument.to_string_lossy().into_owned()).collect();
        assert_eq!(arguments.join(" "), "run --locked --manifest-path tools/Cargo.toml -- verify --logs-dir /logs");
    }
}
