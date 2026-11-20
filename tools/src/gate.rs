//! One directory-independent Linux entry point; no deployment or real model requests.

use std::ffi::OsString;
use std::fs::File;
use std::io::Write;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use regex::Regex;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use crate::cli::{Parsed, Spec};
use crate::util::{resolve, root, splitlines, swift_executable_name, utc_now_iso, which};

const SPEC: Spec = Spec {
    command: "verify",
    about: "One directory-independent Linux entry point; no deployment or real model requests.",
    flags: &[
        ("--skip-swift", "Run other gates; report a PARTIAL result with Swift SKIPPED."),
        ("--skip-control", "Run other gates; report a PARTIAL result with the control panel SKIPPED."),
        ("--measure-session-store", "Also run the synthetic long-history storage benchmark."),
    ],
    options: &[("--logs-dir", "Output directory; default: a new /tmp/mio-verify-* directory.")],
};

/// Each step gets ten minutes, as before.
const STEP_TIMEOUT: Duration = Duration::from_secs(600);

fn output_text(command: &mut Command) -> Result<String, String> {
    let output = command.output().map_err(|error| error.to_string())?;
    if !output.status.success() {
        return Err(crate::util::check_status(command, output.status).unwrap_err());
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn hex(digest: impl AsRef<[u8]>) -> String {
    digest.as_ref().iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Git provenance plus SHA-256 over every tracked and untracked, not ignored file.
pub fn provenance(root: &Path) -> Result<Map<String, Value>, String> {
    let commit = output_text(Command::new("git").args(["rev-parse", "HEAD"]).current_dir(root))?;
    let status = Command::new("git")
        .args(["status", "--porcelain"])
        .current_dir(root)
        .output()
        .map_err(|error| error.to_string())?;
    if !status.status.success() {
        return Err("git status --porcelain failed".to_owned());
    }
    let files = Command::new("git")
        .args(["ls-files", "--cached", "--others", "--exclude-standard", "-z"])
        .current_dir(root)
        .output()
        .map_err(|error| error.to_string())?;
    if !files.status.success() {
        return Err("git ls-files failed".to_owned());
    }
    let mut names: Vec<&[u8]> = files.stdout.split(|byte| *byte == 0).filter(|name| !name.is_empty()).collect();
    names.sort_unstable();
    names.dedup();
    let mut digest = Sha256::new();
    let mut code_digest = Sha256::new();
    for name in names {
        let path = root.join(OsString::from_vec(name.to_vec()));
        digest.update(name);
        digest.update(b"\0");
        let content = match std::fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                let target = std::fs::read_link(&path).map_err(|error| error.to_string())?;
                [b"symlink\0".as_slice(), target.as_os_str().as_bytes()].concat()
            }
            _ if path.is_file() => std::fs::read(&path).map_err(|error| error.to_string())?,
            _ => b"deleted".to_vec(),
        };
        digest.update(&content);
        digest.update(b"\0");
        let markdown = path
            .extension()
            .is_some_and(|extension| extension.to_string_lossy().to_lowercase() == "md");
        if !markdown {
            code_digest.update(name);
            code_digest.update(b"\0");
            code_digest.update(&content);
            code_digest.update(b"\0");
        }
    }
    let mut receipt = Map::new();
    receipt.insert("baseCommit".into(), Value::from(commit));
    receipt.insert("dirtyWorktree".into(), Value::from(!status.stdout.is_empty()));
    receipt.insert("worktreeSHA256".into(), Value::from(hex(digest.finalize())));
    receipt.insert("codeConfigurationSHA256".into(), Value::from(hex(code_digest.finalize())));
    Ok(receipt)
}

/// `cargo 1.100.0 (…)` → (1, 100, 0).
fn cargo_version(text: &str) -> Option<(u64, u64, u64)> {
    let captures = Regex::new(r"^cargo (\d+)\.(\d+)\.(\d+)").expect("valid pattern").captures(text)?;
    let part = |index: usize| captures[index].parse::<u64>().ok();
    Some((part(1)?, part(2)?, part(3)?))
}

/// The receipt entry for skipped control panel checks (CI runs them in a parallel job).
pub const CONTROL_GATE: &str = "Mio Kontroll (control/)";

/// Lowest Rust the selected gates need: control/ (gpui-kit 0.10) needs 1.92, the gateway 1.88.
pub fn rust_floor(skip_control: bool) -> (u64, u64, u64) {
    if skip_control { (1, 88, 0) } else { (1, 92, 0) }
}

/// The final result line: any skipped gate makes a passing run PARTIAL, never a plain PASS.
pub fn result_label(failed: bool, skip_swift: bool, skip_control: bool) -> &'static str {
    if failed {
        "FAIL"
    } else if skip_swift || skip_control {
        "PARTIAL"
    } else {
        "PASS (Linux synthetic gates)"
    }
}

struct Step {
    name: &'static str,
    command: Command,
}

fn step(name: &'static str, program: impl AsRef<std::ffi::OsStr>, arguments: &[&std::ffi::OsStr]) -> Step {
    let mut command = Command::new(program);
    command.args(arguments);
    Step { name, command }
}

