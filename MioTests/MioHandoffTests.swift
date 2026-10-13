import XCTest
@testable import Mio

/// Version 0.9.1: approved proposals are handed to Apple's apps and Mio keeps only a record.
final class MioHandoffTests: XCTestCase {
    func testSessionLinkRoundTripsAndRejectsEverythingElse() throws {
        let session = UUID(), proposal = UUID()
        let url = try XCTUnwrap(MioLink.session(session, proposal: proposal))
        XCTAssertEqual(url.absoluteString, "mio://session/\(session.uuidString)?forslag=\(proposal.uuidString)")
        XCTAssertEqual(MioLink.sessionID(from: url), session)
        XCTAssertEqual(MioLink.sessionID(from: URL(string: "mio://session/\(session.uuidString)")!), session)
        for text in ["https://session/\(session.uuidString)", "mio://lektion/\(session.uuidString)",
                     "mio://session/\(session.uuidString)/extra", "mio://session/inte-ett-id",
                     "mio://session/\(session.uuidString)?forslag=x", "mio://session/\(session.uuidString)?mic=start",
                     "mio://session/\(session.uuidString)#a", "mio://user@session/\(session.uuidString)"] {
            XCTAssertNil(MioLink.sessionID(from: URL(string: text)!), text)
        }
    }

    @MainActor
    func testLinkOpensOnlyAnExistingSessionAndNeverAnythingElse() {
        let navigation = MioNavigationCoordinator()
        let session = UUID()
        navigation.selectedTab = .capture
        navigation.receive(link: MioLink.session(session, proposal: UUID())!)
        XCTAssertNil(navigation.presentedSession, "held until the stores have loaded")
        navigation.resolvePendingLink { $0 == session }
        XCTAssertEqual(navigation.presentedSession?.id, session)
        XCTAssertEqual(navigation.selectedTab, .capture, "a link only presents the session")

        navigation.receive(link: MioLink.session(UUID(), proposal: UUID())!)
        navigation.resolvePendingLink { $0 == session }
        XCTAssertNil(navigation.presentedSession, "a deleted session falls back to Hem")
        XCTAssertEqual(navigation.selectedTab, .home)

        navigation.selectedTab = .lessons
        navigation.receive(link: URL(string: "mio://mikrofon/start")!)
        XCTAssertNil(navigation.pendingLinkSessionID)
        XCTAssertEqual(navigation.selectedTab, .home)
    }

    @MainActor
    private final class FakeReminders {
        var access: MioReminderAccess = .granted
        var requested = 0
        var saved: [MioReminderDraft] = []
        var port: MioReminderPort {
            MioReminderPort(access: { self.access }, requestAccess: { self.requested += 1; return self.access == .granted },
                lists: { [MioReminderList(id: "skola", title: "Skola")] }, defaultListID: { "skola" },
                save: { draft in self.saved.append(draft); return "reminder-\(self.saved.count)" }, upcoming: { _ in [] })
        }
    }

    @MainActor
    private func fixture(_ reminders: FakeReminders) throws -> (root: URL, workflow: MioWorkflowCoordinator, assistant: MioAssistantRepository, content: MioContentViewModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let assistantRepository = MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json"))
        let content = MioContentViewModel(repository: MioContentRepository(storageURL: root.appendingPathComponent("content.json"), exportDirectoryURL: root))
        let workflow = MioWorkflowCoordinator(capture: MioViewModel(repository: SessionRepository(storageURL: root.appendingPathComponent("sessions.json"))),
            content: content, assistant: MioAssistantViewModel(repository: assistantRepository), analysis: MioAnalysisCoordinator(),
            reminders: reminders.port)
        return (root, workflow, assistantRepository, content)
    }

