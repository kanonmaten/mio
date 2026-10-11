#!/usr/bin/env python3
"""Compile and run Mio's portable Swift core with XCTest, without an iOS SDK.

Platform boundaries are substituted: Keychain settings, native microphone and
converter, UIKit presentation, and Apple's URLSession.bytes API. Transports always
fail unless a test injects a fake, so this harness cannot send network/model traffic.
Models, repositories, capture pipeline, view models and coordinators use workspace
sources. This is not an Xcode, UI, Keychain, converter or Apple transport test.
"""
from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    "Mio/Models/MioNavigationModels.swift",
    "Mio/MioNavigationCoordinator.swift",
    "Mio/MioDayContext.swift",
    "Mio/Services/MioConnectionDiscovery.swift",
    "Mio/Models/MioSessionModels.swift",
    "Mio/Models/TranscriptionModels.swift",
    "Mio/Models/MioContentModels.swift",
    "Mio/Models/MioAssistantModels.swift",
    "Mio/Models/MioAnalysisModels.swift",
    "Mio/Models/MioEverydayContext.swift",
    "Mio/Models/MioDiagnosticsModels.swift",
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
    "Mio/Services/MioWakeWordDetector.swift",
    "Mio/MioMaintenanceState.swift",
    "Mio/Models/MioOperationOutcome.swift",
    "Mio/Services/MioSystemActionPort.swift",
    "Mio/MioContentViewModel.swift",
    "Mio/MioQuestionWorkflow.swift",
    "Mio/MioWorkflowCoordinator.swift",
    "Mio/MioAssistantViewModel.swift",
    "Mio/MioAnalysisCoordinator.swift",
    "Mio/Services/LiveTranscriptionPipeline.swift",
]
TESTS = [
    "MioTests/MioCloudTests.swift",
    "MioTests/MioContentModelsTests.swift",
    "MioTests/MioWakeWordDetectorTests.swift",
    "MioTests/MioNavigationTests.swift",
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
    "MioTests/MioQuestionWorkflowTests.swift",
    "MioTests/MioWorkflowTests.swift",
    "MioTests/MioWorkflowRaceTests.swift",
    "MioTests/MioDeletionRecoveryTests.swift",
    "MioTests/MioProtectedFileWriterTests.swift",
    "MioTests/MioIntegrationTests.swift",
]
UI_ONLY_TEST = "testCurrentSessionSnapshotWinsOverEarlierPersistedCopy"  # Now included with UIKit boundaries substituted.


def function_source(source: str, name: str) -> tuple[str, int, int]:
    """Find a named function's balanced body in these controlled Swift sources."""
    match = re.search(r"(?:static )?func " + re.escape(name) + r"\(", source)
    if not match:
        raise ValueError(f"Expected Swift function is missing: {name}")
    opening = source.index("{", match.end())
    depth = 1
    index = opening + 1
    while depth:
        depth += (source[index] == "{") - (source[index] == "}")
        index += 1
    return source[match.start():index], match.start(), index


def portable_cloud_source() -> str:
    source = (ROOT / "Mio/Services/MioCloudService.swift").read_text()
    settings_start = source.index("@MainActor\nenum MioCloudSettings")
    service_start = source.index("enum MioCloudService", settings_start)
    settings = source[settings_start:service_start]
    # Preserve the real URL validation used by default coordinator closures.
    endpoint, _, _ = function_source(settings, "endpoint")
    updated_credentials, _, _ = function_source(settings, "updatedCredentials")
    token_validation, _, _ = function_source(settings, "validateToken")
    platform_settings = f'''@MainActor enum MioCloudSettings {{
    static let enabledKey = "mio.cloud.enabled"
    static let serverKey = "mio.cloud.server"
    static var usesAccess: Bool {{ false }}
    static var serverAddress: String {{ UserDefaults.standard.string(forKey: serverKey) ?? "" }}
    {endpoint}
    {updated_credentials}
    private {token_validation}
    static func connection() throws -> MioCloudConnection {{ throw MioCloudError.disabled }}
}}
'''
    source = source[:settings_start] + platform_settings + source[service_start:]
    source = source.replace("import Security", "import FoundationNetworking")
    # This Apple-only configuration property is get-only in corelibs Foundation.
    source = source.replace("        configuration.waitsForConnectivity = false\n", "")
    source += '''
// A platform boundary, never a model/repository/coordinator substitute.
@MainActor enum MioSystemServices {
    static let shared = PortableSystemActions()
}
@MainActor final class PortableSystemActions {
    var errorMessage: String? { "Unavailable portable boundary" }
    func cancelActions(for id: UUID) async -> Bool { false }
}
extension URLSession {
    func bytes(for request: URLRequest, delegate: URLSessionTaskDelegate?) async throws
        -> (AsyncThrowingStream<UInt8, Error>, URLResponse) {
        throw MioCloudError.network
    }
}
'''
    return source



