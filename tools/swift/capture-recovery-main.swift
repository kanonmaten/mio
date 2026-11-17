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
