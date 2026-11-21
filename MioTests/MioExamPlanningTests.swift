import Foundation
import XCTest
@testable import Mio

/// Fas 5: exams from approved plans, the countdown on Hem, "Inför provet" and the morning and
/// evening texts. Everything here is local and uses no AI.
final class MioExamPlanningTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        calendar.locale = Locale(identifier: "sv-SE")
        return calendar
    }

    private func date(_ day: Int, _ hour: Int = 12, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func lesson(_ subject: String?, day: Int, title: String = "Lektion") -> MioSession {
        var session = MioSession(startedAt: date(day, 9), endedAt: date(day, 10), title: title, captureMode: .lesson)
        session.subject = subject
        return session
    }

    private func examItem(_ title: String, day: Int, subject: String?, allDay: Bool = true) -> MioContentItem {
        MioContentItem(kind: .plan, title: title, scheduledAt: date(1),
                       handoff: MioHandoff(destination: .calendar, externalIdentifier: nil, sentAt: date(1)),
                       exam: MioExamRecord(date: allDay ? calendar.startOfDay(for: date(day)) : date(day, 10),
                                           isAllDay: allDay, subject: subject))
    }

    func testExamWordsAreRecognizedAndOrdinaryWordsAreNot() {
        for title in ["Biologiprov på fredag", "Prov i matte", "Glosprovet", "Läxförhör i engelska", "Tenta", "NP i svenska",
                      "provet i kemi"] {
            XCTAssertTrue(MioExamDetector.looksLikeExam(title), title)
        }
        for title in ["Prova klänningen", "Vi har provat", "Ta två prover", "Möte med mentor", "Approve"] {
            XCTAssertFalse(MioExamDetector.looksLikeExam(title), title)
        }
    }

    func testSamplesAndOtherNonSchoolTestsAreNotExams() {
        for title in ["Blodprov på vårdcentralen", "Stickprov i lagret", "Lämna urinprov", "Smakprov på ost",
                      "Provprov", "Alkoholprov", "Drogprov på jobbet", "Covidprov", "Covid-prov i morgon",
                      "Salivprovet", "Cellprov hos barnmorskan", "Arbetsprov till ansökan", "Blodproven är klara"] {
            XCTAssertFalse(MioExamDetector.looksLikeExam(title), title)
        }
        for title in ["Biologi-prov", "Prov - kemi", "Glosproven", "Matteprov och blodprov"] {
            XCTAssertTrue(MioExamDetector.looksLikeExam(title), title)
        }
    }

    func testAnExamRecordNeedsADateAndAnExamTitleAndMatchesAKnownSubject() {
        XCTAssertNil(MioExamRecord.make(kind: .plan, title: "Biologiprov", date: nil, isAllDay: true, subject: nil))
        XCTAssertNil(MioExamRecord.make(kind: .plan, title: "Fika", date: date(5), isAllDay: true, subject: nil))
        XCTAssertNil(MioExamRecord.make(kind: .note, title: "Biologiprov", date: date(5), isAllDay: true, subject: nil))
        let matched = MioExamRecord.make(kind: .plan, title: "Biologiprov", date: date(5), isAllDay: true, subject: nil,
                                         knownSubjects: ["Kemi", "biologi"], calendar: calendar)
        XCTAssertEqual(matched?.subject, "biologi")
        XCTAssertEqual(matched?.date, calendar.startOfDay(for: date(5)))
        let chosen = MioExamRecord.make(kind: .task, title: "Prov på fredag", date: date(5, 8), isAllDay: false,
                                        subject: "  Kemi \n", knownSubjects: ["Biologi"], calendar: calendar)
        XCTAssertEqual(chosen?.subject, "Kemi")
        XCTAssertEqual(chosen?.date, date(5, 8))
    }

    func testKnownSubjectsComeFromConfirmedLessonsNewestFirstWithoutDuplicates() {
        var everyday = MioSession(startedAt: date(9), endedAt: date(9, 13))
        everyday.subject = "Vardag"
        let subjects = MioExamSubjects.known(in: [lesson("Biologi", day: 2), lesson("Kemi", day: 4), lesson("biologi", day: 6),
                                                  lesson(nil, day: 7), everyday])
        XCTAssertEqual(subjects, ["biologi", "Kemi"])
        XCTAssertEqual(MioExamSubjects.match(title: "Prov i moderna språk", known: ["Språk", "Moderna språk"]), "Moderna språk")
    }

    func testCountdownShowsExamsFromAWeekBeforeWithSwedishWording() {
        let now = date(20, 8)
        let plans = MioExamPlan.all(in: [examItem("Biologiprov", day: 23, subject: "Biologi"),
                                         examItem("Prov", day: 20, subject: nil),
                                         examItem("Glosor", day: 21, subject: "Engelska"),
                                         examItem("Prov", day: 27, subject: "Svenska 2"),
                                         examItem("Prov", day: 28, subject: "Kemi"),
                                         examItem("Prov", day: 19, subject: "Fysik")], calendar: calendar)
        let countdown = MioExamCountdown.upcoming(plans, now: now, calendar: calendar)
        XCTAssertEqual(countdown.map(\.text), ["Prov i dag", "Engelskaprov i morgon", "Biologiprov om 3 dagar",
                                               "Prov i Svenska 2 om 7 dagar"])
        XCTAssertEqual(MioExamPlan.name(subject: "SO"), "Prov i SO")
    }

    func testAnExamWithATimeDisappearsWhenItHasPassedButAnAllDayExamStaysAllDay() {
        let plans = MioExamPlan.all(in: [examItem("Prov", day: 20, subject: "Kemi", allDay: false),
                                         examItem("Prov", day: 20, subject: "Fysik")], calendar: calendar)
        XCTAssertEqual(MioExamCountdown.upcoming(plans, now: date(20, 11), calendar: calendar).map(\.plan.exam.subject), ["Fysik"])
    }

    func testOlderPlansKeptInMioAreExamsByTheirTitleButHandedOverPlansNeedARecord() {
        let legacy = MioContentItem(kind: .plan, title: "Kemiprov", scheduledAt: date(22), isAllDay: true)
        let sent = MioContentItem(kind: .plan, title: "Kemiprov", scheduledAt: date(1),
                                  handoff: MioHandoff(destination: .calendar, externalIdentifier: nil, sentAt: date(1)))
        let plans = MioExamPlan.all(in: [legacy, sent], calendar: calendar)
        XCTAssertEqual(plans.map(\.id), [legacy.id])
        XCTAssertEqual(plans.first?.exam.date, calendar.startOfDay(for: date(22)))
    }

    func testPrepCollectsLessonsInTheSubjectSinceThePreviousExam() {
        let sessions = [lesson("Biologi", day: 2, title: "Celler"), lesson("Biologi", day: 9, title: "Mitos"),
                        lesson("Kemi", day: 10, title: "Syror"), lesson("biologi", day: 12, title: "Meios"),
                        lesson("Biologi", day: 25, title: "Efter provet")]
        let previous = examItem("Biologiprov", day: 5, subject: "Biologi")
        let current = examItem("Biologiprov", day: 20, subject: "Biologi")
        let exams = MioExamPlan.all(in: [previous, current], calendar: calendar)
        let exam = exams.first { $0.id == current.id }
        let prep = MioExamPrep.make(subject: "Biologi", exam: exam, sessions: sessions, exams: exams, now: date(15), calendar: calendar)
        XCTAssertEqual(prep.lessons.map(\.title), ["Mitos", "Meios"])
        XCTAssertEqual(prep.previousExam?.id, previous.id)
        let text = prep.text(records: [], exam: exam, calendar: calendar)
        XCTAssertTrue(text.hasPrefix("# Inför provet: Biologi"))
        XCTAssertTrue(text.contains("2 lektioner sedan förra provet"))
        XCTAssertTrue(text.contains("Ofullständigt: 2 lektioner saknar färdiga anteckningar."))
        XCTAssertTrue(text.contains("# Mitos") && text.contains("# Meios"))
        XCTAssertFalse(text.contains("Syror") || text.contains("Celler") || text.contains("Efter provet"))
        XCTAssertFalse(text.contains(sessions[1].id.uuidString), "No internal source IDs in the copy")
    }

    func testPrepWithoutAPreviousExamTakesEveryLessonInTheSubject() {
        let sessions = [lesson("Kemi", day: 2), lesson("Kemi", day: 9)]
        let prep = MioExamPrep.make(subject: "kemi", exam: nil, sessions: sessions, exams: [], now: date(15), calendar: calendar)
        XCTAssertEqual(prep.lessons.count, 2)
        XCTAssertNil(prep.previousExam)
        XCTAssertTrue(prep.text(records: [], exam: nil, calendar: calendar).contains("Inget tidigare prov i ämnet är sparat"))
        let empty = MioExamPrep.make(subject: "Fysik", exam: nil, sessions: sessions, exams: [], now: date(15), calendar: calendar)
        XCTAssertTrue(empty.text(records: [], exam: nil, calendar: calendar).contains("Inga lektioner med ämnet Fysik"))
    }

    func testMorningTextNamesOnlySubjectsAndTheWordsProvAndLaxa() {
        let biology = lesson("Biologi", day: 19)
        let item = MioContentItem(kind: .task, title: "Läs kapitel 3 – hemligt", sessionID: biology.id,
                                  handoff: MioHandoff(destination: .reminders, externalIdentifier: "r1", sentAt: date(19)))
        let reminders = [MioReminderSummary(id: "r1", title: "Läs kapitel 3 – hemligt", dueDate: date(20, 8), hasTime: false),
                         MioReminderSummary(id: "r2", title: "Läxa: glosor", dueDate: date(20, 8), hasTime: false),
                         MioReminderSummary(id: "r3", title: "Köp mjölk", dueDate: date(20, 8), hasTime: false),
                         MioReminderSummary(id: "r4", title: "Läxa i morgon", dueDate: date(21, 8), hasTime: false)]
        let homework = MioDailyDigest.homework(on: date(20), reminders: reminders, items: [item], sessions: [biology], calendar: calendar)
        XCTAssertEqual(homework, ["Biologi", nil])
        let exams = MioDailyDigest.exams(on: date(20), in: MioExamPlan.all(in: [examItem("Kemiprov", day: 20, subject: "Kemi")],
                                                                          calendar: calendar), calendar: calendar)
        let body = MioDailyDigest.morningBody(exams: exams, homework: homework)
        XCTAssertEqual(body, "I dag: Kemiprov, läxa i Biologi, 1 annan läxa.")
        XCTAssertFalse(body.contains("kapitel") || body.contains("glosor"))
        XCTAssertEqual(MioDailyDigest.morningBody(exams: [], homework: []), "Inga prov eller läxor i dag.")
        XCTAssertEqual(MioDailyDigest.morningBody(exams: [], homework: [nil, nil]), "I dag: 2 läxor.")
    }

    func testEveningTextCountsTodayAndStaysGenericForLaterDays() {
        XCTAssertEqual(MioDailyDigest.eveningBody(pendingCount: 3, isToday: true), "3 förslag att granska i Mio.")
        XCTAssertEqual(MioDailyDigest.eveningBody(pendingCount: 1, isToday: true), "1 förslag att granska i Mio.")
        XCTAssertEqual(MioDailyDigest.eveningBody(pendingCount: 0, isToday: true), "Inga förslag att granska i dag.")
        XCTAssertEqual(MioDailyDigest.eveningBody(pendingCount: 9, isToday: false), "Granska dagens förslag i Mio.")
    }

    func testDailyPlanSkipsAPassedTimeAndNamesEachDay() {
        let plan = MioDailyDigest.plan(base: "mio.daily.evening", minutes: 20 * 60, now: date(20, 21), calendar: calendar,
                                       days: 3) { _, isToday in isToday ? "i dag" : "senare" }
        XCTAssertEqual(plan.map(\.id), ["mio.daily.evening.20261121", "mio.daily.evening.20261122"])
        XCTAssertEqual(plan.map(\.body), ["senare", "senare"])
        XCTAssertEqual(plan.first?.components.hour, 20)
        let morning = MioDailyDigest.plan(base: "mio.daily.morning", minutes: 7 * 60, now: date(20, 6), calendar: calendar,
                                          days: 1) { _, isToday in isToday ? "i dag" : "senare" }
        XCTAssertEqual(morning.map(\.body), ["i dag"])
        XCTAssertTrue(MioDailyDigest.belongs("mio.daily.morning", to: "mio.daily.morning"))
        XCTAssertTrue(MioDailyDigest.belongs("mio.daily.morning.20261121", to: "mio.daily.morning"))
        XCTAssertFalse(MioDailyDigest.belongs("mio.daily.morning.minutes", to: "mio.daily.morning"))
        XCTAssertFalse(MioDailyDigest.belongs("mio.daily.evening.20261121", to: "mio.daily.morning"))
    }

    func testAnOlderItemWithoutTheExamFieldStillDecodes() throws {
        let item = MioContentItem(kind: .plan, title: "Händelse")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        XCTAssertNil(object["exam"])
        object["exam"] = nil
        let decoded = try JSONDecoder().decode(MioContentItem.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.exam)
        let withExam = examItem("Prov", day: 20, subject: "Kemi")
        XCTAssertEqual(try JSONDecoder().decode(MioContentItem.self, from: JSONEncoder().encode(withExam)).exam?.subject, "Kemi")
    }
}
