import Foundation

struct MioFileStamp: Equatable, Sendable {
    let modifiedAt: Date?
    let size: UInt64
    let inode: UInt64
}

enum MioProtectedFileWriterError: LocalizedError {
    case sharedDirectory

    var errorDescription: String? {
        "Lagringen kräver en privat undermapp. Filen har inte skrivits."
    }
}

/// Callers own the immediate parent directory. Privacy failures are operation failures;
/// they must never be hidden behind a successful repository/UI result.
enum MioProtectedFileWriter {
    static func write(_ data: Data, to url: URL, fileManager: FileManager = .default,
                      excludeFromBackup: Bool = true) throws {
        let directory = url.deletingLastPathComponent().standardizedFileURL
        // A caller-supplied export location may be a shared root. Never chmod it.
        let sharedDirectories = [FileManager.default.temporaryDirectory, fileManager.temporaryDirectory]
            + fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            + fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
            + fileManager.urls(for: .documentDirectory, in: .userDomainMask)
            + fileManager.urls(for: .libraryDirectory, in: .userDomainMask)
        guard directory.path != "/", !sharedDirectories.contains(where: { $0.standardizedFileURL.path == directory.path }) else {
            throw MioProtectedFileWriterError.sharedDirectory
        }
        var directoryAttributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        directoryAttributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: directoryAttributes)
        try fileManager.setAttributes(directoryAttributes, ofItemAtPath: directory.path)
        #if os(iOS)
        if excludeFromBackup {
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var ownedDirectory = directory
            try ownedDirectory.setResourceValues(values)
        }
        // Protection applies while Foundation creates the atomic replacement, before bytes
        // become visible. Changing protection only after writing leaves an unsafe interval.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        // Linux verifies atomicity and POSIX privacy, not Apple's Data Protection/backup APIs.
        try data.write(to: url, options: .atomic)
        #endif
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func fileStamp(for url: URL, fileManager: FileManager = .default) throws -> MioFileStamp? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return MioFileStamp(modifiedAt: attributes[.modificationDate] as? Date,
                            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }
}
