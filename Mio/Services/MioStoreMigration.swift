import Foundation

/// Everything the three legacy JSON documents contain, decoded by today's repositories.
struct MioLegacyStoreSnapshot: Sendable {
    var sessions: [MioSession] = []
    var content: [MioContentItem] = []
    var assistant = MioAssistantStoreDocument()
}

/// Row counts compared after the single migration transaction.
struct MioStoreCounts: Codable, Equatable, Sendable {
    var sessions = 0
    var segments = 0
    var captureGaps = 0
    var contentItems = 0
    var suggestions = 0
    var lessons = 0
    var analyses = 0
    var decisions = 0
    var processedSources = 0

    init() {}

    init(snapshot: MioLegacyStoreSnapshot) {
        sessions = snapshot.sessions.count
        segments = snapshot.sessions.reduce(0) { $0 + $1.transcripts.count }
        captureGaps = snapshot.sessions.reduce(0) { $0 + ($1.captureGaps?.count ?? 0) }
        contentItems = snapshot.content.count
        suggestions = snapshot.assistant.suggestions.count
        lessons = snapshot.assistant.lessons.count
        analyses = snapshot.assistant.analyses?.count ?? 0
        decisions = snapshot.assistant.analysisDecisions?.count ?? 0
        processedSources = snapshot.assistant.processedSources.count
    }
}

/// Written only after the migrated rows were saved and their counts verified. Contains
/// counts and a date, never content.
struct MioStoreMigrationMarker: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        /// The store holds every legacy row; legacy files may still sit next to it.
        case verified
        /// Legacy files are in the backup folder until a later launch opens the store.
        case backedUp
    }

    static let currentSchemaVersion = 1
    var schemaVersion = currentSchemaVersion
    var state: State
    var migratedAt: Date
    var counts: MioStoreCounts
}

enum MioStoreMigrationError: LocalizedError, Equatable {
    case unknownMarker

    var errorDescription: String? {
        "Markeringen för datalagringen har ett okänt format och har inte ändrats."
    }
}

/// The SwiftData side of the migration. A conforming type replaces all rows in exactly one
/// transaction, so a failed save leaves no partial copy behind.
protocol MioStoreMigrationTarget: Sendable {
    func replaceAll(with snapshot: MioLegacyStoreSnapshot) async throws
    func removeAll() async throws
    func counts() async throws -> MioStoreCounts
}

enum MioStoreMigrationOutcome: Equatable, Sendable {
    /// SwiftData is the source of truth. The message, if any, is shown once.
    case useStore(message: String?)
    /// Nothing was migrated or changed; the legacy JSON repositories stay in use.
    case useLegacyFiles(message: String)
}

/// File layout of the app-owned `Mio/` directory around the migration.
struct MioLegacyStoreFiles: Sendable {
    let directory: URL

    static var standard: MioLegacyStoreFiles {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return MioLegacyStoreFiles(directory: support.appendingPathComponent("Mio", isDirectory: true))
    }

    var sessionsURL: URL { directory.appendingPathComponent("sessions.json", isDirectory: false) }
    var contentURL: URL { directory.appendingPathComponent("content-v1.json", isDirectory: false) }
    var assistantURL: URL { directory.appendingPathComponent("assistant-v1.json", isDirectory: false) }
    var legacyURLs: [URL] { [sessionsURL, contentURL, assistantURL] }
    var backupDirectory: URL { directory.appendingPathComponent("backup-pre-swiftdata", isDirectory: true) }
    var markerURL: URL { directory.appendingPathComponent("swiftdata-migration-v1.json", isDirectory: false) }
    var storeDirectory: URL { directory.appendingPathComponent("store", isDirectory: true) }
    var storeURL: URL { storeDirectory.appendingPathComponent("Mio.store", isDirectory: false) }

    var presentLegacyURLs: [URL] { legacyURLs.filter { FileManager.default.fileExists(atPath: $0.path) } }

