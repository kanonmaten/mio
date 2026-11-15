import Foundation

/// Pure pacing rules for automatic AI work, so a day of everyday listening fits Groq's free
/// tier (200,000 tokens per day). Everyday excerpts are collected and sent together at most
/// once per five-minute window; lesson parts keep the server's interval (at least 60 s).
enum MioAnalysisSchedule {
    static let everydayWindow: TimeInterval = 300
    /// Minimum spacing between any two model calls, also inside one everyday window.
    static let minimumSpacing: TimeInterval = 60

    enum Kind: Sendable { case everyday, lesson }

    struct Input: Sendable {
        var kind: Kind
        /// When the oldest text in the next request was queued.
        var enqueuedAt: Date
        /// Pause or stop drains already captured everyday text without waiting for the window.
        var isFinal = false
        /// End of the last model call of any kind.
        var lastSentAt: Date?
        /// When the current everyday window started sending; text queued before it rides along.
        var windowOpenedAt: Date?
        var lessonInterval: TimeInterval = 60
        /// Retry-After or quota deadline from the gateway.
        var pausedUntil: Date?
    }

    /// The earliest time the next request may be sent; never earlier than `now`.
    static func nextSendTime(_ input: Input, now: Date) -> Date {
        let spacing = input.kind == .lesson ? max(minimumSpacing, input.lessonInterval) : minimumSpacing
        var due = input.lastSentAt.map { $0.addingTimeInterval(spacing) } ?? .distantPast
        if input.kind == .everyday, !input.isFinal {
            let inOpenWindow = input.windowOpenedAt.map { input.enqueuedAt <= $0 } ?? false
            if !inOpenWindow {
                due = max(due, input.enqueuedAt.addingTimeInterval(everydayWindow))
                if let opened = input.windowOpenedAt { due = max(due, opened.addingTimeInterval(everydayWindow)) }
            }
        }
        if let pausedUntil = input.pausedUntil { due = max(due, pausedUntil) }
        return max(now, due)
    }

    /// When automatic work may continue after an error, or nil when it must stop. A quota or
    /// rate limit follows Retry-After (the day/token limits at least until the quota resets);
    /// an unreachable PC is tried again after one everyday window. Nothing is resent sooner.
    static func retryDeadline(after error: Error, now: Date, quotaResetAt: Date?) -> Date? {
        guard let error = error as? MioCloudError else { return nil }
        switch error {
        case .rateLimited(let seconds):
            return now.addingTimeInterval(TimeInterval(seconds))
        case .gatewayRateLimited(let code, let seconds):
            let retry = now.addingTimeInterval(TimeInterval(seconds))
            guard [.localDayLimit, .localTokenLimit].contains(code), let quotaResetAt else { return retry }
            return max(quotaResetAt, retry)
        case .network:
            return now.addingTimeInterval(everydayWindow)
        case .gateway(_, let code) where transientGatewayCodes.contains(code):
            return now.addingTimeInterval(minimumSpacing)
        case .serverStatus(let status) where [502, 503, 504].contains(status):
            // Tailscale Serve answers these while the gateway restarts.
            return now.addingTimeInterval(minimumSpacing)
        default:
            return nil
        }
    }

    /// Failures that pass by themselves: the provider or the PC was briefly unavailable or slow.
    /// They pause automatic work for a minute instead of stopping AI (2026-11-15).
    static let transientGatewayCodes: Set<MioGatewayErrorCode> = [
        .upstreamTimeout, .requestTimeout, .upstreamUnavailable, .providerInfrastructure, .providerTransport,
        .requestFailed
    ]

    /// Doubles a short wait for each pause in a row, up to one everyday window, so a failure
    /// that keeps returning is retried ever more rarely. Longer waits (a quota reset) are kept.
    static func backoff(_ deadline: Date, now: Date, consecutivePauses: Int) -> Date {
        let wait = deadline.timeIntervalSince(now)
        guard consecutivePauses > 0, wait > 0, wait < everydayWindow else { return deadline }
        let factor = Double(1 << min(consecutivePauses, 4))
        return now.addingTimeInterval(min(everydayWindow, wait * factor))
    }

