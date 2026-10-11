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
    private var activity: Activity<MioListeningAttributes>?
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
            for stale in Activity<MioListeningAttributes>.activities where stale.id != activity?.id {
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
            if let activity {
                self.activity = nil
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            return
        }
        let content = ActivityContent(state: wanted.state, staleDate: nil)
        if let activity, activity.attributes.sessionID == wanted.sessionID {
            // A user-dismissed activity stays dismissed for the rest of this session.
            if activity.activityState == .ended || activity.activityState == .dismissed { return }
            await activity.update(content)
            return
        }
        if let previous = activity {
            activity = nil
            await previous.end(nil, dismissalPolicy: .immediate)
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: MioListeningAttributes(sessionID: wanted.sessionID, isLesson: wanted.isLesson),
                content: content, pushType: nil)
        } catch {
            logger.error("Live Activity could not start: \(String(describing: error), privacy: .public)")
        }
    }
}
