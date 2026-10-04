import Foundation
import XCTest
@testable import Mio

final class MioLessonFreshnessTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(text: String = "Original definition.") -> MioSession {
        MioSession(startedAt: date, endedAt: date.addingTimeInterval(60), transcripts: [
            TranscriptSegment(createdAt: date, audioStartedAt: date, audioEndedAt: date.addingTimeInterval(30),
                              text: text, containsMio: false)
        ], title: "Syntetisk lektion", captureMode: .lesson)
    }

    private func sourceObject(segment: TranscriptSegment, revision: Int) -> [String: Any] {
        ["segmentID": segment.id.uuidString, "correctionRevision": revision]
    }

    private func record(for session: MioSession, sourceRevisions: [[String: Any]]? = nil) throws -> MioAnalysisRecord {
        let fragment = try XCTUnwrap(session.transcripts.flatMap(MioAnalysisFragment.make).first)
        let record = MioAnalysisRecord(id: UUID(), sessionID: session.id, fragmentIDs: [fragment.id],
            highlights: [], uncertainties: [], createdAt: date,
            sections: [MioLessonSection(heading: "Definition", body: "Bevara denna sparade förklaring.",
                sourceIDs: [fragment.id], evidence: fragment.text)])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        if let sourceRevisions { object["sourceRevisions"] = sourceRevisions }
        return try JSONDecoder().decode(MioAnalysisRecord.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testCorrectedSourceMakesExistingNotesOlderWithoutRewritingTheirContentOrEvidence() throws {
        let original = session()
        let part = try record(for: original, sourceRevisions: [sourceObject(segment: original.transcripts[0], revision: 0)])
        var corrected = original
        corrected.transcripts[0].correctedText = "Rättad definition."
        corrected.transcripts[0].correctionRevision = 1
        let document = MioLessonDocument(session: corrected, records: [part])
        XCTAssertTrue(document.markdown.contains("Underlaget har rättats efter bearbetningen"))
        XCTAssertTrue(document.markdown.contains("Bevara denna sparade förklaring."))
        XCTAssertEqual(document.orderedRecords.first?.sections?.first?.evidence, "Original definition.")
        XCTAssertEqual(corrected.transcripts[0].text, "Original definition.")
    }

    func testLegacyPartWithMissingRevisionIsUnknownRatherThanCurrent() throws {
        let original = session()
        let part = try record(for: original)
        let document = MioLessonDocument(session: original, records: [part])
        XCTAssertTrue(document.isComplete)
        XCTAssertTrue(document.markdown.contains("Källans aktualitet är okänd"))
        XCTAssertFalse(document.markdown.contains("Källan är aktuell"))
        XCTAssertEqual(document.orderedRecords, [part])
    }

    func testMatchingRevisionCanBeShownCurrentAndMissingSegmentStaysUnknown() throws {
        let original = session()
        let part = try record(for: original, sourceRevisions: [sourceObject(segment: original.transcripts[0], revision: 0)])
        XCTAssertTrue(MioLessonDocument(session: original, records: [part]).markdown.contains("Källan är aktuell"))
        var missing = original
        missing.transcripts = []
        XCTAssertTrue(MioLessonDocument(session: missing, records: [part]).markdown.contains("Källans aktualitet är okänd"))
    }

    func testLegacyCorrectedSegmentWithoutKnownRevisionDoesNotFabricateCurrentFreshness() throws {
        var corrected = session()
        corrected.transcripts[0].correctedText = "Äldre rättning utan revisionsbevis."
        let part = try record(for: corrected, sourceRevisions: [sourceObject(segment: corrected.transcripts[0], revision: 0)])
        XCTAssertTrue(MioLessonDocument(session: corrected, records: [part]).markdown.contains("Källans aktualitet är okänd"))
    }

    func testSavedPartCapturesActualSubmittedRevisionLocallyWithoutChangingRequestWire() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json"))
        var submitted = session()
        submitted.transcripts[0].correctedText = "Definition rättad vid godkännande."
        submitted.transcripts[0].correctionRevision = 1
        let fragments = submitted.transcripts.flatMap(MioAnalysisFragment.make)
        let request = MioAnalysisRequest(mode: .lesson, timeZone: "Europe/Stockholm", fragments: fragments)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: request.validatedData()) as? [String: Any])
        let wireFragments = try XCTUnwrap(wire["fragments"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(wireFragments.first).keys), ["id", "text", "occurredAt"])
        let result = MioAnalysisResult(candidates: [], highlights: [], uncertainties: [], sections: [
            MioLessonSection(heading: "Definition", body: "En sparad förklaring.", sourceIDs: [fragments[0].id], evidence: fragments[0].text)
        ], metadata: MioAnalysisMetadata(provider: "openai", model: "gpt-6-luna", promptVersion: "fixture", lessonIntervalSeconds: 60))
        _ = try await repository.applyAnalysis(result, request: request, session: submitted)
        let loaded = try await MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json")).loadDocument()
        let part = try XCTUnwrap(loaded.analyses?.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(part)) as? [String: Any])
        let revisions = try XCTUnwrap(object["sourceRevisions"] as? [[String: Any]])
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(revisions.first?["segmentID"] as? String, submitted.transcripts[0].id.uuidString)
        XCTAssertEqual(revisions.first?["correctionRevision"] as? Int, 1)
        var later = submitted
        later.transcripts[0].correctedText = "Ännu senare rättning."
        later.transcripts[0].correctionRevision = 2
        XCTAssertTrue(MioLessonDocument(session: later, records: [part]).markdown.contains("Underlaget har rättats efter bearbetningen"))
    }

    func testPersistedFreshnessRejectsNegativeDuplicateAndUnrelatedSegmentIdentity() async throws {
        let original = session()
        for revisions in [[sourceObject(segment: original.transcripts[0], revision: -1)],
                          [sourceObject(segment: original.transcripts[0], revision: 0), sourceObject(segment: original.transcripts[0], revision: 0)],
                          [["segmentID": UUID().uuidString, "correctionRevision": 0]]] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let value = try record(for: original, sourceRevisions: revisions)
            let document = MioAssistantStoreDocument(analyses: [value])
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(document).write(to: root.appendingPathComponent("assistant.json"))
            do {
                _ = try await MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json")).loadDocument()
                XCTFail("Invalid source freshness must reject the document rather than silently discard metadata")
            } catch { XCTAssertTrue(error is MioAssistantRepositoryError) }
        }
    }

    @MainActor
    func testNewLessonCapturesSourceButEditingTitleDoesNotRecaptureLaterCorrection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json"))
        let assistant = MioAssistantViewModel(repository: repository)
        let original = session()
        let saved = await assistant.saveLessonOutcome(session: original, title: "Definition", note: "Min anteckning.",
            startedAt: original.startedAt, endedAt: try XCTUnwrap(original.endedAt))
        XCTAssertEqual(saved, .success)
        let created = try XCTUnwrap(assistant.lessons.first)
        XCTAssertEqual(created.sourceRevisions?.first?.correctionRevision, 0)
        XCTAssertEqual(created.freshness(in: original), .current)
        var corrected = original
        corrected.transcripts[0].correctedText = "Ny rättning."
        corrected.transcripts[0].correctionRevision = 1
        let updated = await assistant.saveLessonOutcome(id: created.id, session: corrected,
            title: "Ny rubrik", note: "Min redigerade anteckning.", startedAt: created.startedAt, endedAt: created.endedAt)
        XCTAssertEqual(updated, .success)
        let edited = try XCTUnwrap(assistant.lessons.first)
        XCTAssertEqual(edited.freshness(in: corrected), .older)
        XCTAssertEqual(edited.sourceRevisions, created.sourceRevisions)
        XCTAssertEqual(edited.note, "Min redigerade anteckning.")
        XCTAssertEqual(corrected.transcripts[0].text, "Original definition.")
    }

    @MainActor
    func testEditingLegacyLessonPreservesUnknownFreshnessAndItsManualNote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json"))
        let original = session()
        let old = MioLesson(sessionID: original.id, title: "Äldre lektion", note: "Egen text.",
            startedAt: original.startedAt, endedAt: try XCTUnwrap(original.endedAt))
        try await repository.saveLesson(old, session: original)
        let assistant = MioAssistantViewModel(repository: repository)
        let saved = await assistant.saveLessonOutcome(id: old.id, session: original, title: "Redigerad rubrik",
            note: "Egen bevarad text.", startedAt: old.startedAt, endedAt: old.endedAt)
        XCTAssertEqual(saved, .success)
        let edited = try XCTUnwrap(assistant.lessons.first)
        XCTAssertNil(edited.sourceRevisions)
        XCTAssertEqual(edited.freshness(in: original), .unknown)
        XCTAssertEqual(edited.note, "Egen bevarad text.")
    }

    func testPartialRestartKeepsOldPartEvidenceAndContinuesOnlyMissingText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("assistant.json")
        let repository = MioAssistantRepository(storageURL: url)
        var original = session()
        original.transcripts.append(TranscriptSegment(createdAt: date.addingTimeInterval(31),
            audioStartedAt: date.addingTimeInterval(31), audioEndedAt: date.addingTimeInterval(50),
            text: "Andra definitionen.", containsMio: false))
        let fragments = original.transcripts.flatMap(MioAnalysisFragment.make)
        let metadata = MioAnalysisMetadata(provider: "openai", model: "gpt-6-luna", promptVersion: "fixture", lessonIntervalSeconds: 60)
        func result(_ fragment: MioAnalysisFragment) -> MioAnalysisResult {
            MioAnalysisResult(candidates: [], highlights: [], uncertainties: [], sections: [
                MioLessonSection(heading: "Definition", body: "Bevarad del: " + fragment.text,
                    sourceIDs: [fragment.id], evidence: fragment.text)
            ], metadata: metadata)
        }
        let first = MioAnalysisRequest(mode: .lesson, timeZone: "Europe/Stockholm", fragments: [fragments[0]])
        _ = try await repository.applyAnalysis(result(fragments[0]), request: first, session: original)
        let restarted = MioAssistantRepository(storageURL: url)
        let before = try await restarted.loadDocument()
        var corrected = original
        corrected.transcripts[0].correctedText = "Rättad första definition."
        corrected.transcripts[0].correctionRevision = 1
        let partial = MioLessonDocument(session: corrected, records: before.analyses ?? [])
        XCTAssertEqual(partial.remainingCount, 1)
        XCTAssertEqual(partial.remainingRequestCount, 1)
        XCTAssertEqual(partial.freshness, .older)
        XCTAssertFalse(partial.isComplete)
        let duplicate = try await restarted.applyAnalysis(result(fragments[0]), request: first, session: original)
        XCTAssertEqual(duplicate, 0)
        let second = MioAnalysisRequest(mode: .lesson, timeZone: "Europe/Stockholm", fragments: [fragments[1]])
        _ = try await restarted.applyAnalysis(result(fragments[1]), request: second, session: corrected)
        let after = try await restarted.loadDocument()
        XCTAssertEqual(after.analyses?.count, 2)
        XCTAssertEqual(after.analyses?.first?.sections?.first?.evidence, "Original definition.")
        XCTAssertEqual(after.analyses?.first?.sourceRevisions?.first?.correctionRevision, 0)
        let complete = MioLessonDocument(session: corrected, records: after.analyses ?? [])
        XCTAssertTrue(complete.isComplete)
        XCTAssertEqual(complete.remainingRequestCount, 0)
        XCTAssertEqual(complete.freshness, .older)
        XCTAssertTrue(complete.markdown.contains("Original definition."))
        XCTAssertTrue(complete.markdown.contains("Underlaget har rättats efter bearbetningen"))
    }

    @MainActor
    func testCorrectingStoredLessonThroughWorkflowNeverAutomaticallyResendsExpandedText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionRepository(storageURL: root.appendingPathComponent("sessions.json"))
        let original = session()
        let generation = await sessions.operationGeneration()
        let token = try await sessions.operationToken(for: original.id, generation: generation)
        _ = try await sessions.saveCaptureCheckpoint(original, token: token)
        let diagnostics = MioDiagnosticsRepository(storageURL: root.appendingPathComponent("diagnostics.json"))
        let capture = MioViewModel(repository: sessions, diagnostics: diagnostics, captureFactory: { _, _ in
            XCTFail("Correcting text must not restart the microphone")
            throw MioError.microphoneDenied
        })
        let assistant = MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json")))
        let content = MioContentViewModel(repository: MioContentRepository(storageURL: root.appendingPathComponent("content.json")))
        var calls = 0
        let connection = syntheticCloudConnection()
        let analysis = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true },
            prepareConnection: { try await syntheticPreparedConnection($0, task: $1) }, send: { _, _ in
                calls += 1
                return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
            }, wait: { _ in }, now: { self.date.addingTimeInterval(100) })
        let workflow = MioWorkflowCoordinator(capture: capture, content: content, assistant: assistant, analysis: analysis,
            journal: MioDeletionJournal(storageURL: root.appendingPathComponent("operations.json")), diagnostics: diagnostics,
            systemActions: MioSystemActionPort(cancel: { _ in .success }, removeAll: { .success }), clearCredentials: {})
        await workflow.bootstrap()
        try await analysis.enable(existingSessions: capture.allSessions)
        let saved = await capture.correctTranscript(sessionID: original.id, segmentID: original.transcripts[0].id,
            text: String(repeating: "Rättat lektionsunderlag. ", count: 200))
        XCTAssertTrue(saved)
        let corrected = try XCTUnwrap(capture.session(id: original.id))
        XCTAssertGreaterThan(corrected.transcripts.flatMap(MioAnalysisFragment.make).count, 1)
        analysis.observe(corrected, assistant: assistant)
        XCTAssertFalse(analysis.isWorking)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(corrected.transcripts[0].text, original.transcripts[0].text)
        XCTAssertTrue(assistant.analyses.isEmpty)
        analysis.disable()
    }

    func testCorrectionShorteningSourceDoesNotMovePersistedPartsAfterLaterSegments() throws {
        var original = session(text: String(repeating: "Första ämnet. ", count: 600))
        original.transcripts.append(TranscriptSegment(createdAt: date.addingTimeInterval(31),
            audioStartedAt: date.addingTimeInterval(31), audioEndedAt: date.addingTimeInterval(50),
            text: "Andra ämnet.", containsMio: false))
        let fragments = original.transcripts.flatMap(MioAnalysisFragment.make)
        XCTAssertGreaterThan(fragments.count, 2)
        let records = fragments.enumerated().map { index, fragment in
            MioAnalysisRecord(id: UUID(), sessionID: original.id, fragmentIDs: [fragment.id], highlights: [],
                uncertainties: [], createdAt: date, sections: [
                    MioLessonSection(heading: "Sparad del \(index)", body: "Förklaring \(index)",
                        sourceIDs: [fragment.id], evidence: String(fragment.text.prefix(20)))
                ], sourceRevisions: [MioSourceRevision(segmentID: fragment.segmentID!, correctionRevision: 0)])
        }
        var shortened = original
        shortened.transcripts[0].correctedText = "Kort rättad text."
        shortened.transcripts[0].correctionRevision = 1
        let document = MioLessonDocument(session: shortened, records: records)
        XCTAssertEqual(document.orderedRecords.map(\.id), records.map(\.id))
        XCTAssertEqual(document.freshness, .older)
        XCTAssertTrue(document.markdown.contains("Förklaring 1"))
    }
}