    @MainActor
    func testApprovedTaskBecomesAReminderAndMioKeepsOnlyARecord() async throws {
        let reminders = FakeReminders()
        let f = try fixture(reminders)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let suggestion = MioSuggestion(kind: .task, title: "Lämna in labbrapporten", body: "Jag ska lämna in labbrapporten på fredag.",
                                       scheduledAt: Date(timeIntervalSince1970: 1_792_000_000), isAllDay: true)
        try await f.assistant.addSuggestion(suggestion)
        let due = Date(timeIntervalSince1970: 1_792_040_000)
        let outcome = await f.workflow.sendToReminders(id: suggestion.id, expectedRevision: 0, title: " Lämna in labbrapporten ",
            notes: "Jag ska lämna in labbrapporten på fredag.", dueDate: due, hasTime: false, listID: "skola")
        XCTAssertEqual(outcome, .success)
        let draft = try XCTUnwrap(reminders.saved.first)
        XCTAssertEqual(draft.title, "Lämna in labbrapporten")
        XCTAssertEqual(draft.notes, "Jag ska lämna in labbrapporten på fredag.")
        XCTAssertEqual(draft.dueDate, Calendar.current.startOfDay(for: due), "a day without time is due at the start of that day")
        XCTAssertFalse(draft.hasTime)
        XCTAssertEqual(draft.listID, "skola")
        XCTAssertEqual(draft.url, MioLink.proposal(suggestion.id))

        let items = try await f.content.latestItems()
        let record = try XCTUnwrap(items.first)
        XCTAssertEqual(record.id, suggestion.id)
        XCTAssertEqual(record.handoff?.destination, .reminders)
        XCTAssertEqual(record.handoff?.externalIdentifier, "reminder-1")
        XCTAssertEqual(record.body, "", "Reminders owns the text; Mio keeps no copy")
        let document = try await f.assistant.loadDocument()
        XCTAssertTrue(document.suggestions.isEmpty, "the proposal is closed")

        let again = await f.workflow.sendToReminders(id: suggestion.id, expectedRevision: 0, title: "Lämna in labbrapporten",
            notes: "", dueDate: nil, hasTime: false, listID: nil)
        XCTAssertEqual(again, .success)
        XCTAssertEqual(reminders.saved.count, 1, "a repeated Ja never creates a second reminder")
    }

    @MainActor
    func testDeniedRemindersAccessLeavesTheProposalUntouched() async throws {
        let reminders = FakeReminders()
        reminders.access = .denied
        let f = try fixture(reminders)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let suggestion = MioSuggestion(kind: .task, title: "Köpa gympaskor")
        try await f.assistant.addSuggestion(suggestion)
        let outcome = await f.workflow.sendToReminders(id: suggestion.id, expectedRevision: 0, title: "Köpa gympaskor",
            notes: "", dueDate: nil, hasTime: false, listID: nil)
        XCTAssertEqual(outcome, .failure(MioReminderPort.deniedMessage))
        XCTAssertTrue(reminders.saved.isEmpty)
        let items = try await f.content.latestItems()
        XCTAssertTrue(items.isEmpty)
        let document = try await f.assistant.loadDocument()
        XCTAssertEqual(document.suggestions.map(\.id), [suggestion.id], "no silent fallback; the proposal stays")

        reminders.access = .granted
        let retry = await f.workflow.sendToReminders(id: suggestion.id, expectedRevision: 0, title: "Köpa gympaskor",
            notes: "", dueDate: nil, hasTime: false, listID: nil)
        XCTAssertEqual(retry, .success, "the released approval can be retried after access is granted")
        XCTAssertNil(reminders.saved.first?.dueDate)
    }

    @MainActor
    func testCalendarAndShareSheetHandoffsAreRecordedWithoutText() async throws {
        let f = try fixture(FakeReminders())
        defer { try? FileManager.default.removeItem(at: f.root) }
        let event = MioSuggestion(kind: .plan, title: "Religionsprov", body: "Jag har religionsprov på torsdag.", revision: 3)
        let memory = MioSuggestion(kind: .memory, title: "Föredrar blå pennor")
        try await f.assistant.addSuggestion(event)
        try await f.assistant.addSuggestion(memory)
        let first = await f.workflow.recordHandoff(id: event.id, kind: .plan, title: "Religionsprov", destination: .calendar)
        XCTAssertEqual(first, .success, "Apple's editor already saved it; a newer AI revision does not block the record")
        let second = await f.workflow.recordHandoff(id: memory.id, kind: .memory, title: "Föredrar blå pennor", destination: .notes)
        XCTAssertEqual(second, .success)
        let items = try await f.content.latestItems()
        XCTAssertEqual(Set(items.compactMap(\.handoff?.destination)), [.calendar, .notes])
        XCTAssertTrue(items.allSatisfy { $0.body.isEmpty && $0.isAllDay == nil })
        let document = try await f.assistant.loadDocument()
        XCTAssertTrue(document.suggestions.isEmpty)
    }

