//! How the panel calls the root helper: `pkexec <helper> <group> …`, payload on stdin.

use std::io::Write as _;
use std::process::{Command as Process, Stdio};

use crate::command::Command;

/// Where `control/install.sh` puts the helper; the polkit policy names the same path.
pub const HELPER_PATH: &str = "/usr/local/lib/mio-control/mio-control-helper";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HelperError {
    /// The helper or pkexec is not installed.
    Missing,
    /// The password dialog was closed or the user is not allowed.
    NotAuthorized,
    /// The helper refused or the command failed; the message is the helper's, in Swedish.
    Failed(String),
}

impl std::fmt::Display for HelperError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HelperError::Missing => formatter.write_str("Mio Kontrolls hjälpare är inte installerad. Kör control/install.sh."),
            HelperError::NotAuthorized => formatter.write_str("Avbrutet: lösenordet godkändes inte."),
            HelperError::Failed(message) => formatter.write_str(message),
        }
    }
}

impl std::error::Error for HelperError {}

/// Runs `command` through pkexec. `stdin` carries secrets and other payloads, never argv.
pub fn run_helper(command: &Command, stdin: Option<&[u8]>) -> Result<Vec<u8>, HelperError> {
    if !std::path::Path::new(HELPER_PATH).exists() {
        return Err(HelperError::Missing);
    }
    let mut child = Process::new("pkexec")
        .arg(HELPER_PATH)
        .args(command.to_args())
        .stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|_| HelperError::Missing)?;
    if let (Some(input), Some(mut pipe)) = (stdin, child.stdin.take()) {
        pipe.write_all(input).map_err(|_| HelperError::Failed("Kunde inte skicka till hjälparen.".into()))?;
    }
    let output = child.wait_with_output().map_err(|_| HelperError::Missing)?;
    match output.status.code() {
        Some(0) => Ok(output.stdout),
        // pkexec: 126 when the dialog was dismissed, 127 when not authorized.
        Some(126 | 127) => Err(HelperError::NotAuthorized),
        _ => {
            let message = String::from_utf8_lossy(&output.stderr).trim().to_owned();
            Err(HelperError::Failed(if message.is_empty() { "Hjälparen misslyckades.".into() } else { message }))
        }
    }
}