/// Runs one step into its log and returns its exit code; failures to start or a timeout count as 1.
fn run_step(command: &mut Command, log: &Path) -> Result<i32, String> {
    let output = File::create(log).map_err(|error| error.to_string())?;
    let errors = output.try_clone().map_err(|error| error.to_string())?;
    let started = command.stdin(Stdio::null()).stdout(output).stderr(errors).spawn();
    let failure = match started {
        Ok(mut child) => {
            let deadline = Instant::now() + STEP_TIMEOUT;
            loop {
                match child.try_wait() {
                    Ok(Some(status)) => {
                        return Ok(status.code().unwrap_or_else(|| {
                            use std::os::unix::process::ExitStatusExt;
                            -status.signal().unwrap_or(1)
                        }));
                    }
                    Ok(None) if Instant::now() >= deadline => {
                        let _ = child.kill();
                        let _ = child.wait();
                        break "TimeoutExpired";
                    }
                    Ok(None) => std::thread::sleep(Duration::from_millis(50)),
                    Err(_) => break "OSError",
                }
            }
        }
        Err(error) => match error.kind() {
            std::io::ErrorKind::NotFound => "FileNotFoundError",
            std::io::ErrorKind::PermissionDenied => "PermissionError",
            _ => "OSError",
        },
    };
    let mut log = std::fs::OpenOptions::new().append(true).open(log).map_err(|error| error.to_string())?;
    write!(log, "\nVerifier process failed: {failure}\n").map_err(|error| error.to_string())?;
    Ok(1)
}

pub fn run(arguments: &[String]) -> u8 {
    let parsed = match Parsed::parse(&SPEC, arguments) {
        Ok(parsed) => parsed,
        Err(code) => return code,
    };
    match gate(
        parsed.flag("--skip-swift"),
        parsed.flag("--skip-control"),
        parsed.option("--logs-dir").map(PathBuf::from),
        parsed.flag("--measure-session-store"),
    ) {
        Ok(code) => code,
        Err(error) => {
            eprintln!("Verification could not run: {error}");
            1
        }
    }
}

