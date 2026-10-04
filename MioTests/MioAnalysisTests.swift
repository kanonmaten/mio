import Foundation
import XCTest
@testable import Mio

final class MioAnalysisTests: XCTestCase {
    func testAnalysisDatesRejectNormalizedImpossibleCalendarComponents() throws {
        for date in ["2026-02-29T12:00:00Z", "2026-04-31T12:00:00Z", "2026-10-01T24:00:00Z",
                     "2026-10-01T12:00:00+24:00", "2026-10-01T12:00:00+01:60"] {
            XCTAssertNil(MioAnalysisResult.parseDate(date), date)
        }
        XCTAssertNotNil(MioAnalysisResult.parseDate("2024-02-29T12:00:00+01:30"))
        XCTAssertNotNil(MioAnalysisResult.parseDate("2026-10-01T12:00:00.123Z"))
    }

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
        let coordinator = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true }, prepareConnection: { try await syntheticPreparedConnection($0, task: $1) }, send: { request, _ in
            XCTAssertEqual(request.fragments.count, 1)
            XCTAssertNotEqual(request.fragments.first?.segmentID, oldID)
            XCTAssertEqual(request.fragments.first?.text, "Ny plan utan väckningsord")
            sent.fulfill()
            return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
        }, wait: { _ in })
        let delayed = TranscriptSegment(audioStartedAt: .now.addingTimeInterval(-30), text: "Sent svar från äldre ljud", containsMio: false)
        try await coordinator.enable(existingSessions: [everyday, lesson])
        everyday.transcripts.append(delayed)
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
        for action in 0..<3 {
            let waiting = expectation(description: "Batch waits for aggregation")
            let cancelled = expectation(description: "Wait observes cancellation")
            let coordinator = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true }, prepareConnection: { try await syntheticPreparedConnection($0, task: $1) }, send: { _, _ in
                XCTFail("Cancelled text must never reach the transport")
                return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
            }, wait: { _ in
                waiting.fulfill()
                do { try await Task.sleep(for: .seconds(60)) }
                catch { cancelled.fulfill(); throw error }
            })
            try await coordinator.enable(existingSessions: [])
            let session = MioSession(transcripts: [TranscriptSegment(text: "Vi ses i morgon", containsMio: false)])
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

extension MioAnalysisTests {
    private var lessonMetadata: MioAnalysisMetadata {
        MioAnalysisMetadata(provider: "groq", model: "qwen/qwen3.8-27b", promptVersion: "2026-09-28.1", lessonIntervalSeconds: 60)
    }

    func testDetailedLessonRejectsInventedSourcesAndKeepsCalculationSteps() throws {
        let segment = TranscriptSegment(text: "20 procent av 50 är 0,20 gånger 50 = 10.", containsMio: false)
        let fragment = try XCTUnwrap(MioAnalysisFragment.make(from: segment).first)
        let request = MioAnalysisRequest(mode: .lesson, timeZone: "Europe/Stockholm", fragments: [fragment])
        let section = MioLessonSection(heading: "Procent", body: "1. Skriv 20 % som 0,20.\n2. Multiplicera med 50.\n3. Svaret är 10.",
                                       sourceIDs: [fragment.id], evidence: segment.text)
        let result = MioAnalysisResult(candidates: [], highlights: [], uncertainties: [], sections: [section], metadata: lessonMetadata)
        XCTAssertNoThrow(try result.validate(against: request))
        var invalid = result
        invalid.sections = [MioLessonSection(heading: "Procent", body: section.body, sourceIDs: [fragment.id], evidence: "påhittat")]
        XCTAssertThrowsError(try invalid.validate(against: request))
        invalid = result; invalid.metadata = nil
        XCTAssertThrowsError(try invalid.validate(against: request))
    }

    func testLessonDocumentOrdersPartsAndLabelsPartialCopies() throws {
        let first = TranscriptSegment(text: "Första exemplet", containsMio: false)
        let second = TranscriptSegment(text: "Andra exemplet", containsMio: false)
        let session = MioSession(endedAt: .now, transcripts: [first, second], title: "Matematik", captureMode: .lesson)
        let fragments = session.transcripts.flatMap(MioAnalysisFragment.make)
        func record(_ index: Int) -> MioAnalysisRecord {
            MioAnalysisRecord(id: UUID(), sessionID: session.id, fragmentIDs: [fragments[index].id], highlights: [],
                              uncertainties: index == 1 ? ["Ett ord var otydligt"] : [], createdAt: .now,
                              sections: [MioLessonSection(heading: "Del \(index + 1)", body: fragments[index].text,
                                                          sourceIDs: [fragments[index].id], evidence: fragments[index].text)],
                              metadata: lessonMetadata)
        }
        let partial = MioLessonDocument(session: session, records: [record(0)])
        XCTAssertFalse(partial.isComplete)
        XCTAssertTrue(partial.markdown.contains("Ofullständiga"))
        let complete = MioLessonDocument(session: session, records: [record(1), record(0)])
        XCTAssertTrue(complete.isComplete)
        XCTAssertEqual(complete.completedCount, 2)
        XCTAssertEqual(complete.orderedRecords.first?.fragmentIDs, [fragments[0].id])
        XCTAssertTrue(complete.markdown.contains("# Matematik"))
        XCTAssertTrue(complete.markdown.contains("Ett ord var otydligt"))
        XCTAssertFalse(complete.markdown.contains(fragments[0].id))
        XCTAssertFalse(complete.markdown.contains("qwen/"))
    }