    /// Seconds before a question may be sent again by itself, or nil when the user must act.
    /// Short rate limits and brief failures are waited out; day limits and real errors are shown.
    static func questionRetrySeconds(after error: Error) -> Int? {
        guard let error = error as? MioCloudError else { return nil }
        switch error {
        case .rateLimited(let seconds):
            return seconds <= 90 ? seconds : nil
        case .gatewayRateLimited(let code, let seconds):
            return ![.localDayLimit, .localTokenLimit].contains(code) && seconds <= 90 ? seconds : nil
        case .changedConfiguration, .gateway(409, .configurationChanged):
            return 0
        case .gateway(_, let code) where transientGatewayCodes.contains(code):
            return 3
        case .serverStatus(let status) where [502, 503, 504].contains(status):
            return 3
        default:
            return nil
        }
    }

    /// Minutes the oldest queued everyday text has waited, shown on Hem once it exceeds ten.
    static func lagMinutes(oldest: Date?, now: Date) -> Int? {
        guard let oldest else { return nil }
        let waited = now.timeIntervalSince(oldest)
        return waited > 600 ? Int(waited / 60) : nil
    }

    /// Whether queued everyday text is dropped during a pause instead of kept. The text stays on
    /// the phone; only its analysis is skipped, so a long quota pause cannot grow the queue.
    static func dropsEverydayWork(pausedUntil: Date, now: Date) -> Bool {
        pausedUntil.timeIntervalSince(now) > everydayWindow
    }
}

/// Connection failures that happen before the request reaches the PC. They are typical while
/// Tailscale's on-demand VPN is still coming up after the phone was idle, and a retry a moment
/// later succeeds. Nothing was sent, so a retry can never duplicate a model call.
enum MioCloudRetry {
    /// NSURLError codes: cannot find host, cannot connect, DNS lookup failed, not connected,
    /// international roaming off, data not allowed, secure connection failed.
    static let preConnectionCodes: Set<Int> = [-1003, -1004, -1006, -1009, -1018, -1020, -1200]

    /// Wait before attempt `attempt + 1`, or nil when the failure must be reported.
    static func delay(urlErrorCode: Int, attempt: Int) -> TimeInterval? {
        guard preConnectionCodes.contains(urlErrorCode), (1...3).contains(attempt) else { return nil }
        return [1, 2.5, 5][attempt - 1]
    }
}

/// A request the provider cannot take in one piece: too large for its per-minute token budget,
/// or an answer cut off at the output limit. Sending the same text again can never work; a
/// smaller part can (2026-11-15).
enum MioWorkSplit {
    static let maximumShrink = 3

    static func needsSmallerRequest(_ error: Error) -> Bool {
        switch error as? MioCloudError {
        case .gateway(_, let code)?: [.providerRequestTooLarge, .providerTruncated].contains(code)
        case .serverStatus(413)?: true
        default: false
        }
    }
}

/// What to do when the model's answer for a lesson part is rejected (user decision 2026-10-13).
/// A part rejected twice is split into two halves in source order; a half rejected twice more is
/// marked as unprocessed so the rest of the lesson continues. Quota, rate and network errors are
/// pauses, never rejections, and AI is never turned off because of a rejected part.
enum MioLessonRetry {
    static let attemptsPerPart = 2

    enum Action: Equatable, Sendable {
        case retry
        case split([[MioAnalysisFragment]])
        case markUnprocessed
    }

    /// An answer the gateway or the app refused as invalid model output.
    static func isRejectedAnswer(_ error: Error) -> Bool {
        switch error as? MioCloudError {
        case .gateway(_, let code)?:
            [.invalidLessonResult, .invalidAnalysisResult, .invalidUpstreamResponse, .invalidUpstreamAnswer,
             .incompleteUpstreamResponse, .providerInvalidResponse, .providerTruncated].contains(code)
        case .invalidResponse?: true
        default: false
        }
    }

    /// `failures` counts rejections of exactly these fragments, including the latest one.
    /// `depth` is 0 for a part as batched and 1 for a half.
    static func action(failures: Int, depth: Int, fragments: [MioAnalysisFragment]) -> Action {
        guard failures >= attemptsPerPart else { return .retry }
        guard depth == 0, fragments.count > 1 else { return .markUnprocessed }
        let middle = fragments.count / 2
        return .split([Array(fragments[..<middle]), Array(fragments[middle...])])
    }

    static func key(_ fragments: [MioAnalysisFragment]) -> String { fragments.map(\.id).joined(separator: "|") }
}
