import Foundation
import XCTest
@testable import Mio

/// Fas 4 of the 2026-11-19 grilling: the battery rule, the silence question and the 30-day rule
/// for everyday capture. Lessons are never paused by the battery.
final class MioEverydayCaptureTests: XCTestCase {
    // MARK: Battery rule, portable

    func testBatteryRuleReasons() {
        XCTAssertNil(MioBatteryGuard.reason(for: .unknown))
        XCTAssertNil(MioBatteryGuard.reason(for: MioBatteryStatus(level: 0.2, isCharging: false, lowPowerMode: false)), "20 % is not under 20 %")
        XCTAssertEqual(MioBatteryGuard.reason(for: MioBatteryStatus(level: 0.19, isCharging: false, lowPowerMode: false)), .lowBattery)
        XCTAssertEqual(MioBatteryGuard.reason(for: MioBatteryStatus(level: 0.9, isCharging: false, lowPowerMode: true)), .lowPowerMode)
        XCTAssertNil(MioBatteryGuard.reason(for: MioBatteryStatus(level: 0.05, isCharging: true, lowPowerMode: true)), "plugged in never pauses")
    }

    func testBatteryNeverPausesALessonEvenWhenItDropsMidway() {
        var guardian = MioBatteryGuard()
        let fine = MioBatteryStatus(level: 0.6, isCharging: false, lowPowerMode: false)
        let low = MioBatteryStatus(level: 0.1, isCharging: false, lowPowerMode: false)
        let saver = MioBatteryStatus(level: 0.1, isCharging: false, lowPowerMode: true)
        XCTAssertNil(guardian.evaluate(fine, isLesson: true, isListening: true))
        XCTAssertNil(guardian.evaluate(low, isLesson: true, isListening: true), "the level dropped during the lesson")
        XCTAssertNil(guardian.evaluate(saver, isLesson: true, isListening: true), "Low Power Mode was turned on during the lesson")
        // After the lesson the everyday rule applies again.
        XCTAssertEqual(guardian.evaluate(saver, isLesson: false, isListening: true), .lowPowerMode)
        XCTAssertEqual(guardian.evaluate(low, isLesson: false, isListening: true), .lowBattery)
    }

    func testHerOwnStartIsNotUndoneUntilTheBatteryRecoversOrCharges() {
        var guardian = MioBatteryGuard()
        let low = MioBatteryStatus(level: 0.15, isCharging: false, lowPowerMode: false)
        guardian.userStartedEveryday(with: low)
        XCTAssertNil(guardian.evaluate(low, isLesson: false, isListening: true), "she chose to listen at this level")
        XCTAssertNil(guardian.evaluate(MioBatteryStatus(level: 0.12, isCharging: false, lowPowerMode: false), isLesson: false, isListening: true),
                     "a further drop of the same low battery does not pause either")
        XCTAssertNil(guardian.evaluate(MioBatteryStatus(level: 0.12, isCharging: true, lowPowerMode: false), isLesson: false, isListening: true),
                     "charging clears the exception")
        XCTAssertEqual(guardian.evaluate(low, isLesson: false, isListening: true), .lowBattery, "a later drop pauses again")

        var recovered = MioBatteryGuard()
        recovered.userStartedEveryday(with: low)
        XCTAssertNil(recovered.evaluate(MioBatteryStatus(level: 0.21, isCharging: false, lowPowerMode: false), isLesson: false, isListening: true))
        XCTAssertEqual(recovered.evaluate(low, isLesson: false, isListening: true), .lowBattery)

        var fine = MioBatteryGuard()
        fine.userStartedEveryday(with: MioBatteryStatus(level: 0.8, isCharging: false, lowPowerMode: false))
        XCTAssertFalse(fine.userOverride)
        XCTAssertEqual(fine.evaluate(low, isLesson: false, isListening: true), .lowBattery)
        XCTAssertNil(fine.evaluate(low, isLesson: false, isListening: false), "nothing to pause when not listening")
    }

    // MARK: Battery rule through the capture model

