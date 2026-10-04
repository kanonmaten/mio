import Foundation
import XCTest
@testable import Mio

final class MioSessionRepositoryTests: XCTestCase {
    func testFailedFullExportCleanupStillInvalidatesPreDeletionCheckpoint() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = SessionExportFileManager(temporary: fixture.root)
        let repository = SessionRepository(fileManager: manager, storageURL: fixture.url)
        let original = makeSession()
        let generation = await repository.operationGeneration()
        let token = try await repository.operationToken(for: original.id, generation: generation)
        try await repository.saveCaptureCheckpoint(original, token: token)
        _ = try await repository.makeExportFile(for: original)
        manager.refuseExportRemoval = true
        do { try await repository.deleteAll(); XCTFail("Remaining export must block full-deletion success") }
        catch { }
        do { try await repository.saveCaptureCheckpoint(original, token: token); XCTFail("Partial cleanup must invalidate old capture") }
        catch let error as SessionRepositoryError {
            guard case .staleOperation = error else { return XCTFail("Expected invalidated operation token") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
        manager.refuseExportRemoval = false
        try await repository.deleteAll()
    }

    func testPartiallyCommittedDeletionInvalidatesOldSessionToken() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = SessionExportFileManager(temporary: fixture.root)
        let repository = SessionRepository(fileManager: manager, storageURL: fixture.url)
        let original = makeSession()
        let generation = await repository.operationGeneration()
        let token = try await repository.operationToken(for: original.id, generation: generation)
        try await repository.saveCaptureCheckpoint(original, token: token)
        manager.refuseSessionPrivacy = true
        do { try await repository.delete(id: original.id); XCTFail("The post-commit privacy failure must be visible") }
        catch { }
        manager.refuseSessionPrivacy = false
        do { try await repository.saveCaptureCheckpoint(original, token: token); XCTFail("A failed deletion must not let late capture recreate committed deletion") }
        catch let error as SessionRepositoryError {
            guard case .staleOperation = error else { return XCTFail("Expected invalidated operation token") }
        }
        let stored = try await repository.loadSessions()
        XCTAssertTrue(stored.isEmpty)
    }

