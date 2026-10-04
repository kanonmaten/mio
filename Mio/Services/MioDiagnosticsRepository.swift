import Foundation

/// Text and credentials have no fields here. A generation prevents deleted data returning from late network completions.
actor MioDiagnosticsRepository {
    static let shared = MioDiagnosticsRepository()
    private let storageURL: URL
    private let fileManager: FileManager
    private var events: [MioDiagnosticEvent] = []
    private var loaded = false
    private var cachedStamp: MioFileStamp?
    private var storageStatus: MioDiagnosticsStorageStatus = .available
    private var generation = UUID()
    private var deletionCutoff = Date.distantPast

    init(storageURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        self.storageURL = storageURL ?? support.appendingPathComponent("Mio/diagnostics-v1.json")
    }

    func beginRequest() -> UUID { generation }

    func record(_ event: MioDiagnosticEvent, generation token: UUID, now: Date = .now) {
        guard token == generation, event.startedAt > deletionCutoff else { return }
        load()
        guard event.isValid else { return }
        var safeEvent = event
        safeEvent.gateway = event.gateway?.sanitized()
        events.append(safeEvent)
        prune(now: now)
        guard storageStatus != .unsupportedSchema, storageStatus != .readFailed else { return }
        persist()
    }

    private func persist() {
        guard storageStatus != .unsupportedSchema, storageStatus != .readFailed else { return }
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(MioDiagnosticsStoreDocument(events: events))
            try MioProtectedFileWriter.write(data, to: storageURL, fileManager: fileManager)
            cachedStamp = try MioProtectedFileWriter.fileStamp(for: storageURL, fileManager: fileManager)
            storageStatus = .available
        } catch {
            // Atomic bytes may already be committed when a privacy attribute fails.
            // Recognize our own file change without clearing the visible write failure.
            cachedStamp = try? MioProtectedFileWriter.fileStamp(for: storageURL, fileManager: fileManager)
            storageStatus = .writeFailed
        }
    }

    func snapshot(now: Date = .now) -> MioDiagnosticsSnapshot {
        load()
        let previousCount = events.count
        prune(now: now)
        if previousCount != events.count { persist() }
        return MioDiagnosticsSnapshot(events: events, storageStatus: storageStatus)
    }

    func invalidateForDeletion() { generation = UUID(); deletionCutoff = .now }

    func deleteAll() throws {
        invalidateForDeletion()
        if fileManager.fileExists(atPath: storageURL.path) { try fileManager.removeItem(at: storageURL) }
        events = []; loaded = true; cachedStamp = nil; storageStatus = .available
    }

    private func load() {
        do {
            let currentStamp = try MioProtectedFileWriter.fileStamp(for: storageURL, fileManager: fileManager)
            if loaded, cachedStamp == currentStamp { return }
            loaded = true; cachedStamp = currentStamp
            events = []; storageStatus = .available
            guard currentStamp != nil else { return }
            let attributes = try fileManager.attributesOfItem(atPath: storageURL.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= 1_048_576 else {
                storageStatus = .readFailed; return
            }
            let data = try Data(contentsOf: storageURL)
            // Read the schema before decoding its contents; unknown schemas are never writable.
            let header = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard header?["schemaVersion"] as? Int == 1 else { storageStatus = .unsupportedSchema; return }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(MioDiagnosticsStoreDocument.self, from: data).events
            guard decoded.allSatisfy(\.isValid) else { storageStatus = .readFailed; return }
            events = decoded.map { event in
                var safe = event; safe.gateway = event.gateway?.sanitized(); return safe
            }
        } catch { storageStatus = .readFailed }
    }

    private func prune(now: Date) {
        events = Array(events.filter { $0.startedAt >= now.addingTimeInterval(-7 * 86_400) && $0.startedAt <= now }
            .suffix(200))
    }
}
