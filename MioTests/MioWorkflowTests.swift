import Foundation
import XCTest
@testable import Mio

final class MioWorkflowTests: XCTestCase {
    @MainActor
    func testMicrophoneInterruptionSendsQueuedEverydayTextInsteadOfDroppingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let waiting = expectation(description: "Everyday text waits for its five-minute batch")
        let sent = expectation(description: "Text captured before the interruption is sent")
        var calls = 0
        let analysis = MioAnalysisCoordinator(loadConnection: { syntheticCloudConnection() }, configurationMatches: { _ in true },
            prepareConnection: { try await syntheticPreparedConnection($0, task: $1) }, send: { request, _ in
                calls += 1
                XCTAssertEqual(request.fragments.map(\.text), ["Före samtalet"])
                sent.fulfill()
                return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
            }, wait: { _ in
                waiting.fulfill()
                try await Task.sleep(for: .seconds(60))
            }, consentLog: { MioAIConsentLog() }, recordConsent: { _, _, _ in })
        let capture = MioViewModel(repository: SessionRepository(storageURL: root.appendingPathComponent("sessions.json")))
        let assistant = MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json")))
        let workflow = MioWorkflowCoordinator(capture: capture,
            content: MioContentViewModel(repository: MioContentRepository(storageURL: root.appendingPathComponent("content.json"))),
            assistant: assistant, analysis: analysis,
            journal: MioDeletionJournal(storageURL: root.appendingPathComponent("operations.json")))
        await workflow.bootstrap()
        try await analysis.enable(existingSessions: [])
        defer { analysis.disable() }
        let session = MioSession(transcripts: [TranscriptSegment(text: "Före samtalet", containsMio: false)])
        capture.currentSession = session
        capture.runState = .listening
        analysis.observe(session, assistant: assistant)
        await fulfillment(of: [waiting], timeout: 2)
        // A phone call takes the microphone; Mio restarts later, but this text must not be lost.
        capture.runState = .interrupted
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(analysis.enabled)
    }

    /// Ultrareview A7: speech right before a call is transcribed after the interruption began.
    /// It was neither observed while interrupted nor accepted after the restart.
    @MainActor
    func testSpeechTranscribedAfterAnInterruptionStillReachesAI() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var clock = Date.now
        var sent: [[String]] = []
        let analysis = MioAnalysisCoordinator(loadConnection: { syntheticCloudConnection() }, configurationMatches: { _ in true },
            prepareConnection: { try await syntheticPreparedConnection($0, task: $1) }, send: { request, _ in
                sent.append(request.fragments.map(\.text))
                return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
            }, wait: { clock.addTimeInterval($0) }, now: { clock }, consentLog: { MioAIConsentLog() }, recordConsent: { _, _, _ in })
        let capture = MioViewModel(repository: SessionRepository(storageURL: root.appendingPathComponent("sessions.json")))
        let assistant = MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json")))
        let workflow = MioWorkflowCoordinator(capture: capture,
            content: MioContentViewModel(repository: MioContentRepository(storageURL: root.appendingPathComponent("content.json"))),
            assistant: assistant, analysis: analysis,
            journal: MioDeletionJournal(storageURL: root.appendingPathComponent("operations.json")))
        await workflow.bootstrap()
        try await analysis.enable(existingSessions: [])
        defer { analysis.disable() }
        clock.addTimeInterval(10)
        var session = MioSession(transcripts: [TranscriptSegment(createdAt: clock, text: "Före samtalet", containsMio: false)])
        capture.currentSession = session
        capture.runState = .listening
        capture.onFinalizedTranscript?(session)
        clock.addTimeInterval(5)
        let spokenBeforeCall = clock
        clock.addTimeInterval(1)
        capture.runState = .interrupted
        for _ in 0..<20_000 { if sent.count == 1 && !analysis.isWorking { break }; await Task.yield() }
        XCTAssertEqual(sent, [["Före samtalet"]])
        // The last words before the call arrive from the transcriber during the interruption.
        session.transcripts.append(TranscriptSegment(createdAt: spokenBeforeCall, text: "Precis innan samtalet", containsMio: false))
        capture.currentSession = session
        capture.onFinalizedTranscript?(session)
        for _ in 0..<20_000 { if sent.count == 2 && !analysis.isWorking { break }; await Task.yield() }
        XCTAssertEqual(sent.last, ["Precis innan samtalet"])
        // After the automatic restart new speech is sent on its own, without the earlier window.
        clock.addTimeInterval(30)
        capture.runState = .listening
        session.transcripts.append(TranscriptSegment(createdAt: clock, text: "Efter samtalet", containsMio: false))
        capture.currentSession = session
        capture.onFinalizedTranscript?(session)
        for _ in 0..<20_000 { if sent.count == 3 && !analysis.isWorking { break }; await Task.yield() }
        XCTAssertEqual(sent.last, ["Efter samtalet"])
        XCTAssertEqual(sent.count, 3, "Nothing is sent twice")
        XCTAssertTrue(analysis.enabled)
    }

    @MainActor
    func testDeleteAllOnTheTemporaryStoreIsRefusedWithoutBlockingTheApp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = MioViewModel(repository: SessionRepository(storageURL: root.appendingPathComponent("sessions.json")))
        let workflow = MioWorkflowCoordinator(capture: capture,
            content: MioContentViewModel(repository: MioContentRepository(storageURL: root.appendingPathComponent("content.json"))),
            assistant: MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json"))),
            analysis: MioAnalysisCoordinator(), journal: MioDeletionJournal(storageURL: root.appendingPathComponent("operations.json")),
            clearCredentials: { XCTFail("Nothing may be deleted on the temporary store") }, storesAreDurable: { false })
        await workflow.bootstrap()
        let outcome = await workflow.deleteAll()
        XCTAssertEqual(outcome, .conflict(MioDeletionRecovery.temporaryStoreMessage))
        XCTAssertFalse(MioMaintenanceState.shared.recoveryBlocked)
        XCTAssertNil(workflow.deletion.pendingOperationID)
    }

    /// Ultrareview B3: when the content store failed after the claim, the claim was never
    /// released and the proposal stayed "approval in progress" until the app restarted.
    @MainActor
    func testFailingContentStoreReleasesTheApprovalClaim() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FailingApprovalContentStore()
        let repository = MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json"))
        let assistant = MioAssistantViewModel(repository: repository)
        let workflow = MioWorkflowCoordinator(capture: MioViewModel(repository: SessionRepository(storageURL: root.appendingPathComponent("sessions.json"))),
            content: MioContentViewModel(repository: store), assistant: assistant, analysis: MioAnalysisCoordinator(),
            journal: MioDeletionJournal(storageURL: root.appendingPathComponent("operations.json")))
        await workflow.bootstrap()
        let suggestion = MioSuggestion(kind: .note, title: "Syntetiskt förslag")
        try await repository.addSuggestion(suggestion)
        for failure in [FailingApprovalContentStore.Mode.storageError, .repositoryError] {
            await store.set(failure)
            let outcome = await workflow.acceptSuggestion(id: suggestion.id, expectedRevision: 0, kind: .note, title: "Syntetiskt förslag",
                                                          body: "", scheduledAt: .now, dateConfirmed: true, dateChosen: false)
            XCTAssertNotEqual(outcome, .success, "\(failure)")
            let reads = await store.reads
            XCTAssertGreaterThan(reads, 1, "The failure came after the claim (\(failure))")
            // A released claim lets the next attempt claim again instead of "already in progress".
            let again = try await repository.claimSuggestion(id: suggestion.id, expectedRevision: 0)
            try await repository.releaseApproval(again)
        }
    }

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
    func testPendingLessonSurvivesRecoveryBlockAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "MioWorkflowTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defer { MioMaintenanceState.shared.setRecoveryBlocked(false) }
        func launch() -> (workflow: MioWorkflowCoordinator, capture: MioViewModel, assistant: MioAssistantViewModel) {
            let capture = MioViewModel(repository: SessionRepository(storageURL: root.appendingPathComponent("sessions.json")))
            let assistant = MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json")))
            let content = MioContentViewModel(repository: MioContentRepository(storageURL: root.appendingPathComponent("content.json")))
            let workflow = MioWorkflowCoordinator(capture: capture, content: content, assistant: assistant,
                analysis: MioAnalysisCoordinator(), journal: MioDeletionJournal(storageURL: root.appendingPathComponent("operations.json")),
                diagnostics: MioDiagnosticsRepository(storageURL: root.appendingPathComponent("diagnostics.json")),
                systemActions: MioSystemActionPort(cancel: { _ in .success }, removeAll: { .success }),
                clearCredentials: {}, pendingLessonDefaults: defaults)
            return (workflow, capture, assistant)
        }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = MioSession(startedAt: start, endedAt: start.addingTimeInterval(60), title: "Väntande lektion", captureMode: .lesson)
        let repository = SessionRepository(storageURL: root.appendingPathComponent("sessions.json"))
        let token = try await repository.operationToken(for: session.id, generation: await repository.operationGeneration())
        _ = try await repository.saveCaptureCheckpoint(session, token: token)

        let first = launch()
        await first.workflow.bootstrap()
        MioMaintenanceState.shared.setRecoveryBlocked(true)
        try XCTUnwrap(first.capture.onLessonFinished)(session)
        for _ in 0..<200 { await Task.yield() }
        XCTAssertTrue(first.workflow.pendingLessonIDs.contains(session.id), "a blocked finalization must stay visibly pending")
        XCTAssertTrue(first.assistant.lessons.isEmpty)
        MioMaintenanceState.shared.setRecoveryBlocked(false)

        // A restart restores the pending ID and completes the local registration.
        let second = launch()
        await second.workflow.bootstrap()
        for _ in 0..<10_000 { if !second.assistant.lessons.isEmpty { break }; await Task.yield() }
        XCTAssertEqual(second.assistant.lessons.map(\.sessionID), [session.id])
        XCTAssertFalse(second.workflow.pendingLessonIDs.contains(session.id))
    }

    @MainActor
    func testSessionDeletionRemovesExportsThatMayContainIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let exports = root.appendingPathComponent("exports", isDirectory: true)
        let sessions = SessionRepository(storageURL: root.appendingPathComponent("sessions.json"), exportDirectoryURL: exports)
        let capture = MioViewModel(repository: sessions)
        let assistant = MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json")))
        let content = MioContentViewModel(repository: MioContentRepository(storageURL: root.appendingPathComponent("content.json"),
                                                                           exportDirectoryURL: exports))
        let workflow = MioWorkflowCoordinator(capture: capture, content: content, assistant: assistant,
            analysis: MioAnalysisCoordinator(), journal: MioDeletionJournal(storageURL: root.appendingPathComponent("operations.json")),
            diagnostics: MioDiagnosticsRepository(storageURL: root.appendingPathComponent("diagnostics.json")),
            systemActions: MioSystemActionPort(cancel: { _ in .success }, removeAll: { .success }), clearCredentials: {})
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = MioSession(startedAt: start, endedAt: start.addingTimeInterval(60), title: "Exporterad")
        let token = try await sessions.operationToken(for: session.id, generation: await sessions.operationGeneration())
        _ = try await sessions.saveCaptureCheckpoint(session, token: token)
        await workflow.bootstrap()
        let export = try await sessions.makeExportFile(for: session)
        let fullExport = exports.appendingPathComponent("Mio-lokal-export-syntetisk.json")
        try Data("{}".utf8).write(to: fullExport)
        let deleted = await workflow.deleteSession(id: session.id)
        XCTAssertEqual(deleted, .success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fullExport.path))
        do {
            _ = try await sessions.makeExportFile(for: session)
            XCTFail("A deleted session must not be exported from a stale snapshot")
        } catch {}
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

