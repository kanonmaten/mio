import Foundation

struct SessionOperationToken: Sendable {
    let sessionID: UUID
    fileprivate let repositoryGeneration: UUID
    fileprivate let sessionGeneration: UUID
}

enum SessionRepositoryError: LocalizedError {
    case staleOperation, missingSession, sessionNotEnded, missingSegment, emptyCorrection
    case duplicateIdentity, invalidEvidence, conflictingEvidence

    var errorDescription: String? {
        switch self {
        case .staleOperation: "Sessionen har raderats eller ändrats under åtgärden."
        case .missingSession: "Sessionen finns inte längre."
        case .sessionNotEnded: "Stoppa sessionen innan du redigerar den."
        case .missingSegment: "Textdelen finns inte i sessionen."
        case .emptyCorrection: "En textdel kan inte vara tom."
        case .duplicateIdentity: "Sessionsdata innehåller dubbla identifierare och har inte ändrats."
        case .invalidEvidence: "Sessionsdata innehåller ogiltiga tidsrelationer och har inte ändrats."
        case .conflictingEvidence: "Originalunderlaget för sessionen stämmer inte och har inte ändrats."
        }
    }
}

/// Stores protected transcript diagnostics inside the app sandbox. Raw audio is never stored;
/// shareable exports are temporary files and persistent sessions are excluded from backup.
actor SessionRepository {
    private let fileManager: FileManager
    private let storageURL: URL
    private let exportDirectoryURL: URL
    private var cachedSessions: [MioSession]?
    private var cachedStamp: MioFileStamp?
    private var generation = UUID()
    private var sessionGenerations: [UUID: UUID] = [:]
    private var deletedSessionIDs: Set<UUID> = []

    init(fileManager: FileManager = .default, storageURL: URL? = nil, exportDirectoryURL: URL? = nil) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        self.storageURL = storageURL ?? applicationSupport
            .appendingPathComponent("Mio", isDirectory: true)
            .appendingPathComponent("sessions.json", isDirectory: false)
        self.exportDirectoryURL = exportDirectoryURL ?? fileManager.temporaryDirectory
            .appendingPathComponent("Mio-exports", isDirectory: true)
    }

    func loadSessions() throws -> [MioSession] {
        let currentStamp = try MioProtectedFileWriter.fileStamp(for: storageURL, fileManager: fileManager)
        if let cachedSessions, currentStamp == cachedStamp {
            return cachedSessions
        }

        cachedSessions = nil; cachedStamp = nil

        guard fileManager.fileExists(atPath: storageURL.path) else {
            cachedSessions = []
            return []
        }

        let data = try Data(contentsOf: storageURL)
        let sessions = try Self.decoder.decode([MioSession].self, from: data)
        try validate(sessions)
        cachedSessions = sessions
        cachedStamp = currentStamp
        return sessions
    }

    func operationGeneration() -> UUID { generation }

    /// Capture this before the operation suspends. Deletion invalidates existing tokens.
    func operationToken(for id: UUID, generation expectedGeneration: UUID) throws -> SessionOperationToken {
        guard expectedGeneration == generation, !deletedSessionIDs.contains(id) else {
            throw SessionRepositoryError.staleOperation
        }
        let sessionGeneration = sessionGenerations[id] ?? UUID()
        sessionGenerations[id] = sessionGeneration
        return SessionOperationToken(sessionID: id, repositoryGeneration: generation,
                                     sessionGeneration: sessionGeneration)
    }

    /// A checkpoint contains capture evidence only. Corrections and metadata have separate
    /// actor-owned commands so stale capture copies cannot overwrite later user changes.
    @discardableResult
    func saveCaptureCheckpoint(_ session: MioSession, token: SessionOperationToken) throws -> MioSession {
        try requireCurrent(token, id: session.id)
        try validate([session])
        var sessions = try loadSessions()
        var stored = session
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            let existing = sessions[index]
            guard existing.startedAt == session.startedAt, existing.captureMode == session.captureMode else {
                throw SessionRepositoryError.conflictingEvidence
            }
            // Finalization is a one-way boundary, including for delayed capture callbacks.
            guard existing.endedAt == nil else { return existing }
            stored = try mergeCapture(session, into: existing)
            stored.mutationRevision = (existing.mutationRevision ?? 0) + 1
            sessions[index] = stored
        } else {
            stored.mutationRevision = 1
            sessions.append(stored)
        }
        sessions.sort { $0.startedAt > $1.startedAt }
        try write(sessions)
        return stored
    }

    @discardableResult
    func updateMetadata(id: UUID, title: String?, note: String?, token: SessionOperationToken) throws -> MioSession {
        try mutateEndedSession(id: id, token: token) { session in
            session.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            session.manualNote = note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }

    @discardableResult
    func correctTranscript(sessionID: UUID, segmentID: UUID, text: String,
                           token: SessionOperationToken) throws -> MioSession {
        try mutateEndedSession(id: sessionID, token: token) { session in
            guard let index = session.transcripts.firstIndex(where: { $0.id == segmentID }) else {
                throw SessionRepositoryError.missingSegment
            }
            let correction = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !correction.isEmpty else { throw SessionRepositoryError.emptyCorrection }
            let priorDisplayText = session.transcripts[index].displayText
            session.transcripts[index].correctedText = correction == session.transcripts[index].text ? nil : correction
            if session.transcripts[index].displayText != priorDisplayText {
                session.transcripts[index].correctionRevision = (session.transcripts[index].correctionRevision ?? 0) + 1
            }
        }
    }

    func delete(id: UUID) throws {
        // Deletion intent is a one-way token boundary even if an atomic commit is
        // followed by an attribute failure. The journal owns any subsequent retry.
        deletedSessionIDs.insert(id)
        sessionGenerations[id] = UUID()
        var sessions = try loadSessions()
        sessions.removeAll { $0.id == id }
        try write(sessions)
        // Session exports are regenerable snapshots and may contain the deleted session.
        try removeTemporaryExports()
    }

    func removeTemporaryExports() throws {
        for directory in Set([exportDirectoryURL, fileManager.temporaryDirectory]) {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            let temporaryExports = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("Mio-session-") && $0.pathExtension == "json" }
            for export in temporaryExports { try fileManager.removeItem(at: export) }
        }
    }

    @discardableResult
    func deleteAll() throws -> UUID {
        // A partially failed deletion still invalidates every pre-deletion checkpoint.
        generation = UUID(); sessionGenerations = [:]
        // This removes app-owned storage and temporary exports. Copies already shared to
        // Files, mail or another app are outside this sandbox and cannot be recalled here.
        if fileManager.fileExists(atPath: storageURL.path) {
            try fileManager.removeItem(at: storageURL)
        }
        try removeTemporaryExports()
        cachedSessions = []; cachedStamp = nil; deletedSessionIDs = []
        return generation
    }

    func makeExportFile(for session: MioSession) throws -> URL {
        // A caller's snapshot must never resurrect a deleted session in a new export.
        guard !deletedSessionIDs.contains(session.id) else { throw SessionRepositoryError.missingSession }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sv-SE")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"

        let exportURL = exportDirectoryURL
            .appendingPathComponent("Mio-session-\(formatter.string(from: session.startedAt))-\(UUID().uuidString).json")
        let latest = try loadSessions().first(where: { $0.id == session.id }) ?? session
        let data = try Self.exportEncoder.encode(latest)
        try MioProtectedFileWriter.write(data, to: exportURL, fileManager: fileManager)
        return exportURL
    }

    private func write(_ sessions: [MioSession]) throws {
        try validate(sessions)
        let data = try Self.encoder.encode(sessions)
        try MioProtectedFileWriter.write(data, to: storageURL, fileManager: fileManager)
        cachedSessions = sessions
        cachedStamp = try MioProtectedFileWriter.fileStamp(for: storageURL, fileManager: fileManager)
    }

    private func requireCurrent(_ token: SessionOperationToken, id: UUID) throws {
        guard token.sessionID == id, token.repositoryGeneration == generation,
              token.sessionGeneration == sessionGenerations[id], !deletedSessionIDs.contains(id) else {
            throw SessionRepositoryError.staleOperation
        }
    }

    private func mutateEndedSession(id: UUID, token: SessionOperationToken,
                                    mutation: (inout MioSession) throws -> Void) throws -> MioSession {
        try requireCurrent(token, id: id)
        var sessions = try loadSessions()
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            throw SessionRepositoryError.missingSession
        }
        guard sessions[index].endedAt != nil else { throw SessionRepositoryError.sessionNotEnded }
        try mutation(&sessions[index])
        sessions[index].mutationRevision = (sessions[index].mutationRevision ?? 0) + 1
        try write(sessions)
        return sessions[index]
    }

    private func mergeCapture(_ incoming: MioSession, into existing: MioSession) throws -> MioSession {
        var merged = existing
        for segment in incoming.transcripts {
            if let stored = merged.transcripts.first(where: { $0.id == segment.id }) {
                var original = stored; original.correctedText = nil; original.correctionRevision = nil
                var checkpoint = segment; checkpoint.correctedText = nil; checkpoint.correctionRevision = nil
                guard original == checkpoint else { throw SessionRepositoryError.conflictingEvidence }
            } else {
                var original = segment; original.correctedText = nil; original.correctionRevision = nil
                merged.transcripts.append(original)
            }
        }
        merged.events = try mergeImmutable(incoming.events, into: existing.events)
        merged.batteryReadings = try mergeImmutable(incoming.batteryReadings, into: existing.batteryReadings)
        for interval in incoming.backgroundIntervals {
            if let index = merged.backgroundIntervals.firstIndex(where: { $0.id == interval.id }) {
                guard merged.backgroundIntervals[index].startedAt == interval.startedAt else {
                    throw SessionRepositoryError.conflictingEvidence
                }
                if merged.backgroundIntervals[index].endedAt == nil { merged.backgroundIntervals[index].endedAt = interval.endedAt }
            } else { merged.backgroundIntervals.append(interval) }
        }
        merged.captureGaps = try mergeImmutable(incoming.captureGaps ?? [], into: existing.captureGaps ?? [])
        merged.endedAt = incoming.endedAt
        return merged
    }

    private func mergeImmutable<T: Identifiable & Equatable>(_ incoming: [T], into existing: [T]) throws -> [T] {
        var merged = existing
        for value in incoming {
            if let stored = merged.first(where: { $0.id == value.id }) {
                guard stored == value else { throw SessionRepositoryError.conflictingEvidence }
            } else { merged.append(value) }
        }
        return merged
    }

    private func validate(_ sessions: [MioSession]) throws {
        try requireUnique(sessions)
        var transcriptIDs: Set<UUID> = []
        for session in sessions {
            guard session.startedAt.timeIntervalSince1970.isFinite,
                  session.endedAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= session.startedAt }) ?? true else {
                throw SessionRepositoryError.invalidEvidence
            }
            try requireUnique(session.transcripts)
            try requireUnique(session.events)
            try requireUnique(session.batteryReadings)
            try requireUnique(session.backgroundIntervals)
            try requireUnique(session.captureGaps ?? [])
            for segment in session.transcripts {
                guard transcriptIDs.insert(segment.id).inserted else { throw SessionRepositoryError.duplicateIdentity }
                guard segment.createdAt.timeIntervalSince1970.isFinite,
                      segment.audioStartedAt.timeIntervalSince1970.isFinite,
                      segment.audioEndedAt.timeIntervalSince1970.isFinite,
                      segment.audioEndedAt >= segment.audioStartedAt else { throw SessionRepositoryError.invalidEvidence }
            }
            for interval in session.backgroundIntervals {
                guard interval.startedAt.timeIntervalSince1970.isFinite,
                      interval.endedAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= interval.startedAt }) ?? true else {
                    throw SessionRepositoryError.invalidEvidence
                }
            }
            for gap in session.captureGaps ?? [] {
                guard gap.startedAt.timeIntervalSince1970.isFinite, gap.endedAt.timeIntervalSince1970.isFinite,
                      gap.endedAt >= gap.startedAt else { throw SessionRepositoryError.invalidEvidence }
            }
        }
    }

    private func requireUnique<T: Identifiable>(_ values: [T]) throws {
        guard Set(values.map(\.id)).count == values.count else { throw SessionRepositoryError.duplicateIdentity }
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
