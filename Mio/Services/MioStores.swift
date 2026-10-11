import Foundation

// Storage seams used by the view models. The JSON actors remain the Linux test fakes and
// the fallback when the one-time SwiftData migration refuses an unknown legacy schema;
// the SwiftData actors share the same repository cores, so the rules are identical.
// Requirements are async so a deferred proxy can wait for the migration before forwarding.

protocol MioSessionStore: Sendable {
    func loadSessions() async throws -> [MioSession]
    func operationGeneration() async -> UUID
    func operationToken(for id: UUID, generation expectedGeneration: UUID) async throws -> SessionOperationToken
    @discardableResult
    func saveCaptureCheckpoint(_ session: MioSession, token: SessionOperationToken) async throws -> MioSession
    @discardableResult
    func updateMetadata(id: UUID, title: String?, note: String?, token: SessionOperationToken) async throws -> MioSession
    @discardableResult
    func correctTranscript(sessionID: UUID, segmentID: UUID, text: String,
                           token: SessionOperationToken) async throws -> MioSession
    @discardableResult
    func renameSpeaker(sessionID: UUID, speaker: Int, name: String,
                       token: SessionOperationToken) async throws -> MioSession
    func delete(id: UUID) async throws
    func removeTemporaryExports() async throws
    @discardableResult
    func deleteAll() async throws -> UUID
    func makeExportFile(for session: MioSession) async throws -> URL
}

protocol MioContentStore: Sendable {
    func loadItems() async throws -> [MioContentItem]
    func upsert(_ item: MioContentItem) async throws -> [MioContentItem]
    func delete(id: UUID) async throws -> [MioContentItem]
    func saveApprovedIfAbsent(_ item: MioContentItem) async throws -> [MioContentItem]
    func unlinkSession(id: UUID) async throws -> [MioContentItem]
    func deleteAll() async throws
    func removeTemporaryExports() async throws
    func makeExportFile(content: [MioContentItem], sessions: [MioSession],
                        assistant: MioAssistantStoreDocument?, diagnostics: MioDiagnosticsExport?) async throws -> URL
}

protocol MioAssistantStore: Sendable {
    func loadDocument() async throws -> MioAssistantStoreDocument
    func claimSuggestion(id: UUID, expectedRevision: Int) async throws -> MioSuggestionApprovalClaim
    func releaseApproval(_ claim: MioSuggestionApprovalClaim) async throws
    func completeApproval(_ claim: MioSuggestionApprovalClaim) async throws
    func reconcileAcceptedContent(id: UUID) async throws
    func addSuggestion(_ suggestion: MioSuggestion) async throws
    @discardableResult
    func detectSuggestions(in session: MioSession, now: Date) async throws -> Int
    @discardableResult
    func applyAnalysis(_ result: MioAnalysisResult, request: MioAnalysisRequest, session: MioSession) async throws -> Int
    func deferSuggestion(id: UUID, now: Date) async throws
    func removeSuggestion(id: UUID) async throws
    func saveLesson(_ lesson: MioLesson, session: MioSession) async throws
    func deleteLesson(id: UUID) async throws
    func deleteSessionData(sessionID: UUID) async throws
    func deleteAll(now: Date) async throws
}

extension SessionRepository: MioSessionStore {}
extension MioContentRepository: MioContentStore {}
extension MioAssistantRepository: MioAssistantStore {}

/// The backend chosen once per launch, after the one-time migration has run.
struct MioResolvedStores: Sendable {
    let sessions: any MioSessionStore
    let content: any MioContentStore
    let assistant: any MioAssistantStore
    /// Swedish message for the person, shown once; nil when nothing needs attention.
    let message: String?

    static func legacyFiles(message: String?) -> MioResolvedStores {
        MioResolvedStores(sessions: SessionRepository(), content: MioContentRepository(),
                          assistant: MioAssistantRepository(), message: message)
    }
}

/// Lets the view models be created synchronously at launch while the migration runs off
/// the main actor. Every call waits for the same single resolution, then forwards.
struct MioDeferredStores: Sendable {
    let resolve: @Sendable () async -> MioResolvedStores

    var sessions: MioDeferredSessionStore { MioDeferredSessionStore(resolve: resolve) }
    var content: MioDeferredContentStore { MioDeferredContentStore(resolve: resolve) }
    var assistant: MioDeferredAssistantStore { MioDeferredAssistantStore(resolve: resolve) }
}

struct MioDeferredSessionStore: MioSessionStore {
    let resolve: @Sendable () async -> MioResolvedStores
    private func store() async -> any MioSessionStore { await resolve().sessions }