    func testSessionExportsRemainDistinctAndCleanupFailureIsVisible() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let manager = SessionExportFileManager(temporary: fixture.root)
        let repository = SessionRepository(fileManager: manager, storageURL: fixture.url)
        let session = makeSession()
        let first = try await repository.makeExportFile(for: session)
        let original = try Data(contentsOf: first)
        var changed = session; changed.title = "Senare export"
        let second = try await repository.makeExportFile(for: changed)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), original)
        manager.refuseExportRemoval = true
        do { try await repository.deleteAll(); XCTFail("Export removal failures must be reported") }
        catch { XCTAssertTrue(FileManager.default.fileExists(atPath: first.path)) }
        manager.refuseExportRemoval = false
        try await repository.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }
    func testLateCaptureSnapshotCannotOverwriteCorrectionOrMetadata() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = SessionRepository(storageURL: fixture.url)
        let original = makeSession()
        let generation = await repository.operationGeneration()
        let token = try await repository.operationToken(for: original.id, generation: generation)
        try await repository.saveCaptureCheckpoint(original, token: token)
        try await repository.updateMetadata(id: original.id, title: "Rättad rubrik", note: "Manuell anteckning", token: token)
        try await repository.correctTranscript(sessionID: original.id, segmentID: original.transcripts[0].id, text: "Rättad text", token: token)
        try await repository.saveCaptureCheckpoint(original, token: token)
        let stored = try await repository.loadSessions().first
        XCTAssertEqual(stored?.title, "Rättad rubrik")
        XCTAssertEqual(stored?.manualNote, "Manuell anteckning")
        XCTAssertEqual(stored?.transcripts.first?.displayText, "Rättad text")
        XCTAssertEqual(stored?.transcripts.first?.text, original.transcripts.first?.text)
    }

    func testLateSnapshotCannotRecreateDeletedSession() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = SessionRepository(storageURL: fixture.url)
        let original = makeSession()
        let generation = await repository.operationGeneration()
        let token = try await repository.operationToken(for: original.id, generation: generation)
        try await repository.saveCaptureCheckpoint(original, token: token)
        try await repository.delete(id: original.id)
        do {
            try await repository.saveCaptureCheckpoint(original, token: token)
        } catch { }
        let stored = try await repository.loadSessions()
        XCTAssertTrue(stored.isEmpty)
    }

    func testLateSnapshotCannotReopenFinalizedSession() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = SessionRepository(storageURL: fixture.url)
        let original = makeSession()
        let generation = await repository.operationGeneration()
        let token = try await repository.operationToken(for: original.id, generation: generation)
        try await repository.saveCaptureCheckpoint(original, token: token)
        var stale = original
        stale.endedAt = nil
        try await repository.saveCaptureCheckpoint(stale, token: token)
        let stored = try await repository.loadSessions().first
        XCTAssertEqual(stored?.endedAt, original.endedAt)
    }

    func testConcurrentCorrectionsAndMetadataAllPersist() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = SessionRepository(storageURL: fixture.url)
        var original = makeSession()
        original.transcripts.append(TranscriptSegment(createdAt: original.startedAt, text: "Andra originalet", containsMio: false))
        let generation = await repository.operationGeneration()
        let token = try await repository.operationToken(for: original.id, generation: generation)
        try await repository.saveCaptureCheckpoint(original, token: token)
        let sessionID = original.id
        let firstID = original.transcripts[0].id
        let secondID = original.transcripts[1].id
        async let first = repository.correctTranscript(sessionID: sessionID, segmentID: firstID,
                                                       text: "Första rättningen", token: token)
        async let second = repository.correctTranscript(sessionID: sessionID, segmentID: secondID,
                                                        text: "Andra rättningen", token: token)
        async let metadata = repository.updateMetadata(id: sessionID, title: "Rubrik", note: "Anteckning", token: token)
        _ = try await (first, second, metadata)
        let stored = try await SessionRepository(storageURL: fixture.url).loadSessions().first
        XCTAssertEqual(stored?.title, "Rubrik")
        XCTAssertEqual(stored?.manualNote, "Anteckning")
        XCTAssertEqual(stored?.transcripts.map(\.displayText), ["Första rättningen", "Andra rättningen"])
        XCTAssertEqual(stored?.transcripts.map(\.text), ["Originaltext", "Andra originalet"])
    }

    func testDeletionInvalidatesCorrectionsAndMetadata() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = SessionRepository(storageURL: fixture.url)
        let original = makeSession()
        let generation = await repository.operationGeneration()
        let token = try await repository.operationToken(for: original.id, generation: generation)
        try await repository.saveCaptureCheckpoint(original, token: token)
        try await repository.delete(id: original.id)
        do {
            try await repository.updateMetadata(id: original.id, title: "Sent", note: nil, token: token)
            XCTFail("Metadata efter radering ska avvisas")
        } catch let error as SessionRepositoryError {
            guard case .staleOperation = error else { return XCTFail("Fel raderingsskydd") }
        }
        do {
            try await repository.correctTranscript(sessionID: original.id, segmentID: original.transcripts[0].id,
                                                   text: "Sent", token: token)
            XCTFail("Rättning efter radering ska avvisas")
        } catch let error as SessionRepositoryError {
            guard case .staleOperation = error else { return XCTFail("Fel raderingsskydd") }
        }
        let stored = try await repository.loadSessions()
        XCTAssertTrue(stored.isEmpty)
    }

    func testDeleteAllInvalidatesAnUnstoredCheckpoint() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = SessionRepository(storageURL: fixture.url)
        let original = makeSession()
        let generation = await repository.operationGeneration()
        let token = try await repository.operationToken(for: original.id, generation: generation)
        let newGeneration = try await repository.deleteAll()
        do {
            try await repository.saveCaptureCheckpoint(original, token: token)
            XCTFail("En osparad gammal session får inte återkomma efter total radering")
        } catch let error as SessionRepositoryError {
            guard case .staleOperation = error else { return XCTFail("Fel generationsskydd") }
        }
        let newSession = makeSession()
        let newToken = try await repository.operationToken(for: newSession.id, generation: newGeneration)
        try await repository.saveCaptureCheckpoint(newSession, token: newToken)
        let stored = try await repository.loadSessions()
        XCTAssertEqual(stored.map(\.id), [newSession.id])
    }

    func testCaptureCheckpointsMergeEvidenceWithoutReopeningClosedIntervals() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = SessionRepository(storageURL: fixture.url)
        var original = makeSession(); original.endedAt = nil
        original.backgroundIntervals = [BackgroundInterval(startedAt: original.startedAt)]
        let generation = await repository.operationGeneration()
        let token = try await repository.operationToken(for: original.id, generation: generation)
        try await repository.saveCaptureCheckpoint(original, token: token)
        var latest = original
        latest.backgroundIntervals[0].endedAt = original.startedAt.addingTimeInterval(5)
        latest.transcripts.append(TranscriptSegment(createdAt: original.startedAt.addingTimeInterval(2), text: "Ny text", containsMio: false))
        try await repository.saveCaptureCheckpoint(latest, token: token)
        try await repository.saveCaptureCheckpoint(original, token: token)
        let stored = try await repository.loadSessions().first
        XCTAssertEqual(stored?.transcripts.map(\.text), ["Originaltext", "Ny text"])
        XCTAssertEqual(stored?.backgroundIntervals.first?.endedAt, Date(timeIntervalSince1970: 2_005))
    }

    func testMalformedStoredIdentityAndIntervalsAreNotOverwritten() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(at: fixture.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let session = makeSession()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let malformed = try encoder.encode([session, session])
        try malformed.write(to: fixture.url)
        let repository = SessionRepository(storageURL: fixture.url)
        do {
            _ = try await repository.loadSessions()
            XCTFail("Dubbel sessionsidentitet ska avvisas")
        } catch let error as SessionRepositoryError {
            guard case .duplicateIdentity = error else { return XCTFail("Fel identitetsfel") }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.url), malformed)
        var invalid = makeSession()
        invalid.backgroundIntervals = [BackgroundInterval(startedAt: Date(timeIntervalSince1970: 2_005),
                                                           endedAt: Date(timeIntervalSince1970: 2_004))]
        let invalidData = try encoder.encode([invalid])
        try invalidData.write(to: fixture.url)
        do {
            _ = try await SessionRepository(storageURL: fixture.url).loadSessions()
            XCTFail("Omvända intervall ska avvisas")
        } catch let error as SessionRepositoryError {
            guard case .invalidEvidence = error else { return XCTFail("Fel tidsrelationsfel") }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.url), invalidData)
    }

    func testCorrectionRevisionChangesOnlyWithDisplayedSourceText() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = SessionRepository(storageURL: fixture.url)
        let original = makeSession()
        let generation = await repository.operationGeneration()
        let token = try await repository.operationToken(for: original.id, generation: generation)
        try await repository.saveCaptureCheckpoint(original, token: token)
        let first = try await repository.correctTranscript(sessionID: original.id, segmentID: original.transcripts[0].id,
                                                           text: "Rättad", token: token)
        let repeated = try await repository.correctTranscript(sessionID: original.id, segmentID: original.transcripts[0].id,
                                                              text: "  Rättad  ", token: token)
        let restored = try await repository.correctTranscript(sessionID: original.id, segmentID: original.transcripts[0].id,
                                                              text: "Originaltext", token: token)
        XCTAssertEqual(first.transcripts[0].correctionRevision, 1)
        XCTAssertEqual(repeated.transcripts[0].correctionRevision, 1)
        XCTAssertEqual(restored.transcripts[0].correctionRevision, 2)
        XCTAssertNil(restored.transcripts[0].correctedText)
        XCTAssertEqual(restored.transcripts[0].text, "Originaltext")
    }

    private func makeFixture() -> (root: URL, url: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioSessionRepositoryTests-\(UUID())")
        return (root, root.appendingPathComponent("Mio/sessions.json"))
    }

    private func makeSession() -> MioSession {
        let start = Date(timeIntervalSince1970: 2_000)
        return MioSession(startedAt: start, endedAt: start.addingTimeInterval(10),
                          transcripts: [TranscriptSegment(createdAt: start, text: "Originaltext", containsMio: false)])
    }
}

private final class SessionExportFileManager: FileManager, @unchecked Sendable {
    private let temporary: URL
    var refuseExportRemoval = false
    var refuseSessionPrivacy = false
    init(temporary: URL) { self.temporary = temporary; super.init() }
    override var temporaryDirectory: URL { temporary }
    override func removeItem(at URL: URL) throws {
        if refuseExportRemoval, URL.lastPathComponent.hasPrefix("Mio-session-") {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if refuseSessionPrivacy, path.hasSuffix("sessions.json") { throw CocoaError(.fileWriteNoPermission) }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}