    @MainActor
    func testLessonKeepsListeningOnLowBatteryAndEverydayPausesAfterIt() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let battery = BatteryBox()
        let model = MioViewModel(repository: fixture.repository, captureFactory: { _, _ in PolicyCapture() })
        model.batteryStatus = { battery.status }
        await model.bootstrap()
        battery.status = MioBatteryStatus(level: 0.15, isCharging: false, lowPowerMode: false)
        await model.beginLesson(title: "Biologi")
        await waitUntil { model.runState == .listening && model.isLessonActive }
        model.evaluateAutomaticPause()
        battery.status = MioBatteryStatus(level: 0.05, isCharging: false, lowPowerMode: true)
        model.evaluateAutomaticPause()
        try await Task.sleep(nanoseconds: 1_200_000_000) // the model's own clock checks too
        XCTAssertEqual(model.runState, .listening, "a lesson is never paused by the battery")
        XCTAssertTrue(model.isLessonActive)
        XCTAssertNil(model.automaticPause)

        await model.stopListening()
        battery.status = MioBatteryStatus(level: 0.7, isCharging: false, lowPowerMode: false)
        model.beginListening()
        await waitUntil { model.runState == .listening && !model.isLessonActive }
        battery.status = MioBatteryStatus(level: 0.18, isCharging: false, lowPowerMode: false)
        model.evaluateAutomaticPause()
        await waitUntil { model.runState == .paused && model.automaticPause == .lowBattery }
        XCTAssertEqual(model.statusMessage, MioAutomaticPause.lowBattery.message)

