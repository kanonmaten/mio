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
    /// The review sheet after a lesson's notes are done: proposals with Ja or Nej, and the subject.
    var presentedLessonReview: MioPresentedPost?
    /// Notes that finished while she was busy (another sheet open, or capturing on Fånga): a
    /// small row offers the review instead of opening it over what she is doing. Memory only;
    /// the review stays reachable from the lesson itself.
    private(set) var readyLessonReviewID: UUID?
    private(set) var pendingRoute: MioNotificationRoute?
    private(set) var pendingLinkSessionID: UUID?
    @ObservationIgnored private let onDailyRoute: @MainActor () -> Void

    init(onDailyRoute: @escaping @MainActor () -> Void = {}) {
        self.onDailyRoute = onDailyRoute
    }

    func receive(_ route: MioNotificationRoute) { pendingRoute = route }

    /// Finished notes while the app is in the foreground. This is not her tap, so it never
    /// closes a sheet, changes the tab or interrupts capture: the review sheet opens only over a
    /// plain screen, otherwise the offer waits in `readyLessonReviewID` until she taps it.
    /// `otherSheetOpen` covers sheets this coordinator does not own (settings, editors, alerts).
    func lessonNotesReady(_ id: UUID, otherSheetOpen: Bool, capturing: Bool) {
        let busy = otherSheetOpen || pendingRoute != nil || pendingLinkSessionID != nil
            || presentedPost != nil || presentedSession != nil || presentedLessonReview != nil
            || (selectedTab == .capture && capturing)
        if busy {
            readyLessonReviewID = id
        } else {
            readyLessonReviewID = nil
            presentedLessonReview = MioPresentedPost(id: id)
        }
    }

    /// Her tap on the offer: opens the review over the current tab, which stays as it is.
    func openReadyLessonReview(lessonExists: (UUID) -> Bool) {
        guard let id = readyLessonReviewID else { return }
        readyLessonReviewID = nil
        guard lessonExists(id), presentedLessonReview == nil else { return }
        presentedLessonReview = MioPresentedPost(id: id)
    }

    func dismissReadyLessonReview() { readyLessonReviewID = nil }

    func resolvePending(using destination: (UUID) -> MioAppTab?, lessonExists: (UUID) -> Bool = { _ in false }) {
        guard let route = pendingRoute else { return }
        pendingRoute = nil
        presentedPost = nil
        switch route {
        case .lessonReview(let id):
            // Her tap on the notification: it may navigate, and the waiting offer is answered.
            if readyLessonReviewID == id { readyLessonReviewID = nil }
            // A deleted lesson falls back to Hem like a deleted post.
            guard lessonExists(id) else { presentedLessonReview = nil; selectedTab = .home; return }
            selectedTab = .lessons
            presentedLessonReview = MioPresentedPost(id: id)
        case .post(let id):
            guard let tab = destination(id) else { selectedTab = .home; return }
            selectedTab = tab
            presentedPost = MioPresentedPost(id: id)
        case .morning:
            selectedTab = .home
            dailyPeriod = .morning
            onDailyRoute()
        case .evening:
            // Fas 5: the evening notification counts proposals to review, so it opens Förslag.
            selectedTab = .proposals
            dailyPeriod = .evening
            onDailyRoute()
        case .resumeListening:
            // Becoming active retries the microphone in MioViewModel; this only shows it.
            selectedTab = .capture
        case .stillListening:
            // The answer itself is handled by MioViewModel.confirmStillListening; this only shows it.
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
