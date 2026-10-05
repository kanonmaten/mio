import Foundation

enum MioContentRepositoryError: LocalizedError {
    case unsupportedSchemaVersion(Int)
    case duplicateIdentity

    var errorDescription: String? {
        switch self {
        case .duplicateIdentity:
            "Innehållsfilen innehåller dubbla identifierare och har inte ändrats."
        case let .unsupportedSchemaVersion(version):
            "Den lokala innehållsfilen använder okänd schemaversion \(version) och har inte skrivits över."
        }
    }
}

/// Stores manually created content separately from transcription sessions. Raw audio is never accepted or stored by this repository.
actor MioContentRepository {
    private let fileManager: FileManager
    private let storageURL: URL
    private let exportDirectoryURL: URL
    private var cachedItems: [MioContentItem]?
    private var cachedStamp: MioFileStamp?

    init(
        fileManager: FileManager = .default,
        storageURL: URL? = nil,
        exportDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        // This persisted path is independent of the app version and project name.
        self.storageURL = storageURL ?? applicationSupport
            .appendingPathComponent("Mio", isDirectory: true)
            .appendingPathComponent("content-v1.json", isDirectory: false)
        self.exportDirectoryURL = exportDirectoryURL ?? fileManager.temporaryDirectory
            .appendingPathComponent("Mio-exports", isDirectory: true)
    }

    func loadItems() throws -> [MioContentItem] {
        let currentStamp = try MioProtectedFileWriter.fileStamp(for: storageURL, fileManager: fileManager)
        if let cachedItems, currentStamp == cachedStamp {
            return cachedItems
        }

        cachedItems = nil; cachedStamp = nil

        guard fileManager.fileExists(atPath: storageURL.path) else {
            cachedItems = []
            return []
        }

        let data = try Data(contentsOf: storageURL)
        let document = try Self.decoder.decode(MioContentStoreDocument.self, from: data)
        guard document.schemaVersion == MioContentStoreDocument.currentSchemaVersion else {
            throw MioContentRepositoryError.unsupportedSchemaVersion(document.schemaVersion)
        }
        guard Set(document.items.map(\.id)).count == document.items.count else {
            throw MioContentRepositoryError.duplicateIdentity
        }
        let sortedItems = MioContentItem.timelineSorted(document.items)
        cachedItems = sortedItems
        cachedStamp = currentStamp
        return sortedItems
    }

    func upsert(_ item: MioContentItem) throws -> [MioContentItem] {
        var items = try loadItems()
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        items = MioContentItem.timelineSorted(items)
        try write(items)
        return items
    }

    func delete(id: UUID) throws -> [MioContentItem] {
        var items = try loadItems()
        items.removeAll { $0.id == id }
        try write(items)
        return items
    }

    /// Reconcile a retry after partial approval without overwriting later user edits.
    func saveApprovedIfAbsent(_ item: MioContentItem) throws -> [MioContentItem] {
        let items = try loadItems()
        guard !items.contains(where: { $0.id == item.id }) else { return items }
        return try upsert(item)
    }

    func unlinkSession(id: UUID) throws -> [MioContentItem] {
        var items = try loadItems()
        var changed = false
        for index in items.indices where items[index].sessionID == id {
            items[index].sessionID = nil
            changed = true
        }
        if changed { try write(items) }
        return items
    }

    func deleteAll() throws {
        if fileManager.fileExists(atPath: storageURL.path) {
            try fileManager.removeItem(at: storageURL)
        }
        try removeTemporaryExports()
        cachedItems = []; cachedStamp = nil
    }

    /// Full local exports include sessions, so a session deletion removes them as well.
    func removeTemporaryExports() throws {
        for directory in Set([exportDirectoryURL, fileManager.temporaryDirectory]) {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            let temporaryExports = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("Mio-lokal-export-") && $0.pathExtension == "json" }
            for export in temporaryExports { try fileManager.removeItem(at: export) }
        }
    }

    func makeExportFile(
        content: [MioContentItem],
        sessions: [MioSession],
        assistant: MioAssistantStoreDocument? = nil,
        diagnostics: MioDiagnosticsExport? = nil
    ) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sv-SE")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"

        let exportURL = exportDirectoryURL.appendingPathComponent(
            "Mio-lokal-export-\(formatter.string(from: .now))-\(UUID().uuidString).json"
        )
        let export = MioLocalExport(
            content: MioContentItem.timelineSorted(content),
            sessions: sessions.sorted { $0.startedAt > $1.startedAt },
            assistant: assistant,
            diagnostics: diagnostics
        )
        let data = try Self.exportEncoder.encode(export)
        try MioProtectedFileWriter.write(data, to: exportURL, fileManager: fileManager)
        return exportURL
    }

    private func write(_ items: [MioContentItem]) throws {
        let document = MioContentStoreDocument(items: items)
        let data = try Self.encoder.encode(document)
        try MioProtectedFileWriter.write(data, to: storageURL, fileManager: fileManager)
        cachedItems = items
        cachedStamp = try MioProtectedFileWriter.fileStamp(for: storageURL, fileManager: fileManager)
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
