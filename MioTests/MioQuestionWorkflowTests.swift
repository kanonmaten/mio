import Foundation
import XCTest
@testable import Mio

final class MioQuestionWorkflowTests: XCTestCase {
    @MainActor
    func testQuestionDropsAnErrorAfterCredentialsChangeWithoutNotification() async throws {
        var isCurrent = true
        var requests = 0
        let questions = MioQuestionWorkflow(configurationMatches: { _ in isCurrent }, send: { _, _ in
            requests += 1; isCurrent = false; throw MioCloudError.network
        })
        let before = questions.generation
        let result = await questions.sendApproved(request(), connection: connection())
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertNotEqual(questions.generation, before)
        XCTAssertNil(result.answer); XCTAssertNil(questions.answerDraft)
        XCTAssertEqual(requests, 1)
    }

    @MainActor
    func testQuestionDropsAReplyAfterCredentialsChangeWithoutNotification() async throws {
        var isCurrent = true
        var requests = 0
        let questions = MioQuestionWorkflow(configurationMatches: { _ in isCurrent }, send: { _, _ in
            requests += 1; isCurrent = false; return "Gammalt svar"
        })
        let result = await questions.sendApproved(request(), connection: connection())
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertNil(result.answer); XCTAssertNil(questions.answerDraft)
        XCTAssertEqual(requests, 1)
    }


