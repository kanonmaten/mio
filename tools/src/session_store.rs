//! Measure actual Mio session storage with synthetic histories; no iOS performance claim.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

use regex::Regex;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use crate::cli::{Parsed, Spec};
use crate::concurrency::combined_output;
use crate::util::{python_strip, root, swift_executable_name, utc_now_iso, which};

const SOURCES: &[&str] = &[
    "Mio/Models/MioSessionModels.swift",
    "Mio/Models/TranscriptionModels.swift",
    // TranscriptionModels uses the pause detector since 2026-10-11; without it the benchmark
    // stopped compiling (the Python version had the same gap).
    "Mio/Models/SpeechPauseDetector.swift",
    "Mio/Services/MioProtectedFileWriter.swift",
    "Mio/Services/SessionRepository.swift",
];
const MODE_SOURCE: &str = "Mio/Models/MioAnalysisModels.swift";
const FIXTURE: &str = "tools/fixtures/SessionStoreMeasurement.swift";

const SPEC: Spec = Spec {
    command: "session-store",
    about: "Measure actual Mio session storage with synthetic histories; no iOS performance claim.",
    flags: &[],
    options: &[
        ("--output", "Optional absolute path for the JSON report; JSON is always printed."),
        (
            "--samples",
            "Bounded odd sample count for codecs, loads and isolated writes (3, 5, 7 or 9; default: 5). Patches always use 3 samples.",
        ),
    ],
};

/// Runs a command in the repository, stdout and stderr together, failing on a non-zero exit.
fn command_output(command: Command) -> Result<String, String> {
    let (output, code) = combined_output(command)?;
    if code != 0 {
        return Err(format!("Command failed with exit {code}: {}", python_strip(&output)));
    }
    Ok(python_strip(&output).to_owned())
}

fn in_root(program: impl AsRef<std::ffi::OsStr>) -> Command {
    let mut command = Command::new(program);
    command.current_dir(root());
    command
}

/// Writes next to the destination and renames, so a reader never sees half a report.
fn write_report(path: &Path, report: &str) -> Result<(), String> {
    let parent = path.parent().unwrap_or(Path::new("/"));
    std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    let mut temporary = tempfile::Builder::new()
        .prefix(".mio-measurement-")
        .tempfile_in(parent)
        .map_err(|error| error.to_string())?;
    temporary
        .write_all(format!("{report}\n").as_bytes())
        .map_err(|error| error.to_string())?;
    temporary.persist(path).map_err(|error| error.to_string())?;
    Ok(())
}

/// Recursively sorted keys, as json.dumps(sort_keys=True).
fn sorted(value: Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut entries: Vec<(String, Value)> = map.into_iter().collect();
            entries.sort_by(|left, right| left.0.cmp(&right.0));
            Value::Object(entries.into_iter().map(|(key, value)| (key, sorted(value))).collect::<Map<_, _>>())
        }
        Value::Array(items) => Value::Array(items.into_iter().map(sorted).collect()),
        other => other,
    }
}

fn uname(flag: &str) -> String {
    Command::new("uname")
        .arg(flag)
        .output()
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_owned())
        .unwrap_or_default()
}

pub fn run(arguments: &[String]) -> u8 {
    let parsed = match Parsed::parse(&SPEC, arguments) {
        Ok(parsed) => parsed,
        Err(code) => return code,
    };
    let samples = match parsed.option("--samples").unwrap_or("5") {
        value @ ("3" | "5" | "7" | "9") => value.parse::<u32>().expect("digit"),
        other => return SPEC.error(&format!("argument --samples: invalid choice: {other} (choose from 3, 5, 7, 9)")),
    };
    let output = parsed.option("--output").map(PathBuf::from);
    if output.as_ref().is_some_and(|path| !path.is_absolute()) {
        return SPEC.error("--output requires an absolute path");
    }
    if !cfg!(any(target_os = "linux", target_os = "macos")) {
        eprintln!("UNAVAILABLE: this measurement supports Linux or macOS hosts; no measurement ran.");
        return 2;
    }
    let Some(swiftc) = which(&swift_executable_name()) else {
        eprintln!("UNAVAILABLE: Swift compiler missing; set SWIFT_EXECUTABLE. No measurement ran.");
        return 2;
    };
    match measure(&swiftc, samples, output.as_deref()) {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("Session-store measurement failed: {error}");
            1
        }
    }
}

