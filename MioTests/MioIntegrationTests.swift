import Foundation
import XCTest
@testable import Mio

final class MioIntegrationTests: XCTestCase {
    @MainActor
    func testApprovedSuggestionIDRemainsStableAcrossContentSaveRetries() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = MioContentRepository(storageURL: fixture.content, exportDirectoryURL: fixture.exports)
        let model = MioContentViewModel(repository: repository)
        await model.bootstrap()
        let suggestion = MioSuggestion(kind: .task, title: "Ta med boken")
        let first = await model.save(
            id: suggestion.id, kind: suggestion.kind, title: suggestion.title, body: "",
            scheduledAt: suggestion.scheduledAt, isCompleted: false, sessionID: nil
        )
        XCTAssertTrue(first)
        let createdAt = try XCTUnwrap(model.item(id: suggestion.id)).createdAt
        let retry = await model.save(
            id: suggestion.id, kind: suggestion.kind, title: "Ta med den blå boken", body: "Egen rättning",
            scheduledAt: suggestion.scheduledAt, isCompleted: false, sessionID: nil
        )
        XCTAssertTrue(retry)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items.first?.id, suggestion.id)
        XCTAssertEqual(model.items.first?.createdAt, createdAt)
        let reloaded = MioContentRepository(storageURL: fixture.content, exportDirectoryURL: fixture.exports)
        let items = try await reloaded.loadItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, suggestion.id)
        XCTAssertEqual(items.first?.title, "Ta med den blå boken")
    }

    @MainActor
    func testPartialAcceptanceCanRetryWithoutLosingEditedContent() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let assistantRepository = MioAssistantRepository(storageURL: fixture.assistant)
        let assistant = MioAssistantViewModel(repository: assistantRepository)
        let contentRepository = MioContentRepository(storageURL: fixture.content, exportDirectoryURL: fixture.exports)
        let content = MioContentViewModel(repository: contentRepository)
        await assistant.bootstrap()
        await content.bootstrap()
        let proposed = await assistant.propose(text: "Ett uttryckligt minne", kind: .memory)
        XCTAssertTrue(proposed)
        let suggestion = try XCTUnwrap(assistant.suggestions.first)
        let saved = await content.save(
            id: suggestion.id, kind: suggestion.kind, title: suggestion.title, body: suggestion.body,
            scheduledAt: suggestion.scheduledAt, isCompleted: false, sessionID: nil
        )
        XCTAssertTrue(saved)
        let originalAssistantData = try Data(contentsOf: fixture.assistant)
        let unknownSchema = Data(#"{"schemaVersion":999,"futureData":"bevaras"}"#.utf8)
        try unknownSchema.write(to: fixture.assistant, options: .atomic)
        let firstDismissal = await assistant.markAccepted(id: suggestion.id)
        XCTAssertFalse(firstDismissal)
        XCTAssertNotNil(content.item(id: suggestion.id))
        XCTAssertEqual(assistant.suggestions.first?.id, suggestion.id)
        XCTAssertEqual(try Data(contentsOf: fixture.assistant), unknownSchema)

        let edited = await content.save(
            id: suggestion.id, kind: suggestion.kind, title: "Användarens senare ändring", body: "Bevara denna",
            scheduledAt: suggestion.scheduledAt, isCompleted: false, sessionID: nil
        )
        XCTAssertTrue(edited)
        try originalAssistantData.write(to: fixture.assistant, options: .atomic)
        let retryDismissal = await assistant.markAccepted(id: suggestion.id)
        XCTAssertTrue(retryDismissal)
        XCTAssertTrue(assistant.suggestions.isEmpty)
        XCTAssertEqual(content.items.count, 1)
        XCTAssertEqual(content.item(id: suggestion.id)?.title, "Användarens senare ändring")
        XCTAssertEqual(content.item(id: suggestion.id)?.body, "Bevara denna")
    }

    func testLegacyExportDecodesWithoutAssistantField() throws {
        let data = Data(#"{"schemaVersion":1,"exportedAt":"2026-09-25T12:00:00Z","content":[],"sessions":[]}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(MioLocalExport.self, from: data)
        XCTAssertEqual(export.schemaVersion, 1)
        XCTAssertNil(export.assistant)
        XCTAssertTrue(export.content.isEmpty)
        XCTAssertTrue(export.sessions.isEmpty)
    }

    func testNewExportIncludesAssistantWithoutChangingOriginalEvidence() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let date = Date(timeIntervalSince1970: 100_000)
        let segment = TranscriptSegment(
            createdAt: date, audioStartedAt: date, audioEndedAt: date.addingTimeInterval(10),
            text: "Originalet", correctedText: "Rättad visning", containsMio: false, wasObservedInBackground: true
        )
        let session = MioSession(startedAt: date, endedAt: date.addingTimeInterval(60), transcripts: [segment])
        let suggestion = MioSuggestion(
            kind: .note, title: "Väntande förslag", createdAt: date, sessionID: session.id,
            sourceSegmentID: segment.id, state: .deferred, deferredAt: date
        )
        let lesson = MioLesson(
            sessionID: session.id, title: "Matematik", startedAt: date,
            endedAt: date.addingTimeInterval(60), createdAt: date
        )
        let assistant = MioAssistantStoreDocument(
            suggestions: [suggestion], lessons: [lesson],
            processedSources: [MioProcessedSource(sessionID: session.id, segmentID: segment.id)]
        )
        let repository = MioContentRepository(storageURL: fixture.content, exportDirectoryURL: fixture.exports)
        let url = try await repository.makeExportFile(content: [], sessions: [session], assistant: assistant)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(MioLocalExport.self, from: data)
        XCTAssertEqual(export.schemaVersion, 2)
        XCTAssertEqual(export.assistant?.suggestions, [suggestion])
        XCTAssertEqual(export.assistant?.lessons, [lesson])
        XCTAssertEqual(export.assistant?.processedSources, assistant.processedSources)
        XCTAssertEqual(export.sessions, [session])
        XCTAssertEqual(export.sessions.first?.transcripts.first?.text, "Originalet")
        XCTAssertEqual(export.sessions.first?.transcripts.first?.displayText, "Rättad visning")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["rawAudio"])
        XCTAssertNil(json["apiKey"])
        XCTAssertNil(json["authenticationToken"])
    }

    @MainActor
    func testMaintenanceBlocksLateWritesButAllowsCoordinatedDeletion() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let maintenance = MioMaintenanceState.shared
        let previousDeletionState = maintenance.isDeleting
        let previousWriteCount = maintenance.activeWrites
        defer { maintenance.isDeleting = previousDeletionState }
        let contentRepository = MioContentRepository(storageURL: fixture.content, exportDirectoryURL: fixture.exports)
        let content = MioContentViewModel(repository: contentRepository)
        let assistantRepository = MioAssistantRepository(storageURL: fixture.assistant)
        let assistant = MioAssistantViewModel(repository: assistantRepository)
        await content.bootstrap()
        await assistant.bootstrap()
        let proposed = await assistant.propose(text: "Förslag före radering", kind: .note)
        XCTAssertTrue(proposed)
        await content.prepareExport(sessions: [], assistant: assistant.exportDocument)
        let originalExport = try XCTUnwrap(content.exportURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalExport.path))

        maintenance.isDeleting = true
        let lateSave = await content.save(
            kind: .note, title: "Får inte återskapas", body: "", scheduledAt: .now,
            isCompleted: false, sessionID: nil
        )
        let lateProposal = await assistant.propose(text: "Får inte återskapas", kind: .task)
        let lateDetection = await assistant.detectSuggestions(in: MioSession(transcripts: [
            TranscriptSegment(text: "Mio, anteckna sen text", containsMio: true)
        ]))
        XCTAssertFalse(lateSave)
        XCTAssertFalse(lateProposal)
        XCTAssertEqual(lateDetection, 0)
        await content.deleteAllData()
        let deletedAssistant = await assistant.deleteAllData()
        XCTAssertTrue(deletedAssistant)
        await content.prepareExport(sessions: [], assistant: assistant.exportDocument)
        XCTAssertNil(content.exportURL)
        XCTAssertTrue(content.items.isEmpty)
        XCTAssertTrue(assistant.suggestions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalExport.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.assistant.path))
        XCTAssertEqual(maintenance.activeWrites, previousWriteCount)
    }

    private func makeFixture() throws -> (root: URL, content: URL, assistant: URL, exports: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mio-integration-tests-\(UUID().uuidString)", isDirectory: true)
        let exports = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        return (
            root,
            root.appendingPathComponent("content-v1.json"),
            root.appendingPathComponent("assistant-v1.json"),
            exports
        )
    }
}
