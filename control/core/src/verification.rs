//! The latest `mio-verify verify` receipt, which the panel's verification page writes.

use std::path::PathBuf;

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
}
