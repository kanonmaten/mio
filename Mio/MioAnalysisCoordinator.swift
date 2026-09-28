import Foundation
import Observation

@MainActor @Observable
final class MioAnalysisCoordinator {
    private(set) var enabled = false
    private(set) var isWorking = false
    private(set) var status = "AI-tolkning är av."
    private(set) var errorMessage: String?
    private(set) var sentBatches = 0
    @ObservationIgnored private var connection: MioCloudConnection?
    @ObservationIgnored private var observed: [UUID: Set<UUID>] = [:]
    @ObservationIgnored private var queue: [Work] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var workerMode: MioCaptureMode?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var activeSessionID: UUID?
    @ObservationIgnored private var lastSentAt: Date?
    @ObservationIgnored private var lessonInterval: TimeInterval = 60
    @ObservationIgnored private var deletedSessionIDs: Set<UUID> = []
    @ObservationIgnored private let loadConnection: @MainActor () throws -> MioCloudConnection
    @ObservationIgnored private let configurationMatches: @MainActor (MioCloudConnection) -> Bool
    @ObservationIgnored private let send: @MainActor (MioAnalysisRequest, MioCloudConnection) async throws -> MioAnalysisResult
    @ObservationIgnored private let wait: @MainActor (TimeInterval) async throws -> Void

    init(
        loadConnection: @escaping @MainActor () throws -> MioCloudConnection = { try MioCloudSettings.connection() },
        configurationMatches: @escaping @MainActor (MioCloudConnection) -> Bool = {
            UserDefaults.standard.bool(forKey: MioCloudSettings.enabledKey)
                && (try? MioCloudSettings.endpoint(for: MioCloudSettings.serverAddress)) == $0.endpoint
        },
        send: @escaping @MainActor (MioAnalysisRequest, MioCloudConnection) async throws -> MioAnalysisResult = {
            try await MioCloudService.analyze($0, connection: $1)
        },
        wait: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.loadConnection = loadConnection
        self.configurationMatches = configurationMatches
        self.send = send
        self.wait = wait
    }

    private struct Work {
        let session: MioSession
        let request: MioAnalysisRequest
    }

    /// Explicit in-app consent applies to future everyday text and completed lessons
    /// in this run only. Credentials remain in memory while the phone is locked.
    func enable(existingSessions: [MioSession]) throws {
        let selected = try loadConnection()
        disable()
        connection = selected
        for session in existingSessions { observed[session.id] = Set(session.transcripts.map(\.id)) }
        enabled = true
        status = "AI-tolkning på: nya textutdrag analyseras ungefär en gång per minut."
        errorMessage = nil
    }

    func disable() {
        generation = UUID()
        worker?.cancel(); worker = nil; workerMode = nil
        queue.removeAll(); observed.removeAll(); connection = nil; activeSessionID = nil
        enabled = false; isWorking = false
        status = "AI-tolkning är av. Inga fler utdrag skickas."
    }

    func pauseEveryday(assistant: MioAssistantViewModel) {
        queue.removeAll { $0.request.mode == .everyday }
        if workerMode == .everyday {
            generation = UUID(); worker?.cancel(); worker = nil; workerMode = nil; isWorking = false; activeSessionID = nil
            startWorker(assistant: assistant)
        }
    }

    func cancel(sessionID: UUID, assistant: MioAssistantViewModel) {
        deletedSessionIDs.insert(sessionID)
        queue.removeAll { $0.session.id == sessionID }
        if activeSessionID == sessionID || (activeSessionID == nil && queue.isEmpty) {
            generation = UUID(); worker?.cancel(); worker = nil; workerMode = nil; isWorking = false; activeSessionID = nil
            startWorker(assistant: assistant)
        }
    }

    func observe(_ session: MioSession, assistant: MioAssistantViewModel) {
        guard enabled, !session.isLesson, !deletedSessionIDs.contains(session.id), !MioMaintenanceState.shared.isDeleting else { return }
        let known = observed[session.id] ?? []
        let fresh = session.transcripts.filter { !known.contains($0.id) }
        observed[session.id, default: []].formUnion(fresh.map(\.id))
        guard !fresh.isEmpty else { return }
        let processed = assistant.analyzedFragmentIDs(for: session.id)
        let fragments = fresh.flatMap(MioAnalysisFragment.make).filter { !processed.contains($0.id) }
        // Merge unsent chunks so ordinary short utterances do not cause one API call each.
        let waiting = queue.filter { $0.session.id == session.id && $0.request.mode == .everyday }.flatMap { $0.request.fragments }
        queue.removeAll { $0.session.id == session.id && $0.request.mode == .everyday }
        enqueue(session: session, mode: .everyday, fragments: waiting + fragments, assistant: assistant)
    }

