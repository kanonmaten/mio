import Foundation

/// What the listening Live Activity should show for one session.
struct MioListeningActivityTarget: Equatable, Sendable {
    let sessionID: UUID
    let isLesson: Bool
    let state: MioListeningActivityState
}

enum MioListeningActivityDecision: Equatable, Sendable {
    /// A transient capture state (preparing, stopping): leave the activity as it is.
    case keep
    case end
    case show(MioListeningActivityTarget)
}

enum MioListeningActivityMapping {
    /// Maps capture state to the Live Activity. Only live capture starts an activity; a
    /// paused session keeps an existing one (with a stable pause time) but never creates
    /// one, so a lesson's suspended everyday session does not appear on the Lock Screen.
    static func decision(runState: MioRunState, session: MioSession?,
                         previous: MioListeningActivityTarget?, now: Date = .now) -> MioListeningActivityDecision {
        guard let session, session.endedAt == nil else { return .end }
        let gaps = session.captureGaps?.count ?? 0
        func show(_ phase: MioListeningActivityState.Phase, pausedAt: Date? = nil) -> MioListeningActivityDecision {
            .show(MioListeningActivityTarget(sessionID: session.id, isLesson: session.isLesson,
                state: MioListeningActivityState(phase: phase, startedAt: session.startedAt,
                                                 pausedAt: pausedAt, gapCount: gaps)))
        }
        switch runState {
        case .listening: return show(.listening)
        case .interrupted: return show(.interrupted)
        case .paused:
            guard let previous, previous.sessionID == session.id else { return .end }
            return show(.paused, pausedAt: previous.state.pausedAt ?? now)
        case .preparing, .stopping: return .keep
        case .off, .failed, .unavailable: return .end
        }
    }
}
