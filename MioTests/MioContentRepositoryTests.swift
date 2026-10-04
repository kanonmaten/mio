import Foundation
import XCTest
@testable import Mio

final class MioContentRepositoryTests: XCTestCase {
    func testApprovalRetryPreservesLaterUserEditsAndUnlinkUsesLatestPost() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = MioContentRepository(storageURL: fixture.storageURL)
        let sessionID = UUID()
        let suggestion = MioContentItem(kind: .note, title: "Godkänt förslag", sessionID: sessionID)
        _ = try await repository.saveApprovedIfAbsent(suggestion)
        var edited = suggestion; edited.title = "Användarens rubrik"; edited.body = "Egen text"
        _ = try await repository.upsert(edited)
        let retried = try await repository.saveApprovedIfAbsent(suggestion)
        XCTAssertEqual(retried, [edited])
        let unlinked = try await repository.unlinkSession(id: sessionID)
        XCTAssertEqual(unlinked.first?.title, "Användarens rubrik")
        XCTAssertEqual(unlinked.first?.body, "Egen text")
        XCTAssertNil(unlinked.first?.sessionID)
        XCTAssertEqual(unlinked.first?.id, suggestion.id)
    }

    func testExportCopiesRemainDistinctWhileFirstCopyIsShared() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = MioContentRepository(storageURL: fixture.storageURL, exportDirectoryURL: fixture.exportURL)
        let firstItem = MioContentItem(kind: .note, title: "Första kopian")
        let firstURL = try await repository.makeExportFile(content: [firstItem], sessions: [])
        let firstBytes = try Data(contentsOf: firstURL)
        let secondURL = try await repository.makeExportFile(content: [MioContentItem(kind: .note, title: "Senare kopia")], sessions: [])
        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
    }

    func testFailedExportRemovalIsReportedAndCanBeRetried() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = ContentFailureFileManager()
        let repository = MioContentRepository(fileManager: manager, storageURL: fixture.storageURL, exportDirectoryURL: fixture.exportURL)
        let exportURL = try await repository.makeExportFile(content: [], sessions: [])
        manager.refuseExportRemoval = true
        do { try await repository.deleteAll(); XCTFail("A remaining private export must block successful deletion") }
        catch { XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path)) }
        manager.refuseExportRemoval = false
        try await repository.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path))
    }

    func testPrivacyAttributeFailureDoesNotSilentlySucceed() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ordinary = MioContentRepository(storageURL: fixture.storageURL)
        _ = try await ordinary.upsert(MioContentItem(kind: .note, title: "Bevarad"))
        let original = try Data(contentsOf: fixture.storageURL)
        let manager = ContentFailureFileManager(); manager.refusePrivacyAttributes = true
        let repository = MioContentRepository(fileManager: manager, storageURL: fixture.storageURL)
        do { _ = try await repository.upsert(MioContentItem(kind: .note, title: "Osäker")); XCTFail("Privacy failures must be visible") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: fixture.storageURL), original)
    }

    func testCachedItemsCannotOverwriteExternallyReplacedUnknownSchema() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = MioContentRepository(storageURL: fixture.storageURL)
        _ = try await repository.upsert(MioContentItem(kind: .note, title: "Sparad"))
        let unknown = Data(#"{"schemaVersion":99,"items":[],"futureProperty":"protected fixture"}"#.utf8)
        try unknown.write(to: fixture.storageURL, options: .atomic)
        do { _ = try await repository.upsert(MioContentItem(kind: .note, title: "Sent")); XCTFail("Unknown external schemas must remain untouched") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: fixture.storageURL), unknown)
    }

    func testDuplicateContentIdentitiesAreRejectedWithoutOverwriting() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(at: fixture.storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let item = MioContentItem(kind: .note, title: "synthetic")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(MioContentStoreDocument(items: [item, item]))
        try data.write(to: fixture.storageURL)
        do { _ = try await MioContentRepository(storageURL: fixture.storageURL).loadItems(); XCTFail("Duplicate IDs must be rejected") }
        catch { XCTAssertEqual(try Data(contentsOf: fixture.storageURL), data) }
    }

    func testUpsertReloadDeleteAndSessionIsolation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sessionURL = fixture.root
            .appendingPathComponent("Mio", isDirectory: true)
            .appendingPathComponent("sessions.json")
        try FileManager.default.createDirectory(
            at: sessionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sessionSentinel = Data("private session fixture".utf8)
        try sessionSentinel.write(to: sessionURL)

        let repository = MioContentRepository(
            storageURL: fixture.storageURL,
            exportDirectoryURL: fixture.exportURL
        )
        let original = MioContentItem(kind: .note, title: "Första")
        _ = try await repository.upsert(original)

        var updated = original
        updated.title = "Uppdaterad"
        updated.updatedAt = Date(timeIntervalSince1970: 2_000)
        _ = try await repository.upsert(updated)

        let reloadedRepository = MioContentRepository(
            storageURL: fixture.storageURL,
            exportDirectoryURL: fixture.exportURL
        )
        let loaded = try await reloadedRepository.loadItems()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "Uppdaterad")

        _ = try await reloadedRepository.delete(id: original.id)
        let itemsAfterDelete = try await reloadedRepository.loadItems()
        XCTAssertTrue(itemsAfterDelete.isEmpty)
        try await reloadedRepository.deleteAll()
        XCTAssertEqual(try Data(contentsOf: sessionURL), sessionSentinel)
    }

    func testSessionRepositoryStartsFreshAndPersistsAtConfiguredPath() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let currentURL = fixture.root.appendingPathComponent("Mio/sessions.json")
        let repository = SessionRepository(storageURL: currentURL)
        let empty = try await repository.loadSessions()
        XCTAssertTrue(empty.isEmpty)
        var expected = MioSession(startedAt: Date(timeIntervalSince1970: 2_000),
                                  endedAt: Date(timeIntervalSince1970: 2_010))
        let generation = await repository.operationGeneration()
        let token = try await repository.operationToken(for: expected.id, generation: generation)
        expected = try await repository.saveCaptureCheckpoint(expected, token: token)
        let reloaded = try await SessionRepository(storageURL: currentURL).loadSessions()
        XCTAssertEqual(reloaded, [expected])
        try await repository.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentURL.path))
    }

    func testExportIsVersionedAndContainsNoRawAudioField() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = MioContentRepository(
            storageURL: fixture.storageURL,
            exportDirectoryURL: fixture.exportURL
        )
        let fixedDate = Date(timeIntervalSince1970: 2_000)
        let item = MioContentItem(
            kind: .memory,
            title: "Min favoritfärg är blå",
            createdAt: fixedDate,
            scheduledAt: fixedDate
        )

        let url = try await repository.makeExportFile(content: [item], sessions: [])
        let data = try Data(contentsOf: url)
        let export = try Self.decoder.decode(MioLocalExport.self, from: data)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(export.schemaVersion, 2)
        XCTAssertEqual(export.content, [item])
        XCTAssertTrue(export.sessions.isEmpty)
        XCTAssertFalse(json.localizedCaseInsensitiveContains("rawAudio"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("audioData"))
    }

    func testUnknownSchemaIsReportedWithoutOverwrite() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            at: fixture.storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let originalData = Data(#"{"schemaVersion":99,"items":[]}"#.utf8)
        try originalData.write(to: fixture.storageURL)
        let repository = MioContentRepository(
            storageURL: fixture.storageURL,
            exportDirectoryURL: fixture.exportURL
        )

        do {
            _ = try await repository.loadItems()
            XCTFail("En okänd schemaversion ska ge fel")
        } catch let error as MioContentRepositoryError {
            guard case .unsupportedSchemaVersion(99) = error else {
                return XCTFail("Fel schemaversion rapporterades")
            }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.storageURL), originalData)
    }

    private func makeFixture() throws -> (root: URL, storageURL: URL, exportURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MioContentRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        let exportURL = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportURL, withIntermediateDirectories: true)
        return (
            root,
            root.appendingPathComponent("Mio/content-v1.json"),
            exportURL
        )
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private final class ContentFailureFileManager: FileManager, @unchecked Sendable {
    var refuseExportRemoval = false
    var refusePrivacyAttributes = false
    override func removeItem(at URL: URL) throws {
        if refuseExportRemoval, URL.lastPathComponent.hasPrefix("Mio-lokal-export-") {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if refusePrivacyAttributes { throw CocoaError(.fileWriteNoPermission) }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}
