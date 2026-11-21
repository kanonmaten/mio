//! Compile and run Mio's portable Swift core with XCTest, without an iOS SDK.
//!
//! Platform boundaries are substituted: Keychain settings, native microphone and
//! converter, UIKit presentation, and Apple's URLSession.bytes API. Transports always
//! fail unless a test injects a fake, so this harness cannot send network/model traffic.
//! Models, repositories, capture pipeline, view models and coordinators use workspace
//! sources. This is not an Xcode, UI, Keychain, converter or Apple transport test.
//!
//! The source rewrites below must stay byte-for-byte what the earlier Python harness
//! produced; the substituted Swift lives in `tools/swift/`.

use std::path::Path;
use std::process::Command;

use regex::Regex;

use crate::util::{root, run_checked, swift_executable_name, which};

pub const SOURCES: &[&str] = &[
    "Mio/Models/MioNavigationModels.swift",
    "Mio/MioNavigationCoordinator.swift",
    "Mio/MioDayContext.swift",
    "Mio/Services/MioConnectionDiscovery.swift",
    "Mio/Models/MioSessionModels.swift",
    "Mio/Models/TranscriptionModels.swift",
    "Mio/Models/SpeechPauseDetector.swift",
    "Mio/Models/MioContentModels.swift",
    "Mio/Models/MioAssistantModels.swift",
    "Mio/Models/MioAnalysisModels.swift",
    "Mio/Models/MioEverydayContext.swift",
    "Mio/Models/MioDiagnosticsModels.swift",
    "Mio/Models/MioPairing.swift",
    "Mio/Models/MioAnalysisSchedule.swift",
    "Mio/Services/MioProtectedFileWriter.swift",
    "Mio/Services/MioLog.swift",
    "Mio/Services/MioStores.swift",
    "Mio/Services/MioStoreMigration.swift",
    "Mio/Services/MioMetricArchive.swift",
    "Mio/Services/MioDeletionJournal.swift",
    "Mio/Services/MioAssistantRepository.swift",
    "Mio/Services/MioContentRepository.swift",
    "Mio/Services/MioDiagnosticsRepository.swift",
    "Mio/Services/SessionRepository.swift",
    "Mio/Models/MioDirectCommands.swift",
    "Mio/Models/MioCapturePolicies.swift",
    "Mio/Services/MioWakeWordDetector.swift",
    "Mio/Models/MioLessonReview.swift",
    "Mio/Models/MioVocabulary.swift",
    "Mio/Models/MioExamPlanning.swift",
    "Mio/Models/MioDailyDigest.swift",
    "Mio/Models/MioHealthCheck.swift",
    "Mio/Models/MioSigning.swift",
    "Mio/Services/MioBackupService.swift",
    "Mio/MioMaintenanceState.swift",
    "Mio/Models/MioOperationOutcome.swift",
    "Mio/Services/MioSystemActionPort.swift",
    "Mio/MioContentViewModel.swift",
    "Mio/MioQuestionWorkflow.swift",
    "Mio/MioWorkflowCoordinator.swift",
    "Mio/MioAssistantViewModel.swift",
    "Mio/MioAnalysisCoordinator.swift",
    "Mio/Services/LiveTranscriptionPipeline.swift",
    "Mio/Models/MioListeningActivityState.swift",
    "Mio/Models/MioListeningActivityMapping.swift",
    "Mio/Models/MioLessonNotesProgress.swift",
    "Mio/Models/MioWeekPlanner.swift",
    "Mio/Models/MioHandoffModels.swift",
    "Mio/Models/MioSuggestedQuestions.swift",
];

pub const TESTS: &[&str] = &[
    "MioTests/MioCloudTests.swift",
    "MioTests/MioPairingTests.swift",
    "MioTests/MioAnalysisScheduleTests.swift",
    "MioTests/MioContentModelsTests.swift",
    "MioTests/MioWakeWordDetectorTests.swift",
    "MioTests/MioDirectNoteTests.swift",
    "MioTests/MioEverydayCaptureTests.swift",
    "MioTests/MioLessonNotesV2Tests.swift",
    "MioTests/MioVocabularyTests.swift",
    "MioTests/MioExamPlanningTests.swift",
    "MioTests/MioSimplicityTests.swift",
    "MioTests/MioBackupTests.swift",
    "MioTests/MioNavigationTests.swift",
    "MioTests/MioWeekPlannerTests.swift",
    "MioTests/MioHandoffTests.swift",
    "MioTests/MioConnectionDiscoveryTests.swift",
    "MioTests/MioAnswerNoteTests.swift",
    "MioTests/MioLessonFreshnessTests.swift",
    "MioTests/MioContextTests.swift",
    "MioTests/MioDiagnosticsTests.swift",
    "MioTests/MioStoreMigrationTests.swift",
    "MioTests/MioTaskDiscoveryTests.swift",
    "MioTests/MioCoordinatorContextTests.swift",
    "MioTests/MioAnalysisTests.swift",
    "MioTests/MioAssistantTests.swift",
    "MioTests/MioContentRepositoryTests.swift",
    "MioTests/MioSessionRepositoryTests.swift",
    "MioTests/MioSessionModelsTests.swift",
    "MioTests/MioCaptureLifecycleTests.swift",
    "MioTests/AudioReliabilityTests.swift",
    "MioTests/MioSpeechPauseDetectorTests.swift",
    "MioTests/MioSpeakerAndResumeTests.swift",
    "MioTests/MioQuestionWorkflowTests.swift",
    "MioTests/MioWorkflowTests.swift",
    "MioTests/MioWorkflowRaceTests.swift",
    "MioTests/MioDeletionRecoveryTests.swift",
    "MioTests/MioProtectedFileWriterTests.swift",
    "MioTests/MioIntegrationTests.swift",
    "MioTests/MioBackgroundPresenceTests.swift",
];