/// Content store whose approval path fails after the claim, as in ultrareview B3.
private actor FailingApprovalContentStore: MioContentStore {
    enum Mode: Sendable { case storageError, repositoryError }
    private var mode = Mode.storageError
    private(set) var reads = 0
    func set(_ mode: Mode) { self.mode = mode; reads = 0 }
    func loadItems() async throws -> [MioContentItem] {
        reads += 1
        // The first read is before the claim; the read after the failed save fails too.
        guard reads > 1 else { return [] }
        switch mode {
        case .storageError: throw CocoaError(.fileReadUnknown)
        case .repositoryError: throw MioAssistantRepositoryError.invalidRelationships
        }
    }
    func upsert(_ item: MioContentItem) async throws -> [MioContentItem] { throw CocoaError(.fileWriteUnknown) }
    func delete(id: UUID) async throws -> [MioContentItem] { [] }
    func saveApprovedIfAbsent(_ item: MioContentItem) async throws -> [MioContentItem] { throw CocoaError(.fileWriteUnknown) }
    func unlinkSession(id: UUID) async throws -> [MioContentItem] { [] }
    func deleteAll() async throws {}
    func removeTemporaryExports() async throws {}
    func makeExportFile(content: [MioContentItem], sessions: [MioSession],
                        assistant: MioAssistantStoreDocument?, diagnostics: MioDiagnosticsExport?) async throws -> URL {
        throw CocoaError(.fileWriteUnknown)
    }
}