    func readMarker() throws -> MioStoreMigrationMarker? {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return nil }
        let data = try Data(contentsOf: markerURL)
        struct Header: Decodable { let schemaVersion: Int }
        guard (try? Self.decoder.decode(Header.self, from: data))?.schemaVersion
                == MioStoreMigrationMarker.currentSchemaVersion,
              let marker = try? Self.decoder.decode(MioStoreMigrationMarker.self, from: data) else {
            throw MioStoreMigrationError.unknownMarker
        }
        return marker
    }

    func writeMarker(_ marker: MioStoreMigrationMarker) throws {
        try MioProtectedFileWriter.write(Self.encoder.encode(marker), to: markerURL)
    }

    /// Creates an owned, private directory with the same protection as the JSON stores.
    func prepareOwnedDirectory(_ url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        #if os(iOS)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var owned = url
        try owned.setResourceValues(values)
        #endif
    }

    /// Moves, never copies or overwrites: an existing backup name gets a unique suffix.
    func moveLegacyFilesToBackup() throws {
        let present = presentLegacyURLs
        guard !present.isEmpty else { return }
        try prepareOwnedDirectory(backupDirectory)
        for source in present {
            var destination = backupDirectory.appendingPathComponent(source.lastPathComponent, isDirectory: false)
            if FileManager.default.fileExists(atPath: destination.path) {
                destination = backupDirectory.appendingPathComponent(
                    source.deletingPathExtension().lastPathComponent + "-" + UUID().uuidString + ".json", isDirectory: false)
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    /// The backup holds user text. Deletions call this as well, so deleted data does not
    /// survive in the backup until the next launch.
    func discardBackup() throws {
        guard FileManager.default.fileExists(atPath: backupDirectory.path) else { return }
        try FileManager.default.removeItem(at: backupDirectory)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum MioLegacyStoreReader {
    /// Reads with today's repositories, including their schema and relationship validation.
    /// Nil means that no legacy file exists. Any unknown schema or decoding failure throws.
    static func read(_ files: MioLegacyStoreFiles) async throws -> MioLegacyStoreSnapshot? {
        guard !files.presentLegacyURLs.isEmpty else { return nil }
        let exports = files.directory.appendingPathComponent("unused-exports", isDirectory: true)
        var snapshot = MioLegacyStoreSnapshot()
        do {
            snapshot.sessions = try await SessionRepository(storageURL: files.sessionsURL,
                                                            exportDirectoryURL: exports).loadSessions()
        } catch {
            throw MioLegacyReadError(file: "sessions.json", underlying: error)
        }
        do {
            snapshot.content = try await MioContentRepository(storageURL: files.contentURL,
                                                              exportDirectoryURL: exports).loadItems()
        } catch {
            throw MioLegacyReadError(file: "content-v1.json", underlying: error)
        }
        do {
            snapshot.assistant = try await MioAssistantRepository(storageURL: files.assistantURL).loadDocument()
        } catch {
            throw MioLegacyReadError(file: "assistant-v1.json", underlying: error)
        }
        return snapshot
    }
}

struct MioLegacyReadError: LocalizedError {
    let file: String
    let underlying: Error

    var errorDescription: String? {
        let detail = (underlying as? LocalizedError)?.errorDescription ?? "Filen kunde inte avkodas."
        return "\(file): \(detail)"
    }
}

/// One-time, idempotent move from the three JSON documents to SwiftData. Crash safety:
/// the legacy files stay untouched until the marker records a verified save, and a
/// launch without that marker repeats the whole replacement from the untouched files.
struct MioStoreMigrator: Sendable {
    let files: MioLegacyStoreFiles
    let target: any MioStoreMigrationTarget
    var now: @Sendable () -> Date = { .now }

    func run() async -> MioStoreMigrationOutcome {
        let marker: MioStoreMigrationMarker?
        do { marker = try files.readMarker() } catch {
            MioLog.error(.storage, "migration marker unreadable")
            return .useLegacyFiles(message: Self.markerMessage)
        }
        if var marker {
            if marker.state == .verified {
                // A crash between the verified save and the move leaves legacy files behind.
                do {
                    try files.moveLegacyFilesToBackup()
                    marker.state = .backedUp
                    try files.writeMarker(marker)
                } catch {
                    MioLog.error(.storage, "legacy backup move failed")
                }
                return .useStore(message: nil)
            }
            // A later launch that can read the store ends the backup period.
            do {
                _ = try await target.counts()
                try files.discardBackup()
            } catch {
                MioLog.error(.storage, "legacy backup cleanup failed")
            }
            return .useStore(message: nil)
        }

        let snapshot: MioLegacyStoreSnapshot?
        do { snapshot = try await MioLegacyStoreReader.read(files) } catch {
            MioLog.error(.storage, "legacy store unreadable; migration skipped")
            return .useLegacyFiles(message: Self.unreadableMessage(error))
        }
        guard let snapshot else {
            // Nothing to migrate. An existing store is never wiped on this path.
            let marker = MioStoreMigrationMarker(state: .backedUp, migratedAt: now(), counts: MioStoreCounts())
            do { try files.writeMarker(marker) } catch { MioLog.error(.storage, "fresh-install marker write failed") }
            return .useStore(message: nil)
        }

        let expected = MioStoreCounts(snapshot: snapshot)
        do {
            try await target.replaceAll(with: snapshot)
            let actual = try await target.counts()
            guard actual == expected else {
                MioLog.error(.storage, "migration count mismatch")
                try? await target.removeAll()
                return .useLegacyFiles(message: Self.verificationMessage)
            }
        } catch {
            MioLog.error(.storage, "migration transaction failed")
            try? await target.removeAll()
            return .useLegacyFiles(message: Self.saveMessage)
        }

        var written = MioStoreMigrationMarker(state: .verified, migratedAt: now(), counts: expected)
        do { try files.writeMarker(written) } catch {
            // Without a marker the next launch replaces the store from the legacy files again,
            // so this launch must keep writing to those files or its changes would be lost.
            MioLog.error(.storage, "migration marker write failed")
            try? await target.removeAll()
            return .useLegacyFiles(message: Self.saveMessage)
        }
        MioLog.notice(.storage, "migration verified", value: expected.sessions)
        do {
            try files.moveLegacyFilesToBackup()
            written.state = .backedUp
            try files.writeMarker(written)
        } catch {
            MioLog.error(.storage, "legacy backup move failed")
        }
        return .useStore(message: nil)
    }

    static func unreadableMessage(_ error: Error) -> String {
        let detail = (error as? LocalizedError)?.errorDescription ?? "Okänt läsfel."
        return "Mio flyttade inte dina data till den nya databasen eftersom en gammal fil har ett okänt eller skadat format (\(detail)). "
            + "Ingenting har flyttats, ändrats eller raderats. Mio fortsätter med de gamla filerna tills en uppdatering kan läsa dem."
    }

    static let verificationMessage = "Mio flyttade inte dina data till den nya databasen eftersom kontrollen efter flytten inte stämde. "
        + "De gamla filerna är orörda och används tills vidare. Flytten försöks igen vid nästa start."
    static let saveMessage = "Mio kunde inte spara dina data i den nya databasen. De gamla filerna är orörda och används tills vidare. "
        + "Flytten försöks igen vid nästa start."
    static let markerMessage = "Mio kunde inte läsa markeringen för datalagringen. Ingenting har flyttats eller raderats, "
        + "och Mio använder de gamla filerna tills vidare."
}
