import Foundation
import Observation

/// Routes are held until local stores have loaded; opening a notification performs
/// no model work, capture restart, or system action.
@MainActor @Observable
final class MioNavigationCoordinator {
    var selectedTab = MioAppTab.capture
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
            guard let tab = destination(id) else { selectedTab = .daily; return }
            selectedTab = tab
            presentedPost = MioPresentedPost(id: id)
        case .morning:
            selectedTab = .daily
            dailyPeriod = .morning
            onDailyRoute()
        case .evening:
            selectedTab = .daily
            dailyPeriod = .evening
            onDailyRoute()
        }
    }

    func reconcile(using destination: (UUID) -> MioAppTab?) {
        guard let post = presentedPost, destination(post.id) == nil else { return }
        presentedPost = nil
        selectedTab = .daily
    }
}
