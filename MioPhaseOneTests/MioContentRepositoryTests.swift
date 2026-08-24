import Foundation
import XCTest
@testable import MioPhaseOne

final class MioContentRepositoryTests: XCTestCase {
    func testUpsertReloadDeleteAndPhaseOneIsolation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let phaseOneURL = fixture.root
            .appendingPathComponent("MioPhaseOne", isDirectory: true)
            .appendingPathComponent("sessions.json")
        try FileManager.default.createDirectory(
            at: phaseOneURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let phaseOneSentinel = Data("private phase one fixture".utf8)
        try phaseOneSentinel.write(to: phaseOneURL)

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
        XCTAssertEqual(try Data(contentsOf: phaseOneURL), phaseOneSentinel)
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

        XCTAssertEqual(export.schemaVersion, 1)
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
            root.appendingPathComponent("MioPhaseTwo/content-v1.json"),
            exportURL
        )
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
