//! `mio-control-helper`: Mio Kontroll's root helper, started only through pkexec.
//!
//! Usage: `pkexec /usr/local/lib/mio-control/mio-control-helper <read|write|service|pair> …`.
//! The command list is in `mio_control_core::command`; everything else is refused.

use std::io::{Read as _, Write as _};
use std::process::ExitCode;

use mio_control_core::command::Command;
use mio_control_helper::{MAX_INPUT, System, SystemRunner, execute, real_http};

fn running_as_root() -> bool {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|status| status.lines().find(|line| line.starts_with("Uid:")).map(str::to_owned))
        .is_some_and(|line| line.split_whitespace().nth(2) == Some("0"))
}

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let command = match Command::parse(&arguments) {
        Ok(command) => command,
        Err(message) => {
            eprintln!("{message}");
            return ExitCode::from(2);
        }
    };
    if !running_as_root() {
        eprintln!("mio-control-helper körs bara via pkexec.");
        return ExitCode::from(2);
    }
    let mut input = Vec::new();
    if command.takes_stdin() {
        // One byte more than allowed tells a too-large input from one that fits exactly.
        if std::io::stdin().take(MAX_INPUT as u64 + 1).read_to_end(&mut input).is_err() || input.len() > MAX_INPUT {
            eprintln!("För mycket indata.");
            return ExitCode::from(2);
        }
    }
    let system = System { root: "/".into(), runner: &SystemRunner, http: &real_http };
    match execute(&system, &command, &input) {
        Ok(output) => {
            let _ = std::io::stdout().write_all(&output);
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}