fn gate(skip_swift: bool, skip_control: bool, logs_dir: Option<PathBuf>, measure_session_store: bool) -> Result<u8, String> {
    if !cfg!(target_os = "linux") {
        println!(
            "UNAVAILABLE: this entry point requires Linux. Run native XCTest/Xcode and mio-verify concurrency --native on macOS."
        );
        return Ok(2);
    }
    let root = root();
    let logs = match logs_dir {
        Some(directory) => directory,
        None => tempfile::Builder::new()
            .prefix("mio-verify-")
            .tempdir()
            .map_err(|error| error.to_string())?
            .keep(),
    };
    std::fs::create_dir_all(&logs).map_err(|error| error.to_string())?;
    let logs = resolve(&logs);
    let mut required = vec!["cargo".to_owned(), "uv".to_owned(), "git".to_owned()];
    if !skip_swift || measure_session_store {
        required.push(swift_executable_name());
    }
    let missing: Vec<String> = required.into_iter().filter(|name| which(name).is_none()).collect();
    if !missing.is_empty() {
        println!("UNAVAILABLE: required executables missing: {}", missing.join(", "));
        return Ok(2);
    }
    let rust_version = output_text(Command::new("cargo").arg("--version"))?;
    if cargo_version(&rust_version).is_none_or(|version| version < (1, 88, 0)) {
        println!("UNAVAILABLE: {rust_version}; the gateway needs Rust 1.88 or later (edition 2024, let chains).");
        return Ok(2);
    }
    if cargo_version(&rust_version).is_none_or(|version| version < rust_floor(skip_control)) {
        println!("UNAVAILABLE: {rust_version}; the control panel (control/) needs Rust 1.92 or later (gpui-kit 0.10).");
        return Ok(2);
    }
    let mut receipt = Map::new();
    receipt.insert("startedAt".into(), Value::from(utc_now_iso()));
    receipt.extend(provenance(&root)?);
    receipt.insert("rust".into(), Value::from(rust_version.clone()));
    receipt.insert("uv".into(), Value::from(output_text(Command::new("uv").arg("--version"))?));
    receipt.insert("nativeIOS".into(), Value::from("NOT RUN"));
    receipt.insert("realProvider".into(), Value::from("NOT RUN"));
    let mut gates: Vec<Value> = Vec::new();

    let me = std::env::current_exe().map_err(|error| error.to_string())?;
    let transcription = root.join("transcription-server");
    let server = root.join("server/Cargo.toml");
    let tools = root.join("tools/Cargo.toml");
    let control = root.join("control/Cargo.toml");
    let concurrency_log = logs.join("concurrency-diagnostics.log");
    let session_store = logs.join("session-store.json");
    let os = |text: &'static str| std::ffi::OsStr::new(text);
    let mut steps = vec![
        step("python-lock", "uv", &[os("--directory"), transcription.as_os_str(), os("sync"), os("--locked"), os("--extra"), os("test"), os("--python"), os("3.12")]),
        step("structure", &me, &[os("project")]),
        step("verification-tools-lint", "cargo", &[os("clippy"), os("--locked"), os("--manifest-path"), tools.as_os_str(), os("--all-targets"), os("--"), os("-D"), os("warnings")]),
        step("verification-tools", "cargo", &[os("test"), os("--locked"), os("--manifest-path"), tools.as_os_str()]),
        step("gateway-lint", "cargo", &[os("clippy"), os("--locked"), os("--manifest-path"), server.as_os_str(), os("--all-targets"), os("--"), os("-D"), os("warnings")]),
        step("gateway-tests", "cargo", &[os("test"), os("--locked"), os("--manifest-path"), server.as_os_str()]),
    ];
    if !skip_control {
        // The control panel's core, root helper and GPUI app; GPUI tests run headless.
        steps.push(step("control-lint", "cargo", &[os("clippy"), os("--locked"), os("--manifest-path"), control.as_os_str(), os("--workspace"), os("--all-targets"), os("--"), os("-D"), os("warnings")]));
        steps.push(step("control-tests", "cargo", &[os("test"), os("--locked"), os("--manifest-path"), control.as_os_str(), os("--workspace")]));
    } else {
        gates.push(json!({"gate": CONTROL_GATE, "result": "SKIPPED"}));
    }
    steps.push(step("transcription-fake", "uv", &[os("--directory"), transcription.as_os_str(), os("run"), os("--no-sync"), os("python"), os("-m"), os("pytest"), os("tests")]));
    if !skip_swift {
        steps.push(step("swift-core", &me, &[os("swift-core")]));
        steps.push(step("capture-recovery", &me, &[os("capture-recovery")]));
        steps.push(step("concurrency-portable", &me, &[os("concurrency"), os("--log"), concurrency_log.as_os_str()]));
    } else {
        gates.push(json!({"gate": "Swift core/capture/concurrency", "result": "SKIPPED"}));
    }
    if measure_session_store {
        steps.push(step("session-store", &me, &[os("session-store"), os("--output"), session_store.as_os_str()]));
    }
    let dirty = if receipt["dirtyWorktree"] == Value::Bool(true) { "True" } else { "False" };
    println!(
        "Logs: {}\n{rust_version}; base {}; dirty={dirty}\nSynthetic/local checks only. Xcode, installation and device/provider acceptance remain separate.",
        logs.display(),
        receipt["baseCommit"].as_str().unwrap_or_default()
    );
    let mut failed = false;
    for Step { name, mut command } in steps {
        let log = logs.join(format!("{name}.log"));
        let started = Instant::now();
        println!("RUN {name}");
        // A fresh lockfile environment avoids stale interpreter symlinks and excludes GPU extras.
        command.current_dir(&root).env("UV_PROJECT_ENVIRONMENT", logs.join("python-venv"));
        let code = run_step(&mut command, &log)?;
        let seconds = (started.elapsed().as_secs_f64() * 1000.0).round() / 1000.0;
        let result = if code == 0 { "PASS" } else { "FAIL" };
        gates.push(json!({"gate": name, "result": result, "exitCode": code, "seconds": seconds,
                          "log": format!("{name}.log")}));
        println!("{result} {name}: {}", log.display());
        if code != 0 {
            // CI logs are often the only evidence available; show the failing gate's tail.
            let bytes = std::fs::read(&log).unwrap_or_default();
            let text = String::from_utf8_lossy(&bytes);
            let lines = splitlines(&text);
            // Failures may scroll out of the tail; list assertion/error lines first.
            let markers = ["error:", "failed (", "Fatal error", "Simultaneous accesses"];
            let errors: Vec<String> = lines
                .iter()
                .filter(|line| markers.iter().any(|marker| line.contains(marker)))
                .take(60)
                .map(|line| format!("  ! {line}"))
                .collect();
            println!("{}", errors.join("\n"));
            let tail: Vec<String> = lines[lines.len().saturating_sub(40)..].iter().map(|line| format!("  | {line}")).collect();
            println!("{}", tail.join("\n"));
            failed = true;
            break;
        }
    }
    receipt.insert("gates".into(), Value::Array(gates));
    receipt.insert("finishedAt".into(), Value::from(utc_now_iso()));
    let result = result_label(failed, skip_swift, skip_control);
    receipt.insert("result".into(), Value::from(result));
    let receipt_path = logs.join("verification.json");
    let encoded = serde_json::to_string_pretty(&Value::Object(receipt)).map_err(|error| error.to_string())?;
    std::fs::write(&receipt_path, encoded + "\n").map_err(|error| error.to_string())?;
    println!("{result}. Receipt: {}", receipt_path.display());
    Ok(u8::from(failed))
}

#[cfg(test)]
mod tests {
    use super::cargo_version;

    #[test]
    fn rust_version_floor() {
        assert_eq!(cargo_version("cargo 1.100.0 (3acc79c0c 2026-11-05)"), Some((1, 100, 0)));
        assert!(cargo_version("cargo 1.87.2").is_some_and(|version| version < (1, 88, 0)));
        assert_eq!(cargo_version("rustup 1.0"), None);
        assert!(cargo_version("cargo 1.91.1").is_some_and(|version| version < (1, 92, 0)));
    }
}
