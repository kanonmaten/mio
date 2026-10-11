import Foundation
import XCTest
@testable import Mio

final class MioWeekPlannerTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    func testSwedishWeekNumbersFollowISO8601AcrossTheYearBoundary() {
        // 2026-01-01 is a Thursday, so it belongs to week 1; 2027-01-01 is a Friday in week 53 of 2026.
        XCTAssertEqual(MioWeekPlanner.weekNumber(of: date("2026-01-01T12:00:00Z"), calendar: calendar), 1)
        XCTAssertEqual(MioWeekPlanner.weekNumber(of: date("2026-10-11T12:00:00Z"), calendar: calendar), 41)
        XCTAssertEqual(MioWeekPlanner.weekNumber(of: date("2027-01-01T12:00:00Z"), calendar: calendar), 53)
        // A US-style calendar (Sunday first) must not change the Swedish answer.
        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        sundayFirst.minimumDaysInFirstWeek = 1
        XCTAssertEqual(MioWeekPlanner.weekNumber(of: date("2026-10-11T12:00:00Z"), calendar: sundayFirst), 41)
    }

    func testWeekStartsOnMondayAndMarksTodayAndFuture() {
        let sunday = date("2026-10-11T10:00:00Z")
        let week = MioWeekOverview.make(containing: sunday, today: sunday, activity: [:], calendar: calendar)
        XCTAssertEqual(week.days.count, 7)
        XCTAssertEqual(calendar.component(.weekday, from: week.days[0].date), 2)
        XCTAssertEqual(calendar.component(.day, from: week.days[0].date), 5)
        XCTAssertTrue(week.days[6].isToday)
        XCTAssertFalse(week.days.contains { $0.isFuture })

        let wednesday = date("2026-10-07T10:00:00Z")
        let midweek = MioWeekOverview.make(containing: wednesday, today: wednesday, activity: [:], calendar: calendar)
        XCTAssertTrue(midweek.days[2].isToday)
        XCTAssertEqual(midweek.days.filter(\.isFuture).count, 4)
    }

    func testActivityCountsSessionsSavedPostsAndFinishedTasksButNotTimelineEntries() {
        let morning = date("2026-10-09T07:00:00Z")
        let evening = date("2026-10-09T19:00:00Z")
        let task = MioContentItem(kind: .task, title: "Läxa", createdAt: date("2026-10-08T15:00:00Z"), completedAt: evening)
        let note = MioContentItem(kind: .note, title: "Procent", createdAt: morning)
        let timeline = MioContentItem(kind: .timeline, title: "Session", createdAt: morning)
        let counts = MioWeekPlanner.activity(content: [task, note, timeline], sessionStarts: [morning], calendar: calendar)
        XCTAssertEqual(counts[calendar.startOfDay(for: morning)], 3)
        XCTAssertEqual(counts[calendar.startOfDay(for: date("2026-10-08T15:00:00Z"))], 1)
        XCTAssertEqual(counts.values.reduce(0, +), 4)
    }

    func testStreakGridHasTwelveWeeksEndingThisWeekAndCountsTheCurrentRun() {
        let today = date("2026-10-11T10:00:00Z")
        let starts = ["2026-10-08T08:00:00Z", "2026-10-09T08:00:00Z", "2026-10-10T08:00:00Z", "2026-09-01T08:00:00Z"].map(date)
        let activity = MioWeekPlanner.activity(content: [], sessionStarts: starts, calendar: calendar)
        let grid = MioStreakGrid.make(today: today, activity: activity, calendar: calendar)
        XCTAssertEqual(grid.weeks.count, 12)
        XCTAssertTrue(grid.weeks.allSatisfy { $0.count == 7 })
        XCTAssertEqual(grid.weekNumbers.last, 41)
        XCTAssertEqual(grid.weekNumbers.first, 30)
        XCTAssertEqual(grid.activeDays, 4)
        // Nothing yet today: the run up to yesterday still counts.
        XCTAssertEqual(grid.currentRun, 3)

        let gap = MioStreakGrid.make(today: date("2026-10-13T10:00:00Z"), activity: activity, calendar: calendar)
        XCTAssertEqual(gap.currentRun, 0)
    }

    func testNextUpPrefersTodaysNextItemThenTheOldestOverdueTask() {
        let now = date("2026-10-09T10:00:00Z")
        let started = MioContentItem(kind: .plan, title: "Matte", createdAt: now, scheduledAt: now.addingTimeInterval(-20 * 60))
        let later = MioContentItem(kind: .task, title: "Läxa", createdAt: now, scheduledAt: now.addingTimeInterval(3 * 3600))
        let old = MioContentItem(kind: .task, title: "Bok", createdAt: now, scheduledAt: date("2026-10-07T08:00:00Z"))
        let done = MioContentItem(kind: .task, title: "Klar", createdAt: now, scheduledAt: now.addingTimeInterval(600), completedAt: now)
        XCTAssertEqual(MioNextUp.make(content: [later, old, started, done], now: now, calendar: calendar), .upcoming(started))
        XCTAssertEqual(MioNextUp.make(content: [later, old], now: now.addingTimeInterval(4 * 3600), calendar: calendar), .overdue(old))
        XCTAssertEqual(MioNextUp.make(content: [done], now: now, calendar: calendar), .none)
    }

    func testDayPhaseChangesAtTenAndFive() {
        XCTAssertEqual(MioDayPhase.at(date("2026-10-09T06:30:00Z"), calendar: calendar), .morning)
        XCTAssertEqual(MioDayPhase.at(date("2026-10-09T08:00:00Z"), calendar: calendar), .school)
        XCTAssertEqual(MioDayPhase.at(date("2026-10-09T15:00:00Z"), calendar: calendar), .evening)
        XCTAssertEqual(MioDayPhase.at(date("2026-10-09T01:00:00Z"), calendar: calendar), .evening)
    }

    func testQuestionsUseTheLatestLessonAndNextItemAndStayShort() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        let now = ISO8601DateFormatter().date(from: "2026-10-09T10:00:00Z")!
        let task = MioContentItem(kind: .task, title: "Läxa i matte\nsidan 40", createdAt: now, scheduledAt: now.addingTimeInterval(3600))
        let questions = MioSuggestedQuestions.make(content: [task], lessonTitles: ["  ", "Procent"], now: now, calendar: calendar)
        XCTAssertEqual(questions, [
            "Förklara det viktigaste från Procent enkelt.",
            "Hjälp mig dela upp Läxa i matte i små steg.",
            "Hjälp mig planera kvällen i små steg.",
        ])
        let long = String(repeating: "a", count: 80)
        let trimmed = MioSuggestedQuestions.make(content: [], lessonTitles: [long], now: now, calendar: calendar)
        XCTAssertEqual(trimmed.first, "Förklara det viktigaste från \(String(repeating: "a", count: 60))… enkelt.")
        XCTAssertEqual(MioSuggestedQuestions.make(content: [], lessonTitles: [], now: now, calendar: calendar).count, 1)
    }
}
