import Foundation
import XCTest
@testable import Mio

final class MioWorkflowRaceTests: XCTestCase {
    @MainActor
    func testAdmittedLessonTransitionCompletesWhileUnrelatedDeletionWaitsForItsDrain() async throws {
        let drainingCapture = WorkflowRaceCapture(holdsFirstStop: true)
        var microphoneStarts = 0
        let fixture = makeFixture(captureFactory: { _, _ in
            microphoneStarts += 1
            return microphoneStarts == 1 ? drainingCapture : WorkflowRaceCapture()
        })
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.workflow.bootstrap()
        fixture.capture.beginListening()
        await waitUntil { fixture.capture.runState == .listening }
        let everydayID = try XCTUnwrap(fixture.capture.currentSession?.id)
        let unrelated = MioContentItem(kind: .note, title: "Orelaterad post", scheduledAt: .now)
        _ = try await fixture.contentRepository.upsert(unrelated)

        let finished = expectation(description: "Both admitted lesson transition and unrelated deletion finish")
        finished.expectedFulfillmentCount = 2
        let lesson = Task {
            await fixture.capture.beginLesson(title: "Lektion efter paus")
            finished.fulfill()
        }
        await drainingCapture.waitForStop()
        XCTAssertGreaterThan(MioMaintenanceState.shared.activeWrites, 0)
        let deleting = Task {
            let result = await fixture.workflow.deleteContent(id: unrelated.id)
            finished.fulfill()
            return result
        }
        await waitUntil { MioMaintenanceState.shared.isDeleting }
        await drainingCapture.releaseStop()
        await fulfillment(of: [finished], timeout: 2)

        // On the regressed implementation this releases the circular wait only after the
        // bounded assertion has failed, so the test itself cannot leave the suite hung.
        if MioMaintenanceState.shared.isDeleting, MioMaintenanceState.shared.activeWrites > 0 {
            MioMaintenanceState.shared.endExclusive()
        }
        await lesson.value
        let result = await deleting.value
        XCTAssertEqual(result, .success)
        await waitUntil { fixture.capture.runState == .listening && fixture.capture.isLessonActive }
        XCTAssertNotEqual(fixture.capture.currentSession?.id, everydayID)
        XCTAssertNotNil(fixture.capture.session(id: everydayID))
        XCTAssertNil(fixture.capture.session(id: everydayID)?.endedAt)
        XCTAssertEqual(microphoneStarts, 2)
        let stored = try await fixture.sessionRepository.loadSessions()
        XCTAssertEqual(Set(stored.map(\.id)), Set(fixture.capture.allSessions.map(\.id)))
        let content = try await fixture.contentRepository.loadItems()
        XCTAssertFalse(content.contains { $0.id == unrelated.id })
        XCTAssertEqual(MioMaintenanceState.shared.activeWrites, 0)
        XCTAssertFalse(MioMaintenanceState.shared.blocksWork)

        await fixture.capture.stopListening()
        await fixture.capture.stopListening()
        await waitForCommands(fixture.workflow)
    }

    @MainActor
    func testUnrelatedDeletionKeepsQueuedFinishedLessonVisibleAndBothDeletionIntentsComplete() async throws {
        let gate = WorkflowRaceGate()
        var cancellations = 0
        let fixture = makeFixture(systemActions: MioSystemActionPort(cancel: { _ in
            cancellations += 1
            if cancellations == 1 { await gate.hold() }
            return .success
        }, removeAll: { .success }))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.workflow.bootstrap()
        let firstItem = MioContentItem(kind: .note, title: "Första orelaterade posten", scheduledAt: .now)
        let secondItem = MioContentItem(kind: .note, title: "Andra orelaterade posten", scheduledAt: .now)
        _ = try await fixture.contentRepository.upsert(firstItem)
        _ = try await fixture.contentRepository.upsert(secondItem)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = MioSession(startedAt: start, endedAt: start.addingTimeInterval(60),
                                 title: "Avslutad lektion", captureMode: .lesson)
        let generation = await fixture.sessionRepository.operationGeneration()
        let token = try await fixture.sessionRepository.operationToken(for: session.id, generation: generation)
        _ = try await fixture.sessionRepository.saveCaptureCheckpoint(session, token: token)
        fixture.capture.currentSession = session

        let firstDeletion = Task { await fixture.workflow.deleteContent(id: firstItem.id) }
        await gate.waitForEntry()
        try XCTUnwrap(fixture.capture.onLessonFinished)(session)
        await waitUntil { fixture.workflow.queuedCommands >= 2 }
        let secondDeletion = Task { await fixture.workflow.deleteContent(id: secondItem.id) }
        await waitUntil { fixture.workflow.queuedCommands >= 3 }
        gate.release()
        let firstResult = await firstDeletion.value
        let secondResult = await secondDeletion.value
        await waitForCommands(fixture.workflow)
        XCTAssertEqual(firstResult, .success, "An unrelated delete must not cancel a deletion already in progress")
        XCTAssertEqual(secondResult, .success)
        let journal = try await fixture.journal.pendingOperations()
        XCTAssertTrue(journal.isEmpty, "A later successful deletion must not conceal an unfinished earlier intent")
        XCTAssertFalse(MioMaintenanceState.shared.recoveryBlocked)
        let registered = fixture.assistant.lessons.contains { $0.sessionID == session.id }
        let pending = fixture.workflow.pendingLessonIDs.contains(session.id)
        XCTAssertTrue(registered || pending, "Automatic lesson finalization must be stored or visibly retryable")

        if pending {
            let retried = await fixture.workflow.retryLessonFinalization()
            XCTAssertEqual(retried, .success)
        }
        XCTAssertTrue(fixture.assistant.lessons.contains { $0.sessionID == session.id })
        XCTAssertNotNil(fixture.capture.session(id: session.id))
        let remaining = try await fixture.contentRepository.loadItems()
        XCTAssertTrue(remaining.isEmpty)

        // Clean up retained RED intents without hiding their assertions above.
        if !journal.isEmpty { _ = await fixture.workflow.resumeDeletion() }
    }

