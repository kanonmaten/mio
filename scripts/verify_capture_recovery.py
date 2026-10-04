#!/usr/bin/env python3
"""Exercise real microphone notification/lifecycle logic with an Apple engine double.

Only engine construction/start/teardown and AVFoundation types are substituted.
The workspace MicrophoneCapture start, stop, observers, notification handling,
foreground check and recovery logic execute unchanged. This is a Linux regression
gate for manual continuation, not an AVFoundation or physical microphone test.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

from verify_concurrency import concurrency_warnings

ROOT = Path(__file__).resolve().parents[1]


def replace_body(source, name, replacement):
    marker = f"private func {name}("
    start = source.index(marker)
    opening = source.index("{", start)
    index, depth = opening + 1, 1
    while depth:
        depth += (source[index] == "{") - (source[index] == "}")
        index += 1
    return source[:opening + 1] + replacement + source[index - 1:]


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
    case needsResume(String), routeChanged(String)
}
struct AVAudioFormat { var channelCount: UInt32 = 1 }
final class AVAudioPCMBuffer { let format = AVAudioFormat() }
final class AVAudioEngine: @unchecked Sendable {
    nonisolated(unsafe) static var latest: AVAudioEngine?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var starts = 0
    static var startCount: Int { lock.withLock { starts } }
    static func resetCounts() { lock.withLock { starts = 0 } }
    var isRunning = false
    init() { Self.latest = self }
    func start() throws { isRunning = true; Self.lock.withLock { Self.starts += 1 } }
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
    var reportsReset: Bool {
        lock.withLock { events.contains { if case .mediaServicesReset = $0 { return true }; return false } }
    }
}
'''

TESTS = r'''
@main struct RecoveryRegression {
    static func main() async throws {
        var failures = 0
        for scenario in ["interruption-resumable", "interruption-manual", "route", "configuration",
                         "configuration-stale", "reset", "own-category", "foreground"] {
            AVAudioEngine.resetCounts()
            let (_, continuation) = AsyncStream<CapturedPCMBuffer>.makeStream()
            let events = Events()
            let capture = MicrophoneCapture(output: continuation, event: { events.receive($0) })
            try await capture.start()
            let center = NotificationCenter.default
            switch scenario {
            case "interruption-resumable", "interruption-manual":
                center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: UInt(1)])
                center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: UInt(0),
                        AVAudioSessionInterruptionOptionKey: scenario == "interruption-resumable" ? UInt(1) : UInt(0)])
            case "route", "own-category":
                center.post(name: AVAudioSession.routeChangeNotification, object: nil,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: scenario == "route" ? UInt(1) : UInt(3)])
            case "configuration":
                center.post(name: .AVAudioEngineConfigurationChange, object: AVAudioEngine.latest)
            case "configuration-stale":
                _ = AVAudioEngine()
                center.post(name: .AVAudioEngineConfigurationChange, object: AVAudioEngine.latest)
            case "reset":
                center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
            default: capture.checkAfterForeground()
            }
            // stop is queued after notification handling and provides a deterministic barrier.
            await capture.stop()
            let continuationExpected = !["configuration-stale", "own-category", "reset"].contains(scenario)
            if AVAudioEngine.startCount != 1 || events.requestsContinuation != continuationExpected
                || (scenario == "reset" && !events.reportsReset) {
                failures += 1
                print("FAIL \(scenario): starts=\(AVAudioEngine.startCount), requestsContinuation=\(events.requestsContinuation)")
            } else { print("PASS \(scenario)") }
        }
        if failures > 0 { exit(1) }
        print("8 microphone lifecycle regressions passed; Apple engine boundary substituted.")
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
    with tempfile.TemporaryDirectory(prefix="mio-capture-recovery-") as temporary:
        directory = Path(temporary)
        program = directory / "capture.swift"
        program.write_text(BOUNDARY + source + TESTS)
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
