use std::process::ExitCode;

use mio_verify::{capture, concurrency, gate, project, session_store, swift_core};

const USAGE: &str = "usage: mio-verify <command> [options]

commands:
  verify            the whole Linux gate: every step below plus the gateway and Pianissimo tests
  project           structural checks of the Xcode project, plists, workflows and docs
  swift-core        portable Swift core with XCTest
  capture-recovery  microphone lifecycle regressions against an Apple engine double
  concurrency       complete-concurrency diagnostic (--native: the real iOS target, macOS only)
  session-store     synthetic session storage benchmark

Run `mio-verify <command> --help` for a command's options.";

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let Some((command, rest)) = arguments.split_first() else {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    };
    let code = match command.as_str() {
        "verify" => gate::run(rest),
        "project" => project::run(rest),
        "swift-core" => swift_core::run(rest),
        "capture-recovery" => capture::run(rest),
        "concurrency" => concurrency::run(rest),
        "session-store" => session_store::run(rest),
        "-h" | "--help" | "help" => {
            println!("{USAGE}");
            0
        }
        other => {
            eprintln!("mio-verify: unknown command '{other}'\n{USAGE}");
            2
        }
    };
    ExitCode::from(code)
}