// testCurrentSessionSnapshotWinsOverEarlierPersistedCopy was once UI-only; it is now included
// with the UIKit boundaries substituted.

const CLOUD_BOUNDARY: &str = include_str!("../swift/cloud-boundary.swift");
const CAPTURE_BOUNDARY: &str = include_str!("../swift/capture-boundary.swift");

fn read(root: &Path, relative: &str) -> Result<String, String> {
    std::fs::read_to_string(root.join(relative)).map_err(|error| format!("{relative}: {error}"))
}

fn find_from(source: &str, needle: &str, from: usize) -> Result<usize, String> {
    source[from..]
        .find(needle)
        .map(|offset| from + offset)
        .ok_or_else(|| "substring not found".to_owned())
}

/// The index just past the brace that closes the one at `opening`.
pub fn balanced_end(source: &str, opening: usize) -> Result<usize, String> {
    let bytes = source.as_bytes();
    let (mut index, mut depth) = (opening + 1, 1);
    while depth > 0 {
        match bytes.get(index) {
            Some(b'{') => depth += 1,
            Some(b'}') => depth -= 1,
            Some(_) => {}
            None => return Err("unbalanced braces in Swift source".to_owned()),
        }
        index += 1;
    }
    Ok(index)
}

/// Find a named function's balanced body in these controlled Swift sources.
pub fn function_source<'a>(source: &'a str, name: &str) -> Result<&'a str, String> {
    let pattern = Regex::new(&format!(r"(?:static )?func {}\(", regex::escape(name))).expect("valid pattern");
    let found = pattern
        .find(source)
        .ok_or_else(|| format!("Expected Swift function is missing: {name}"))?;
    let opening = find_from(source, "{", found.end())?;
    Ok(&source[found.start()..balanced_end(source, opening)?])
}

pub fn portable_cloud_source(root: &Path) -> Result<String, String> {
    let source = read(root, "Mio/Services/MioCloudService.swift")?;
    let settings_start = find_from(&source, "@MainActor\nenum MioCloudSettings", 0)?;
    let service_start = find_from(&source, "enum MioCloudService", settings_start)?;
    let settings = &source[settings_start..service_start];
    // Preserve the real URL validation used by default coordinator closures.
    let endpoint = function_source(settings, "endpoint")?;
    let token_validation = function_source(settings, "validateToken")?;
    let platform_settings = format!(
        r#"@MainActor enum MioCloudSettings {{
    static let serverKey = "mio.cloud.server"
    static var serverAddress: String {{ UserDefaults.standard.string(forKey: serverKey) ?? "" }}
    static var isPaired: Bool {{ (try? endpoint(for: serverAddress)) != nil }}
    {endpoint}
    private {token_validation}
    static func connection() throws -> MioCloudConnection {{ throw MioCloudError.disabled }}
    static var credentialsReadable: Bool {{ true }}
    static func waitUntilCredentialsReadable() async throws {{ }}
}}
"#
    );
    let mut source = format!("{}{platform_settings}{}", &source[..settings_start], &source[service_start..]);
    source = source.replace("import Security", "import FoundationNetworking");
    // This Apple-only configuration property is get-only in corelibs Foundation.
    source = source.replace("        configuration.waitsForConnectivity = false\n", "");
    source.push('\n');
    source.push_str(CLOUD_BOUNDARY);
    Ok(source)
}

/// Keep real VM/pipeline logic; substitute only Apple capture/settings/device APIs.
pub fn portable_capture_source(root: &Path) -> Result<String, String> {
    let mut source = read(root, "Mio/MioViewModel.swift")?;
    for name in ["AVFoundation", "SwiftUI", "UIKit"] {
        source = source.replace(&format!("import {name}\n"), "");
    }
    source = source.replace(
        "return Self.durationFormatter.string(from: TimeInterval(seconds))",
        "return String(seconds)",
    );
    let marker = "    private static let durationFormatter: DateComponentsFormatter = {";
    let start = find_from(&source, marker, 0)?;
    let end = find_from(&source, "    }()", start)? + "    }()".len();
    source.replace_range(start..end, "");
    Ok(format!("\n{CAPTURE_BOUNDARY}{source}"))
}