def portable_capture_source() -> str:
    """Keep real VM/pipeline logic; substitute only Apple capture/settings/device APIs."""
    source = (ROOT / "Mio/MioViewModel.swift").read_text()
    for name in ("AVFoundation", "SwiftUI", "UIKit"):
        source = source.replace("import " + name + "\n", "")
    source = source.replace("return Self.durationFormatter.string(from: TimeInterval(seconds))", "return String(seconds)")
    marker = "    private static let durationFormatter: DateComponentsFormatter = {"
    start = source.index(marker)
    end = source.index("    }()", start) + len("    }()")
    source = source[:start] + source[end:]
    platform = r'''
// Linux substitutes for Apple-only boundaries; all application/session logic is real.
struct TranscriptionConnection: Sendable { }
@MainActor enum TranscriptionSettings {
    static func connection() throws -> TranscriptionConnection { throw TranscriptionError.notConfigured }
}
final class TranscriptionClient: TranscriptionTransport, @unchecked Sendable {
    init(connection: TranscriptionConnection) { }
    func cancel() { }
    func startTranscription(_ chunk: AudioChunk) -> Task<TranscriptionReply, Error> { Task { throw TranscriptionError.notConfigured } }
    func health() async throws -> TranscriptionHealth { throw TranscriptionError.notConfigured }
}
@MainActor enum SpeechCapabilityService {
    static var microphonePermission: MicrophonePermission { .notDetermined }
}
struct UIBackgroundTaskIdentifier: Hashable, Sendable {
    let rawValue: Int
    static let invalid = UIBackgroundTaskIdentifier(rawValue: -1)
}
@MainActor final class UIApplication {
    enum State { case active, background, inactive }
    static let shared = UIApplication()
    static let openSettingsURLString = "app-settings:"
    var applicationState: State = .active
    func beginBackgroundTask(withName: String, expirationHandler: () -> Void) -> UIBackgroundTaskIdentifier { .invalid }
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) { }
    func open(_ url: URL) { }
}
@MainActor final class UIDevice: NSObject {
    enum BatteryState { case unknown, unplugged, charging, full }
    static let current = UIDevice()
    static let batteryLevelDidChangeNotification = Notification.Name("batteryLevel")
    static let batteryStateDidChangeNotification = Notification.Name("batteryState")
    var isBatteryMonitoringEnabled = false
    var batteryLevel: Float = -1
    var batteryState: BatteryState = .unknown
    var systemVersion = "portable-boundary"
}
enum ScenePhase { case active, inactive, background }
@MainActor enum MioFeedback { static func success() { } }
struct CapturedPCMBuffer: Sendable {
    let buffer: Data
    let stamp: AudioCaptureStamp
    var channelCount: Int { 1 }
}
final class BufferConverter {
    func reset() {}
    func transcriptionPCM(_ buffer: Data) throws -> Data { buffer }
    func finishTranscriptionPCM() throws -> Data { Data() }
}

final class UnavailableAudioCapture: AudioCapturing, @unchecked Sendable {
    var lastBufferUptime: TimeInterval { 0 }
    func start() async throws { throw TranscriptionError.notConfigured }
    func stop() async { }
    func checkAfterForeground() { }
}
extension LiveTranscriptionPipeline {
    init(connection: TranscriptionConnection, sessionID: UUID, handlers: Handlers) {
        self.init(sessionID: sessionID, handlers: handlers, transport: TranscriptionClient(connection: connection),
            captureFactory: { _, _ in UnavailableAudioCapture() }, permission: { false })
    }
}
'''
    return platform + source


def main() -> int:
    requested = os.environ.get("SWIFT_EXECUTABLE", "swiftc")
    swiftc = shutil.which(requested)
    if not swiftc:
        print("Swift compiler unavailable; set SWIFT_EXECUTABLE to a compatible swiftc. No tests ran.", file=sys.stderr)
        return 2
    if sys.platform != "linux":
        print("This harness uses Linux FoundationNetworking; run native XCTest through Xcode on Apple hosts.", file=sys.stderr)
        return 2
    subprocess.run([swiftc, "--version"], check=True)
    with tempfile.TemporaryDirectory(prefix="mio-swift-core-") as temporary:
        build = Path(temporary)
        cloud = build / "MioCloudPortable.swift"
        cloud.write_text(portable_cloud_source() + portable_capture_source())
        copied_tests: list[str] = []
        registrations: list[str] = []
        for relative in TESTS:
            source = (ROOT / relative).read_text()
            class_match = re.search(r"final class (\w+): XCTestCase", source)
            if not class_match:
                raise ValueError(f"XCTest class missing in {relative}")
            class_name = class_match.group(1)
            entries: list[str] = []
            for match in re.finditer(r"func (test\w+)\(\)([^\{]*)\{", source):
                name, signature = match.groups()
                function = f"{class_name}.{name}"
                if "async" in signature:
                    function = f"asyncTest({function})"
                entries.append(f'("{name}", {function})')
            registrations.append("testCase([\n" + ",\n".join(entries) + "\n])")
            test_path = build / Path(relative).name
            test_path.write_text(source)
            copied_tests.append(str(test_path))
        runner = build / "main.swift"
        runner.write_text("import XCTest\nXCTMain([\n" + ",\n".join(registrations) + "\n])\n")
        module_cache = str(build / "module-cache")
        library = build / "libMio.so"
        compile_module = [swiftc, "-swift-version", "5", "-module-cache-path", module_cache,
                          "-enable-testing", "-emit-library", "-emit-module", "-module-name", "Mio",
                          "-emit-module-path", str(build / "Mio.swiftmodule"), "-o", str(library)]
        subprocess.run(compile_module + [str(ROOT / path) for path in SOURCES] + [str(cloud)], check=True)
        executable = build / "core-tests"
        subprocess.run([swiftc, "-swift-version", "5", "-module-cache-path", module_cache,
                        "-I", str(build), "-L", str(build), "-lMio"] + copied_tests
                       + [str(runner), "-o", str(executable)], check=True)
        environment = dict(os.environ)
        environment["LD_LIBRARY_PATH"] = str(build) + ":" + environment.get("LD_LIBRARY_PATH", "")
        print("Portable core + capture lifecycle XCTest; native microphone/converter/network/UI boundaries excluded.", flush=True)
        subprocess.run([str(executable)], env=environment, check=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (subprocess.CalledProcessError, ValueError, OSError) as error:
        print(f"Portable Swift core verification failed: {error}", file=sys.stderr)
        raise SystemExit(1)
