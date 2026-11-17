//! Exercise real microphone notification/lifecycle logic with an Apple engine double.
//!
//! Only engine construction/start/teardown, the omnidirectional-microphone preference and
//! AVFoundation types are substituted. The workspace MicrophoneCapture start, stop, observers,
//! notification handling, automatic restart (user decision 2026-10-11), its rate limit,
//! foreground check and the real MioCaptureResumePolicy execute unchanged. This is a Linux
//! regression gate, not an AVFoundation or physical microphone test.

use std::path::Path;
use std::process::Command;

use crate::concurrency::{combined_output, concurrency_warnings};
use crate::swift_core::balanced_end;
use crate::util::{root, run_checked, swift_executable_name, which};

/// The Apple engine double and event recorder (`tools/swift/capture-recovery-boundary.swift`).
const BOUNDARY: &str = include_str!("../swift/capture-recovery-boundary.swift");
/// The 13 lifecycle scenarios, each printing `PASS <name>` (`tools/swift/capture-recovery-main.swift`).
const TESTS: &str = include_str!("../swift/capture-recovery-main.swift");

fn index_of(source: &str, needle: &str, from: usize) -> Result<usize, String> {
    source[from..]
        .find(needle)
        .map(|offset| from + offset)
        .ok_or_else(|| format!("substring not found: {needle}"))
}

/// Replaces the body of `private func <name>(` and keeps its braces.
pub fn replace_body(source: &str, name: &str, replacement: &str) -> Result<String, String> {
    let start = index_of(source, &format!("private func {name}("), 0)?;
    let opening = index_of(source, "{", start)?;
    let index = balanced_end(source, opening)?;
    Ok(format!("{}{replacement}{}", &source[..=opening], &source[index - 1..]))
}

/// The real resume policy, so the gate exercises the same decisions as the app.
fn policy_source(root: &Path) -> Result<String, String> {
    let source = read(root, "Mio/Models/MioSessionModels.swift")?;
    let start = index_of(&source, "enum MioCaptureResumePolicy {", 0)?;
    let end = balanced_end(&source, index_of(&source, "{", start)?)?;
    Ok(format!("\n{}\n", &source[start..end]))
}

fn read(root: &Path, relative: &str) -> Result<String, String> {
    std::fs::read_to_string(root.join(relative)).map_err(|error| format!("{relative}: {error}"))
}

/// The single Swift program the harness compiles.
pub fn program_source(root: &Path) -> Result<String, String> {
    let mut source = read(root, "Mio/Services/MicrophoneCapture.swift")?.replace("import AVFoundation\n", "");
    // Keep the real rebuild admission guard; replace only the hardware operations below it.
    source = replace_body(
        &source,
        "rebuild",
        "\n        guard active, !stopped, !interrupted else { return }\n        try engine.start()\n    ",
    )?;
    source = replace_body(&source, "tearDownEngine", "\n        engine.stop()\n    ")?;
    source = replace_body(&source, "preferOmnidirectionalBuiltInMicrophone", "\n    ")?;
    // The text-free logger is portable; on Linux its os.Logger branch compiles out.
    let log_source = read(root, "Mio/Services/MioLog.swift")?.replace("import Foundation\n", "");
    Ok(format!("\n{BOUNDARY}{}{log_source}{source}\n{TESTS}", policy_source(root)?))
}

pub fn run(arguments: &[String]) -> u8 {
    if let Some(argument) = arguments.first() {
        if argument == "-h" || argument == "--help" {
            println!("usage: mio-verify capture-recovery\n\nExercise real microphone lifecycle logic with an Apple engine double.");
            return 0;
        }
        eprintln!("mio-verify capture-recovery: error: unrecognized arguments: {}", arguments.join(" "));
        return 2;
    }
    let Some(swiftc) = which(&swift_executable_name()) else {
        eprintln!("Swift compiler unavailable; no capture recovery tests ran.");
        return 1;
    };
    match verify(&swiftc) {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("{error}");
            1
        }
    }
}

fn verify(swiftc: &Path) -> Result<(), String> {
    let root = root();
    let program_text = program_source(&root)?;
    let temporary = tempfile::Builder::new()
        .prefix("mio-capture-recovery-")
        .tempdir()
        .map_err(|error| error.to_string())?;
    let program = temporary.path().join("capture.swift");
    std::fs::write(&program, program_text).map_err(|error| error.to_string())?;
    let executable = temporary.path().join("capture-tests");
    let mut command = Command::new(swiftc);
    command
        .args(["-swift-version", "5", "-strict-concurrency=complete", "-warn-concurrency", "-parse-as-library"])
        .arg(&program)
        .arg("-o")
        .arg(&executable);
    let (output, code) = combined_output(command)?;
    let warnings = concurrency_warnings(&output);
    if code != 0 || !warnings.is_empty() {
        print!("{output}");
        return Err(format!(
            "Capture recovery diagnostic failed: compiler exit {code}; {} concurrency warning blocks.",
            warnings.len()
        ));
    }
    run_checked(&mut Command::new(&executable))
}