        // She starts again right away and Mio keeps listening at that level.
        model.beginListening()
        await waitUntil { model.runState == .listening }
        XCTAssertNil(model.automaticPause)
        model.evaluateAutomaticPause()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(model.runState, .listening)
        await model.stopListening()
    }

    @MainActor
    func testLowPowerModePausesEverydayAndShowsWhy() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let battery = BatteryBox()
        battery.status = MioBatteryStatus(level: 0.8, isCharging: false, lowPowerMode: false)
        let model = MioViewModel(repository: fixture.repository, captureFactory: { _, _ in PolicyCapture() })
        model.batteryStatus = { battery.status }
        await model.bootstrap()
        model.beginListening()
        await waitUntil { model.runState == .listening }
        battery.status = MioBatteryStatus(level: 0.8, isCharging: false, lowPowerMode: true)
        model.evaluateAutomaticPause()
        await waitUntil { model.runState == .paused && model.automaticPause == .lowPowerMode }
        XCTAssertEqual(model.statusMessage, MioAutomaticPause.lowPowerMode.message)
        battery.status = MioBatteryStatus(level: 0.8, isCharging: false, lowPowerMode: false)
        model.evaluateAutomaticPause()
        XCTAssertEqual(model.runState, .paused, "an automatic pause never restarts by itself")
        await model.stopListening()
        XCTAssertNil(model.automaticPause)
    }

    // MARK: Silence

    func testSilenceAsksAfterTwentyMinutesAndPausesFiveMinutesLater() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var watch = MioSilenceWatch()
        watch.reset(at: start)
        XCTAssertEqual(watch.evaluate(now: start.addingTimeInterval(19 * 60 + 59)), .none)
        XCTAssertEqual(watch.evaluate(now: start.addingTimeInterval(20 * 60)), .ask)
        XCTAssertEqual(watch.evaluate(now: start.addingTimeInterval(21 * 60)), .none, "asked only once")
        XCTAssertEqual(watch.evaluate(now: start.addingTimeInterval(24 * 60 + 59)), .none)
        XCTAssertEqual(watch.evaluate(now: start.addingTimeInterval(25 * 60)), .pause)

        // Speech (or Ja) resets the clock and the question.
        var answered = MioSilenceWatch()
        answered.reset(at: start)
        XCTAssertEqual(answered.evaluate(now: start.addingTimeInterval(20 * 60)), .ask)
        answered.reset(at: start.addingTimeInterval(22 * 60))
        XCTAssertEqual(answered.evaluate(now: start.addingTimeInterval(30 * 60)), .none)
        XCTAssertEqual(answered.evaluate(now: start.addingTimeInterval(42 * 60)), .ask)
    }

    @MainActor
    func testSilencePausesEverydayWithoutAnswerAndJaKeepsListening() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = MioViewModel(repository: fixture.repository, captureFactory: { _, _ in PolicyCapture() })
        var notices: [MioSilenceNotice] = []
        model.onSilenceNotice = { notices.append($0) }
        await model.bootstrap()
        model.beginListening()
        await waitUntil { model.runState == .listening }
        let start = Date.now

        model.evaluateAutomaticPause(now: start.addingTimeInterval(20 * 60 + 1))
        XCTAssertEqual(notices, [.post])
        model.confirmStillListening()
        XCTAssertEqual(model.runState, .listening, "Ja keeps listening without restarting the microphone")
        XCTAssertEqual(notices, [.post, .withdraw])
        model.evaluateAutomaticPause(now: start.addingTimeInterval(25 * 60 + 1))
        XCTAssertEqual(model.runState, .listening, "after Ja the clock starts over")

        // No answer this time: five minutes after the question Mio pauses and says why.
        model.evaluateAutomaticPause(now: start.addingTimeInterval(45 * 60))
        model.evaluateAutomaticPause(now: start.addingTimeInterval(50 * 60 + 1))
        await waitUntil { model.runState == .paused && model.automaticPause == .silence }
        XCTAssertEqual(model.statusMessage, MioAutomaticPause.silence.message)
        XCTAssertEqual(notices.last, .withdraw)
        model.evaluateAutomaticPause(now: start.addingTimeInterval(80 * 60))
        XCTAssertEqual(model.runState, .paused, "no automatic restart")
        await model.stopListening()
    }

    @MainActor
    func testSilenceNeverPausesALesson() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = MioViewModel(repository: fixture.repository, captureFactory: { _, _ in PolicyCapture() })
        var notices: [MioSilenceNotice] = []
        model.onSilenceNotice = { notices.append($0) }
        await model.bootstrap()
        await model.beginLesson(title: "Prov")
        await waitUntil { model.runState == .listening && model.isLessonActive }
        model.evaluateAutomaticPause(now: Date.now.addingTimeInterval(20 * 60 + 1))
        model.evaluateAutomaticPause(now: Date.now.addingTimeInterval(60 * 60))
        XCTAssertEqual(model.runState, .listening)
        XCTAssertFalse(notices.contains(.post))
        await model.stopListening()
    }

    func testStillListeningRouteRoundTripsAndOpensFanga() {
        let route = MioNotificationRoute.stillListening
        XCTAssertEqual(MioNotificationRoute(userInfo: route.userInfo), route)
        XCTAssertNil(MioNotificationRoute(userInfo: ["mioRoute": "stillListening", "extra": "x"]))
        XCTAssertFalse(route.notificationBody.isEmpty)
    }

    @MainActor
    func testStillListeningNotificationOnlyShowsFanga() {
        let navigation = MioNavigationCoordinator()
        navigation.receive(.stillListening)
        navigation.resolvePending { _ in nil }
        XCTAssertEqual(navigation.selectedTab, .capture)
    }

    // MARK: 30 days

    func testRetentionDeletesOnlyEndedEverydaySessionsOlderThanThirtyDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 9))!
        let day: TimeInterval = 24 * 60 * 60
        let old = MioSession(startedAt: now.addingTimeInterval(-40 * day), endedAt: now.addingTimeInterval(-31 * day))
        let borderline = MioSession(startedAt: now.addingTimeInterval(-30 * day), endedAt: now.addingTimeInterval(-29 * day))
        let lesson = MioSession(startedAt: now.addingTimeInterval(-90 * day), endedAt: now.addingTimeInterval(-90 * day + 3_000), captureMode: .lesson)
        let divided = MioSession(startedAt: now.addingTimeInterval(-60 * day), endedAt: now.addingTimeInterval(-60 * day + 3_000))
        let open = MioSession(startedAt: now.addingTimeInterval(-45 * day))
        let older = MioSession(startedAt: now.addingTimeInterval(-50 * day), endedAt: now.addingTimeInterval(-49 * day))
        let expired = MioRetentionPolicy.expiredEverydaySessionIDs([old, borderline, lesson, divided, open, older],
            lessonSessionIDs: [divided.id], now: now, calendar: calendar)
        XCTAssertEqual(expired, [older.id, old.id], "oldest first; lessons, divided sessions, open and recent ones stay")
    }

    @MainActor
    func testPruningRemovesExpiredEverydayTranscriptsButKeepsLessonsAndNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioRetention-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionRepository(storageURL: root.appendingPathComponent("sessions.json"))
        let assistantRepository = MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json"))
        let contentRepository = MioContentRepository(storageURL: root.appendingPathComponent("content.json"), exportDirectoryURL: root)
        let now = Date.now
        let day: TimeInterval = 24 * 60 * 60
        let old = MioSession(startedAt: now.addingTimeInterval(-41 * day), endedAt: now.addingTimeInterval(-40 * day),
                             transcripts: [TranscriptSegment(text: "Gammalt vardagssamtal", containsMio: false)])
        let lesson = MioSession(startedAt: now.addingTimeInterval(-60 * day), endedAt: now.addingTimeInterval(-60 * day + 2_400),
                                transcripts: [TranscriptSegment(text: "Gammal lektion", containsMio: false)], captureMode: .lesson)
        let recent = MioSession(startedAt: now.addingTimeInterval(-2 * day), endedAt: now.addingTimeInterval(-2 * day + 600))
        let generation = await sessions.operationGeneration()
        for session in [old, lesson, recent] {
            let token = try await sessions.operationToken(for: session.id, generation: generation)
            _ = try await sessions.saveCaptureCheckpoint(session, token: token)
        }
        try await assistantRepository.saveLesson(MioLesson(sessionID: lesson.id, title: "Biologi", startedAt: lesson.startedAt,
                                                           endedAt: lesson.endedAt!), session: lesson)
        let note = MioContentItem(kind: .note, title: "Provet gäller procent", sessionID: old.id,
                                  direct: MioDirectRecord(destination: .mioNote, savedAt: old.startedAt))
        _ = try await contentRepository.upsert(note)
        let content = MioContentViewModel(repository: contentRepository)
        let capture = MioViewModel(repository: sessions)
        let workflow = MioWorkflowCoordinator(capture: capture, content: content,
            assistant: MioAssistantViewModel(repository: assistantRepository), analysis: MioAnalysisCoordinator(),
            journal: MioDeletionJournal(storageURL: root.appendingPathComponent("operations.json")),
            systemActions: MioSystemActionPort(cancel: { _ in .success }, removeAll: { .success }))
        await workflow.bootstrap()

        let deleted = await workflow.pruneExpiredEverydaySessions(now: now)
        XCTAssertEqual(deleted, 1)
        let stored = try await sessions.loadSessions()
        XCTAssertEqual(Set(stored.map(\.id)), [lesson.id, recent.id])
        let items = try await contentRepository.loadItems()
        XCTAssertEqual(items.map(\.id), [note.id], "the note stays")
        XCTAssertNil(items.first?.sessionID, "only its link to the deleted session goes")
        let again = await workflow.pruneExpiredEverydaySessions(now: now)
        XCTAssertEqual(again, 0)
    }

    /// Pruning is maintenance (fix 2026-11-20): a "Mio, notera" queued when the phone locks is
    /// saved, the queue's generation is untouched and a lesson start is admitted throughout.
    @MainActor
    func testPruningNeverCancelsQueuedWorkOrBlocksALessonStart() async throws {
        let f = try await retentionFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var feedback: [MioDirectFeedback] = []
        f.capture.directFeedback = { feedback.append($0) }
        let live = MioSession(startedAt: .now.addingTimeInterval(-60),
                              transcripts: [TranscriptSegment(text: "Mio, notera att provet gäller procent", containsMio: true)])
        f.capture.currentSession = live
        f.capture.onFinalizedTranscript?(live)
        let probe = PruneProbe()
        let prune = Task { @MainActor in
            let deleted = await f.workflow.pruneExpiredEverydaySessions(now: .now)
            probe.finished = true
            return deleted
        }
        var checks = 0
        while !probe.finished, checks < 20_000 {
            XCTAssertFalse(MioMaintenanceState.shared.isDeleting, "pruning never takes the exclusive deletion")
            // `beginLesson` is admitted exactly by this call.
            XCTAssertTrue(MioMaintenanceState.shared.beginWrite(), "a lesson start is never refused")
            MioMaintenanceState.shared.endWrite()
            checks += 1
            await Task.yield()
        }
        let deleted = await prune.value
        XCTAssertEqual(deleted, 1)
        await waitUntil { !feedback.isEmpty }
        XCTAssertEqual(feedback, [.saved], "the queued direct note was not cancelled")
        let items = try await f.content.loadItems()
        XCTAssertEqual(items.map(\.title), ["Provet gäller procent"])
        XCTAssertEqual(items.first?.direct?.destination, .mioNote)
        let stored = try await f.sessions.loadSessions()
        XCTAssertFalse(stored.contains { $0.id == f.old.id })
        let document = try await f.assistant.loadDocument()
        XCTAssertFalse(document.suggestions.contains { $0.sessionID == f.old.id }, "its pending proposals went too")
        XCTAssertTrue(f.workflow.pendingLessonIDs.isEmpty)
    }

    @MainActor
    func testPruningWaitsWhileALessonIsStartingAndNeverTakesAnOpenSession() async throws {
        let f = try await retentionFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.capture.isSwitchingCaptureMode = true
        let waiting = await f.workflow.pruneExpiredEverydaySessions(now: .now)
        XCTAssertEqual(waiting, 0, "nothing runs while a lesson starts")
        var stored = try await f.sessions.loadSessions()
        XCTAssertTrue(stored.contains { $0.id == f.old.id })
        f.capture.isSwitchingCaptureMode = false

        // Far in the future everything has expired, but the open session is never taken.
        let open = MioSession(startedAt: .now.addingTimeInterval(-60))
        f.capture.currentSession = open
        let deleted = await f.workflow.pruneExpiredEverydaySessions(now: .now.addingTimeInterval(400 * 24 * 60 * 60))
        XCTAssertEqual(deleted, 1)
        stored = try await f.sessions.loadSessions()
        XCTAssertFalse(stored.contains { $0.id == f.old.id })
        XCTAssertNotNil(f.capture.session(id: open.id))
    }

    @MainActor
    private struct RetentionFixture {
        let root: URL
        let old: MioSession
        let sessions: SessionRepository
        let assistant: MioAssistantRepository
        let content: MioContentRepository
        let capture: MioViewModel
        let workflow: MioWorkflowCoordinator
    }

    /// One everyday session that ended 40 days ago, with a pending proposal from it.
    @MainActor
    private func retentionFixture() async throws -> RetentionFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioRetention-\(UUID())")
        let sessions = SessionRepository(storageURL: root.appendingPathComponent("sessions.json"))
        let assistantRepository = MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json"))
        let contentRepository = MioContentRepository(storageURL: root.appendingPathComponent("content.json"), exportDirectoryURL: root)
        let day: TimeInterval = 24 * 60 * 60
        let old = MioSession(startedAt: .now.addingTimeInterval(-41 * day), endedAt: .now.addingTimeInterval(-40 * day),
                             transcripts: [TranscriptSegment(text: "Mio, kom ihåg att köpa gympaskor", containsMio: true)])
        let generation = await sessions.operationGeneration()
        let token = try await sessions.operationToken(for: old.id, generation: generation)
        _ = try await sessions.saveCaptureCheckpoint(old, token: token)
        _ = try await assistantRepository.detectNewSuggestions(in: old, now: old.startedAt)
        let capture = MioViewModel(repository: sessions)
        let workflow = MioWorkflowCoordinator(capture: capture, content: MioContentViewModel(repository: contentRepository),
            assistant: MioAssistantViewModel(repository: assistantRepository), analysis: MioAnalysisCoordinator(),
            journal: MioDeletionJournal(storageURL: root.appendingPathComponent("operations.json")),
            systemActions: MioSystemActionPort(cancel: { _ in .success }, removeAll: { .success }),
            reminders: .unavailable,
            pendingLessonDefaults: try XCTUnwrap(UserDefaults(suiteName: "MioRetention-\(UUID())")))
        await workflow.bootstrap()
        let pending = try await assistantRepository.loadDocument().suggestions
        XCTAssertTrue(pending.contains { $0.sessionID == old.id }, "fixture: a proposal from the old session")
        return RetentionFixture(root: root, old: old, sessions: sessions, assistant: assistantRepository,
                                content: contentRepository, capture: capture, workflow: workflow)
    }

    // MARK: Helpers

    @MainActor
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<20_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Övergången blev inte klar", file: file, line: line)
    }

    private func fixture() -> (root: URL, repository: SessionRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioEverydayCaptureTests-\(UUID())")
        return (root, SessionRepository(storageURL: root.appendingPathComponent("sessions.json")))
    }
}

@MainActor
private final class PruneProbe {
    var finished = false
}

@MainActor
private final class BatteryBox {
    var status = MioBatteryStatus.unknown
}

private actor PolicyCapture: MioCapturePipeline {
    func start() async throws -> CaptureStartDetails {
        CaptureStartDetails(health: TranscriptionHealth(apiVersion: 1, serverVersion: "fixture", status: "ready",
            metadata: TranscriptionMetadata(model: "fixture", revision: "fixture", backend: "fixture"),
            sampleRate: 16_000, channels: 1, encoding: "pcm_s16le_wav", maxSeconds: 22, maxBytes: 704_044))
    }
    func foreground() async { }
    func stop(discard: Bool) async { }
}