fn measure(swiftc: &Path, samples: u32, output: Option<&Path>) -> Result<(), String> {
    let root = root();
    let io = |error: std::io::Error| error.to_string();
    let mut source_hashes = Map::new();
    let mut source_bytes = std::collections::HashMap::new();
    for path in SOURCES.iter().chain([MODE_SOURCE, FIXTURE].iter()) {
        let data = std::fs::read(root.join(path)).map_err(io)?;
        let digest: String = Sha256::digest(&data).iter().map(|byte| format!("{byte:02x}")).collect();
        source_hashes.insert((*path).to_owned(), Value::from(digest));
        source_bytes.insert(*path, data);
    }
    let mode_text = String::from_utf8(source_bytes[MODE_SOURCE].clone()).map_err(|error| error.to_string())?;
    // Keep the actual production enum verbatim. Fail if its declaration gains
    // nested behavior rather than quietly replacing it with a benchmark stub.
    let mode = Regex::new(r"enum MioCaptureMode:\s*String,\s*Codable,\s*Sendable\s*\{[^{}]*\}")
        .expect("valid pattern")
        .find(&mode_text)
        .ok_or("Production MioCaptureMode extraction needs review; no substitute was compiled.")?
        .as_str()
        .to_owned();
    let mut version = in_root(swiftc);
    version.arg("--version");
    let swift_version = command_output(version)?;
    let mut git = in_root("git");
    git.args(["rev-parse", "HEAD"]);
    let head = command_output(git).ok();
    let mut cases = Vec::new();
    let temporary = tempfile::Builder::new()
        .prefix("mio-session-measurement-")
        .tempdir()
        .map_err(io)?;
    let build = temporary.path().to_path_buf();
    let mut compilation_sources = Vec::new();
    for path in SOURCES.iter().chain([FIXTURE].iter()) {
        let copied = build.join(Path::new(path).file_name().expect("file name"));
        std::fs::write(&copied, &source_bytes[path]).map_err(io)?;
        compilation_sources.push(copied);
    }
    let capture_mode = build.join("ProductionCaptureMode.swift");
    std::fs::write(&capture_mode, format!("{mode}\n")).map_err(io)?;
    compilation_sources.push(capture_mode);
    let executable = build.join("measure-session-store");
    let mut compile = in_root(swiftc);
    compile
        .args(["-swift-version", "5", "-O", "-parse-as-library", "-module-cache-path"])
        .arg(build.join("module-cache"))
        .args(["-module-name", "MioStoreMeasurement"])
        .args(&compilation_sources)
        .arg("-o")
        .arg(&executable);
    command_output(compile)?;
    for count in [50_u32, 500, 2_000] {
        eprintln!("Measuring {count} ended sessions / {} synthetic segments …", count * 20);
        // Independent processes keep each history's RSS high-water mark from
        // inheriting allocations from the preceding history or compiler.
        let mut measurement = in_root(&executable);
        measurement
            .arg(count.to_string())
            .arg(samples.to_string())
            .arg(build.join(format!("history-{count}")));
        let output = command_output(measurement)?;
        cases.push(serde_json::from_str::<Value>(&output).map_err(|error| error.to_string())?);
    }
    temporary.close().map_err(io)?;
    if build.exists() {
        return Err("Temporary synthetic files were not removed; report withheld.".to_owned());
    }
    let report = json!({
        "schemaVersion": 2,
        "measuredAtUTC": utc_now_iso(),
        "platform": {"system": uname("-s"), "release": uname("-r"), "machine": uname("-m"),
                     "harness": format!("mio-verify {}", env!("CARGO_PKG_VERSION")), "swiftVersion": swift_version},
        "provenance": {"headCommit": head, "sourceSHA256": source_hashes,
                       "note": "Workspace source snapshot; HEAD alone may not identify uncommitted measured code.",
                       "captureMode": "Verbatim production MioCaptureMode enum; all other production sources compiled unchanged."},
        "method": {
            "build": "Swift 5 language mode, -O, actual SessionRepository/MioSession/MioProtectedFileWriter",
            "clock": "ContinuousClock monotonic milliseconds",
            "timingSamples": samples,
            "patchSamples": 3,
            "percentile": "Nearest-rank p95; with these small sample counts p95 is the maximum observation.",
            "codec": "Independent compact JSONEncoder/JSONDecoder, ISO-8601; excludes validation, actor and file IO.",
            "protectedAtomicWrite": "Production writer with already encoded bytes; includes directory/privacy attributes and atomic replacement.",
            "freshRepositoryLoad": "New repository actor each sample; includes file stamp/read, decode and validation. OS page cache is not flushed.",
            "cachedRepositoryLoad": "Previously loaded actor; includes scheduling and fingerprint validation, with repository cache retained.",
            "metadataPatchWithAtomicWrite": "Real actor patch; includes cache/fingerprint, mutation, full validation, full encoding, protected atomic write and final fingerprint. It is not encoder-only or write-only timing.",
            "memory": "Isolated process per history. Peak RSS uses getrusage (Linux KiB normalized to bytes; macOS bytes). Current RSS uses Linux /proc/self/status immediately before getrusage and is null on macOS. These are sequential kernel observations, not one atomic snapshot. Fixture, encoded bytes, live actor cache and verification copies contribute to process RSS; it is not the app's steady-state memory.",
            "seed": "Single direct protected seed write; no quadratic upsert seeding. All evidence checks are outside timing intervals.",
            "syntheticOnly": true,
            "rawAudioCreated": false,
            "temporaryDataCleaned": true,
        },
        "limitations": [
            "Linux/macOS host results do not prove iPhone performance, battery usage or Apple's iOS Data Protection.",
            "Repeated operations use a warm OS/file-system cache; fresh repository does not mean cold disk.",
            "Atomic Foundation replacement is measured without an added fsync; this is not a durability or power-loss test.",
            "Small bounded samples describe this run only; no improvement or database migration is inferred.",
        ],
        "histories": cases,
    });
    let encoded = serde_json::to_string_pretty(&sorted(report)).map_err(|error| error.to_string())?;
    if let Some(output) = output {
        write_report(output, &encoded)?;
    }
    println!("{encoded}");
    Ok(())
}