    func testHandoffRecordSurvivesEncodingAndOlderItemsDecodeWithoutIt() throws {
        let item = MioContentItem(kind: .plan, title: "Prov", handoff: MioHandoff(destination: .calendar, externalIdentifier: nil,
                                                                                   sentAt: Date(timeIntervalSince1970: 1_792_000_000)))
        let decoded = try JSONDecoder().decode(MioContentItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded, item)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MioContentItem(kind: .note, title: "Gammal"))) as! [String: Any]
        legacy["handoff"] = nil
        let old = try JSONDecoder().decode(MioContentItem.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.handoff)
    }

    func testHomeReadsTheNextReminderAndTheDayFromReminders() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Stockholm"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 14, minute: 30)))
        func at(_ day: Int, _ hour: Int?) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour ?? 0))!
        }
        let lateYesterday = MioReminderSummary(id: "a", title: "Lämna boken", dueDate: at(12, nil), hasTime: false)
        let passed = MioReminderSummary(id: "b", title: "Ring", dueDate: at(13, 9), hasTime: true)
        let allDay = MioReminderSummary(id: "c", title: "Gympakläder", dueDate: at(13, nil), hasTime: false)
        let later = MioReminderSummary(id: "d", title: "Plugga", dueDate: at(13, 18), hasTime: true)
        let thursday = MioReminderSummary(id: "e", title: "Religionsprov", dueDate: at(15, nil), hasTime: false)
        let undated = MioReminderSummary(id: "f", title: "Köpa gympaskor", dueDate: nil, hasTime: false)
        let all = [later, thursday, undated, passed, allDay, lateYesterday]
        XCTAssertEqual(MioReminderNext.make(reminders: all, now: now, calendar: calendar), .upcoming(allDay),
                       "an all-day reminder counts for the whole day; a timed one long past does not")
        XCTAssertEqual(MioReminderNext.make(reminders: [later, thursday], now: now, calendar: calendar), .upcoming(later))
        XCTAssertEqual(MioReminderNext.make(reminders: [lateYesterday, thursday], now: now, calendar: calendar), .overdue(lateYesterday))
        XCTAssertEqual(MioReminderNext.make(reminders: [thursday, undated], now: now, calendar: calendar), .none)

        let today = MioReminderDay.make(reminders: all, date: now, today: now, calendar: calendar)
        XCTAssertEqual(today.due.map(\.id), ["c", "b", "d"])
        XCTAssertEqual(today.overdue.map(\.id), ["a"])
        let other = MioReminderDay.make(reminders: all, date: at(15, 12), today: now, calendar: calendar)
        XCTAssertEqual(other.due.map(\.id), ["e"])
        XCTAssertTrue(other.overdue.isEmpty, "only today lists what was left from earlier days")
    }

    @MainActor
    func testUpgradeRemovesOldLocalItemsAndAlarmsOnceButKeepsHandoffs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "MioHandoffTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = MioContentRepository(storageURL: root.appendingPathComponent("content.json"), exportDirectoryURL: root)
        let sent = MioContentItem(kind: .plan, title: "Skickad", handoff: MioHandoff(destination: .calendar, externalIdentifier: nil, sentAt: .now))
        _ = try await repository.upsert(MioContentItem(kind: .plan, title: "Religionsprov"))
        _ = try await repository.upsert(MioContentItem(kind: .memory, title: "Föredrar blå pennor"))
        _ = try await repository.upsert(sent)
        var legacyRemovals = 0
        var cancelled: [UUID] = []
        func workflow() -> MioWorkflowCoordinator {
            MioWorkflowCoordinator(capture: MioViewModel(repository: SessionRepository(storageURL: root.appendingPathComponent("sessions.json"))),
                content: MioContentViewModel(repository: repository),
                assistant: MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json"))),
                analysis: MioAnalysisCoordinator(),
                systemActions: MioSystemActionPort(cancel: { cancelled.append($0); return .success }, removeAll: { .success },
                                                   removeLegacy: { legacyRemovals += 1; return .success }),
                removesLegacyItems: true, pendingLessonDefaults: defaults)
        }
        await workflow().bootstrap()
        let items = try await repository.loadItems()
        XCTAssertEqual(items.map(\.id), [sent.id], "only the handoff record survives the upgrade")
        XCTAssertEqual(legacyRemovals, 1)
        XCTAssertTrue(cancelled.isEmpty, "alarms go in one sweep, not per item")
        XCTAssertTrue(defaults.bool(forKey: MioWorkflowCoordinator.legacyCleanupKey))

        _ = try await repository.upsert(MioContentItem(kind: .note, title: "Efter uppgraderingen"))
        await workflow().bootstrap()
        let later = try await repository.loadItems()
        XCTAssertEqual(later.count, 2, "the cleanup runs once")
        XCTAssertEqual(legacyRemovals, 1)
    }
}
