import Foundation

/// Stores protected transcript diagnostics inside the app sandbox. Raw audio is never stored;
/// shareable exports are temporary files and persistent sessions are excluded from backup.
actor SessionRepository {
    private let fileManager: FileManager
    private let storageURL: URL
    private var cachedSessions: [PhaseOneSession]?

    init(fileManager: FileManager = .default, storageURL: URL? = nil) {
        self.fileManager = fileManager

        if let storageURL {
            self.storageURL = storageURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.storageURL = applicationSupport
                .appendingPathComponent("MioPhaseOne", isDirectory: true)
                .appendingPathComponent("sessions.json", isDirectory: false)
        }
    }

    func loadSessions() throws -> [PhaseOneSession] {
        if let cachedSessions {
            return cachedSessions
        }

        guard fileManager.fileExists(atPath: storageURL.path) else {
            cachedSessions = []
            return []
        }

        let data = try Data(contentsOf: storageURL)
        let sessions = try Self.decoder.decode([PhaseOneSession].self, from: data)
        cachedSessions = sessions
        return sessions
    }

    func upsert(_ session: PhaseOneSession) throws {
        var sessions = try loadSessions()
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sessions.sort { $0.startedAt > $1.startedAt }
        try write(sessions)
    }

    func delete(id: UUID) throws {
        var sessions = try loadSessions()
        sessions.removeAll { $0.id == id }
        try write(sessions)
    }

    func deleteAll() throws {
        // This removes app-owned storage and temporary exports. Copies already shared to
        // Files, mail or another app are outside this sandbox and cannot be recalled here.
        if fileManager.fileExists(atPath: storageURL.path) {
            try fileManager.removeItem(at: storageURL)
        }
        let temporaryExports = try fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("Mio-fas-1-") && $0.pathExtension == "json"
        }
        for export in temporaryExports {
            try? fileManager.removeItem(at: export)
        }
        cachedSessions = []
    }

    func makeExportFile(for session: PhaseOneSession) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sv-SE")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"

        let exportURL = fileManager.temporaryDirectory
            .appendingPathComponent("Mio-fas-1-\(formatter.string(from: session.startedAt)).json")
        let data = try Self.exportEncoder.encode(session)
        try data.write(to: exportURL, options: .atomic)
        // This protection remains writable after the first device unlock, which is required
        // for an ongoing background audio session while the screen is locked.
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: exportURL.path
        )
        return exportURL
    }

    private func write(_ sessions: [PhaseOneSession]) throws {
        let directory = storageURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(sessions)
        try data.write(to: storageURL, options: .atomic)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: storageURL.path
        )
        // Diagnostic transcripts are intentionally kept out of device backups.
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(resourceValues)
        cachedSessions = sessions
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let exportEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
