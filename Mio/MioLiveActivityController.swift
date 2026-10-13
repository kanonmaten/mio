import ActivityKit
import Foundation
import Observation
import os

/// Mirrors the capture state into one Lock Screen / Dynamic Island Live Activity.
/// The timer is rendered by the system, so updates happen only when the phase or the
/// gap count changes. All ActivityKit calls run serially, newest wanted state last.
@MainActor
final class MioLiveActivityController {
    private let capture: MioViewModel
    private var target: MioListeningActivityTarget?
    private var applied: MioListeningActivityTarget?
    // Only the identity is kept. `Activity` is not Sendable and its `update`/`end` are @concurrent,
    // so a stored instance would be main-actor state sent off the actor. Each call looks the
    // activity up in `activities` instead, with a plain loop: a closure such as `first(where:)`
    // would tie the result to the main actor again.
    private var current: (id: String, sessionID: UUID)?
    private var worker: Task<Void, Never>?
    private var removedStaleActivities = false
    private var started = false
    private let logger = Logger(subsystem: "app.mio.assistant", category: "live-activity")

    init(capture: MioViewModel) {
        self.capture = capture
    }

    func start() {
        guard !started else { return }
        started = true
        observe()
        schedule()
    }

    private func observe() {
        let decision = withObservationTracking {
            MioListeningActivityMapping.decision(runState: capture.runState, session: capture.currentSession,
                                                 previous: target)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
        switch decision {
        case .keep: return
        case .end: target = nil
        case let .show(next): target = next
        }
        schedule()
    }

    private func schedule() {
        guard worker == nil, target != applied || !removedStaleActivities else { return }
        worker = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        if !removedStaleActivities {
            removedStaleActivities = true
            // Capture never survives a relaunch, so activities from an earlier process are stale.
            for stale in Activity<MioListeningAttributes>.activities where stale.id != current?.id {
                await stale.end(nil, dismissalPolicy: .immediate)
            }
        }
        while target != applied {
            let wanted = target
            await reconcile(to: wanted)
            applied = wanted
        }
        worker = nil
    }

    private func reconcile(to wanted: MioListeningActivityTarget?) async {
        guard let wanted else {
            if let current {
                self.current = nil
                await end(activityID: current.id)
            }
            return
        }
        let content = ActivityContent(state: wanted.state, staleDate: nil)
        if let current, current.sessionID == wanted.sessionID {
            // A user-dismissed activity stays dismissed for the rest of this session, also once
            // the system has removed it from `activities`.
            for activity in Activity<MioListeningAttributes>.activities where activity.id == current.id {
                if activity.activityState == .ended || activity.activityState == .dismissed { return }
                await activity.update(content)
            }
            return
        }
        if let previous = current {
            current = nil
            await end(activityID: previous.id)
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            let activity = try Activity.request(
                attributes: MioListeningAttributes(sessionID: wanted.sessionID, isLesson: wanted.isLesson),
                content: content, pushType: nil)
            current = (activity.id, wanted.sessionID)
        } catch {
            logger.error("Live Activity could not start: \(String(describing: error), privacy: .public)")
        }
    }

    private func end(activityID id: String) async {
        for activity in Activity<MioListeningAttributes>.activities where activity.id == id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
