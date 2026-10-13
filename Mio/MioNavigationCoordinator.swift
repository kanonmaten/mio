import Foundation
import Observation

/// Routes are held until local stores have loaded; opening a notification performs
/// no model work or system action. A capture restart comes from the app becoming active.
@MainActor @Observable
final class MioNavigationCoordinator {
    var selectedTab = MioAppTab.home
    var dailyPeriod = MioDailyPeriod.morning
    var presentedPost: MioPresentedPost?
    /// A session opened from a `mio://` link in Calendar, Reminders or Notes.
    var presentedSession: MioPresentedPost?
    private(set) var pendingRoute: MioNotificationRoute?
    private(set) var pendingLinkSessionID: UUID?
    @ObservationIgnored private let onDailyRoute: @MainActor () -> Void

    init(onDailyRoute: @escaping @MainActor () -> Void = {}) {
        self.onDailyRoute = onDailyRoute
    }

    func receive(_ route: MioNotificationRoute) { pendingRoute = route }

    func resolvePending(using destination: (UUID) -> MioAppTab?) {
        guard let route = pendingRoute else { return }
        pendingRoute = nil
        presentedPost = nil
        switch route {
        case .post(let id):
            guard let tab = destination(id) else { selectedTab = .home; return }
            selectedTab = tab
            presentedPost = MioPresentedPost(id: id)
        case .morning:
            selectedTab = .home
            dailyPeriod = .morning
            onDailyRoute()
        case .evening:
            selectedTab = .home
            dailyPeriod = .evening
            onDailyRoute()
        case .resumeListening:
            // Becoming active retries the microphone in MioViewModel; this only shows it.
            selectedTab = .capture
        }
    }

    /// Held like a notification route until the stores have loaded. Only opens a view: a link
    /// never starts the microphone or AI, and anything but a session link just shows Hem.
    func receive(link url: URL) {
        pendingLinkSessionID = MioLink.sessionID(from: url)
        if pendingLinkSessionID == nil { presentedSession = nil; selectedTab = .home }
    }

    func resolvePendingLink(sessionExists: (UUID) -> Bool) {
        guard let id = pendingLinkSessionID else { return }
        pendingLinkSessionID = nil
        presentedPost = nil
        guard sessionExists(id) else { presentedSession = nil; selectedTab = .home; return }
        presentedSession = MioPresentedPost(id: id)
    }

    func reconcile(using destination: (UUID) -> MioAppTab?) {
        guard let post = presentedPost, destination(post.id) == nil else { return }
        presentedPost = nil
        selectedTab = .home
    }
}