/// The XCTMain registration for one test file: every `func test…()`, async ones wrapped.
pub fn test_registration(relative: &str, source: &str) -> Result<String, String> {
    let class = Regex::new(r"final class (\w+): XCTestCase").expect("valid pattern");
    let class_name = class
        .captures(source)
        .ok_or_else(|| format!("XCTest class missing in {relative}"))?[1]
        .to_owned();
    let test = Regex::new(r"func (test\w+)\(\)([^\{]*)\{").expect("valid pattern");
    let entries: Vec<String> = test
        .captures_iter(source)
        .map(|captures| {
            let (name, signature) = (&captures[1], &captures[2]);
            let mut function = format!("{class_name}.{name}");
            if signature.contains("async") {
                function = format!("asyncTest({function})");
            }
            format!("(\"{name}\", {function})")
        })
        .collect();
    Ok(format!("testCase([\n{}\n])", entries.join(",\n")))
}

/// Writes the generated Swift into `build` and returns (portable module file, test files, runner).
pub fn write_sources(root: &Path, build: &Path) -> Result<(std::path::PathBuf, Vec<std::path::PathBuf>, std::path::PathBuf), String> {
    let io = |error: std::io::Error| error.to_string();
    let cloud = build.join("MioCloudPortable.swift");
    std::fs::write(&cloud, portable_cloud_source(root)? + &portable_capture_source(root)?).map_err(io)?;
    let mut copied = Vec::new();
    let mut registrations = Vec::new();
    for relative in TESTS {
        let source = read(root, relative)?;
        registrations.push(test_registration(relative, &source)?);
        let path = build.join(Path::new(relative).file_name().expect("test file name"));
        std::fs::write(&path, source).map_err(io)?;
        copied.push(path);
    }
    let runner = build.join("main.swift");
    std::fs::write(&runner, format!("import XCTest\nXCTMain([\n{}\n])\n", registrations.join(",\n"))).map_err(io)?;
    Ok((cloud, copied, runner))
}

pub fn run(arguments: &[String]) -> u8 {
    if let Some(argument) = arguments.first() {
        if argument == "-h" || argument == "--help" {
            println!("usage: mio-verify swift-core\n\nCompile and run Mio's portable Swift core with XCTest, without an iOS SDK.");
            return 0;
        }
        eprintln!("mio-verify swift-core: error: unrecognized arguments: {}", arguments.join(" "));
        return 2;
    }
    let Some(swiftc) = which(&swift_executable_name()) else {
        eprintln!("Swift compiler unavailable; set SWIFT_EXECUTABLE to a compatible swiftc. No tests ran.");
        return 2;
    };
    if !cfg!(target_os = "linux") {
        eprintln!("This harness uses Linux FoundationNetworking; run native XCTest through Xcode on Apple hosts.");
        return 2;
    }
    match verify(&swiftc) {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("Portable Swift core verification failed: {error}");
            1
        }
    }
}

fn verify(swiftc: &Path) -> Result<(), String> {
    let root = root();
    run_checked(Command::new(swiftc).arg("--version"))?;
    let temporary = tempfile::Builder::new()
        .prefix("mio-swift-core-")
        .tempdir()
        .map_err(|error| error.to_string())?;
    let build = temporary.path();
    let (cloud, copied_tests, runner) = write_sources(&root, build)?;
    let module_cache = build.join("module-cache");
    let library = build.join("libMio.so");
    run_checked(
        Command::new(swiftc)
            .args(["-swift-version", "5", "-module-cache-path"])
            .arg(&module_cache)
            .args(["-enable-testing", "-emit-library", "-emit-module", "-module-name", "Mio", "-emit-module-path"])
            .arg(build.join("Mio.swiftmodule"))
            .arg("-o")
            .arg(&library)
            .args(SOURCES.iter().map(|path| root.join(path)))
            .arg(&cloud),
    )?;
    let executable = build.join("core-tests");
    run_checked(
        Command::new(swiftc)
            .args(["-swift-version", "5", "-module-cache-path"])
            .arg(&module_cache)
            .arg("-I")
            .arg(build)
            .arg("-L")
            .arg(build)
            .arg("-lMio")
            .args(&copied_tests)
            .arg(&runner)
            .arg("-o")
            .arg(&executable),
    )?;
    let library_path = format!(
        "{}:{}",
        build.display(),
        std::env::var("LD_LIBRARY_PATH").unwrap_or_default()
    );
    println!("Portable core + capture lifecycle XCTest; native microphone/converter/network/UI boundaries excluded.");
    run_checked(Command::new(&executable).env("LD_LIBRARY_PATH", library_path))
}
