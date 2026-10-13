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
}
