//! Dedicated complete-concurrency diagnostic; portable checks do not prove iOS builds.

use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::LazyLock;

use regex::Regex;

use crate::cli::{Parsed, Spec};
use crate::swift_core::{SOURCES, portable_capture_source, portable_cloud_source};
use crate::util::{python_strip, resolve, root, swift_executable_name, which};

static RELEVANT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)Sendable|concurren|actor.isolat|main actor|nonisolated|data race|Swift 6 language mode|sending .* risks",
    )
    .expect("valid pattern")
});

/// Inspect compiler warning blocks, including Swift's following explanatory notes.
///
/// A block starts at every line that contains `warning:` and runs to the next such line, so the
/// "this is an error in the Swift 6 language mode" note under a warning counts with it.
pub fn concurrency_warnings(output: &str) -> Vec<String> {
    let mut starts = vec![0];
    let mut line_start = 0;
    for line in output.split_inclusive('\n') {
        if line_start != 0 && line.contains("warning:") {
            starts.push(line_start);
        }
        line_start += line.len();
    }
    starts.push(output.len());
    starts
        .windows(2)
        .map(|pair| &output[pair[0]..pair[1]])
        .filter(|block| block.contains("warning:") && RELEVANT.is_match(block))
        .map(|block| python_strip(block).to_owned())
        .collect()
}

const SPEC: Spec = Spec {
    command: "concurrency",
    about: "Dedicated complete-concurrency diagnostic; portable checks do not prove iOS builds.",
    flags: &[("--native", "Check the actual Mio target with Xcode on macOS.")],
    options: &[("--log", "Full diagnostic output (absolute path recommended).")],
};

pub fn run(arguments: &[String]) -> u8 {
    let parsed = match Parsed::parse(&SPEC, arguments) {
        Ok(parsed) => parsed,
        Err(code) => return code,
    };
    match diagnose(parsed.flag("--native"), parsed.option("--log").map(PathBuf::from)) {
        Ok(code) => code,
        Err(error) => {
            eprintln!("Concurrency diagnostic failed: {error}");
            1
        }
    }
}

fn diagnose(native: bool, log: Option<PathBuf>) -> Result<u8, String> {
    let root = root();
    let log = match log {
        Some(log) => log,
        // The default log directory is kept, as with tempfile.mkdtemp.
        None => tempfile::Builder::new()
            .prefix("mio-concurrency-log-")
            .tempdir()
            .map_err(|error| error.to_string())?
            .keep()
            .join("concurrency.log"),
    };
    let log = resolve(&log);
    if let Some(parent) = log.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let build = tempfile::Builder::new()
        .prefix("mio-concurrency-")
        .tempdir()
        .map_err(|error| error.to_string())?;
    let mut command;
    if native {
        if !cfg!(target_os = "macos") || which("xcodebuild").is_none() {
            println!("UNAVAILABLE: native concurrency requires macOS, Xcode and the iOS SDK. No native check ran.");
            return Ok(2);
        }
        command = Command::new("xcodebuild");
        command
            .arg("-project")
            .arg(root.join("Mio.xcodeproj"))
            .args(["-scheme", "Mio", "-configuration", "Debug", "-sdk", "iphonesimulator"])
            .args(["-destination", "generic/platform=iOS Simulator", "-derivedDataPath"])
            .arg(build.path())
            .args([
                "CODE_SIGNING_ALLOWED=NO",
                "CODE_SIGNING_REQUIRED=NO",
                "COMPILER_INDEX_STORE_ENABLE=NO",
                "SWIFT_STRICT_CONCURRENCY=complete",
                "OTHER_SWIFT_FLAGS=$(inherited) -warn-concurrency",
                "build",
            ]);
    } else {
        let swiftc = which(&swift_executable_name());
        let Some(swiftc) = swiftc.filter(|_| cfg!(target_os = "linux")) else {
            println!("UNAVAILABLE: portable concurrency requires Linux and Swift; use --native on macOS.");
            return Ok(2);
        };
        let cloud = build.path().join("MioCloudPortable.swift");
        std::fs::write(&cloud, portable_cloud_source(&root)? + &portable_capture_source(&root)?)
            .map_err(|error| error.to_string())?;
        // SIL, not -typecheck: "sending ... risks causing data races" comes from region-based
        // isolation, a SIL pass that -typecheck never runs. The upcoming feature mirrors the
        // Mio target's SWIFT_UPCOMING_FEATURE_INFER_SENDABLE_FROM_CAPTURES.
        command = Command::new(swiftc);
        command
            .args(["-swift-version", "5", "-strict-concurrency=complete", "-warn-concurrency"])
            .args(["-enable-upcoming-feature", "InferSendableFromCaptures", "-module-cache-path"])
            .arg(build.path().join("module-cache"))
            .args(["-wmo", "-emit-sil", "-o", "/dev/null", "-module-name", "Mio"])
            .args(SOURCES.iter().map(|path| root.join(path)))
            .arg(&cloud);
    }
    let kind = if native { "native iOS target" } else { "portable core with substituted native boundaries" };
    println!("Checking {kind}; log: {}", log.display());
    command.current_dir(&root);
    let (output, code) = combined_output(command)?;
    std::fs::write(&log, &output).map_err(|error| error.to_string())?;
    let warnings = concurrency_warnings(&output);
    if code != 0 || !warnings.is_empty() {
        println!(
            "FAIL: compiler exit {code}; {} concurrency warning blocks. See {}.",
            warnings.len(),
            log.display()
        );
        return Ok(1);
    }
    let note = if native { "" } else { " Native SDK/AVFoundation/UIKit/Keychain boundaries remain unverified." };
    println!("PASS: complete-concurrency diagnostic, no relevant warnings.{note}");
    Ok(0)
}

/// Runs a command with stderr merged into stdout, in order, as `stderr=subprocess.STDOUT` does.
pub fn combined_output(mut command: Command) -> Result<(String, i32), String> {
    let (mut reader, writer) = std::io::pipe().map_err(|error| error.to_string())?;
    let mut child = command
        .stdin(Stdio::null())
        .stdout(writer.try_clone().map_err(|error| error.to_string())?)
        .stderr(writer)
        .spawn()
        .map_err(|error| error.to_string())?;
    // The command still holds the parent's copies of the write end; drop it so the read sees EOF.
    drop(command);
    let mut bytes = Vec::new();
    std::io::Read::read_to_end(&mut reader, &mut bytes).map_err(|error| error.to_string())?;
    let status = child.wait().map_err(|error| error.to_string())?;
    let code = status.code().unwrap_or_else(|| {
        use std::os::unix::process::ExitStatusExt;
        -status.signal().unwrap_or(1)
    });
    Ok((String::from_utf8_lossy(&bytes).into_owned(), code))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blocks_include_following_notes() {
        let output = "a.swift:1: warning: unsafe operation\n  note: this is an error in the Swift 6 language mode\n\
                      b.swift:2: warning: oldAPI was deprecated\n";
        let warnings = concurrency_warnings(output);
        assert_eq!(warnings.len(), 1);
        assert!(warnings[0].ends_with("Swift 6 language mode"));
    }
}
