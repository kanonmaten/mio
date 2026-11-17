//! Verify diagnostics cannot silently pass when Swift reports concurrency warnings, and that the
//! workflow contracts catch a missing safety-critical setting.

use mio_verify::concurrency::concurrency_warnings;
use mio_verify::project::workflow_contract_issues;
use serde_json::{Value, json};

#[test]
fn actor_sendability_and_swift6_notes_fail_the_gate() {
    let fixtures = [
        "App.swift:5: warning: main actor-isolated value cannot be referenced here\n",
        "App.swift:8: warning: capture of 'work' with non-Sendable type in a closure\n",
        "App.swift:10: warning: passing argument may introduce data races\n",
        "App.swift:12: warning: unsafe operation\n  note: this is an error in the Swift 6 language mode\n",
    ];
    for fixture in fixtures {
        assert_eq!(concurrency_warnings(fixture).len(), 1, "{fixture}");
    }
}

#[test]
fn ordinary_sdk_deprecation_and_clean_output_do_not_fail_concurrency() {
    assert!(concurrency_warnings("App.swift:2: warning: oldAPI was deprecated in iOS 26\n").is_empty());
    assert!(concurrency_warnings("Build succeeded\n").is_empty());
}

#[cfg(target_os = "linux")]
#[test]
fn native_mode_cannot_claim_ios_checks_on_linux() {
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_mio-verify"))
        .args(["concurrency", "--native"])
        .output()
        .expect("mio-verify runs");
    assert_eq!(output.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&output.stdout).contains("No native check ran"));
}

fn job(commands: &[&str]) -> Value {
    let steps: Vec<Value> = commands.iter().map(|command| json!({"run": command})).collect();
    json!({"runs-on": "xcode-27", "steps": steps})
}

#[test]
fn ipa_workflow_requires_parallel_ipa_and_test_jobs() {
    let mut workflow = json!({"jobs": {
        "ipa": job(&[
            r#"xcodebuild -configuration Release CURRENT_PROJECT_VERSION="$GITHUB_RUN_NUMBER" build"#,
            "zip Mio-unsigned.ipa; echo > Mio-buildinfo.txt",
        ]),
        "test": job(&[
            "xcodebuild -only-testing:MioTests test-without-building",
            "xcodebuild -only-testing:MioUITests test-without-building",
            r#"cargo run --locked --manifest-path "$GITHUB_WORKSPACE/tools/Cargo.toml" -- concurrency --native"#,
        ]),
    }});
    assert!(workflow_contract_issues("build-unsigned-ipa.yml", &workflow).is_empty());
    workflow["jobs"]["test"]["steps"].as_array_mut().expect("steps").pop();
    workflow["jobs"]["ipa"]["runs-on"] = json!("macos-latest");
    workflow["jobs"]["ipa"]["steps"][0]["run"] = json!("xcodebuild -configuration Release build");
    let issues = workflow_contract_issues("build-unsigned-ipa.yml", &workflow);
    for expected in ["byggnummer från körningens nummer", "IPA- och testjobb på xcode-27", "native strict-concurrencydiagnostik"] {
        assert!(issues.iter().any(|issue| issue == expected), "{expected} missing from {issues:?}");
    }
}

#[test]
fn linux_workflow_requires_the_shared_gate_and_evidence_artifact() {
    let mut workflow = json!({"jobs": {"verify": {
        "runs-on": "ubuntu-24.04",
        "container": "swift:6.3.3-noble",
        "steps": [
            {"run": r#"cargo run --locked --manifest-path "$GITHUB_WORKSPACE/tools/Cargo.toml" -- verify --logs-dir "$RUNNER_TEMP/mio-verification""#},
            {"uses": "actions/upload-artifact@v7"},
        ],
    }}});
    assert!(workflow_contract_issues("verify-linux.yml", &workflow).is_empty());

    workflow["jobs"]["verify"]["container"] = json!("ubuntu:latest");
    workflow["jobs"]["verify"]["steps"][0]["run"] = json!("echo skipped");
    workflow["jobs"]["verify"]["steps"].as_array_mut().expect("steps").pop();
    let issues = workflow_contract_issues("verify-linux.yml", &workflow);
    assert_eq!(issues.len(), 3);
    for expected in [
        "Ubuntu 24.04 och Swift 6.3.3 Noble",
        "den gemensamma verifieraren med sparad loggplats",
        "uppladdning av verifieringsbevis",
    ] {
        assert!(issues.iter().any(|issue| issue == expected), "{expected} missing from {issues:?}");
    }
}
