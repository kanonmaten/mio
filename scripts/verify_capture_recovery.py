#!/usr/bin/env python3
"""Exercise real microphone notification/lifecycle logic with an Apple engine double.

Only engine construction/start/teardown, the omnidirectional-microphone preference and
AVFoundation types are substituted. The workspace MicrophoneCapture start, stop, observers,
notification handling, automatic restart (user decision 2026-10-11), its rate limit,
foreground check and the real MioCaptureResumePolicy execute unchanged. This is a Linux
regression gate, not an AVFoundation or physical microphone test.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

from verify_concurrency import concurrency_warnings

ROOT = Path(__file__).resolve().parents[1]


def balanced_end(source, opening):
    index, depth = opening + 1, 1
    while depth:
        depth += (source[index] == "{") - (source[index] == "}")
        index += 1
    return index


def replace_body(source, name, replacement):
    marker = f"private func {name}("
    start = source.index(marker)
    opening = source.index("{", start)
    index = balanced_end(source, opening)
    return source[:opening + 1] + replacement + source[index - 1:]


def policy_source():
    """The real resume policy, so the gate exercises the same decisions as the app."""
    source = (ROOT / "Mio/Models/MioSessionModels.swift").read_text()
    start = source.index("enum MioCaptureResumePolicy {")
    return "\n" + source[start:balanced_end(source, source.index("{", start))] + "\n"


BOUNDARY = r'''
import Foundation

struct AudioCaptureStamp: Sendable { }
protocol AudioCapturing: AnyObject, Sendable {
    func start() async throws
    func stop() async
    var lastBufferUptime: TimeInterval { get }
    var droppedBufferCount: Int { get }
    func checkAfterForeground()
}
enum PipelineEvent: Sendable {
    case interruptionBegan, interruptionEnded(shouldResume: Bool), mediaServicesReset
    case needsResume(String), routeChanged(String), restartFailed(String)
}
struct AVAudioFormat { var channelCount: UInt32 = 1 }
final class AVAudioPCMBuffer { let format = AVAudioFormat() }
struct RefusedStart: Error { }
final class AVAudioEngine: @unchecked Sendable {
    nonisolated(unsafe) static var latest: AVAudioEngine?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var starts = 0
    nonisolated(unsafe) private static var refusing = false
    static var startCount: Int { lock.withLock { starts } }
    static func resetCounts() { lock.withLock { starts = 0; refusing = false } }
    /// Models iOS refusing to activate recording, as it can in the background.
    static func refuseStarts(_ value: Bool) { lock.withLock { refusing = value } }
    var isRunning = false
    init() { Self.latest = self }
    func start() throws {
        let refused = Self.lock.withLock { () -> Bool in
            if Self.refusing { return true }
            Self.starts += 1
            return false
        }
        if refused { throw RefusedStart() }
        isRunning = true
    }
    func stop() { isRunning = false }
}
final class AVAudioSession {
    static func sharedInstance() -> AVAudioSession { AVAudioSession() }
    struct SetActiveOptions: OptionSet {
        let rawValue: UInt
        static let notifyOthersOnDeactivation = Self(rawValue: 1)
    }
    struct InterruptionOptions: OptionSet {
        let rawValue: UInt
        static let shouldResume = Self(rawValue: 1)
    }
    enum InterruptionType: UInt { case began = 1, ended = 0 }
    enum RouteChangeReason: UInt { case newDeviceAvailable = 1, categoryChange = 3 }
    static let interruptionNotification = Notification.Name("interruption")
    static let routeChangeNotification = Notification.Name("route")
    static let mediaServicesWereLostNotification = Notification.Name("lost")
    static let mediaServicesWereResetNotification = Notification.Name("reset")
    func setActive(_ active: Bool, options: SetActiveOptions) throws { }
}
let AVAudioSessionInterruptionTypeKey = "type"
let AVAudioSessionInterruptionOptionKey = "options"
let AVAudioSessionRouteChangeReasonKey = "reason"
extension Notification.Name {
    static let AVAudioEngineConfigurationChange = Notification.Name("configuration")
}
final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PipelineEvent] = []
    func receive(_ event: PipelineEvent) { lock.withLock { events.append(event) } }
    var requestsContinuation: Bool {
        lock.withLock { events.contains { if case .needsResume = $0 { return true }; return false } }
    }
    var reportsRefusal: Bool {
        lock.withLock { events.contains { if case .restartFailed = $0 { return true }; return false } }
    }
    var reportsResume: Bool {
        lock.withLock { events.contains { if case .interruptionEnded(shouldResume: true) = $0 { return true }; return false } }
    }
}
'''

TESTS = r'''
struct Expectation { let starts: Int; let continuation: Bool; let refusal: Bool; let resume: Bool }

@main struct RecoveryRegression {
    static func main() async throws {
        let scenarios: [(String, Expectation)] = [
            ("interruption-resumable", Expectation(starts: 2, continuation: false, refusal: false, resume: true)),
            ("interruption-without-should-resume", Expectation(starts: 2, continuation: false, refusal: false, resume: true)),
            ("interruption-then-foreground", Expectation(starts: 2, continuation: false, refusal: false, resume: true)),
            ("route-while-running", Expectation(starts: 1, continuation: false, refusal: false, resume: false)),
            ("route-after-engine-stopped", Expectation(starts: 2, continuation: false, refusal: false, resume: true)),
            ("configuration", Expectation(starts: 2, continuation: false, refusal: false, resume: true)),
            ("configuration-stale", Expectation(starts: 1, continuation: false, refusal: false, resume: false)),
            ("reset", Expectation(starts: 2, continuation: false, refusal: false, resume: true)),
            ("own-category", Expectation(starts: 1, continuation: false, refusal: false, resume: false)),
            ("foreground-stale-buffers", Expectation(starts: 1, continuation: true, refusal: false, resume: false)),
            ("refused-in-background", Expectation(starts: 1, continuation: false, refusal: true, resume: false)),
            ("refused-then-foreground", Expectation(starts: 2, continuation: false, refusal: true, resume: true)),
            ("restart-loop", Expectation(starts: 4, continuation: true, refusal: false, resume: true)),
        ]
        var failures = 0
        for (scenario, expected) in scenarios {
            AVAudioEngine.resetCounts()
            let (_, continuation) = AsyncStream<CapturedPCMBuffer>.makeStream()
            let events = Events()
            let capture = MicrophoneCapture(output: continuation, event: { events.receive($0) })
            try await capture.start()
            let center = NotificationCenter.default
            let began: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: UInt(1)]
            func ended(_ options: UInt) -> [AnyHashable: Any] {
                [AVAudioSessionInterruptionTypeKey: UInt(0), AVAudioSessionInterruptionOptionKey: options]
            }
            switch scenario {
            case "interruption-resumable", "interruption-without-should-resume":
                center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: began)
                center.post(name: AVAudioSession.interruptionNotification, object: nil,
                            userInfo: ended(scenario == "interruption-resumable" ? 1 : 0))
            case "interruption-then-foreground":
                // iOS does not guarantee an .ended notification; foreground retries instead.
                center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: began)
                capture.checkAfterForeground()
            case "route-while-running", "own-category":
                center.post(name: AVAudioSession.routeChangeNotification, object: nil,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: scenario == "own-category" ? UInt(3) : UInt(1)])
            case "route-after-engine-stopped":
                AVAudioEngine.latest?.stop()
                center.post(name: AVAudioSession.routeChangeNotification, object: nil,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: UInt(1)])
            case "configuration":
                center.post(name: .AVAudioEngineConfigurationChange, object: AVAudioEngine.latest)
            case "configuration-stale":
                _ = AVAudioEngine()
                center.post(name: .AVAudioEngineConfigurationChange, object: AVAudioEngine.latest)
            case "reset":
                center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
            case "refused-in-background", "refused-then-foreground":
                AVAudioEngine.refuseStarts(true)
                center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: began)
                center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: ended(1))
                // The capture retries once after one second before reporting the refusal.
                try await Task.sleep(nanoseconds: 1_500_000_000)
                if scenario == "refused-then-foreground" {
                    AVAudioEngine.refuseStarts(false)
                    capture.checkAfterForeground()
                }
            case "restart-loop":
                for _ in 0..<4 { center.post(name: .AVAudioEngineConfigurationChange, object: AVAudioEngine.latest) }
            default: capture.checkAfterForeground()
            }
            // stop is queued after notification handling and provides a deterministic barrier.
            await capture.stop()
            let starts = AVAudioEngine.startCount
            if starts != expected.starts || events.requestsContinuation != expected.continuation
                || events.reportsRefusal != expected.refusal || events.reportsResume != expected.resume {
                failures += 1
                print("FAIL \(scenario): starts=\(starts), continuation=\(events.requestsContinuation), "
                      + "refusal=\(events.reportsRefusal), resume=\(events.reportsResume)")
            } else { print("PASS \(scenario)") }
        }
        if failures > 0 { exit(1) }
        print("\(scenarios.count) microphone lifecycle regressions passed; Apple engine boundary substituted.")
    }
}
'''


def main():
    swiftc = shutil.which(os.environ.get("SWIFT_EXECUTABLE", "swiftc"))
    if not swiftc:
        raise SystemExit("Swift compiler unavailable; no capture recovery tests ran.")
    source = (ROOT / "Mio/Services/MicrophoneCapture.swift").read_text().replace("import AVFoundation\n", "")
    # Keep the real rebuild admission guard; replace only the hardware operations below it.
    source = replace_body(source, "rebuild", "\n        guard active, !stopped, !interrupted else { return }\n        try engine.start()\n    ")
    source = replace_body(source, "tearDownEngine", "\n        engine.stop()\n    ")
    source = replace_body(source, "preferOmnidirectionalBuiltInMicrophone", "\n    ")
    with tempfile.TemporaryDirectory(prefix="mio-capture-recovery-") as temporary:
        directory = Path(temporary)
        program = directory / "capture.swift"
        program.write_text(BOUNDARY + policy_source() + source + TESTS)
        executable = directory / "capture-tests"
        result = subprocess.run(
            [swiftc, "-swift-version", "5", "-strict-concurrency=complete", "-warn-concurrency",
             "-parse-as-library", str(program), "-o", str(executable)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        warnings = concurrency_warnings(result.stdout)
        if result.returncode or warnings:
            print(result.stdout, end="")
            raise SystemExit(f"Capture recovery diagnostic failed: compiler exit {result.returncode}; "
                             f"{len(warnings)} concurrency warning blocks.")
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    main()
