import Foundation
import XCTest
@testable import Mio

final class MioAnswerNoteTests: XCTestCase {
    @MainActor
    func testAnswerStaysTemporaryUntilExplicitSaveAndRetryPreservesLaterEdits() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let response = await fixture.workflow.questions.sendApproved(.init(question: "Syntetisk fråga", context: []), connection: connection())
        XCTAssertEqual(response.answer, "Syntetiskt svar")
        let empty = try await fixture.workflow.content.latestItems()
        XCTAssertTrue(empty.isEmpty)
        let draft = try XCTUnwrap(fixture.workflow.questions.answerDraft)
        let saved = await fixture.workflow.saveAnswerNote(draft, title: "Granskad rubrik", body: "Redigerat svar")
        XCTAssertEqual(saved, .success)
        let first = try await fixture.workflow.content.latestItems()
        XCTAssertEqual(first.count, 1); XCTAssertEqual(first.first?.id, draft.id)
        XCTAssertEqual(first.first?.kind, .note); XCTAssertEqual(first.first?.body, "Redigerat svar")
        _ = await fixture.workflow.content.saveOutcome(id: draft.id, kind: .note, title: "Senare ändring", body: "Behåll", scheduledAt: .now, isCompleted: false, sessionID: nil)
        let repeated = await fixture.workflow.saveAnswerNote(draft, title: "Äldre rubrik", body: "Äldre svar")
        XCTAssertEqual(repeated, .success)
        let final = try await fixture.workflow.content.latestItems()
        XCTAssertEqual(final.count, 1); XCTAssertEqual(final.first?.title, "Senare ändring"); XCTAssertEqual(final.first?.body, "Behåll")
    }

    @MainActor
    func testConfigurationAndDeletionInvalidateUnsavedAnswerDraft() async throws {
        for delete in [false, true] {
            let fixture = makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            _ = await fixture.workflow.questions.sendApproved(.init(question: "Fråga", context: []), connection: connection())
            let draft = try XCTUnwrap(fixture.workflow.questions.answerDraft)
            if delete { let deleted = await fixture.workflow.deleteAll(); XCTAssertEqual(deleted, .success) }
            else { fixture.workflow.cloudConfigurationChanged() }
            XCTAssertNil(fixture.workflow.questions.answerDraft)
            let result = await fixture.workflow.saveAnswerNote(draft, title: "Får inte återskapas", body: draft.body)
            XCTAssertEqual(result, .cancelled)
            let items = try await fixture.workflow.content.latestItems()
            XCTAssertTrue(items.isEmpty)
        }
    }

    @MainActor
    func testFailedOrEmptyNoteSaveKeepsDraftForManualRetry() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = await fixture.workflow.questions.sendApproved(.init(question: "Fråga", context: []), connection: connection())
        let draft = try XCTUnwrap(fixture.workflow.questions.answerDraft)
        let empty = await fixture.workflow.saveAnswerNote(draft, title: "  ", body: draft.body)
        guard case .failure = empty else { return XCTFail("Empty review must fail") }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let url = fixture.root.appendingPathComponent("content.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let failed = await fixture.workflow.saveAnswerNote(draft, title: draft.title, body: draft.body)
        guard case .failure = failed else { return XCTFail("Storage failure must be visible") }
        XCTAssertEqual(fixture.workflow.questions.answerDraft?.id, draft.id)
        try FileManager.default.removeItem(at: url)
        let retried = await fixture.workflow.saveAnswerNote(draft, title: draft.title, body: draft.body)
        XCTAssertEqual(retried, .success)
        let repeated = await fixture.workflow.saveAnswerNote(draft, title: draft.title, body: draft.body)
        XCTAssertEqual(repeated, .success, "an identical retry stays idempotent")
        let edited = await fixture.workflow.saveAnswerNote(draft, title: draft.title, body: "Ändrad text")
        guard case .conflict = edited else { return XCTFail("changed text must not be silently ignored") }
    }

    @MainActor
    private func makeFixture() -> (root: URL, workflow: MioWorkflowCoordinator) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let questions = MioQuestionWorkflow(configurationMatches: { _ in true }, send: { _, _ in "Syntetiskt svar" })
        let workflow = MioWorkflowCoordinator(capture: MioViewModel(repository: SessionRepository(storageURL: root.appendingPathComponent("sessions.json"))),
            content: MioContentViewModel(repository: MioContentRepository(storageURL: root.appendingPathComponent("content.json"))),
            assistant: MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json"))),
            analysis: MioAnalysisCoordinator(), journal: MioDeletionJournal(storageURL: root.appendingPathComponent("operations.json")),
            diagnostics: MioDiagnosticsRepository(storageURL: root.appendingPathComponent("diagnostics.json")),
            systemActions: MioSystemActionPort(cancel: { _ in .success }, removeAll: { .success }),
            questions: questions, clearCredentials: {})
        return (root, workflow)
    }
    private func connection() -> MioCloudConnection { .init(endpoint: URL(string: "https://example.invalid/v1/ask")!, token: "fixture") }
}
