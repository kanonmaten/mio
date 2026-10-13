import Foundation

enum MioAssistantRepositoryError: LocalizedError {
    case unsupportedSchemaVersion(Int)
    case invalidRelationships
    case suggestionChanged, approvalInProgress, invalidApproval

    var errorDescription: String? {
        switch self {
        case .suggestionChanged:
            "Förslaget ändrades. Dina ändringar finns kvar; granska det aktuella förslaget innan du godkänner igen."
        case .approvalInProgress:
            "Förslaget håller redan på att godkännas. Vänta tills åtgärden är klar."
        case .invalidApproval:
            "Godkännandet är inte längre aktuellt. Granska förslaget igen."
        case .invalidRelationships:
            "Assistentdata innehåller dubbla identifierare eller trasiga relationer och har inte ändrats."
        case let .unsupportedSchemaVersion(version):
            "Den lokala assistentfilen använder okänd schemaversion \(version) och har inte skrivits över."
        }
    }
}

/// Persistence boundary for the assistant document. One storage object is owned and
/// called by exactly one repository actor.
protocol MioAssistantStorage: AnyObject {
    func stamp() throws -> MioFileStamp?
    /// Nil means that nothing has been stored yet. Unknown schemas throw and are never replaced.
    func read() throws -> MioAssistantStoreDocument?
    /// `previous` is the last state this owner read or wrote; nil requests a full replacement.
    func write(_ document: MioAssistantStoreDocument, replacing previous: MioAssistantStoreDocument?) throws
    func erase() throws
}

final class MioJSONAssistantStorage: MioAssistantStorage {
    private let fileManager: FileManager
    let storageURL: URL

    init(storageURL: URL, fileManager: FileManager) {
        self.storageURL = storageURL
        self.fileManager = fileManager
    }

    func stamp() throws -> MioFileStamp? {
        try MioProtectedFileWriter.fileStamp(for: storageURL, fileManager: fileManager)
    }

    func read() throws -> MioAssistantStoreDocument? {
        guard fileManager.fileExists(atPath: storageURL.path) else { return nil }
        let data = try Data(contentsOf: storageURL)
        struct SchemaHeader: Decodable { let schemaVersion: Int }
        let header = try Self.decoder.decode(SchemaHeader.self, from: data)
        guard header.schemaVersion == MioAssistantStoreDocument.currentSchemaVersion else {
            throw MioAssistantRepositoryError.unsupportedSchemaVersion(header.schemaVersion)
        }
        return try Self.decoder.decode(MioAssistantStoreDocument.self, from: data)
    }

    func write(_ document: MioAssistantStoreDocument, replacing previous: MioAssistantStoreDocument?) throws {
        let data = try Self.encoder.encode(document)
        try MioProtectedFileWriter.write(data, to: storageURL, fileManager: fileManager)
    }

