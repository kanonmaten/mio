import Foundation
import XCTest
@testable import Mio

final class MioCaptureLifecycleTests: XCTestCase {
    @MainActor
    func testCaptureDiagnosticIsPersistedThroughTheApplicationBoundary() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let diagnostics = MioDiagnosticsRepository(storageURL: fixture.root.appendingPathComponent("diagnostics.json"))
        let model = MioViewModel(repository: fixture.repository, diagnostics: diagnostics, captureFactory: { _, handlers in
            Task { await handlers.diagnostic(STTDiagnostic(kind: .retry, count: 1, category: "transport_retry")) }
            return LifecycleCapture()
        })
        await model.bootstrap()
        model.beginListening()
        await waitUntil { model.runState == .listening }
        for _ in 0..<1_000 {
            if !(await diagnostics.snapshot()).events.isEmpty { break }
            await Task.yield()
        }
        let events = await diagnostics.snapshot().events
        XCTAssertEqual(events.first?.transcription?.kind, .retry)
        XCTAssertEqual(events.first?.transcription?.count, 1)
        await model.stopListening()
    }

    @MainActor
    func testEverydayLessonEverydayRetainsBothSessionsUntilExplicitResume() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = MioViewModel(repository: fixture.repository, captureFactory: { _, _ in LifecycleCapture() })
        await model.bootstrap()
        model.beginListening()
        await waitUntil { model.runState == .listening }
        let everydayID = try XCTUnwrap(model.currentSession?.id)
        await model.beginLesson(title: "Procent")
        await waitUntil { model.runState == .listening && model.isLessonActive }
        let lessonID = try XCTUnwrap(model.currentSession?.id)
        XCTAssertNotEqual(everydayID, lessonID)
        XCTAssertEqual(Set(model.allSessions.map(\.id)), Set([everydayID, lessonID]))
        await model.stopListening()
        XCTAssertEqual(model.currentSession?.id, everydayID)
        XCTAssertNil(model.currentSession?.endedAt)
        XCTAssertEqual(model.runState, .paused)
        XCTAssertNotNil(model.session(id: lessonID)?.endedAt)
        model.beginListening()
        await waitUntil { model.runState == .listening }
        XCTAssertEqual(model.currentSession?.id, everydayID)
        await model.stopListening()
        let stored = try await fixture.repository.loadSessions()
        XCTAssertEqual(Set(stored.map(\.id)), Set([everydayID, lessonID]))
        XCTAssertTrue(stored.allSatisfy { $0.endedAt != nil })
    }

    @MainActor
    func testFailedLessonStartupRestoresPausedEveryday() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var starts = 0
        let model = MioViewModel(repository: fixture.repository, captureFactory: { _, _ in
            starts += 1
            return LifecycleCapture(failure: starts == 2)
        })
        await model.bootstrap()
        model.beginListening()
        await waitUntil { model.runState == .listening }
        let everydayID = try XCTUnwrap(model.currentSession?.id)
        await model.beginLesson(title: "Nekad mikrofon")
        await waitUntil { model.currentSession?.id == everydayID && model.runState == .paused }
        XCTAssertEqual(model.currentSession?.id, everydayID)
        XCTAssertEqual(model.runState, .paused)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.allSessions.count, 2)
        XCTAssertNotNil(model.allSessions.first(where: \.isLesson)?.endedAt)
        await model.stopListening()
    }

    @MainActor
    func testCancelledLessonStartupRetainsLessonAndPausedEveryday() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let held = LifecycleCapture(holdsStart: true)
        var starts = 0
        let model = MioViewModel(repository: fixture.repository, captureFactory: { _, _ in
            starts += 1
            return starts == 2 ? held : LifecycleCapture()
        })
        await model.bootstrap()
        model.beginListening()
        await waitUntil { model.runState == .listening }
        let everydayID = try XCTUnwrap(model.currentSession?.id)
        await model.beginLesson(title: "Avbruten")
        await held.waitForStart()
        model.cancelPreparation()
        await held.releaseStart()
        await waitUntil { model.currentSession?.id == everydayID && model.runState == .paused }
        XCTAssertEqual(model.allSessions.count, 2)
        XCTAssertNotNil(model.allSessions.first(where: \.isLesson)?.endedAt)
        XCTAssertNil(model.errorMessage)
        await model.stopListening()
    }

    @MainActor
    func testSuccessfulLessonSaveFinalizesDespiteEarlierPresentationError() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = MioViewModel(repository: fixture.repository, captureFactory: { _, _ in LifecycleCapture() })
        await model.bootstrap()
        await model.beginLesson(title: "Sparad")
        await waitUntil { model.runState == .listening }
        let lessonID = try XCTUnwrap(model.currentSession?.id)
        var finished: MioSession?
        model.onLessonFinished = { finished = $0 }
        model.errorMessage = "Ett tidigare mikrofonfel"
        await model.stopListening()
        XCTAssertEqual(finished?.id, lessonID)
        XCTAssertNotNil(finished?.endedAt)
        XCTAssertEqual(model.runState, .off)
        XCTAssertNotNil(model.session(id: lessonID))
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Livscykelövergången blev inte klar", file: file, line: line)
    }

    private func fixture() -> (root: URL, repository: SessionRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioCaptureLifecycleTests-\(UUID())")
        return (root, SessionRepository(storageURL: root.appendingPathComponent("sessions.json")))
    }
}

private actor LifecycleCapture: MioCapturePipeline {
    private let failure: Bool
    private let holdsStart: Bool
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var started = false

    init(failure: Bool = false, holdsStart: Bool = false) {
        self.failure = failure; self.holdsStart = holdsStart
    }

    func start() async throws -> CaptureStartDetails {
        started = true
        if holdsStart {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
                startWaiters.forEach { $0.resume() }; startWaiters = []
            }
        }
        try Task.checkCancellation()
        if failure { throw MioError.microphoneDenied }
        return CaptureStartDetails(health: TranscriptionHealth(apiVersion: 1, serverVersion: "fixture", status: "ready",
            metadata: TranscriptionMetadata(model: "fixture", revision: "fixture", backend: "fixture"),
            sampleRate: 16_000, channels: 1, encoding: "pcm_s16le_wav", maxSeconds: 22, maxBytes: 704_044))
    }

    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseStart() { startContinuation?.resume(); startContinuation = nil }
    func foreground() async { }
    func stop(discard: Bool) async { }
}
