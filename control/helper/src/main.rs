//! Placeholder until phase 1: the helper refuses every command.

use std::process::ExitCode;

fn main() -> ExitCode {
    eprintln!("mio-control-helper: inga kommandon än");
    ExitCode::from(2)
}