    func erase() throws {
        if fileManager.fileExists(atPath: storageURL.path) {
            try fileManager.removeItem(at: storageURL)
        }
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

/// Owns only proposals, lesson metadata and source identities, never raw audio.
/// Mutations read this actor's cache after checking the external-file fingerprint,
/// preserving concurrent work and refusing replacement of an unknown schema.
actor MioAssistantRepository {
    private let core: MioAssistantRepositoryCore

    init(fileManager: FileManager = .default, storageURL: URL? = nil) {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        let resolvedURL = storageURL ?? applicationSupport
            .appendingPathComponent("Mio", isDirectory: true)
            .appendingPathComponent("assistant-v1.json", isDirectory: false)
        core = MioAssistantRepositoryCore(storage: MioJSONAssistantStorage(storageURL: resolvedURL, fileManager: fileManager))
    }

    func loadDocument() throws -> MioAssistantStoreDocument { try core.loadDocument() }
    func invalidateCache() { core.invalidateCache() }
    func claimSuggestion(id: UUID, expectedRevision: Int) throws -> MioSuggestionApprovalClaim {
        try core.claimSuggestion(id: id, expectedRevision: expectedRevision)
    }
    func releaseApproval(_ claim: MioSuggestionApprovalClaim) throws { try core.releaseApproval(claim) }
    func completeApproval(_ claim: MioSuggestionApprovalClaim) throws { try core.completeApproval(claim) }
    func reconcileAcceptedContent(id: UUID) throws { try core.reconcileAcceptedContent(id: id) }
    func addSuggestion(_ suggestion: MioSuggestion) throws { try core.addSuggestion(suggestion) }
    @discardableResult
    func detectSuggestions(in session: MioSession, now: Date = .now) throws -> Int {
        try core.detectSuggestions(in: session, now: now)
    }
    @discardableResult
    func applyAnalysis(_ result: MioAnalysisResult, request: MioAnalysisRequest, session: MioSession) throws -> Int {
        try core.applyAnalysis(result, request: request, session: session)
    }
    func markLessonPartUnprocessed(request: MioAnalysisRequest, session: MioSession) throws {
        try core.markLessonPartUnprocessed(request: request, session: session)
    }
    func deferSuggestion(id: UUID, now: Date = .now) throws { try core.deferSuggestion(id: id, now: now) }
    func removeSuggestion(id: UUID) throws { try core.removeSuggestion(id: id) }
    func saveLesson(_ lesson: MioLesson, session: MioSession) throws { try core.saveLesson(lesson, session: session) }
    func deleteLesson(id: UUID) throws { try core.deleteLesson(id: id) }
    func deleteSessionData(sessionID: UUID) throws { try core.deleteSessionData(sessionID: sessionID) }
    func deleteAll(now: Date = .now) throws { try core.deleteAll(now: now) }
}

/// Assistant rules shared by the JSON and SwiftData actors; owned and serialized by one actor.
final class MioAssistantRepositoryCore {
    private let storage: any MioAssistantStorage
    private var deletedSessionIDs: Set<UUID> = []
    private var ignoreSessionsStartedThrough: Date?
    private var cachedDocument: MioAssistantStoreDocument?
    private var cachedFingerprint: MioFileStamp?
    private var approvalClaims: [UUID: (claim: MioSuggestionApprovalClaim, wasClosed: Bool)] = [:]

    init(storage: any MioAssistantStorage) {
        self.storage = storage
    }

    func loadDocument() throws -> MioAssistantStoreDocument {
        let fingerprint = try storage.stamp()
        if let cachedDocument, fingerprint == cachedFingerprint { return cachedDocument }
        // A replaced fixture must be validated even if the previous file was valid.
        cachedDocument = nil
        cachedFingerprint = nil
        guard let document = try storage.read() else {
            let document = MioAssistantStoreDocument()
            cachedDocument = document
            return document
        }
        try validate(document)
        cachedDocument = document
        cachedFingerprint = fingerprint
        return document
    }

    func invalidateCache() { cachedDocument = nil; cachedFingerprint = nil }

    func claimSuggestion(id: UUID, expectedRevision: Int) throws -> MioSuggestionApprovalClaim {
        var document = try loadDocument()
        guard let suggestion = document.suggestions.first(where: { $0.id == id }) else {
            throw MioAssistantValidationError.missingSuggestion
        }
        guard suggestion.reviewRevision == expectedRevision else { throw MioAssistantRepositoryError.suggestionChanged }
        guard approvalClaims[id] == nil else { throw MioAssistantRepositoryError.approvalInProgress }
        let claim = MioSuggestionApprovalClaim(suggestionID: id, revision: expectedRevision)
        var wasClosed = true
        if let index = document.analysisDecisions?.firstIndex(where: { $0.id == id }) {
            wasClosed = document.analysisDecisions![index].isClosed
            document.analysisDecisions?[index].isClosed = true
        }
        // Close before content storage. An analysis already in flight then cannot replace it.
        try write(document)
        approvalClaims[id] = (claim, wasClosed)
        return claim
    }

    func releaseApproval(_ claim: MioSuggestionApprovalClaim) throws {
        let reservation = try requireApproval(claim)
        var document = try loadDocument()
        guard document.suggestions.contains(where: { $0.id == claim.suggestionID && $0.reviewRevision == claim.revision }) else {
            throw MioAssistantRepositoryError.suggestionChanged
        }
        if let index = document.analysisDecisions?.firstIndex(where: { $0.id == claim.suggestionID }) {
            document.analysisDecisions?[index].isClosed = reservation.wasClosed
        }
        try write(document)
        approvalClaims[claim.suggestionID] = nil
    }

    func completeApproval(_ claim: MioSuggestionApprovalClaim) throws {
        _ = try requireApproval(claim)
        var document = try loadDocument()
        guard document.suggestions.contains(where: { $0.id == claim.suggestionID && $0.reviewRevision == claim.revision }) else {
            throw MioAssistantRepositoryError.suggestionChanged
        }
        document.suggestions.removeAll { $0.id == claim.suggestionID }
        if let index = document.analysisDecisions?.firstIndex(where: { $0.id == claim.suggestionID }) {
            document.analysisDecisions?[index].isClosed = true
        }
        try write(document)
        approvalClaims[claim.suggestionID] = nil
    }

    /// Trusted workflow reconciliation only after the content actor confirms this ID
    /// already exists. It clears a partial acceptance without rewriting the content.
    func reconcileAcceptedContent(id: UUID) throws {
        var document = try loadDocument()
        if document.suggestions.contains(where: { $0.id == id }) {
            document.suggestions.removeAll { $0.id == id }
            if let index = document.analysisDecisions?.firstIndex(where: { $0.id == id }) {
                document.analysisDecisions?[index].isClosed = true
            }
            try write(document)
        }
        approvalClaims[id] = nil
    }

    private func requireApproval(_ claim: MioSuggestionApprovalClaim) throws -> (claim: MioSuggestionApprovalClaim, wasClosed: Bool) {
        guard let reservation = approvalClaims[claim.suggestionID], reservation.claim == claim else {
            throw MioAssistantRepositoryError.invalidApproval
        }
        return reservation
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
        let fragments = session.transcripts.flatMap(MioAnalysisFragment.make)
        guard Set(fragments.map(\.id)).count == fragments.count else { throw MioCloudError.invalidContext }
        let actualFragments = Dictionary(uniqueKeysWithValues: fragments.map { ($0.id, $0) })
        guard request.allFragments.allSatisfy({ submitted in
            guard let actual = actualFragments[submitted.id] else { return false }
            return actual.id == submitted.id && actual.text == submitted.text && actual.occurredAt == submitted.occurredAt
                && (submitted.sourceRevision == nil || submitted.sourceRevision == actual.sourceRevision)
        }) else { throw MioCloudError.invalidContext }
        var document = try loadDocument()
        let alreadyAnalyzed = Set((document.analyses ?? []).filter { $0.sessionID == session.id && (result.sections == nil || $0.sections != nil) }.flatMap(\.fragmentIDs))
        guard alreadyAnalyzed.isDisjoint(with: request.fragments.map(\.id)) else { return 0 }
        let sources = Dictionary(uniqueKeysWithValues: request.allFragments.map { ($0.id, $0) })
        var decisions = document.analysisDecisions ?? []
        var count = 0
        for candidate in result.candidates {
            guard let firstID = candidate.sourceIDs.first, let segmentID = sources[firstID]?.segmentID else { continue }
            let source = MioProcessedSource(sessionID: session.id, segmentID: segmentID)
            // A segment can contain both a local command and an unrelated ordinary plan.
            let date = candidate.scheduledAt.flatMap(MioAnalysisResult.parseDate)
            let linked = decisions.filter { $0.sessionID == session.id
                && !Set($0.sourceIDs).isDisjoint(with: candidate.sourceIDs.filter { !request.fragments.map(\.id).contains($0) }) }
            if let replacement = candidate.replacesID {
                // The persisted decision is authoritative: acceptance/rejection may
                // have happened while the server was preparing this response.
                guard linked.count == 1, linked[0].id == replacement, !linked[0].isClosed,
                      linked[0].kind == candidate.kind,
                      let suggestionIndex = document.suggestions.firstIndex(where: { $0.id == replacement }),
                      let decisionIndex = decisions.firstIndex(where: { $0.id == replacement }) else { continue }
                document.suggestions[suggestionIndex].title = candidate.title
                document.suggestions[suggestionIndex].body = candidate.body
                document.suggestions[suggestionIndex].scheduledAt = date ?? document.suggestions[suggestionIndex].scheduledAt
                document.suggestions[suggestionIndex].needsDateConfirmation = date == nil
                document.suggestions[suggestionIndex].evidence = candidate.evidence
                let nextRevision = document.suggestions[suggestionIndex].reviewRevision.addingReportingOverflow(1)
                guard !nextRevision.overflow else { throw MioAssistantRepositoryError.invalidRelationships }
                document.suggestions[suggestionIndex].revision = nextRevision.partialValue
                decisions[decisionIndex].sourceIDs = Array(Set(decisions[decisionIndex].sourceIDs + candidate.sourceIDs)).sorted()
                document.processedSources.insert(source)
                count += 1
                continue
            }
            guard linked.isEmpty else { continue }
            let proposal = MioSuggestion(
                kind: candidate.kind, title: candidate.title, body: candidate.body,
                scheduledAt: date, sessionID: session.id, sourceSegmentID: segmentID,
                evidence: candidate.evidence, needsDateConfirmation: date == nil
            )
            // V2 never guesses whether identical new-only events mean the same
            // plan. Only an explicit, grounded replacement may merge identities.
            let duplicate = !request.usesContextContract && document.suggestions.contains {
                $0.sessionID == session.id && $0.kind == proposal.kind
                    && $0.scheduledAt == proposal.scheduledAt
                    && $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "sv_SE"))
                    == proposal.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "sv_SE"))
            }
            if !duplicate {
                document.suggestions.append(proposal)
                decisions.append(MioAnalysisDecision(id: proposal.id, sessionID: session.id,
                    kind: proposal.kind, sourceIDs: candidate.sourceIDs, isClosed: false))
                count += 1
            }
            document.processedSources.insert(source)
        }
        var records = document.analyses ?? []
        records.append(MioAnalysisRecord(id: UUID(), sessionID: session.id, fragmentIDs: request.fragments.map(\.id),
                                         highlights: result.highlights, uncertainties: result.uncertainties, createdAt: .now,
                                         sections: result.sections, metadata: result.metadata,
                                         sourceRevisions: request.sourceRevisions))
        document.analyses = records
        document.analysisDecisions = decisions
        try write(document)
        return count
    }

    /// Records a lesson part whose model answers were rejected repeatedly, so the lesson can
    /// continue past it. Only the exact submitted text is accepted; nothing from a model is stored.
    func markLessonPartUnprocessed(request: MioAnalysisRequest, session: MioSession) throws {
        guard !isDeleted(session) else { throw MioAssistantValidationError.deletedSession }
        guard request.mode == .lesson, session.isLesson, !request.fragments.isEmpty else { throw MioCloudError.invalidContext }
        _ = try request.validatedData()
        let actual = Dictionary(uniqueKeysWithValues: session.transcripts.flatMap(MioAnalysisFragment.make).map { ($0.id, $0) })
        guard request.fragments.allSatisfy({ actual[$0.id]?.text == $0.text && actual[$0.id]?.occurredAt == $0.occurredAt })
        else { throw MioCloudError.invalidContext }
        var document = try loadDocument()
        let handled = Set((document.analyses ?? []).filter { $0.sessionID == session.id && $0.sections != nil }.flatMap(\.fragmentIDs))
        guard handled.isDisjoint(with: request.fragments.map(\.id)) else { return }
        var records = document.analyses ?? []
        records.append(MioAnalysisRecord(id: UUID(), sessionID: session.id, fragmentIDs: request.fragments.map(\.id),
                                         highlights: [], uncertainties: [], createdAt: .now, sections: [],
                                         sourceRevisions: request.sourceRevisions, isUnprocessed: true))
        document.analyses = records
        try write(document)
    }

    func deferSuggestion(id: UUID, now: Date = .now) throws {
        guard approvalClaims[id] == nil else { throw MioAssistantRepositoryError.approvalInProgress }
        var document = try loadDocument()
        guard let index = document.suggestions.firstIndex(where: { $0.id == id }) else {
            throw MioAssistantValidationError.missingSuggestion
        }
        document.suggestions[index].state = .deferred
        document.suggestions[index].deferredAt = now
        try write(document)
    }

    func removeSuggestion(id: UUID) throws {
        guard approvalClaims[id] == nil else { throw MioAssistantRepositoryError.approvalInProgress }
        var document = try loadDocument()
        guard document.suggestions.contains(where: { $0.id == id }) else { return }
        document.suggestions.removeAll { $0.id == id }
        if let index = document.analysisDecisions?.firstIndex(where: { $0.id == id }) {
            document.analysisDecisions?[index].isClosed = true
        }
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
        // Intent invalidates callbacks even if the protected write commits and
        // subsequently reports a privacy-attribute failure. Retry is idempotent.
        deletedSessionIDs.insert(sessionID)
        var document = try loadDocument()
        let deletedSuggestionIDs = Set(document.suggestions.filter { $0.sessionID == sessionID }.map(\.id))
        approvalClaims = approvalClaims.filter { !deletedSuggestionIDs.contains($0.key) }
        let before = document
        document.suggestions.removeAll { $0.sessionID == sessionID }
        document.lessons.removeAll { $0.sessionID == sessionID }
        document.processedSources = document.processedSources.filter { $0.sessionID != sessionID }
        document.analyses?.removeAll { $0.sessionID == sessionID }
        document.analysisDecisions?.removeAll { $0.sessionID == sessionID }
        if document.suggestions != before.suggestions || document.lessons != before.lessons
            || document.processedSources != before.processedSources || document.analyses != before.analyses
            || document.analysisDecisions != before.analysisDecisions {
            try write(document)
        }
    }

    func deleteAll(now: Date = .now) throws {
        // Queued callbacks can hold sessions that have never produced a proposal,
        // so invalidate them at intent, before any destruction or throwing I/O.
        ignoreSessionsStartedThrough = max(ignoreSessionsStartedThrough ?? now, now)
        approvalClaims = [:]
        invalidateCache()
        try storage.erase()
    }

    private func isDeleted(_ session: MioSession) -> Bool {
        deletedSessionIDs.contains(session.id)
            || ignoreSessionsStartedThrough.map { session.startedAt <= $0 } == true
    }

    private func validate(_ document: MioAssistantStoreDocument) throws {
        let analyses = document.analyses ?? []
        let decisions = document.analysisDecisions ?? []
        guard Set(document.suggestions.map(\.id)).count == document.suggestions.count,
              Set(document.lessons.map(\.id)).count == document.lessons.count,
              Set(analyses.map(\.id)).count == analyses.count,
              Set(decisions.map(\.id)).count == decisions.count,
              document.suggestions.allSatisfy({ $0.sourceSegmentID == nil || $0.sessionID != nil }),
              document.suggestions.allSatisfy({ ($0.revision ?? 0) >= 0 }),
              analyses.allSatisfy({ Set($0.fragmentIDs).count == $0.fragmentIDs.count && $0.sourceRevisionsAreValid && $0.unprocessedShapeIsValid }),
              decisions.allSatisfy({ decision in
                  Set(decision.sourceIDs).count == decision.sourceIDs.count && (decision.isClosed ||
                      document.suggestions.contains { $0.id == decision.id && $0.sessionID == decision.sessionID && $0.kind == decision.kind })
              }),
              document.lessons.allSatisfy({ $0.startedAt.timeIntervalSince1970.isFinite
                  // Legacy ISO-8601 persistence rounds subsecond intervals to one
                  // instant. Input validation still requires a positive interval.
                  && $0.endedAt.timeIntervalSince1970.isFinite && $0.startedAt <= $0.endedAt
                  && MioSourceRevision.areValid($0.sourceRevisions) })
        else { throw MioAssistantRepositoryError.invalidRelationships }
    }

    private func write(_ document: MioAssistantStoreDocument) throws {
        try validate(document)
        // The cache equals the last persisted document, so storage may write only the difference.
        try storage.write(document, replacing: cachedDocument)
        cachedDocument = document
        cachedFingerprint = try storage.stamp()
    }
}
