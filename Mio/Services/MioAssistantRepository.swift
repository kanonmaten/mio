import Foundation

enum MioAssistantRepositoryError: LocalizedError {
    case unsupportedSchemaVersion(Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "Den lokala assistentfilen använder okänd schemaversion \(version) och har inte skrivits över."
        }
    }
}

/// Owns only proposals, lesson metadata and source identities, never raw audio.
/// Each mutation loads the latest document inside this actor to preserve concurrent
/// detections and to refuse replacement of an unknown schema.
actor MioAssistantRepository {
    private let fileManager: FileManager
    private let storageURL: URL
    private var deletedSessionIDs: Set<UUID> = []
    private var ignoreSessionsStartedThrough: Date?

    init(fileManager: FileManager = .default, storageURL: URL? = nil) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        self.storageURL = storageURL ?? applicationSupport
            .appendingPathComponent("Mio", isDirectory: true)
            .appendingPathComponent("assistant-v1.json", isDirectory: false)
    }

    func loadDocument() throws -> MioAssistantStoreDocument {
        guard fileManager.fileExists(atPath: storageURL.path) else {
            return MioAssistantStoreDocument()
        }
        let data = try Data(contentsOf: storageURL)
        struct SchemaHeader: Decodable { let schemaVersion: Int }
        let header = try Self.decoder.decode(SchemaHeader.self, from: data)
        guard header.schemaVersion == MioAssistantStoreDocument.currentSchemaVersion else {
            throw MioAssistantRepositoryError.unsupportedSchemaVersion(header.schemaVersion)
        }
        return try Self.decoder.decode(MioAssistantStoreDocument.self, from: data)
    }

    func addSuggestion(_ suggestion: MioSuggestion) throws {
        if let sessionID = suggestion.sessionID, deletedSessionIDs.contains(sessionID) {
            throw MioAssistantValidationError.deletedSession
        }
        var document = try loadDocument()
        guard !document.suggestions.contains(where: { $0.id == suggestion.id }) else { return }
        if let sessionID = suggestion.sessionID, let segmentID = suggestion.sourceSegmentID {
            let source = MioProcessedSource(sessionID: sessionID, segmentID: segmentID)
            guard !document.processedSources.contains(source) else { return }
            document.processedSources.insert(source)
        }
        document.suggestions.append(suggestion)
        try write(document)
    }

    @discardableResult
    func detectSuggestions(in session: MioSession, now: Date = .now) throws -> Int {
        guard !isDeleted(session), !session.isLesson else { return 0 }
        var document = try loadDocument()
        var count = 0
        for segment in session.transcripts {
            let source = MioProcessedSource(sessionID: session.id, segmentID: segment.id)
            guard !document.processedSources.contains(source) else { continue }
            let suggestions = MioLocalSuggestionEngine.suggestions(from: segment, sessionID: session.id, now: now)
            guard !suggestions.isEmpty else { continue }
            document.suggestions.append(contentsOf: suggestions)
            document.processedSources.insert(source)
            count += suggestions.count
        }
        if count > 0 { try write(document) }
        return count
    }

    @discardableResult
    func applyAnalysis(_ result: MioAnalysisResult, request: MioAnalysisRequest, session: MioSession) throws -> Int {
        guard !isDeleted(session) else { throw MioAssistantValidationError.deletedSession }
        _ = try request.validatedData()
        try result.validate(against: request)
        let actualFragments = Dictionary(uniqueKeysWithValues: session.transcripts.flatMap(MioAnalysisFragment.make).map { ($0.id, $0) })
        guard request.fragments.allSatisfy({ actualFragments[$0.id] == $0 }) else { throw MioCloudError.invalidContext }
        var document = try loadDocument()
        let alreadyAnalyzed = Set((document.analyses ?? []).filter { $0.sessionID == session.id }.flatMap(\.fragmentIDs))
        guard alreadyAnalyzed.isDisjoint(with: request.fragments.map(\.id)) else { return 0 }
        let sources = Dictionary(uniqueKeysWithValues: request.fragments.map { ($0.id, $0) })
        var count = 0
        for candidate in result.candidates {
            guard let firstID = candidate.sourceIDs.first, let segmentID = sources[firstID]?.segmentID else { continue }
            let source = MioProcessedSource(sessionID: session.id, segmentID: segmentID)
            // A segment can contain both a local command and an unrelated ordinary plan.
            let date = candidate.scheduledAt.flatMap(MioAnalysisResult.parseDate)
            let proposal = MioSuggestion(
                kind: candidate.kind, title: candidate.title, body: candidate.body,
                scheduledAt: date, sessionID: session.id, sourceSegmentID: segmentID,
                evidence: candidate.evidence, needsDateConfirmation: date == nil
            )
            let duplicate = document.suggestions.contains {
                $0.sessionID == session.id && $0.kind == proposal.kind
                    && $0.scheduledAt == proposal.scheduledAt
                    && $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "sv_SE"))
                    == proposal.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "sv_SE"))
            }
            if !duplicate { document.suggestions.append(proposal); count += 1 }
            document.processedSources.insert(source)
        }
        var records = document.analyses ?? []
        records.append(MioAnalysisRecord(id: UUID(), sessionID: session.id, fragmentIDs: request.fragments.map(\.id),
                                         highlights: result.highlights, uncertainties: result.uncertainties, createdAt: .now))
        document.analyses = records
        try write(document)
        return count
    }

    func deferSuggestion(id: UUID, now: Date = .now) throws {
        var document = try loadDocument()
        guard let index = document.suggestions.firstIndex(where: { $0.id == id }) else {
            throw MioAssistantValidationError.missingSuggestion
        }
        document.suggestions[index].state = .deferred
        document.suggestions[index].deferredAt = now
        try write(document)
    }

    func removeSuggestion(id: UUID) throws {
        var document = try loadDocument()
        guard document.suggestions.contains(where: { $0.id == id }) else { return }
        document.suggestions.removeAll { $0.id == id }
        // processedSources contains only UUIDs, so a rejection cannot keep its text.
        try write(document)
    }

    func saveLesson(_ lesson: MioLesson, session: MioSession) throws {
        guard !isDeleted(session) else { throw MioAssistantValidationError.deletedSession }
        var document = try loadDocument()
        try MioLocalSuggestionEngine.validateLesson(lesson, session: session, otherLessons: document.lessons)
        if let index = document.lessons.firstIndex(where: { $0.id == lesson.id }) {
            document.lessons[index] = lesson
        } else {
            document.lessons.append(lesson)
        }
        try write(document)
    }

    func deleteLesson(id: UUID) throws {
        var document = try loadDocument()
        guard document.lessons.contains(where: { $0.id == id }) else { return }
        document.lessons.removeAll { $0.id == id }
        try write(document)
    }

    func deleteSessionData(sessionID: UUID) throws {
        var document = try loadDocument()
        let before = document
        document.suggestions.removeAll { $0.sessionID == sessionID }
        document.lessons.removeAll { $0.sessionID == sessionID }
        document.processedSources = document.processedSources.filter { $0.sessionID != sessionID }
        document.analyses?.removeAll { $0.sessionID == sessionID }
        if document.suggestions != before.suggestions || document.lessons != before.lessons
            || document.processedSources != before.processedSources || document.analyses != before.analyses {
            try write(document)
        }
        deletedSessionIDs.insert(sessionID)
    }

    func deleteAll(now: Date = .now) throws {
        if fileManager.fileExists(atPath: storageURL.path) {
            try fileManager.removeItem(at: storageURL)
        }
        // Queued callbacks can hold sessions that have never produced a proposal,
        // so their UUIDs cannot be recovered from the deleted assistant document.
        ignoreSessionsStartedThrough = max(ignoreSessionsStartedThrough ?? now, now)
    }

    private func isDeleted(_ session: MioSession) -> Bool {
        deletedSessionIDs.contains(session.id)
            || ignoreSessionsStartedThrough.map { session.startedAt <= $0 } == true
    }

    private func write(_ document: MioAssistantStoreDocument) throws {
        let directory = storageURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS) || os(macOS)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
        #endif
        let data = try Self.encoder.encode(document)
        #if os(iOS)
        try data.write(to: storageURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: storageURL, options: .atomic)
        #endif
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
