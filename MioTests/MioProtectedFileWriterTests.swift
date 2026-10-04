import Foundation
import XCTest
@testable import Mio

final class MioProtectedFileWriterTests: XCTestCase {
    func testProtectedAtomicReplacementUsesPrivateOwnedDirectoryAndFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioWriterTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Mio/content-v1.json")
        try MioProtectedFileWriter.write(Data("original".utf8), to: url)
        try MioProtectedFileWriter.write(Data("replacement".utf8), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("replacement".utf8))
        let file = try FileManager.default.attributesOfItem(atPath: url.path)
        let directory = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        #if os(iOS)
        let protection = (file[.protectionKey] as? FileProtectionType)?.rawValue ?? file[.protectionKey] as? String
        XCTAssertEqual(protection, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
        XCTAssertEqual(try url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        #endif
    }

    func testSharedTemporaryRootIsNeverChmoddedOrWritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioSharedRootTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o755])
        let manager = WriterTemporaryFileManager(temporary: root)
        let url = root.appendingPathComponent("export.json")
        XCTAssertThrowsError(try MioProtectedFileWriter.write(Data("private".utf8), to: url, fileManager: manager))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }
}

private final class WriterTemporaryFileManager: FileManager, @unchecked Sendable {
    private let temporary: URL
    init(temporary: URL) { self.temporary = temporary; super.init() }
    override var temporaryDirectory: URL { temporary }
}