    func loadSessions() async throws -> [MioSession] { try await store().loadSessions() }
    func operationGeneration() async -> UUID { await store().operationGeneration() }
    func operationToken(for id: UUID, generation expectedGeneration: UUID) async throws -> SessionOperationToken {
        try await store().operationToken(for: id, generation: expectedGeneration)
    }
    func saveCaptureCheckpoint(_ session: MioSession, token: SessionOperationToken) async throws -> MioSession {
        try await store().saveCaptureCheckpoint(session, token: token)
    }
    func updateMetadata(id: UUID, title: String?, note: String?, token: SessionOperationToken) async throws -> MioSession {
        try await store().updateMetadata(id: id, title: title, note: note, token: token)
    }
    func correctTranscript(sessionID: UUID, segmentID: UUID, text: String,
                           token: SessionOperationToken) async throws -> MioSession {
        try await store().correctTranscript(sessionID: sessionID, segmentID: segmentID, text: text, token: token)
    }
    func renameSpeaker(sessionID: UUID, speaker: Int, name: String,
                       token: SessionOperationToken) async throws -> MioSession {
        try await store().renameSpeaker(sessionID: sessionID, speaker: speaker, name: name, token: token)
    }
    func delete(id: UUID) async throws { try await store().delete(id: id) }
    func removeTemporaryExports() async throws { try await store().removeTemporaryExports() }
    func deleteAll() async throws -> UUID { try await store().deleteAll() }
    func makeExportFile(for session: MioSession) async throws -> URL { try await store().makeExportFile(for: session) }
}

struct MioDeferredContentStore: MioContentStore {
    let resolve: @Sendable () async -> MioResolvedStores
    private func store() async -> any MioContentStore { await resolve().content }

    func loadItems() async throws -> [MioContentItem] { try await store().loadItems() }
    func upsert(_ item: MioContentItem) async throws -> [MioContentItem] { try await store().upsert(item) }
    func delete(id: UUID) async throws -> [MioContentItem] { try await store().delete(id: id) }
    func saveApprovedIfAbsent(_ item: MioContentItem) async throws -> [MioContentItem] {
        try await store().saveApprovedIfAbsent(item)
    }
    func unlinkSession(id: UUID) async throws -> [MioContentItem] { try await store().unlinkSession(id: id) }
    func deleteAll() async throws { try await store().deleteAll() }
    func removeTemporaryExports() async throws { try await store().removeTemporaryExports() }
    func makeExportFile(content: [MioContentItem], sessions: [MioSession],
                        assistant: MioAssistantStoreDocument?, diagnostics: MioDiagnosticsExport?) async throws -> URL {
        try await store().makeExportFile(content: content, sessions: sessions, assistant: assistant, diagnostics: diagnostics)
    }
}

struct MioDeferredAssistantStore: MioAssistantStore {
    let resolve: @Sendable () async -> MioResolvedStores
    private func store() async -> any MioAssistantStore { await resolve().assistant }

    func loadDocument() async throws -> MioAssistantStoreDocument { try await store().loadDocument() }
    func claimSuggestion(id: UUID, expectedRevision: Int) async throws -> MioSuggestionApprovalClaim {
        try await store().claimSuggestion(id: id, expectedRevision: expectedRevision)
    }
    func releaseApproval(_ claim: MioSuggestionApprovalClaim) async throws { try await store().releaseApproval(claim) }
    func completeApproval(_ claim: MioSuggestionApprovalClaim) async throws { try await store().completeApproval(claim) }
    func reconcileAcceptedContent(id: UUID) async throws { try await store().reconcileAcceptedContent(id: id) }
    func addSuggestion(_ suggestion: MioSuggestion) async throws { try await store().addSuggestion(suggestion) }
    func detectSuggestions(in session: MioSession, now: Date) async throws -> Int {
        try await store().detectSuggestions(in: session, now: now)
    }
    func applyAnalysis(_ result: MioAnalysisResult, request: MioAnalysisRequest, session: MioSession) async throws -> Int {
        try await store().applyAnalysis(result, request: request, session: session)
    }
    func deferSuggestion(id: UUID, now: Date) async throws { try await store().deferSuggestion(id: id, now: now) }
    func removeSuggestion(id: UUID) async throws { try await store().removeSuggestion(id: id) }
    func saveLesson(_ lesson: MioLesson, session: MioSession) async throws {
        try await store().saveLesson(lesson, session: session)
    }
    func deleteLesson(id: UUID) async throws { try await store().deleteLesson(id: id) }
    func deleteSessionData(sessionID: UUID) async throws { try await store().deleteSessionData(sessionID: sessionID) }
    func deleteAll(now: Date) async throws { try await store().deleteAll(now: now) }
}