    func summarizeLesson(_ session: MioSession, assistant: MioAssistantViewModel) {
        guard enabled, session.isLesson, session.endedAt != nil, !deletedSessionIDs.contains(session.id), activeSessionID != session.id,
              !queue.contains(where: { $0.session.id == session.id }) else { return }
        let processed = assistant.analyzedFragmentIDs(for: session.id, detailedLesson: true)
        let queued = Set(queue.filter { $0.session.id == session.id }.flatMap { $0.request.fragments.map(\.id) })
        let fragments = session.transcripts.flatMap(MioAnalysisFragment.make)
            .filter { !processed.contains($0.id) && !queued.contains($0.id) }
        let remaining = MioAnalysisRequest.batches(mode: .lesson, fragments: fragments)
        queue += remaining.prefix(max(0, 100 - queue.count)).map { Work(session: session, request: $0) }
        startWorker(assistant: assistant)
    }

    private func enqueue(session: MioSession, mode: MioCaptureMode, fragments: [MioAnalysisFragment], assistant: MioAssistantViewModel) {
        queue += MioAnalysisRequest.batches(mode: mode, fragments: fragments).map { Work(session: session, request: $0) }
        guard queue.count <= 100 else {
            fail("För mycket väntande text. AI-tolkningen har stoppats; originaltexten finns kvar lokalt.")
            return
        }
        startWorker(assistant: assistant)
    }

    private func startWorker(assistant: MioAssistantViewModel) {
        guard enabled, worker == nil, !queue.isEmpty else { return }
        let token = generation
        workerMode = queue.first?.request.mode
        isWorking = true
        worker = Task { [weak self, weak assistant] in
            guard let self, let assistant else { return }
            defer {
                if self.generation == token {
                    self.worker = nil; self.workerMode = nil; self.isWorking = false; self.activeSessionID = nil
                }
            }
            do {
                // Leave everyday fragments in the queue while waiting so new text joins the batch.
                if self.workerMode == .everyday { try await self.wait(60) }
                while self.enabled, self.generation == token, !self.queue.isEmpty {
                    try Task.checkCancellation()
                    if let last = self.lastSentAt {
                        let minimumInterval: TimeInterval = self.queue.first?.request.mode == .lesson ? self.lessonInterval : 60
                        let remaining = minimumInterval - Date.now.timeIntervalSince(last)
                        if remaining > 0 {
                            self.isWorking = true
                            self.status = "Väntar mellan AI-anrop för att begränsa förbrukningen …"
                            try await self.wait(remaining)
                        }
                    }
                    guard self.generation == token, !MioMaintenanceState.shared.isDeleting,
                          let connection = self.connection,
                          self.configurationMatches(connection)
                    else { throw MioCloudError.changedConfiguration }
                    guard !self.queue.isEmpty else { break }
                    let work = self.queue.removeFirst()
                    self.workerMode = work.request.mode
                    self.activeSessionID = work.session.id
                    self.isWorking = true
                    self.status = work.request.mode == .lesson ? "AI skriver detaljerade lektionsanteckningar …" : "AI granskar senaste textutdraget …"
                    self.lastSentAt = .now
                    let result = try await self.send(work.request, connection)
                    try Task.checkCancellation()
                    guard self.enabled, self.generation == token else { return }
                    if let metadata = result.metadata { self.lessonInterval = TimeInterval(metadata.lessonIntervalSeconds) }
                    let count = try await assistant.applyAnalysis(result, request: work.request, session: work.session)
                    self.activeSessionID = nil
                    self.sentBatches += 1
                    self.status = "Senast analyserat \(Date.now.formatted(date: .omitted, time: .shortened)). \(count) nya förslag."
                    if work.request.mode == .lesson {
                        self.status = MioLessonDocument(session: work.session, records: assistant.analyses).progress
                    }
                    self.isWorking = false
                }
            } catch is CancellationError {
                // Disabling, pausing or deleting rejects any late response.
            } catch {
                if self.generation == token { self.fail(error.localizedDescription) }
            }
        }
    }

    private func fail(_ message: String) {
        disable()
        errorMessage = message + " Aktivera läget igen när problemet är löst. Inget automatiskt omförsök görs."
        status = "AI-tolkning stoppad. Lokal transkription fortsätter."
    }
}