    func testOldAnalysisRecordsDecodeWithoutDetailedNotes() throws {
        let original = MioAnalysisRecord(id: UUID(), sessionID: UUID(), fragmentIDs: [], highlights: [], uncertainties: [], createdAt: .now)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MioAnalysisRecord.self, from: data)
        XCTAssertNil(decoded.sections)
        XCTAssertNil(decoded.metadata)
    }

    func testLessonBatchesKeepAllTextWithinSmallerBudget() throws {
        let segments = (0..<18).map { _ in TranscriptSegment(text: String(repeating: "Svensk lektion. ", count: 100), containsMio: false) }
        let fragments = segments.flatMap(MioAnalysisFragment.make)
        let requests = MioAnalysisRequest.batches(mode: .lesson, fragments: fragments)
        XCTAssertEqual(requests.flatMap(\.fragments), fragments)
        for request in requests {
            XCTAssertLessThanOrEqual(request.fragments.reduce(0) { $0 + $1.text.utf8.count }, 3_500)
            _ = try request.validatedData()
        }
    }

    func testWireRejectsUnknownFieldsAndMissingNullableFields() throws {
        let valid: [String: Any] = ["candidates": [], "sections": [], "uncertainties": [],
            "metadata": ["provider": "groq", "model": "qwen/qwen3.8-27b", "promptVersion": "test", "lessonIntervalSeconds": 60]]
        XCTAssertNoThrow(try MioCloudService.validateWire(JSONSerialization.data(withJSONObject: valid), lesson: true))
        var extra = valid; extra["slides"] = []
        XCTAssertThrowsError(try MioCloudService.validateWire(JSONSerialization.data(withJSONObject: extra), lesson: true))
        var missing = valid
        missing["candidates"] = [["kind": "task", "title": "Läxa", "body": "", "sourceIDs": [], "evidence": "Läxa"]]
        XCTAssertThrowsError(try MioCloudService.validateWire(JSONSerialization.data(withJSONObject: missing), lesson: true))
        XCTAssertThrowsError(try MioCloudService.validateWire(Data("{\"answer\":\"Hej\",\"tools\":[]}".utf8), lesson: false, ask: true))
    }

    @MainActor
    func testResumeLessonUsesPersistedDetailedParts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json"))
        let first = TranscriptSegment(text: "Definitionen är viktig.", containsMio: false)
        let second = TranscriptSegment(text: "Sedan kommer exemplet.", containsMio: false)
        let session = MioSession(endedAt: .now, transcripts: [first, second], captureMode: .lesson)
        let fragments = session.transcripts.flatMap(MioAnalysisFragment.make)
        let request = MioAnalysisRequest(mode: .lesson, timeZone: "Europe/Stockholm", fragments: [fragments[0]])
        // Old highlights must not hide fragments from the new detailed-note pass.
        _ = try await repository.applyAnalysis(MioAnalysisResult(candidates: [], highlights: [], uncertainties: []), request: request, session: session)
        let detailed = MioAnalysisResult(candidates: [], highlights: [], uncertainties: [], sections: [
            MioLessonSection(heading: "Definition", body: first.text, sourceIDs: [fragments[0].id], evidence: first.text)
        ], metadata: lessonMetadata)
        _ = try await repository.applyAnalysis(detailed, request: request, session: session)
        let reloaded = MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json"))
        let assistant = MioAssistantViewModel(repository: reloaded)
        await assistant.bootstrap()
        XCTAssertEqual(assistant.analyzedFragmentIDs(for: session.id, detailedLesson: true), [fragments[0].id])
        let sent = expectation(description: "Only unfinished part sent")
        let connection = MioCloudConnection(endpoint: URL(string: "https://example.invalid/v1/ask")!, token: "synthetic")
        let metadata = lessonMetadata
        let coordinator = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true }, prepareConnection: { try await syntheticPreparedConnection($0, task: $1) }, send: { request, _ in
            XCTAssertEqual(request.fragments.map(\.id), [fragments[1].id])
            sent.fulfill()
            return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [], sections: [], metadata: metadata)
        }, wait: { seconds in XCTAssertGreaterThan(seconds, 0) })
        try await coordinator.enable(existingSessions: [session])
        coordinator.summarizeLesson(session, assistant: assistant)
        await fulfillment(of: [sent], timeout: 2)
        coordinator.disable()
    }
}

extension MioAnalysisTests {
    @MainActor
    func testLessonPacingWaitsForServerIntervalAndCancellationKeepsSavedPart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json")))
        let segments = (0..<2).map { _ in TranscriptSegment(text: String(repeating: "A", count: 3400), containsMio: false) }
        let session = MioSession(endedAt: .now, transcripts: segments, captureMode: .lesson)
        let waiting = expectation(description: "Server pacing applied before second part")
        let cancelled = expectation(description: "Pending part cancelled")
        var calls = 0
        let connection = MioCloudConnection(endpoint: URL(string: "https://example.invalid/v1/ask")!, token: "synthetic")
        let coordinator = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true }, prepareConnection: { try await syntheticPreparedConnection($0, task: $1) }, send: { _, _ in
            calls += 1
            return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [], sections: [], metadata:
                MioAnalysisMetadata(provider: "groq", model: "qwen/qwen3.8-27b", promptVersion: "test", lessonIntervalSeconds: 120))
        }, wait: { seconds in
            XCTAssertGreaterThan(seconds, 100)
            XCTAssertLessThanOrEqual(seconds, 120)
            waiting.fulfill()
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled.fulfill(); throw error }
        })
        try await coordinator.enable(existingSessions: [session])
        coordinator.summarizeLesson(session, assistant: assistant)
        await fulfillment(of: [waiting], timeout: 2)
        coordinator.disable()
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(assistant.analyzedFragmentIDs(for: session.id, detailedLesson: true).count, 1)
        XCTAssertFalse(MioLessonDocument(session: session, records: assistant.analyses).isComplete)
    }
}
