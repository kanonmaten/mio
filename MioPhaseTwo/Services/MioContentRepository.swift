import Foundation

enum MioContentRepositoryError: LocalizedError {
    case unsupportedSchemaVersion(Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "Den lokala innehållsfilen använder okänd schemaversion \(version) och har inte skrivits över."
        }
    }
}

/// Stores manually created phase 2 content separately from the verified phase 1
/// session file. Raw audio is never accepted or stored by this repository.
actor MioContentRepository {
    private let fileManager: FileManager
    private let storageURL: URL
    private let exportDirectoryURL: URL
    private var cachedItems: [MioContentItem]?

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
        self.storageURL = storageURL ?? applicationSupport
            .appendingPathComponent("MioPhaseTwo", isDirectory: true)
            .appendingPathComponent("content-v1.json", isDirectory: false)
        self.exportDirectoryURL = exportDirectoryURL ?? fileManager.temporaryDirectory
    }

    func loadItems() throws -> [MioContentItem] {
        if let cachedItems {
            return cachedItems
        }

        guard fileManager.fileExists(atPath: storageURL.path) else {
            cachedItems = []
            return []
        }

        let data = try Data(contentsOf: storageURL)
        let document = try Self.decoder.decode(MioContentStoreDocument.self, from: data)
        guard document.schemaVersion == MioContentStoreDocument.currentSchemaVersion else {
            throw MioContentRepositoryError.unsupportedSchemaVersion(document.schemaVersion)
        }
        let sortedItems = MioContentItem.timelineSorted(document.items)
        cachedItems = sortedItems
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

    func deleteAll() throws {
        if fileManager.fileExists(atPath: storageURL.path) {
            try fileManager.removeItem(at: storageURL)
        }
        let temporaryExports = try fileManager.contentsOfDirectory(
            at: exportDirectoryURL,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("Mio-lokal-export-") && $0.pathExtension == "json"
        }
        for export in temporaryExports {
            try? fileManager.removeItem(at: export)
        }
        cachedItems = []
    }

    func makeExportFile(
        content: [MioContentItem],
        sessions: [MioSession]
    ) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sv-SE")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"

        try fileManager.createDirectory(at: exportDirectoryURL, withIntermediateDirectories: true)
        let exportURL = exportDirectoryURL.appendingPathComponent(
            "Mio-lokal-export-\(formatter.string(from: .now)).json"
        )
        let export = MioLocalExport(
            content: MioContentItem.timelineSorted(content),
            sessions: sessions.sorted { $0.startedAt > $1.startedAt }
        )
        let data = try Self.exportEncoder.encode(export)
        try data.write(to: exportURL, options: .atomic)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: exportURL.path
        )
        return exportURL
    }

    private func write(_ items: [MioContentItem]) throws {
        let directory = storageURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = MioContentStoreDocument(items: items)
        let data = try Self.encoder.encode(document)
        try data.write(to: storageURL, options: .atomic)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: storageURL.path
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(resourceValues)
        cachedItems = items
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
