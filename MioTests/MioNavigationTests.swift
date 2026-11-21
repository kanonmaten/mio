import Foundation
import Observation
import XCTest
@testable import Mio

final class MioNavigationTests: XCTestCase {
    func testNotificationRoutesRoundTripOnlyFixedNamesAndOpaquePostIdentity() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        for route in [MioNotificationRoute.post(id), .morning, .evening] {
            XCTAssertEqual(MioNotificationRoute(userInfo: route.userInfo), route)
            XCTAssertTrue(Set(route.userInfo.keys).isSubset(of: ["mioRoute", "mioPostID"]))
        }
        XCTAssertEqual(MioNotificationRoute.post(id).userInfo["mioPostID"], id.uuidString)
        XCTAssertEqual(MioNotificationRoute(userInfo: ["mioRoute": "post", "mioPostID": id.uuidString.lowercased()]), .post(id))
    }

    func testMalformedNotificationRoutesNeverBecomeContentOrExecutableActions() {
        for payload: [AnyHashable: Any] in [[:], ["mioRoute": "post"], ["mioRoute": "post", "mioPostID": "private text"],
            ["mioRoute": "post", "mioPostID": 42], ["mioRoute": "morning", "mioPostID": UUID().uuidString],
            ["mioRoute": "evening", "text": "Private text"], ["mioRoute": "execute"], [42: "morning"]] {
            XCTAssertNil(MioNotificationRoute(userInfo: payload))
        }
    }

    @MainActor
    func testFinishedNotesNeverCloseASheetChangeTheTabOrInterruptCapture() {
        let navigation = MioNavigationCoordinator()
        let lesson = UUID()
        // A plain screen: the review opens over the tab she is on, which stays as it is.
        navigation.selectedTab = .proposals
        navigation.lessonNotesReady(lesson, otherSheetOpen: false, capturing: false)
        XCTAssertEqual(navigation.presentedLessonReview?.id, lesson)
        XCTAssertEqual(navigation.selectedTab, .proposals)
        XCTAssertNil(navigation.readyLessonReviewID)
        navigation.presentedLessonReview = nil

        // Settings or another screen's sheet is up: only the offer, nothing is closed.
        navigation.lessonNotesReady(lesson, otherSheetOpen: true, capturing: false)
        XCTAssertNil(navigation.presentedLessonReview)
        XCTAssertEqual(navigation.readyLessonReviewID, lesson)
        XCTAssertEqual(navigation.selectedTab, .proposals)
        navigation.dismissReadyLessonReview()

        // A post or session the coordinator shows stays open.
        let post = MioPresentedPost(id: UUID())
        navigation.presentedSession = post
        navigation.lessonNotesReady(lesson, otherSheetOpen: false, capturing: false)
        XCTAssertEqual(navigation.presentedSession, post)
        XCTAssertNil(navigation.presentedLessonReview)
        XCTAssertEqual(navigation.readyLessonReviewID, lesson)
        navigation.presentedSession = nil
        navigation.dismissReadyLessonReview()

        // Capturing on Fånga: no sheet over the capture screen. Elsewhere it may open.
        navigation.selectedTab = .capture
        navigation.lessonNotesReady(lesson, otherSheetOpen: false, capturing: true)
        XCTAssertNil(navigation.presentedLessonReview)
        XCTAssertEqual(navigation.selectedTab, .capture)
        // Her tap on the row opens it without changing the tab.
        navigation.openReadyLessonReview { $0 == lesson }
        XCTAssertEqual(navigation.presentedLessonReview?.id, lesson)
        XCTAssertEqual(navigation.selectedTab, .capture)
        XCTAssertNil(navigation.readyLessonReviewID)
        navigation.presentedLessonReview = nil

        // A deleted lesson's offer opens nothing.
        navigation.lessonNotesReady(lesson, otherSheetOpen: true, capturing: false)
        navigation.openReadyLessonReview { _ in false }
        XCTAssertNil(navigation.presentedLessonReview)
        XCTAssertNil(navigation.readyLessonReviewID)

        // Her tap on the notification still navigates, and answers the waiting offer.
        navigation.lessonNotesReady(lesson, otherSheetOpen: true, capturing: true)
        navigation.receive(.lessonReview(lesson))
        navigation.resolvePending(using: { _ in nil }, lessonExists: { $0 == lesson })
        XCTAssertEqual(navigation.selectedTab, .lessons)
        XCTAssertEqual(navigation.presentedLessonReview?.id, lesson)
        XCTAssertNil(navigation.readyLessonReviewID)
    }

    @MainActor
    func testNotificationWaitsForLoadedStoreBeforeResolvingThePost() async {
        let id = UUID()
        let navigation = MioNavigationCoordinator()
        navigation.receive(.post(id))
        XCTAssertEqual(navigation.selectedTab, .home)
        XCTAssertNil(navigation.presentedPost)
        navigation.resolvePending { requested in requested == id ? .proposals : nil }
        XCTAssertEqual(navigation.selectedTab, .proposals)
        XCTAssertEqual(navigation.presentedPost?.id, id)
        XCTAssertNil(navigation.pendingRoute)
    }

    @MainActor
    func testDeletedOrMissingPostsFallBackAndNeverReopenAStaleEditor() async {
        let id = UUID()
        let navigation = MioNavigationCoordinator()
        navigation.receive(.post(id))
        navigation.resolvePending { _ in .proposals }
        XCTAssertEqual(navigation.presentedPost?.id, id)
        navigation.reconcile { _ in nil }
        XCTAssertNil(navigation.presentedPost)
        XCTAssertEqual(navigation.selectedTab, .home)
        navigation.receive(.post(id))
        navigation.resolvePending { _ in nil }
        XCTAssertNil(navigation.presentedPost)
        XCTAssertEqual(navigation.selectedTab, .home)
    }

    @MainActor
    func testDailyNotificationsSelectTheirNativeOverviewAndClearPostPresentation() async {
        let navigation = MioNavigationCoordinator()
        navigation.receive(.post(UUID()))
        navigation.resolvePending { _ in .proposals }
        navigation.receive(.evening)
        navigation.resolvePending { _ in nil }
        // Fas 5: the evening notification counts proposals to review and opens Förslag.
        XCTAssertEqual(navigation.selectedTab, .proposals)
        XCTAssertEqual(navigation.dailyPeriod, .evening)
        XCTAssertNil(navigation.presentedPost)
        navigation.receive(.morning)
        navigation.resolvePending { _ in nil }
        XCTAssertEqual(navigation.selectedTab, .home)
        XCTAssertEqual(navigation.dailyPeriod, .morning)
    }

    @MainActor
    func testDailyNotificationReturnsToTodayAfterHistoricalDateSelection() async {
        let now = date("2026-10-03T12:00:00Z")
        let calendar = calendar("Europe/Stockholm")
        let day = MioDayContext(now: now, calendar: calendar)
        let navigation = MioNavigationCoordinator(onDailyRoute: {
            day.refresh(now: now, calendar: calendar)
            day.select(day.referenceDate)
        })
        for route in [MioNotificationRoute.morning, .evening] {
            day.select(date("2026-09-20T12:00:00Z"))
            navigation.receive(route)
            navigation.resolvePending { _ in nil }
            XCTAssertEqual(day.selectedDate, now)
            XCTAssertTrue(day.followsToday)
        }
    }

    @MainActor
    func testPostNotificationPreservesExplicitHistoricalOverviewDate() async {
        let now = date("2026-10-03T12:00:00Z")
        let calendar = calendar("Europe/Stockholm")
        let selected = date("2026-09-20T12:00:00Z")
        let day = MioDayContext(now: now, calendar: calendar)
        let navigation = MioNavigationCoordinator(onDailyRoute: {
            day.refresh(now: now, calendar: calendar)
            day.select(day.referenceDate)
        })
        day.select(selected)
        navigation.receive(.post(UUID()))
        navigation.resolvePending { _ in .proposals }
        XCTAssertEqual(day.selectedDate, selected)
        XCTAssertFalse(day.followsToday)
    }

    /// Ultrareview E3: Hem rebuilds its overview when `revision` changes, and choosing another
    /// day or week did not change it, so Hem kept showing the previous day.
    @MainActor
    func testSelectingAnotherDayChangesTheRevisionHemObserves() async {
        let day = MioDayContext(now: date("2026-10-03T12:00:00Z"), calendar: calendar("Europe/Stockholm"))
        let before = day.revision
        day.select(date("2026-09-28T12:00:00Z"))
        XCTAssertGreaterThan(day.revision, before)
        let after = day.revision
        day.select(date("2026-09-28T12:00:00Z"))
        XCTAssertEqual(day.revision, after, "Choosing the same date again changes nothing")
    }

    @MainActor
    func testFollowingTodayRefreshesAfterMidnightAndAfterSeveralDaysAsleep() async {
        let day = MioDayContext(now: date("2026-10-02T21:50:00Z"), calendar: calendar("Europe/Stockholm"))
        let before = day.revision
        day.refresh(now: date("2026-10-03T07:00:00Z"), calendar: calendar("Europe/Stockholm"))
        XCTAssertEqual(day.selectedDate, date("2026-10-03T07:00:00Z"))
        XCTAssertEqual(day.startOfToday, date("2026-10-02T22:00:00Z"))
        XCTAssertGreaterThan(day.revision, before)
        day.refresh(now: date("2026-10-06T07:00:00Z"), calendar: calendar("Europe/Stockholm"))
        XCTAssertEqual(day.selectedDate, date("2026-10-06T07:00:00Z"))
    }

    @MainActor
    func testExplicitHistoricalDayIsPreservedDuringForegroundRefresh() async {
        let oldDate = date("2026-09-20T12:00:00Z")
        let day = MioDayContext(now: date("2026-10-02T12:00:00Z"), calendar: calendar("Europe/Stockholm"))
        day.select(oldDate)
        day.refresh(now: date("2026-10-03T12:00:00Z"), calendar: calendar("Europe/Stockholm"))
        XCTAssertEqual(day.selectedDate, oldDate)
        XCTAssertFalse(day.followsToday)
        day.select(date("2026-10-03T08:00:00Z"))
        XCTAssertTrue(day.followsToday)
    }

    @MainActor
    func testTimezoneRefreshRecomputesTodayInsteadOfKeepingTheOldLocalDayBoundary() async {
        let now = date("2026-10-02T22:15:00Z")
        let day = MioDayContext(now: now, calendar: calendar("Europe/Stockholm"))
        XCTAssertEqual(day.startOfToday, date("2026-10-02T22:00:00Z"))
        day.refresh(now: now, calendar: calendar("America/New_York"))
        XCTAssertEqual(day.startOfToday, date("2026-10-02T04:00:00Z"))
        XCTAssertEqual(day.calendar.component(.day, from: day.selectedDate), 2)
    }

    @MainActor
    func testHistoricalOverviewObservesRefreshEvenWhenItsDateAndCalendarStayTheSame() async {
        let now = date("2026-10-03T12:00:00Z")
        let calendar = calendar("Europe/Stockholm")
        let selected = date("2026-09-20T12:00:00Z")
        let day = MioDayContext(now: now, calendar: calendar)
        day.select(selected)
        let refreshed = expectation(description: "Historical overview refreshes")
        withObservationTracking {
            XCTAssertEqual(day.overviewDate, selected)
        } onChange: {
            refreshed.fulfill()
        }
        day.refresh(now: now, calendar: calendar)
        await fulfillment(of: [refreshed], timeout: 0.2)
        XCTAssertEqual(day.selectedDate, selected)
        XCTAssertFalse(day.followsToday)
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }
}