    @MainActor
    func testDefaultQuestionCannotSendWhenThePCIsNotPaired() async throws {
        let previous = UserDefaults.standard.object(forKey: MioCloudSettings.serverKey)
        UserDefaults.standard.removeObject(forKey: MioCloudSettings.serverKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: MioCloudSettings.serverKey) }
        }
        var requests = 0
        let questions = MioQuestionWorkflow( send: { _, _ in requests += 1; return "Får inte visas" })
        let result = await questions.sendApproved(request(), connection: connection())
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertEqual(requests, 0)
        XCTAssertNil(questions.answerDraft)
    }


    @MainActor
    func testBlockedContentDeletionInvalidatesReviewedQuestionAndLateAnswer() async throws {
        try await assertTargetedDeletionInvalidatesQuestion(scope: .content)
    }

    @MainActor
    func testBlockedSessionDeletionInvalidatesReviewedQuestionAndLateAnswer() async throws {
        try await assertTargetedDeletionInvalidatesQuestion(scope: .session)
    }

    @MainActor
    func testBlockedFullDeletionInvalidatesQuestionBeforeCredentialCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); MioMaintenanceState.shared.setRecoveryBlocked(false) }
        let transport = QuestionHeldTransport()
        let questions = MioQuestionWorkflow(configurationMatches: { _ in true }, send: { try await transport.send($0, connection: $1) })
        var captureStarts = 0
        var credentialsCleared = false
        let capture = MioViewModel(repository: SessionRepository(storageURL: root.appendingPathComponent("sessions.json")),
            captureFactory: { _, _ in captureStarts += 1; throw MioError.microphoneDenied })
        let workflow = MioWorkflowCoordinator(capture: capture,
            content: MioContentViewModel(repository: MioContentRepository(storageURL: root.appendingPathComponent("content.json"))),
            assistant: MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json"))),
            analysis: MioAnalysisCoordinator(), journal: MioDeletionJournal(storageURL: root.appendingPathComponent("operations.json")),
            diagnostics: MioDiagnosticsRepository(storageURL: root.appendingPathComponent("diagnostics.json")),
            systemActions: MioSystemActionPort(cancel: { _ in .success }, removeAll: { .failure("Avbryt kvarvarande alarm och försök igen.") }),
            questions: questions, clearCredentials: { credentialsCleared = true })
        let task = Task { await questions.sendApproved(request(), connection: connection()) }
        await transport.waitForSend()
        let before = questions.generation
        let deletion = await workflow.deleteAll()
        guard case .failure = deletion else { return XCTFail("Systemfelet ska blockera raderingen") }
        XCTAssertTrue(MioMaintenanceState.shared.recoveryBlocked)
        XCTAssertFalse(credentialsCleared, "Frågan måste invalideras även när städningen inte nådde credentialreset")
        XCTAssertNotEqual(questions.generation, before)
        await transport.finish(answer: "Sent svar medan raderingen väntar")
        let result = await task.value
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertNil(result.answer)
        let blocked = await questions.sendApproved(request(), connection: connection())
        guard case .conflict = blocked.outcome else { return XCTFail("Blockerad radering får inte tillåta en ny fråga") }
        let sent = await transport.payloads()
        XCTAssertEqual(sent.requests.count, 1)
        XCTAssertEqual(captureStarts, 0)
    }

    @MainActor
    func testConfigurationChangeInvalidatesBothPendingQuestionAndReviewedPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = QuestionHeldTransport()
        let questions = MioQuestionWorkflow(configurationMatches: { _ in true }, send: { try await transport.send($0, connection: $1) })
        let workflow = MioWorkflowCoordinator(capture: MioViewModel(repository: SessionRepository(storageURL: root.appendingPathComponent("sessions.json"))),
            content: MioContentViewModel(repository: MioContentRepository(storageURL: root.appendingPathComponent("content.json"))),
            assistant: MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json"))),
            analysis: MioAnalysisCoordinator(), journal: MioDeletionJournal(storageURL: root.appendingPathComponent("operations.json")),
            diagnostics: MioDiagnosticsRepository(storageURL: root.appendingPathComponent("diagnostics.json")),
            questions: questions)
        let reviewedGeneration = questions.generation
        let task = Task { await questions.sendApproved(request(), connection: connection(), expectedGeneration: reviewedGeneration) }
        await transport.waitForSend()
        workflow.cloudConfigurationChanged()
        await transport.finish(answer: "Ett svar från den gamla anslutningen")
        let pending = await task.value
        XCTAssertEqual(pending.outcome, .cancelled)
        XCTAssertNil(pending.answer)
        let preview = await questions.sendApproved(request(), connection: connection(), expectedGeneration: reviewedGeneration)
        XCTAssertEqual(preview.outcome, .cancelled)
        let sent = await transport.payloads()
        XCTAssertEqual(sent.requests.count, 1)
    }

    @MainActor
    func testPreviewInvalidatedBeforeItsQueuedApprovalCannotStartTransport() async throws {
        var requests = 0
        let workflow = MioQuestionWorkflow(configurationMatches: { _ in true }, send: { _, _ in requests += 1; return "Oönskat svar" })
        let reviewedGeneration = workflow.generation
        workflow.invalidate()
        let result = await workflow.sendApproved(request(), connection: connection(), expectedGeneration: reviewedGeneration)
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertNil(result.answer)
        XCTAssertEqual(requests, 0)
    }

    @MainActor
    func testOnlyTheExactApprovedQuestionAndContextReachTheTransport() async throws {
        let transport = QuestionHeldTransport()
        let workflow = MioQuestionWorkflow(configurationMatches: { _ in true }, send: { try await transport.send($0, connection: $1) })
        let approved = MioCloudRequest(question: "  Hur räknar jag procent?  ",
            context: [.init(label: "Godkänt utdrag", text: "Exakt vald text.")])
        let connection = connection()
        let task = Task { await workflow.sendApproved(approved, connection: connection) }
        await transport.waitForSend()
        XCTAssertTrue(workflow.isSending)
        let sent = await transport.payloads()
        XCTAssertEqual(sent.requests, [approved])
        XCTAssertEqual(sent.connections, [connection])
        await transport.finish(answer: "Ett syntetiskt svar")
        let result = await task.value
        XCTAssertEqual(result, MioQuestionResult(outcome: .success, answer: "Ett syntetiskt svar"))
        XCTAssertFalse(workflow.isSending)
    }

    @MainActor
    func testInvalidationSuppressesAnUncancellableLateAnswerWithoutRetry() async throws {
        let transport = QuestionHeldTransport()
        let workflow = MioQuestionWorkflow(configurationMatches: { _ in true }, send: { try await transport.send($0, connection: $1) })
        let task = Task { await workflow.sendApproved(request(), connection: connection()) }
        await transport.waitForSend()
        let before = workflow.generation
        workflow.invalidate()
        XCTAssertNotEqual(workflow.generation, before)
        XCTAssertFalse(workflow.isSending)
        await transport.finish(answer: "Ett sent svar efter radering")
        let result = await task.value
        XCTAssertEqual(result, MioQuestionResult(outcome: .cancelled, answer: nil))
        let sent = await transport.payloads()
        XCTAssertEqual(sent.requests.count, 1)
    }

    @MainActor
    func testCallerCancellationSuppressesAnUncancellableLateAnswer() async throws {
        let transport = QuestionHeldTransport()
        let workflow = MioQuestionWorkflow(configurationMatches: { _ in true }, send: { try await transport.send($0, connection: $1) })
        let task = Task { await workflow.sendApproved(request(), connection: connection()) }
        await transport.waitForSend()
        task.cancel()
        await transport.finish(answer: "Svar efter avbryt")
        let result = await task.value
        XCTAssertEqual(result, MioQuestionResult(outcome: .cancelled, answer: nil))
        XCTAssertFalse(workflow.isSending)
    }

    @MainActor
    func testInvalidationSuppressesLateTransportErrorAsCancelled() async throws {
        let transport = QuestionHeldTransport()
        let workflow = MioQuestionWorkflow(configurationMatches: { _ in true }, send: { try await transport.send($0, connection: $1) })
        let task = Task { await workflow.sendApproved(request(), connection: connection()) }
        await transport.waitForSend()
        workflow.invalidate()
        await transport.fail()
        let result = await task.value
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertNil(result.answer)
    }

    @MainActor
    func testAVisibleTransportFailureIsExplicitAndNeverRetried() async throws {
        let transport = QuestionHeldTransport()
        let workflow = MioQuestionWorkflow(configurationMatches: { _ in true }, send: { try await transport.send($0, connection: $1) })
        let task = Task { await workflow.sendApproved(request(), connection: connection()) }
        await transport.waitForSend()
        await transport.fail()
        let result = await task.value
        guard case .failure = result.outcome else { return XCTFail("Transportfel ska visas som misslyckade") }
        XCTAssertNil(result.answer)
        XCTAssertFalse(workflow.isSending)
        let sent = await transport.payloads()
        XCTAssertEqual(sent.requests.count, 1)
    }

    @MainActor
    func testBlockedRecoveryAndInvalidPayloadCannotReachTransport() async throws {
        let transport = QuestionHeldTransport()
        let workflow = MioQuestionWorkflow(configurationMatches: { _ in true }, send: { try await transport.send($0, connection: $1) }, canSend: { false })
        let blocked = await workflow.sendApproved(request(), connection: connection())
        guard case .conflict = blocked.outcome else { return XCTFail("Pågående radering måste blockera sändning") }
        let allowed = MioQuestionWorkflow(configurationMatches: { _ in true }, send: { try await transport.send($0, connection: $1) })
        let invalid = await allowed.sendApproved(MioCloudRequest(question: "", context: []), connection: connection())
        guard case .failure = invalid.outcome else { return XCTFail("Ogiltigt underlag ska avvisas före sändning") }
        let sent = await transport.payloads()
        XCTAssertTrue(sent.requests.isEmpty)
    }

    private func request() -> MioCloudRequest { MioCloudRequest(question: "Syntetisk fråga", context: []) }
    private func connection() -> MioCloudConnection {
        MioCloudConnection(endpoint: URL(string: "https://fixture.invalid/v1/ask")!, token: String(repeating: "x", count: 40))
    }

    @MainActor
    private func assertTargetedDeletionInvalidatesQuestion(scope: MioDeletionScope) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); MioMaintenanceState.shared.setRecoveryBlocked(false) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let contentURL = root.appendingPathComponent("content.json")
        if scope == .session {
            // Session deletion first unlinks content. An unknown schema blocks that
            // cleanup while the reviewed question still contains a copied excerpt.
            try Data(#"{"schemaVersion":99}"#.utf8).write(to: contentURL)
        }
        let transport = QuestionHeldTransport()
        let questions = MioQuestionWorkflow(configurationMatches: { _ in true }, send: { try await transport.send($0, connection: $1) })
        let workflow = MioWorkflowCoordinator(capture: MioViewModel(repository: SessionRepository(storageURL: root.appendingPathComponent("sessions.json"))),
            content: MioContentViewModel(repository: MioContentRepository(storageURL: contentURL)),
            assistant: MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json"))),
            analysis: MioAnalysisCoordinator(), journal: MioDeletionJournal(storageURL: root.appendingPathComponent("operations.json")),
            diagnostics: MioDiagnosticsRepository(storageURL: root.appendingPathComponent("diagnostics.json")),
            systemActions: MioSystemActionPort(cancel: { _ in .failure("Avbryt kvarvarande alarm och försök igen.") }, removeAll: { .success }),
            questions: questions)
        let approved = MioCloudRequest(question: "Syntetisk fråga", context: [.init(label: "Valt utdrag", text: "En kopia av källtexten.")])
        let reviewedGeneration = questions.generation
        let task = Task { await questions.sendApproved(approved, connection: connection(), expectedGeneration: reviewedGeneration) }
        await transport.waitForSend()
        let deletion: MioOperationOutcome
        if scope == .content { deletion = await workflow.deleteContent(id: UUID()) }
        else { deletion = await workflow.deleteSession(id: UUID()) }
        guard case .failure = deletion else { return XCTFail("Städfelet ska lämna raderingen blockerad") }
        XCTAssertTrue(MioMaintenanceState.shared.recoveryBlocked)
        XCTAssertNotEqual(questions.generation, reviewedGeneration)
        await transport.finish(answer: "Svar från ett nu raderat utdrag")
        let result = await task.value
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertNil(result.answer)
        let stalePreview = await questions.sendApproved(approved, connection: connection(), expectedGeneration: reviewedGeneration)
        XCTAssertEqual(stalePreview.outcome, .cancelled)
        let sent = await transport.payloads()
        XCTAssertEqual(sent.requests, [approved])
    }
}

/// Models a transport that has already sent its request and ignores task cancellation.
private actor QuestionHeldTransport {
    private var requests: [MioCloudRequest] = []
    private var connections: [MioCloudConnection] = []
    private var response: CheckedContinuation<String, Error>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func send(_ request: MioCloudRequest, connection: MioCloudConnection) async throws -> String {
        requests.append(request); connections.append(connection)
        return try await withCheckedThrowingContinuation { continuation in
            response = continuation
            waiters.forEach { $0.resume() }; waiters = []
        }
    }
    func waitForSend() async {
        if response != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func finish(answer: String) { response?.resume(returning: answer); response = nil }
    func fail() { response?.resume(throwing: URLError(.notConnectedToInternet)); response = nil }
    func payloads() -> (requests: [MioCloudRequest], connections: [MioCloudConnection]) { (requests, connections) }
}
