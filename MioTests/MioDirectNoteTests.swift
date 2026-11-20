import Foundation
import XCTest
@testable import Mio

/// "Mio, kom ihåg" and "Mio, notera" (grilling 2026-11-19, rule change approved 2026-11-20):
/// the local grammar, saving straight away with Ångra for 24 hours, the vibration outcome and
/// the text-free count of Nej and Ångra.
final class MioDirectNoteTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        return calendar
    }()

    /// Wednesday 18 November 2026, 10.00 in Stockholm.
    private var wednesday: Date { date(day: 18, hour: 10) }

    private func date(day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func command(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> MioDirectCommand? {
        let parses = MioDirectCommandGrammar.parse(text, now: wednesday, calendar: calendar)
        guard parses.count == 1, case .command(let command) = parses[0] else {
            XCTFail("Expected one command in: \(text)", file: file, line: line)
            return nil
        }
        return command
    }

    // MARK: Grammar

    func testKomIhagGoesToRemindersAndNoteraBecomesAMioNote() throws {
        let reminder = try XCTUnwrap(command("Mio, kom ihåg att köpa mjölk."))
        XCTAssertEqual(reminder.phrase, .remember)
        XCTAssertEqual(reminder.destination, .reminders)
        XCTAssertEqual(reminder.text, "Köpa mjölk")
        XCTAssertNil(reminder.date)

        let note = try XCTUnwrap(command("Mio, notera att provet gäller kapitel tre. Det är viktigt."))
        XCTAssertEqual(note.phrase, .note)
        XCTAssertEqual(note.destination, .mioNote)
        XCTAssertEqual(note.text, "Provet gäller kapitel tre. Det är viktigt", "a note keeps every sentence")
        XCTAssertNil(note.date)

        let cut = try XCTUnwrap(command("Mio, kom ihåg att ta med boken. Sen gick vi till bussen."))
        XCTAssertEqual(cut.text, "Ta med boken", "a reminder keeps only the first sentence")
    }

    func testDaysAndClockTimesWithoutAI() throws {
        let friday = try XCTUnwrap(command("Mio, kom ihåg att lämna in uppsatsen på fredag"))
        XCTAssertEqual(friday.destination, .reminders)
        XCTAssertEqual(friday.date, date(day: 20))
        XCTAssertFalse(friday.hasTime)

        let tomorrow = try XCTUnwrap(command("Mio, kom ihåg att ringa mormor i morgon klockan 18"))
        XCTAssertEqual(tomorrow.destination, .reminders, "a time without a place stays a reminder")
        XCTAssertEqual(tomorrow.date, date(day: 19, hour: 18))
        XCTAssertTrue(tomorrow.hasTime)

        XCTAssertEqual(command("Mio, kom ihåg att plugga klockan nio")?.date, date(day: 19, hour: 9), "09.00 has passed, so tomorrow")
        XCTAssertEqual(command("Mio, kom ihåg att träna klockan tre")?.date, date(day: 18, hour: 15), "a bare 3 is the afternoon")
        XCTAssertEqual(command("Mio, kom ihåg att handla kl. 16.30")?.date, date(day: 18, hour: 16, minute: 30))
        XCTAssertEqual(command("Mio, kom ihåg simningen i övermorgon")?.date, date(day: 20))
        XCTAssertEqual(command("Mio, kom ihåg matteläxan på onsdag")?.date, date(day: 25), "today's weekday means next week")
        XCTAssertEqual(command("Mio, kom ihåg att jag har gympa i dag")?.date, date(day: 18))
    }

    func testTimeAndPlaceWaitForCalendar() throws {
        let dentist = try XCTUnwrap(command("Mio, kom ihåg tandläkaren på fredag klockan 14 hos Folktandvården"))
        XCTAssertEqual(dentist.destination, .calendar)
        XCTAssertEqual(dentist.date, date(day: 20, hour: 14))
        XCTAssertTrue(dentist.hasTime)

        XCTAssertEqual(command("Mio, notera att vi ses i biblioteket kl. 15.30")?.destination, .calendar)
        XCTAssertEqual(command("Mio, kom ihåg att vi ska på en fest klockan 20")?.destination, .calendar)
        XCTAssertEqual(command("Mio, kom ihåg biblioteket på torsdag")?.destination, .reminders, "a place without a time is a reminder")
        XCTAssertEqual(command("Mio, kom ihåg att ringa i morgon klockan 17")?.destination, .reminders, "i morgon is a day, not a place")
    }

    func testNothingUsableAfterTheWakePhraseIsNotUnderstood() {
        for text in ["Mio, kom ihåg", "Mio, kom ihåg att.", "Mio, notera det", "Mio notera:"] {
            XCTAssertEqual(MioDirectCommandGrammar.parse(text, now: wednesday, calendar: calendar), [.notUnderstood], text)
        }
        XCTAssertTrue(MioDirectCommandGrammar.parse("Mio, vad är klockan?", now: wednesday, calendar: calendar).isEmpty)
        let mixed = MioDirectCommandGrammar.parse("Mio, kom ihåg. Mio, notera att vi har prov", now: wednesday, calendar: calendar)
        XCTAssertEqual(mixed.count, 2)
        XCTAssertEqual(mixed.first, .notUnderstood)
    }

    func testDirectProposalCarriesItsOriginAndDecodesWithoutIt() throws {
        let segment = TranscriptSegment(text: "Mio, kom ihåg att lämna in uppsatsen på fredag", containsMio: true)
        let suggestion = try XCTUnwrap(MioLocalSuggestionEngine.suggestions(from: segment, sessionID: UUID(), now: wednesday,
                                                                            calendar: calendar).first)
        XCTAssertEqual(suggestion.kind, .task)
        XCTAssertEqual(suggestion.direct, MioDirectOrigin(destination: .reminders, hasDate: true, hasTime: false))
        XCTAssertEqual(suggestion.isAllDay, true)
        XCTAssertEqual(suggestion.scheduledAt, date(day: 20))
        let decoded = try JSONDecoder().decode(MioSuggestion.self, from: JSONEncoder().encode(suggestion))
        XCTAssertEqual(decoded, suggestion)

        var legacy = MioSuggestion(kind: .note, title: "Äldre förslag")
        legacy.direct = nil
        let older = try JSONDecoder().decode(MioSuggestion.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(older.direct)
        let item = try JSONDecoder().decode(MioContentItem.self, from: JSONEncoder().encode(MioContentItem(kind: .note, title: "Äldre post")))
        XCTAssertNil(item.direct)
    }

    // MARK: Ångra window and the count

    func testUndoIsOfferedForTwentyFourHours() {
        let saved = wednesday
        let record = MioDirectRecord(destination: .reminders, savedAt: saved)
        XCTAssertTrue(record.canUndo(at: saved))
        XCTAssertTrue(record.canUndo(at: saved.addingTimeInterval(24 * 60 * 60 - 1)))
        XCTAssertFalse(record.canUndo(at: saved.addingTimeInterval(24 * 60 * 60)))
    }

    func testTallyCountsWithoutText() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MioDirectNoteTests-\(UUID())"))
        XCTAssertEqual(MioDirectNoteTally.load(from: defaults), MioDirectNoteTally())
        MioDirectNoteTally.record(.saved, in: defaults)
        MioDirectNoteTally.record(.saved, in: defaults)
        MioDirectNoteTally.record(.undone, in: defaults)
        MioDirectNoteTally.record(.rejected, in: defaults)
        MioDirectNoteTally.record(.waiting, in: defaults)
        XCTAssertEqual(MioDirectNoteTally.load(from: defaults), MioDirectNoteTally(saved: 2, waiting: 1, undone: 1, rejected: 1))
        let stored = try XCTUnwrap(defaults.data(forKey: MioDirectNoteTally.key))
        XCTAssertEqual(Set(try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Int]).keys),
                       ["saved", "waiting", "undone", "rejected"], "only numbers are stored")
        MioDirectNoteTally.reset(in: defaults)
        XCTAssertEqual(MioDirectNoteTally.load(from: defaults), MioDirectNoteTally())
    }

    // MARK: Workflow

    @MainActor
    private final class FakeReminders {
        var access: MioReminderAccess = .granted
        var saved: [MioReminderDraft] = []
        var removed: [String] = []
        var port: MioReminderPort {
            MioReminderPort(access: { self.access }, requestAccess: { self.access == .granted },
                lists: { [] }, defaultListID: { nil },
                save: { draft in self.saved.append(draft); return "reminder-\(self.saved.count)" }, upcoming: { _ in [] },
                remove: { self.removed.append($0) })
        }
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let workflow: MioWorkflowCoordinator
        let capture: MioViewModel
        let assistant: MioAssistantRepository
        let content: MioContentRepository
        let defaults: UserDefaults
    }

    @MainActor
    private func makeFixture(_ reminders: FakeReminders) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioDirectNoteTests-\(UUID())")
        let assistant = MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json"))
        let content = MioContentRepository(storageURL: root.appendingPathComponent("content.json"), exportDirectoryURL: root)
        let capture = MioViewModel(repository: SessionRepository(storageURL: root.appendingPathComponent("sessions.json")))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MioDirectNoteTests-\(UUID())"))
        let workflow = MioWorkflowCoordinator(capture: capture, content: MioContentViewModel(repository: content),
            assistant: MioAssistantViewModel(repository: assistant), analysis: MioAnalysisCoordinator(),
            journal: MioDeletionJournal(storageURL: root.appendingPathComponent("operations.json")),
            systemActions: MioSystemActionPort(cancel: { _ in .success }, removeAll: { .success }),
            reminders: reminders.port, pendingLessonDefaults: defaults)
        await workflow.bootstrap()
        return Fixture(root: root, workflow: workflow, capture: capture, assistant: assistant, content: content, defaults: defaults)
    }

    /// Hands a finalized everyday segment to the workflow as capture does, and waits for the result.
    @MainActor
    private func speak(_ text: String, in f: Fixture, until done: @MainActor () async -> Bool) async throws -> MioSession {
        let session = MioSession(startedAt: .now.addingTimeInterval(-60),
                                 transcripts: [TranscriptSegment(text: text, containsMio: true)])
        f.capture.currentSession = session
        f.capture.onFinalizedTranscript?(session)
        for _ in 0..<20_000 {
            if await done() { return session }
            await Task.yield()
        }
        XCTFail("Den direkta anteckningen blev inte klar")
        return session
    }

    @MainActor
    func testKomIhagIsSavedToRemindersAtOnceAndAngraRemovesItCompletely() async throws {
        let reminders = FakeReminders()
        let f = try await makeFixture(reminders)
        defer { try? FileManager.default.removeItem(at: f.root) }
        var feedback: [MioDirectFeedback] = []
        f.capture.directFeedback = { feedback.append($0) }
        let session = try await speak("Mio, kom ihåg att köpa mjölk", in: f) { !feedback.isEmpty }

        XCTAssertEqual(feedback, [.saved], "two short vibrations")
        XCTAssertEqual(reminders.saved.map(\.title), ["Köpa mjölk"])
        XCTAssertNil(reminders.saved.first?.dueDate)
        let items = try await f.content.loadItems()
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.handoff?.destination, .reminders)
        XCTAssertEqual(item.handoff?.externalIdentifier, "reminder-1")
        XCTAssertEqual(item.direct?.destination, .reminders)
        XCTAssertEqual(item.sessionID, session.id)
        let pending = try await f.assistant.loadDocument().suggestions
        XCTAssertTrue(pending.isEmpty, "nothing waits under Förslag")
        XCTAssertEqual(MioDirectNoteTally.load(from: f.defaults).saved, 1)

        let undo = await f.workflow.undoDirect(id: item.id)
        XCTAssertEqual(undo, .success)
        XCTAssertEqual(reminders.removed, ["reminder-1"], "the reminder is removed from Reminders")
        let remaining = try await f.content.loadItems()
        XCTAssertTrue(remaining.isEmpty)
        let left = try await f.assistant.loadDocument().suggestions
        XCTAssertTrue(left.isEmpty, "and nothing is left under Förslag")
        XCTAssertEqual(MioDirectNoteTally.load(from: f.defaults).undone, 1)

        // The same segment is never saved again.
        f.capture.onFinalizedTranscript?(session)
        for _ in 0..<2_000 { await Task.yield() }
        XCTAssertEqual(reminders.saved.count, 1)
        XCTAssertEqual(feedback, [.saved])
    }

    @MainActor
    func testNoteraIsAMioNoteAndCalendarWaitsUnderForslag() async throws {
        let f = try await makeFixture(FakeReminders())
        defer { try? FileManager.default.removeItem(at: f.root) }
        var feedback: [MioDirectFeedback] = []
        f.capture.directFeedback = { feedback.append($0) }
        _ = try await speak("Mio, notera att provet gäller procent. Mio, kom ihåg tandläkaren i morgon klockan 14 hos Folktandvården",
                            in: f) { !feedback.isEmpty }
        XCTAssertEqual(feedback, [.saved])
        let saved = try await f.content.loadItems()
        let note = try XCTUnwrap(saved.first)
        XCTAssertEqual(note.kind, .note)
        XCTAssertEqual(note.title, "Provet gäller procent")
        XCTAssertNil(note.handoff, "a Mio note keeps its text in Mio")
        XCTAssertEqual(note.direct?.destination, .mioNote)

        let waiting = try await f.assistant.loadDocument().suggestions
        XCTAssertEqual(waiting.count, 1)
        XCTAssertEqual(waiting.first?.kind, .plan, "a calendar event is never saved silently")
        XCTAssertEqual(waiting.first?.direct?.destination, .calendar)
        XCTAssertEqual(waiting.first?.state, .pending)
        XCTAssertEqual(MioDirectNoteTally.load(from: f.defaults), MioDirectNoteTally(saved: 1, waiting: 1, undone: 0, rejected: 0))

        let rejected = await f.workflow.rejectSuggestion(id: try XCTUnwrap(waiting.first?.id))
        XCTAssertEqual(rejected, .success)
        XCTAssertEqual(MioDirectNoteTally.load(from: f.defaults).rejected, 1, "Nej on a direct instruction is counted")

        let undo = await f.workflow.undoDirect(id: note.id)
        XCTAssertEqual(undo, .success)
        let afterUndo = try await f.content.loadItems()
        XCTAssertTrue(afterUndo.isEmpty, "Ångra deletes the Mio note")
    }

    @MainActor
    func testWithoutRemindersAccessItWaitsUnderForslagWithOneLongVibration() async throws {
        let reminders = FakeReminders()
        reminders.access = .denied
        let f = try await makeFixture(reminders)
        defer { try? FileManager.default.removeItem(at: f.root) }
        var feedback: [MioDirectFeedback] = []
        f.capture.directFeedback = { feedback.append($0) }
        _ = try await speak("Mio, kom ihåg att köpa gympaskor", in: f) { !feedback.isEmpty }
        XCTAssertEqual(feedback, [.notUnderstood])
        XCTAssertTrue(reminders.saved.isEmpty)
        let items = try await f.content.loadItems()
        XCTAssertTrue(items.isEmpty)
        let waiting = try await f.assistant.loadDocument().suggestions
        XCTAssertEqual(waiting.map(\.title), ["Köpa gympaskor"], "nothing is lost; Ja in Förslag can send it later")
        XCTAssertEqual(MioDirectNoteTally.load(from: f.defaults).waiting, 1)
    }

    @MainActor
    func testAngraEndsAfterTwentyFourHoursButTheItemStays() async throws {
        let reminders = FakeReminders()
        let f = try await makeFixture(reminders)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let savedAt = Date.now.addingTimeInterval(-25 * 60 * 60)
        let item = MioContentItem(kind: .task, title: "Köpa mjölk", createdAt: savedAt,
            handoff: MioHandoff(destination: .reminders, externalIdentifier: "reminder-9", sentAt: savedAt),
            direct: MioDirectRecord(destination: .reminders, savedAt: savedAt))
        _ = try await f.content.upsert(item)
        let late = await f.workflow.undoDirect(id: item.id)
        guard case .conflict = late else { return XCTFail("Ångra after 24 hours must be refused") }
        XCTAssertTrue(reminders.removed.isEmpty)
        let kept = try await f.content.loadItems()
        XCTAssertEqual(kept.map(\.id), [item.id], "the item stays")
    }

    @MainActor
    func testOldUpgradeCleanupKeepsMioNotes() async throws {
        let f = try await makeFixture(FakeReminders())
        defer { try? FileManager.default.removeItem(at: f.root) }
        let note = MioContentItem(kind: .note, title: "Provet gäller procent",
                                  direct: MioDirectRecord(destination: .mioNote, savedAt: .now))
        let legacy = MioContentItem(kind: .note, title: "Gammal lokal anteckning")
        _ = try await f.content.upsert(note)
        _ = try await f.content.upsert(legacy)
        await f.workflow.removeLegacyItemsOnce()
        let kept = try await f.content.loadItems()
        XCTAssertEqual(kept.map(\.id), [note.id])
    }

    @MainActor
    func testLessonsTakeNoDirectInstructionsAndNeverVibrate() async throws {
        let f = try await makeFixture(FakeReminders())
        defer { try? FileManager.default.removeItem(at: f.root) }
        var feedback: [MioDirectFeedback] = []
        f.capture.directFeedback = { feedback.append($0) }
        let lesson = MioSession(startedAt: .now.addingTimeInterval(-60),
                                transcripts: [TranscriptSegment(text: "Mio, kom ihåg att plugga", containsMio: true)],
                                captureMode: .lesson)
        f.capture.currentSession = lesson
        f.capture.onFinalizedTranscript?(lesson)
        for _ in 0..<2_000 { await Task.yield() }
        XCTAssertTrue(feedback.isEmpty)
        let suggestions = try await f.assistant.loadDocument().suggestions
        XCTAssertTrue(suggestions.isEmpty)
    }
}
