import Foundation
import XCTest
@testable import Mio

final class MioWorkflowTests: XCTestCase {
    @MainActor
    func testFinalizedLocalDetectionReportsItsStorageFailureExplicitly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("blocked")
        let assistant = MioAssistantViewModel(repository: MioAssistantRepository(storageURL: blocker.appendingPathComponent("assistant.json")))
        let capture = MioViewModel(repository: SessionRepository(storageURL: root.appendingPathComponent("sessions.json")))
        let workflow = MioWorkflowCoordinator(capture: capture,
            content: MioContentViewModel(repository: MioContentRepository(storageURL: root.appendingPathComponent("content.json"))),
            assistant: assistant, analysis: MioAnalysisCoordinator(),
            journal: MioDeletionJournal(storageURL: root.appendingPathComponent("operations.json")))
        await workflow.bootstrap()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: blocker)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = MioSession(startedAt: start, endedAt: start.addingTimeInterval(60),
            transcripts: [TranscriptSegment(text: "Mio, anteckna syntetiskt exempel", containsMio: true)])
        capture.currentSession = session
        capture.onFinalizedTranscript?(session)
        for _ in 0..<10_000 {
            if case .failure = workflow.lastOutcome { break }
            await Task.yield()
        }
        guard case .failure = workflow.lastOutcome else {
            return XCTFail("A failed local capture operation cannot report success")
        }
        XCTAssertNotNil(assistant.errorMessage)
    }

    @MainActor
    func testExportFlushesTheFinalCaptureCheckpointBeforeReadingStores() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = MioViewModel(repository: SessionRepository(storageURL: root.appendingPathComponent("sessions.json")))
        let content = MioContentViewModel(repository: MioContentRepository(storageURL: root.appendingPathComponent("content.json"), exportDirectoryURL: root))
        let assistant = MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json")))
        let workflow = MioWorkflowCoordinator(capture: capture, content: content, assistant: assistant, analysis: MioAnalysisCoordinator())
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let session = MioSession(startedAt: date, endedAt: date.addingTimeInterval(60))
        capture.currentSession = session
        let result = await workflow.prepareExport()
        XCTAssertEqual(result, .success)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(MioLocalExport.self, from: Data(contentsOf: XCTUnwrap(content.exportURL)))
        XCTAssertEqual(export.sessions.map(\.id), [session.id])
    }

    @MainActor
    func testExportReadsLatestActorsRatherThanPresentationSnapshots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contentRepository = MioContentRepository(storageURL: root.appendingPathComponent("content.json"), exportDirectoryURL: root)
        let assistantRepository = MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json"))
        let sessionRepository = SessionRepository(storageURL: root.appendingPathComponent("sessions.json"))
        let assistant = MioAssistantViewModel(repository: assistantRepository)
        let content = MioContentViewModel(repository: contentRepository, diagnostics: MioDiagnosticsRepository(storageURL: root.appendingPathComponent("diagnostics.json")))
        let capture = MioViewModel(repository: sessionRepository)
        let workflow = MioWorkflowCoordinator(capture: capture, content: content, assistant: assistant, analysis: MioAnalysisCoordinator())
        await content.bootstrap(); await assistant.bootstrap()
        let item = MioContentItem(kind: .memory, title: "Senaste actor-post", scheduledAt: .now)
        _ = try await contentRepository.upsert(item)
        let suggestion = MioSuggestion(kind: .note, title: "Senaste actor-förslag")
        try await assistantRepository.addSuggestion(suggestion)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let session = MioSession(startedAt: date, endedAt: date.addingTimeInterval(60))
        let generation = await sessionRepository.operationGeneration()
        let token = try await sessionRepository.operationToken(for: session.id, generation: generation)
        _ = try await sessionRepository.saveCaptureCheckpoint(session, token: token)
        XCTAssertTrue(content.items.isEmpty); XCTAssertTrue(assistant.suggestions.isEmpty)
        let outcome = await workflow.prepareExport()
        XCTAssertEqual(outcome, .success)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(MioLocalExport.self, from: Data(contentsOf: XCTUnwrap(content.exportURL)))
        XCTAssertEqual(document.content.map(\.id), [item.id])
        XCTAssertEqual(document.sessions.map(\.id), [session.id])
        XCTAssertEqual(document.assistant?.suggestions.map(\.id), [suggestion.id])
    }

    @MainActor
    func testRecoveryRetryLoadsUnrelatedDataWithoutStartingCaptureOrAI() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); MioMaintenanceState.shared.setRecoveryBlocked(false) }
        let contentRepository = MioContentRepository(storageURL: root.appendingPathComponent("content.json"))
        let content = MioContentViewModel(repository: contentRepository)
        let item = MioContentItem(kind: .memory, title: "Orelaterad post", scheduledAt: .now)
        _ = try await contentRepository.upsert(item)
        let assistantURL = root.appendingPathComponent("assistant.json")
        try Data(#"{"schemaVersion":99}"#.utf8).write(to: assistantURL)
        let assistant = MioAssistantViewModel(repository: MioAssistantRepository(storageURL: assistantURL))
        var microphoneStarts = 0; var modelRequests = 0
        let capture = MioViewModel(repository: SessionRepository(storageURL: root.appendingPathComponent("sessions.json")), captureFactory: { _, _ in
            microphoneStarts += 1; throw MioError.microphoneDenied
        })
        let analysis = MioAnalysisCoordinator(send: { _, _ in modelRequests += 1; return MioAnalysisResult(candidates: [], highlights: [], uncertainties: []) })
        let journal = MioDeletionJournal(storageURL: root.appendingPathComponent("operations.json"))
        _ = try await journal.begin(scope: .session, targetID: UUID())
        let workflow = MioWorkflowCoordinator(capture: capture, content: content, assistant: assistant, analysis: analysis,
            journal: journal, diagnostics: MioDiagnosticsRepository(storageURL: root.appendingPathComponent("diagnostics.json")),
            systemActions: MioSystemActionPort(cancel: { _ in .success }, removeAll: { .success }), clearCredentials: {})
        await workflow.bootstrap()
        XCTAssertTrue(MioMaintenanceState.shared.recoveryBlocked)
        capture.beginListening()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(microphoneStarts, 0)
        try FileManager.default.removeItem(at: assistantURL)
        let result = await workflow.resumeDeletion()
        XCTAssertEqual(result, .success)
        XCTAssertEqual(content.items.map(\.id), [item.id])
        XCTAssertEqual(microphoneStarts, 0); XCTAssertEqual(modelRequests, 0)
        XCTAssertFalse(MioMaintenanceState.shared.recoveryBlocked)
    }

    @MainActor
    func testFinalizationUsesSaveResultDespiteUnrelatedPresentationErrors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json")))
        let capture = MioViewModel(repository: SessionRepository(storageURL: root.appendingPathComponent("sessions.json")))
        let content = MioContentViewModel(repository: MioContentRepository(storageURL: root.appendingPathComponent("content.json")))
        let workflow = MioWorkflowCoordinator(capture: capture, content: content, assistant: assistant, analysis: MioAnalysisCoordinator())
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = MioSession(startedAt: start, endedAt: start.addingTimeInterval(60), title: "Syntetisk lektion", captureMode: .lesson)
        capture.errorMessage = "Ett tidigare mikrofonfel"
        assistant.errorMessage = "Ett tidigare presentationsfel"
        let outcome = await workflow.finalizeLesson(session)
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(assistant.lessons.map(\.sessionID), [session.id])
    }

    @MainActor
    func testFailedFinalizationRemainsVisibleAndCanBeRetried() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("blocked")
        try Data([1]).write(to: blocker)
        let assistant = MioAssistantViewModel(repository: MioAssistantRepository(storageURL: blocker.appendingPathComponent("assistant.json")))
        let capture = MioViewModel(repository: SessionRepository(storageURL: root.appendingPathComponent("sessions.json")))
        let content = MioContentViewModel(repository: MioContentRepository(storageURL: root.appendingPathComponent("content.json")))
        let workflow = MioWorkflowCoordinator(capture: capture, content: content, assistant: assistant, analysis: MioAnalysisCoordinator())
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = MioSession(startedAt: start, endedAt: start.addingTimeInterval(60), captureMode: .lesson)
        let failed = await workflow.finalizeLesson(session)
        XCTAssertFalse(failed.isSuccess)
        XCTAssertTrue(assistant.lessons.isEmpty)
        try FileManager.default.removeItem(at: blocker)
        let retried = await workflow.finalizeLesson(session)
        XCTAssertEqual(retried, .success)
        XCTAssertEqual(assistant.lessons.map(\.sessionID), [session.id])
    }
    @MainActor
    func testBlockedFullDeletionPreventsWritesAndAllowsExplicitRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var blocked = true
        let port = MioSystemActionPort(cancel: { _ in .success }, removeAll: {
            blocked ? .failure("Systemåtgärder behöver åtgärdas.") : .success
        })
        let assistant = MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json")))
        let capture = MioViewModel(repository: SessionRepository(storageURL: root.appendingPathComponent("sessions.json")))
        let content = MioContentViewModel(repository: MioContentRepository(storageURL: root.appendingPathComponent("content.json")))
        let workflow = MioWorkflowCoordinator(capture: capture, content: content, assistant: assistant,
            analysis: MioAnalysisCoordinator(), journal: MioDeletionJournal(storageURL: root.appendingPathComponent("operations.json")),
            diagnostics: MioDiagnosticsRepository(storageURL: root.appendingPathComponent("diagnostics.json")),
            systemActions: port, clearCredentials: {})
        defer { MioMaintenanceState.shared.endExclusive(); MioMaintenanceState.shared.setRecoveryBlocked(false) }
        let failed = await workflow.deleteAll()
        XCTAssertFalse(failed.isSuccess)
        let wrote = await content.save(kind: .memory, title: "Ska blockeras", body: "", scheduledAt: .now,
                                       isCompleted: false, sessionID: nil)
        XCTAssertFalse(wrote, "Pending deletion must block writes until its explicit retry completes")
        blocked = false
        let resumed = await workflow.resumeDeletion()
        XCTAssertTrue(resumed.isSuccess)
        let after = await content.save(kind: .memory, title: "Efter slutförd radering", body: "", scheduledAt: .now,
                                       isCompleted: false, sessionID: nil)
        XCTAssertTrue(after)
    }

    @MainActor
    func testCancelledQueuedFinalizationDoesNotRunAfterDeletionCommand() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = WorkflowGate()
        let port = MioSystemActionPort(cancel: { _ in await gate.hold(); return .success }, removeAll: { .success })
        let assistant = MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json")))
        let capture = MioViewModel(repository: SessionRepository(storageURL: root.appendingPathComponent("sessions.json")))
        let content = MioContentViewModel(repository: MioContentRepository(storageURL: root.appendingPathComponent("content.json")))
        let workflow = MioWorkflowCoordinator(capture: capture, content: content, assistant: assistant,
            analysis: MioAnalysisCoordinator(), journal: MioDeletionJournal(storageURL: root.appendingPathComponent("operations.json")),
            systemActions: port, clearCredentials: {})
        let deleting = Task { await workflow.deleteContent(id: UUID()) }
        while !gate.started { await Task.yield() }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = MioSession(startedAt: start, endedAt: start.addingTimeInterval(60), captureMode: .lesson)
        let finalizing = Task { await workflow.finalizeLesson(session) }
        while workflow.queuedCommands < 2 { await Task.yield() }
        finalizing.cancel()
        gate.release()
        let deleted = await deleting.value
        let final = await finalizing.value
        XCTAssertEqual(deleted, .success)
        XCTAssertEqual(final, .cancelled)
        XCTAssertTrue(assistant.lessons.isEmpty)
    }

}


@MainActor private final class WorkflowGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        await withCheckedContinuation { continuation = $0; started = true }
    }
    func release() { continuation?.resume(); continuation = nil }
}
