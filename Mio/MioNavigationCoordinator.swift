import Foundation
import Observation

/// Routes are held until local stores have loaded; opening a notification performs
/// no model work or system action. A capture restart comes from the app becoming active.
@MainActor @Observable
final class MioNavigationCoordinator {
    var selectedTab = MioAppTab.home
    var dailyPeriod = MioDailyPeriod.morning
    var presentedPost: MioPresentedPost?
    private(set) var pendingRoute: MioNotificationRoute?
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

    func reconcile(using destination: (UUID) -> MioAppTab?) {
        guard let post = presentedPost, destination(post.id) == nil else { return }
        presentedPost = nil
        selectedTab = .home
    }
}