    @MainActor
    func testCancelledExclusiveWaitWakesWithoutReleasingAnotherOperationsSnapshot() async throws {
        let maintenance = MioMaintenanceState.shared
        let admitted = await maintenance.beginExclusive(deleting: false)
        XCTAssertTrue(admitted)
        defer { maintenance.endExclusive(); maintenance.setRecoveryBlocked(false) }
        let entered = expectation(description: "Task starts waiting for the exclusive owner")
        let exited = expectation(description: "Cancellation wakes the wait without releasing the owner")
        let waiting = Task {
            entered.fulfill()
            await maintenance.waitForExclusive()
            exited.fulfill()
        }
        await fulfillment(of: [entered], timeout: 1)
        waiting.cancel()
        await fulfillment(of: [exited], timeout: 1)
        XCTAssertTrue(maintenance.isSnapshotting)
        XCTAssertFalse(maintenance.beginWrite())
        // Release only after checking cancellation, including in the RED version.
        maintenance.endExclusive()
        await waiting.value
        XCTAssertFalse(maintenance.blocksWork)
    }

    @MainActor
    private func makeFixture(
        captureFactory: @escaping @MainActor (UUID, MioCaptureHandlers) throws -> any MioCapturePipeline = { _, _ in WorkflowRaceCapture() },
        systemActions: MioSystemActionPort? = nil
    ) -> WorkflowRaceFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioWorkflowRaces-\(UUID())")
        let sessions = SessionRepository(storageURL: root.appendingPathComponent("sessions.json"))
        let contentRepository = MioContentRepository(storageURL: root.appendingPathComponent("content.json"))
        let diagnostics = MioDiagnosticsRepository(storageURL: root.appendingPathComponent("diagnostics.json"))
        let capture = MioViewModel(repository: sessions, diagnostics: diagnostics, captureFactory: captureFactory)
        let content = MioContentViewModel(repository: contentRepository, diagnostics: diagnostics)
        let assistant = MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json")))
        let analysis = MioAnalysisCoordinator(send: { _, _ in
            XCTFail("These local workflow tests must not send model requests")
            return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
        })
        let journal = MioDeletionJournal(storageURL: root.appendingPathComponent("operations-v1.json"))
        let workflow = MioWorkflowCoordinator(capture: capture, content: content, assistant: assistant, analysis: analysis,
            journal: journal, diagnostics: diagnostics,
            systemActions: systemActions ?? MioSystemActionPort(cancel: { _ in .success }, removeAll: { .success }),
            clearCredentials: {})
        return WorkflowRaceFixture(root: root, sessionRepository: sessions, contentRepository: contentRepository,
                                   journal: journal, capture: capture, assistant: assistant, workflow: workflow)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Den deterministiska övergången slutfördes inte", file: file, line: line)
    }

    @MainActor
    private func waitForCommands(_ workflow: MioWorkflowCoordinator) async {
        for _ in 0..<10 { await Task.yield() }
        await waitUntil { workflow.queuedCommands == 0 }
    }
}

@MainActor
private struct WorkflowRaceFixture {
    let root: URL
    let sessionRepository: SessionRepository
    let contentRepository: MioContentRepository
    let journal: MioDeletionJournal
    let capture: MioViewModel
    let assistant: MioAssistantViewModel
    let workflow: MioWorkflowCoordinator
}

private actor WorkflowRaceCapture: MioCapturePipeline {
    private let holdsFirstStop: Bool
    private var hasStopped = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    init(holdsFirstStop: Bool = false) { self.holdsFirstStop = holdsFirstStop }

    func start() async throws -> CaptureStartDetails {
        try Task.checkCancellation()
        return CaptureStartDetails(health: TranscriptionHealth(apiVersion: 1, serverVersion: "fixture", status: "ready",
            metadata: TranscriptionMetadata(model: "fixture", revision: "fixture", backend: "fixture"),
            sampleRate: 16_000, channels: 1, encoding: "pcm_s16le_wav", maxSeconds: 22, maxBytes: 704_044))
    }

    func foreground() async { }
    func stop(discard: Bool) async {
        guard holdsFirstStop, !hasStopped, !discard else { return }
        hasStopped = true
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
            stopWaiters.forEach { $0.resume() }; stopWaiters = []
        }
    }
    func waitForStop() async {
        if hasStopped { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }
    func releaseStop() { stopContinuation?.resume(); stopContinuation = nil }
}

@MainActor
private final class WorkflowRaceGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        entered = true
        await withCheckedContinuation { continuation = $0; entryWaiters.forEach { $0.resume() }; entryWaiters = [] }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}
