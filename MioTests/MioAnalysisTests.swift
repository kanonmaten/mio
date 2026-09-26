import Foundation
import XCTest
@testable import Mio

final class MioAnalysisTests: XCTestCase {
    func testFragmentationPreservesEveryCharacterAndBoundsUnicodePayloads() throws {
        let text = String(repeating: "Åäö 👩🏽‍🏫 Vi övar procent. ", count: 800)
        let segment = TranscriptSegment(text: text, containsMio: false)
        let fragments = MioAnalysisFragment.make(from: segment)
        XCTAssertEqual(fragments.map(\.text).joined(), text)
        XCTAssertTrue(fragments.allSatisfy { $0.text.utf8.count <= 4_000 && $0.segmentID == segment.id })
        let batches = MioAnalysisRequest.batches(mode: .lesson, fragments: fragments)
        XCTAssertEqual(batches.flatMap(\.fragments), fragments)
        for batch in batches { XCTAssertLessThanOrEqual(try batch.validatedData().count, 20_000) }
    }

    func testAnalysisRejectsInventedEvidenceAndImplicitMemories() throws {
        let segment = TranscriptSegment(text: "Vi ses på biblioteket klockan tre.", containsMio: false)
        let fragment = try XCTUnwrap(MioAnalysisFragment.make(from: segment).first)
        let request = MioAnalysisRequest(mode: .everyday, timeZone: "Europe/Stockholm", fragments: [fragment])
        for (kind, evidence) in [(MioContentKind.plan, "Påhittat citat"), (.memory, "Vi ses")] {
            let candidate = MioAnalysisCandidate(kind: kind, title: "Bibliotek", body: "", scheduledAt: nil, sourceIDs: [fragment.id], evidence: evidence)
            XCTAssertThrowsError(try MioAnalysisResult(candidates: [candidate], highlights: [], uncertainties: []).validate(against: request))
        }
    }

    func testAnalysisPersistsOnceAndCannotResurrectDeletedSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json"))
        let segment = TranscriptSegment(text: "Jag måste lämna boken i morgon.", containsMio: false)
        let session = MioSession(transcripts: [segment])
        let fragment = try XCTUnwrap(MioAnalysisFragment.make(from: segment).first)
        let request = MioAnalysisRequest(mode: .everyday, timeZone: "Europe/Stockholm", fragments: [fragment])
        let candidate = MioAnalysisCandidate(kind: .task, title: "Lämna boken", body: "Kontrollera tiden.", scheduledAt: nil, sourceIDs: [fragment.id], evidence: segment.text)
        let result = MioAnalysisResult(candidates: [candidate], highlights: [], uncertainties: [])
        let first = try await repository.applyAnalysis(result, request: request, session: session)
        let second = try await repository.applyAnalysis(result, request: request, session: session)
        XCTAssertEqual(first, 1); XCTAssertEqual(second, 0)
        let document = try await repository.loadDocument()
        XCTAssertEqual(document.suggestions.count, 1)
        XCTAssertEqual(document.suggestions.first?.needsDateConfirmation, true)
        XCTAssertEqual(document.suggestions.first?.evidence, segment.text)
        XCTAssertEqual(document.analyses?.count, 1)
        try await repository.removeSuggestion(id: try XCTUnwrap(document.suggestions.first?.id))
        let afterReject = try await repository.applyAnalysis(result, request: request, session: session)
        XCTAssertEqual(afterReject, 0)
        try await repository.deleteSessionData(sessionID: session.id)
        do {
            _ = try await repository.applyAnalysis(result, request: request, session: session)
            XCTFail("Deleted sessions must reject late AI replies")
        } catch { XCTAssertTrue(error is MioAssistantValidationError) }
        let cleared = try await repository.loadDocument()
        XCTAssertTrue(cleared.analyses?.isEmpty == true)
    }

    func testLessonCaptureDoesNotGenerateEverydayCommands() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json"))
        let session = MioSession(transcripts: [TranscriptSegment(text: "Mio anteckna ett exempel", containsMio: true)], captureMode: .lesson)
        let count = try await repository.detectSuggestions(in: session)
        XCTAssertEqual(count, 0)
        let decoded = try JSONDecoder().decode(MioSession.self, from: JSONEncoder().encode(session))
        XCTAssertTrue(decoded.isLesson)
    }

    @MainActor
    func testActivationExcludesOldTextIncludingSuspendedEverydaySession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json")))
        var everyday = MioSession(transcripts: [TranscriptSegment(text: "Gammal privat text", containsMio: false)])
        let oldID = everyday.transcripts[0].id
        let lesson = MioSession(captureMode: .lesson)
        let sent = expectation(description: "New everyday text is sent")
        let connection = MioCloudConnection(endpoint: URL(string: "https://example.invalid/v1/ask")!, token: "synthetic")
        let coordinator = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true }, send: { request, _ in
            XCTAssertEqual(request.fragments.count, 1)
            XCTAssertNotEqual(request.fragments.first?.segmentID, oldID)
            XCTAssertEqual(request.fragments.first?.text, "Ny plan utan väckningsord")
            sent.fulfill()
            return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
        }, wait: { _ in })
        try coordinator.enable(existingSessions: [everyday, lesson])
        everyday.transcripts.append(TranscriptSegment(text: "Ny plan utan väckningsord", containsMio: false))
        coordinator.observe(everyday, assistant: assistant)
        await fulfillment(of: [sent], timeout: 2)
        coordinator.disable()
    }

    @MainActor
    func testPauseDisableAndDeletionCancelQueuedTextBeforeTransport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json")))
        let connection = MioCloudConnection(endpoint: URL(string: "https://example.invalid/v1/ask")!, token: "synthetic")
        let session = MioSession(transcripts: [TranscriptSegment(text: "Vi ses i morgon", containsMio: false)])
        for action in 0..<3 {
            let waiting = expectation(description: "Batch waits for aggregation")
            let cancelled = expectation(description: "Wait observes cancellation")
            let coordinator = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true }, send: { _, _ in
                XCTFail("Cancelled text must never reach the transport")
                return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
            }, wait: { _ in
                waiting.fulfill()
                do { try await Task.sleep(for: .seconds(60)) }
                catch { cancelled.fulfill(); throw error }
            })
            try coordinator.enable(existingSessions: [])
            coordinator.observe(session, assistant: assistant)
            await fulfillment(of: [waiting], timeout: 2)
            if action == 0 { coordinator.pauseEveryday(assistant: assistant) }
            else if action == 1 { coordinator.disable() }
            else { coordinator.cancel(sessionID: session.id, assistant: assistant) }
            // Cancellation must wake a pending aggregation delay without waiting a minute.
            await fulfillment(of: [cancelled], timeout: 2)
            XCTAssertFalse(coordinator.isWorking)
            coordinator.disable()
        }
    }

    @MainActor
    func testCurrentSessionSnapshotWinsOverEarlierPersistedCopy() {
        let model = MioViewModel()
        let original = MioSession(captureMode: .lesson)
        model.previousSessions = [original]
        var updated = original
        updated.transcripts = [TranscriptSegment(text: "Ny text", containsMio: false)]
        model.currentSession = updated
        XCTAssertEqual(model.allSessions.first?.transcripts.count, 1)
    }
}
