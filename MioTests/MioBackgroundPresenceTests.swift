import Foundation
import XCTest
@testable import Mio

final class MioBackgroundPresenceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testListeningStartsActivityWithSessionStartAndGapCount() {
        var session = MioSession(startedAt: start, captureMode: .lesson)
        session.captureGaps = [CaptureGap(startedAt: start, endedAt: start.addingTimeInterval(5), reason: "Syntetiskt avbrott")]
        let decision = MioListeningActivityMapping.decision(runState: .listening, session: session, previous: nil)
        guard case let .show(target) = decision else { return XCTFail("Live capture must show the activity") }
        XCTAssertEqual(target.sessionID, session.id)
        XCTAssertTrue(target.isLesson)
        XCTAssertEqual(target.state, MioListeningActivityState(phase: .listening, startedAt: start, pausedAt: nil, gapCount: 1))
        XCTAssertEqual(target.state.title, "Lyssnar")
        XCTAssertEqual(target.state.gapText, "1 avbrott i ljudet")
    }

    func testPauseKeepsAStablePauseTimeAndNeverCreatesAnActivity() {
        let session = MioSession(startedAt: start)
        let pausedAt = start.addingTimeInterval(600)
        XCTAssertEqual(MioListeningActivityMapping.decision(runState: .paused, session: session, previous: nil), .end,
                       "a session that never listened in this activity gets no Lock Screen entry")
        guard case let .show(listening) = MioListeningActivityMapping.decision(runState: .listening, session: session, previous: nil),
              case let .show(paused) = MioListeningActivityMapping.decision(runState: .paused, session: session,
                                                                            previous: listening, now: pausedAt),
              case let .show(later) = MioListeningActivityMapping.decision(runState: .paused, session: session,
                                                                           previous: paused, now: pausedAt.addingTimeInterval(300))
        else { return XCTFail("A live session's pause must stay visible") }
        XCTAssertEqual(paused.state.phase, .paused)
        XCTAssertEqual(paused.state.title, "Pausad")
        XCTAssertEqual(later.state.pausedAt, pausedAt, "repeated observations must not move the frozen timer")
        guard case let .show(resumed) = MioListeningActivityMapping.decision(runState: .listening, session: session, previous: later)
        else { return XCTFail("Resuming must show listening again") }
        XCTAssertNil(resumed.state.pausedAt)
    }

    func testTransientAndEndedStates() {
        let live = MioSession(startedAt: start)
        XCTAssertEqual(MioListeningActivityMapping.decision(runState: .stopping, session: live, previous: nil), .keep)
        XCTAssertEqual(MioListeningActivityMapping.decision(runState: .preparing, session: live, previous: nil), .keep)
        for state in [MioRunState.off, .failed, .unavailable] {
            XCTAssertEqual(MioListeningActivityMapping.decision(runState: state, session: live, previous: nil), .end)
        }
        let ended = MioSession(startedAt: start, endedAt: start.addingTimeInterval(60))
        XCTAssertEqual(MioListeningActivityMapping.decision(runState: .listening, session: ended, previous: nil), .end)
        XCTAssertEqual(MioListeningActivityMapping.decision(runState: .listening, session: nil, previous: nil), .end)
        guard case let .show(interrupted) = MioListeningActivityMapping.decision(runState: .interrupted, session: live, previous: nil)
        else { return XCTFail("An interruption keeps the activity visible") }
        XCTAssertEqual(interrupted.state.title, "Avbrott")
        XCTAssertNil(interrupted.state.gapText)
    }

    func testLessonNotesProgressCountsTextPartsAndDecidesTheTaskOutcome() {
        let partial = MioLessonNotesProgress(completed: 3, total: 10)
        XCTAssertEqual(partial.subtitle, "3 av 10 textdelar klara")
        XCTAssertEqual(partial.step(hasPendingWork: true), .running)
        XCTAssertEqual(partial.step(hasPendingWork: false), .stopped)
        XCTAssertEqual(MioLessonNotesProgress(completed: 10, total: 10).step(hasPendingWork: false), .finished)
        XCTAssertEqual(MioLessonNotesProgress(completed: 12, total: 10).completed, 10)
        XCTAssertFalse(MioLessonNotesProgress(completed: 0, total: 0).isComplete, "an empty lesson has no finished notes")
        let session = MioSession(startedAt: start, endedAt: start.addingTimeInterval(60),
            transcripts: [TranscriptSegment(text: "Första delen.", containsMio: false),
                          TranscriptSegment(text: "Andra delen.", containsMio: false)], captureMode: .lesson)
        let progress = MioLessonNotesProgress(document: MioLessonDocument(session: session, records: []))
        XCTAssertEqual(progress, MioLessonNotesProgress(completed: 0, total: 2))
    }

    @MainActor
    func testStoppingLessonNotesKeepsAIOnAndAllowsContinuingLater() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json")))
        let segments = (0..<2).map { _ in TranscriptSegment(text: String(repeating: "A", count: 3400), containsMio: false) }
        let session = MioSession(endedAt: .now, transcripts: segments, captureMode: .lesson)
        let waiting = expectation(description: "Pacing wait before the second part")
        let cancelled = expectation(description: "Stopping cancels the pending part")
        var calls = 0
        var holdNextWait = true
        let connection = MioCloudConnection(endpoint: URL(string: "https://example.invalid/v1/ask")!, token: "synthetic")
        let coordinator = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true },
            prepareConnection: { try await syntheticPreparedConnection($0, task: $1) }, send: { _, _ in
                calls += 1
                return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [], sections: [], metadata:
                    MioAnalysisMetadata(provider: "groq", model: "qwen/qwen3.8-27b", promptVersion: "test", lessonIntervalSeconds: 60))
            }, wait: { _ in
                guard holdNextWait else { return }
                holdNextWait = false
                waiting.fulfill()
                do { try await Task.sleep(for: .seconds(60)) }
                catch { cancelled.fulfill(); throw error }
            })
        try await coordinator.enable(existingSessions: [session])
        coordinator.summarizeLesson(session, assistant: assistant)
        XCTAssertTrue(coordinator.hasPendingLessonNotes(sessionID: session.id))
        await fulfillment(of: [waiting], timeout: 2)
        coordinator.stopLessonNotes(sessionID: session.id, assistant: assistant)
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertTrue(coordinator.enabled, "stopping one lesson's notes must not turn AI off")
        XCTAssertFalse(coordinator.hasPendingLessonNotes(sessionID: session.id))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(assistant.analyzedFragmentIDs(for: session.id, detailedLesson: true).count, 1)

        coordinator.summarizeLesson(session, assistant: assistant)
        for _ in 0..<10_000 where calls < 2 { await Task.yield() }
        XCTAssertEqual(calls, 2, "the remaining part can be queued again")
        coordinator.disable()
    }

    @MainActor
    func testUnfinishedLessonNotesResumeWhenAIIsEnabledAfterLaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "MioBackgroundPresenceTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let lesson = MioSession(startedAt: start, endedAt: start.addingTimeInterval(60),
            transcripts: [TranscriptSegment(text: "Syntetisk lektionsdel.", containsMio: false)], title: "Lektion", captureMode: .lesson)
        let repository = SessionRepository(storageURL: root.appendingPathComponent("sessions.json"))
        let token = try await repository.operationToken(for: lesson.id, generation: await repository.operationGeneration())
        _ = try await repository.saveCaptureCheckpoint(lesson, token: token)
        let deleted = UUID()
        defaults.set([lesson.id.uuidString, deleted.uuidString], forKey: MioWorkflowCoordinator.lessonNotesKey)

        let sent = expectation(description: "The listed lesson's notes are resumed")
        let connection = MioCloudConnection(endpoint: URL(string: "https://example.invalid/v1/ask")!, token: "synthetic")
        let analysis = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true },
            prepareConnection: { try await syntheticPreparedConnection($0, task: $1) }, send: { request, _ in
                XCTAssertEqual(request.mode, .lesson)
                sent.fulfill()
                throw CancellationError()
            }, wait: { _ in })
        let capture = MioViewModel(repository: repository)
        let assistant = MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json")))
        let content = MioContentViewModel(repository: MioContentRepository(storageURL: root.appendingPathComponent("content.json")))
        let workflow = MioWorkflowCoordinator(capture: capture, content: content, assistant: assistant, analysis: analysis,
            journal: MioDeletionJournal(storageURL: root.appendingPathComponent("operations.json")),
            diagnostics: MioDiagnosticsRepository(storageURL: root.appendingPathComponent("diagnostics.json")),
            systemActions: MioSystemActionPort(cancel: { _ in .success }, removeAll: { .success }),
            clearCredentials: {}, pendingLessonDefaults: defaults)
        await workflow.bootstrap()
        XCTAssertFalse(analysis.hasPendingLessonNotes(sessionID: lesson.id), "nothing is sent while AI is off")

        try await analysis.enable(existingSessions: [])
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(defaults.stringArray(forKey: MioWorkflowCoordinator.lessonNotesKey), [lesson.id.uuidString],
                       "deleted lessons are dropped; unfinished ones stay listed until complete")
        analysis.disable()
    }
}
