import Foundation
import Observation

@MainActor @Observable
final class MioAnalysisCoordinator {
    private(set) var enabled = false
    private(set) var isWorking = false
    private(set) var status = "AI-tolkning är av."
    private(set) var errorMessage: String?
    private(set) var sentBatches = 0
    private(set) var pausedUntil: Date?
    @ObservationIgnored private var consentStartedAt = Date.distantFuture
    @ObservationIgnored private var connection: MioCloudConnection?
    @ObservationIgnored private var observed: [UUID: Set<UUID>] = [:]
    @ObservationIgnored private var eligible: [UUID: Set<UUID>] = [:]
    @ObservationIgnored private var latestSessions: [UUID: MioSession] = [:]
    @ObservationIgnored private var continuityStarts: [UUID: Date] = [:]
    @ObservationIgnored private var endingSessionIDs: Set<UUID> = []
    @ObservationIgnored private var queue: [Work] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var workerMode: MioCaptureMode?
    @ObservationIgnored private var isWaiting = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var activeSessionID: UUID?
    @ObservationIgnored private var lastSentAt: Date?
    @ObservationIgnored private var lessonInterval: TimeInterval = 60
    @ObservationIgnored private var deletedSessionIDs: Set<UUID> = []
    @ObservationIgnored private let loadConnection: @MainActor () throws -> MioCloudConnection
    @ObservationIgnored private let configurationMatches: @MainActor (MioCloudConnection) -> Bool
    @ObservationIgnored private let prepareConnection: @MainActor (MioCloudConnection, MioAITaskID) async throws -> MioPreparedConnection
    @ObservationIgnored private var quotaResetAt: Date?
    @ObservationIgnored private let send: @MainActor (MioAnalysisRequest, MioCloudConnection) async throws -> MioAnalysisResult
    @ObservationIgnored private let wait: @MainActor (TimeInterval) async throws -> Void
    @ObservationIgnored private let now: @MainActor () -> Date

    init(
        loadConnection: @escaping @MainActor () throws -> MioCloudConnection = { try MioCloudSettings.connection() },
        configurationMatches: @escaping @MainActor (MioCloudConnection) -> Bool = {
            guard let current = try? MioCloudSettings.connection() else { return false }
            return $0.hasSameCredentials(as: current)
        },
        prepareConnection: @escaping @MainActor (MioCloudConnection, MioAITaskID) async throws -> MioPreparedConnection = {
            try await MioConnectionDiscovery.shared.prepare(connection: $0, task: $1)
        },
        send: @escaping @MainActor (MioAnalysisRequest, MioCloudConnection) async throws -> MioAnalysisResult = {
            try await MioCloudService.analyze($0, connection: $1)
        },
        wait: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        now: @escaping @MainActor () -> Date = { .now }
    ) {
        self.loadConnection = loadConnection
        self.configurationMatches = configurationMatches
        self.prepareConnection = prepareConnection
        self.send = send
        self.wait = wait
        self.now = now
    }

    private struct Work {
        let session: MioSession
        let request: MioAnalysisRequest
        var enqueuedAt: Date = .now
        var waited: TimeInterval = 0
        var continuityStartedAt: Date = .distantFuture
        var eligibleSegmentIDs: Set<UUID> = []
        var isFinal = false
    }

    /// Consent follows capture time, including delayed transcription callbacks.
    func enable(existingSessions: [MioSession], task: MioAITaskID = .everyday) async throws {
        guard !MioMaintenanceState.shared.blocksWork else { throw MioCloudError.disabled }
        if let pausedUntil, pausedUntil > now() {
            throw MioCloudError.rateLimited(min(86_400, max(1, Int(ceil(pausedUntil.timeIntervalSince(now()))))))
        }
        let selected = try loadConnection()
        disable()
        let token = generation
        let prepared = try await prepareConnection(selected, task)
        try Task.checkCancellation()
        guard generation == token, !MioMaintenanceState.shared.blocksWork, configurationMatches(selected) else {
            throw MioCloudError.changedConfiguration
        }
        connection = prepared.connection
        quotaResetAt = prepared.status.quota?.resetAt.flatMap(MioAnalysisResult.parseDate)
        pausedUntil = nil
        for session in existingSessions { observed[session.id] = Set(session.transcripts.map(\.id)) }
        consentStartedAt = now()
        enabled = true
        MioDiagnosticsRuntime.analysisEnabled = true
        status = "AI-tolkning på: nya textutdrag analyseras ungefär en gång per minut."
        errorMessage = nil
    }

    func disable() {
        generation = UUID()
        worker?.cancel(); worker = nil; workerMode = nil; isWaiting = false
        queue.removeAll(); observed.removeAll(); eligible.removeAll(); latestSessions.removeAll()
        continuityStarts.removeAll(); endingSessionIDs.removeAll()
        connection = nil; activeSessionID = nil
        // A server-imposed wait survives disable/re-enable; re-saving settings must not bypass it.
        quotaResetAt = nil
        enabled = false; isWorking = false
        MioDiagnosticsRuntime.analysisEnabled = false
        status = "AI-tolkning är av. Inga fler utdrag skickas."
    }

    func pauseEveryday(assistant: MioAssistantViewModel) {
        queue.removeAll { $0.request.mode == .everyday }
        eligible.removeAll(); endingSessionIDs.removeAll()
        for id in continuityStarts.keys { continuityStarts[id] = now() }
        if workerMode == .everyday {
            generation = UUID(); worker?.cancel(); worker = nil; workerMode = nil; isWaiting = false; isWorking = false; activeSessionID = nil
            startWorker(assistant: assistant)
        }
    }

    func beginEndingEveryday(sessionID: UUID) {
        guard enabled, !deletedSessionIDs.contains(sessionID) else { return }
        endingSessionIDs.insert(sessionID)
    }

    /// User pause/stop drains already captured text; future capture begins a new context boundary.
    func finishEveryday(_ session: MioSession?, assistant: MioAssistantViewModel) {
        if let session, !session.isLesson { observe(session, assistant: assistant) }
        let finished = endingSessionIDs.union(session.map { [$0.id] } ?? [])
        for index in queue.indices where queue[index].request.mode == .everyday && finished.contains(queue[index].session.id) {
            queue[index].isFinal = true
        }
        for id in finished { continuityStarts[id] = now(); eligible[id] = [] }
        endingSessionIDs.subtract(finished)
        // Wake aggregation/rate waits without interrupting a model request already sent.
        if workerMode == .everyday, isWaiting {
            generation = UUID(); worker?.cancel(); worker = nil; workerMode = nil; isWaiting = false
            isWorking = false; activeSessionID = nil
        }
        startWorker(assistant: assistant)
    }

    func cancel(sessionID: UUID, assistant: MioAssistantViewModel) {
        deletedSessionIDs.insert(sessionID)
        queue.removeAll { $0.session.id == sessionID }
        latestSessions[sessionID] = nil; eligible[sessionID] = nil; observed[sessionID] = nil
        continuityStarts[sessionID] = nil; endingSessionIDs.remove(sessionID)
        if activeSessionID == sessionID || (activeSessionID == nil && queue.isEmpty) {
            generation = UUID(); worker?.cancel(); worker = nil; workerMode = nil; isWaiting = false; isWorking = false; activeSessionID = nil
            startWorker(assistant: assistant)
        }
    }

    func observe(_ session: MioSession, assistant: MioAssistantViewModel) {
        guard enabled, !session.isLesson, !deletedSessionIDs.contains(session.id) else { return }
        latestSessions[session.id] = session
        let boundary = continuityStarts[session.id] ?? consentStartedAt
        continuityStarts[session.id] = boundary
        let known = observed[session.id] ?? []
        let fresh = session.transcripts.filter { !known.contains($0.id) && Self.captured($0, after: max(consentStartedAt, boundary)) }
        observed[session.id, default: []].formUnion(session.transcripts.map(\.id))
        eligible[session.id, default: []].formUnion(fresh.map(\.id))
        guard !fresh.isEmpty else { return }
        let processed = assistant.analyzedFragmentIDs(for: session.id)
        let fragments = fresh.flatMap(MioAnalysisFragment.make).filter { !processed.contains($0.id) }
        enqueueEveryday(session: session, fragments: fragments, boundary: boundary, assistant: assistant)
    }

    /// Estimated callback time cannot prove that audio was captured after consent or a
    /// continuity boundary. Such audio qualifies only beyond the 60 s RAM bound, where it
    /// cannot predate the boundary; legacy segments keep their stored validity flag.
    nonisolated static func captured(_ segment: TranscriptSegment, after boundary: Date) -> Bool {
        let reliable = segment.timingValidity?.isReliable ?? segment.audioTimingIsValid
        return segment.audioStartedAt >= (reliable ? boundary : boundary.addingTimeInterval(60))
    }

    func summarizeLesson(_ session: MioSession, assistant: MioAssistantViewModel) {
        guard enabled, session.isLesson, session.endedAt != nil, !deletedSessionIDs.contains(session.id), activeSessionID != session.id,
              !queue.contains(where: { $0.session.id == session.id }) else { return }
        let processed = assistant.analyzedFragmentIDs(for: session.id, detailedLesson: true)
        let fragments = session.transcripts.flatMap(MioAnalysisFragment.make).filter { !processed.contains($0.id) }
        let remaining = MioAnalysisRequest.batches(mode: .lesson, fragments: fragments)
        queue += remaining.prefix(max(0, 100 - queue.count)).map { Work(session: session, request: $0) }
        startWorker(assistant: assistant)
    }

    /// True while detailed-note parts for this lesson are queued or a lesson part is in
    /// flight (a part leaves the queue before its connection check, hence the worker mode).
    func hasPendingLessonNotes(sessionID: UUID) -> Bool {
        enabled && (queue.contains { $0.session.id == sessionID && $0.request.mode == .lesson }
            || activeSessionID == sessionID || (worker != nil && workerMode == .lesson))
    }

    /// Stops this lesson's detailed notes without turning AI off, e.g. when iOS ends the
    /// continued-processing task. A part in flight is discarded; saved parts stay and the
    /// rest can be queued again with summarizeLesson.
    func stopLessonNotes(sessionID: UUID, assistant: MioAssistantViewModel) {
        queue.removeAll { $0.session.id == sessionID && $0.request.mode == .lesson }
        if workerMode == .lesson, activeSessionID == sessionID || activeSessionID == nil {
            generation = UUID(); worker?.cancel(); worker = nil; workerMode = nil; isWaiting = false; isWorking = false; activeSessionID = nil
            startWorker(assistant: assistant)
        }
    }

    private func enqueueEveryday(session: MioSession, fragments: [MioAnalysisFragment], boundary: Date, assistant: MioAssistantViewModel) {
        let waiting = queue.filter { $0.session.id == session.id && $0.request.mode == .everyday }
        queue.removeAll { $0.session.id == session.id && $0.request.mode == .everyday }
        // The live session is not repository-validated; keep the first copy instead of trapping.
        let segments = Dictionary(session.transcripts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        struct Group {
            var fragments: [MioAnalysisFragment] = []
            var enqueuedAt: Date
            var waited: TimeInterval = 0
            var eligible: Set<UUID> = []
            var isFinal = false
        }
        var groups: [Date: Group] = [:]
        func append(_ source: [MioAnalysisFragment], base: Date, enqueuedAt: Date, waited: TimeInterval, allowed: Set<UUID>, final: Bool) {
            for fragment in source {
                guard let segmentID = fragment.segmentID, let segment = segments[segmentID] else { continue }
                let gapBoundary = session.captureGaps?.filter { $0.endedAt <= segment.audioStartedAt }.map(\.endedAt).max() ?? base
                let start = max(base, gapBoundary)
                var group = groups[start] ?? Group(enqueuedAt: enqueuedAt)
                group.fragments.append(fragment); group.enqueuedAt = min(group.enqueuedAt, enqueuedAt)
                group.waited = max(group.waited, waited); group.eligible.formUnion(allowed)
                group.isFinal = group.isFinal || final
                groups[start] = group
            }
        }
        for work in waiting {
            append(work.request.fragments, base: work.continuityStartedAt, enqueuedAt: work.enqueuedAt,
                   waited: work.waited, allowed: work.eligibleSegmentIDs, final: work.isFinal)
        }
        append(fragments, base: boundary, enqueuedAt: now(), waited: 0, allowed: eligible[session.id] ?? [], final: false)
        for start in groups.keys.sorted() {
            guard let group = groups[start] else { continue }
            queue += MioEverydayContext.batches(group.fragments).map {
                Work(session: session, request: MioAnalysisRequest(mode: .everyday, timeZone: TimeZone.current.identifier, fragments: $0),
                     enqueuedAt: group.enqueuedAt, waited: group.waited, continuityStartedAt: start,
                     eligibleSegmentIDs: group.eligible, isFinal: group.isFinal)
            }
        }
        guard queue.count <= 100 else {
            fail("För mycket väntande text. AI-tolkningen har stoppats; originaltexten finns kvar lokalt."); return
        }
        startWorker(assistant: assistant)
    }

    private func waitForEverydayBoundary(token: UUID) async throws {
        while generation == token, let work = queue.first, work.request.mode == .everyday {
            let age = max(now().timeIntervalSince(work.enqueuedAt), work.waited)
            let text = work.request.fragments.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let unquoted = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"”»'’ "))
            let complete = unquoted.last.map { ".?!…".contains($0) } ?? false
            let full = work.request.fragments.count >= 5 || work.request.fragments.reduce(0, { $0 + $1.text.utf8.count }) >= 6_000
            let delay: TimeInterval
            if age < 60, !work.isFinal { delay = 60 - age }
            else if !work.isFinal, !complete, !full, age < 120 { delay = min(20, 120 - age) }
            else { return }
            status = "Samlar nästa textdel för bättre sammanhang …"
            try await waitFor(delay, token: token)
            try Task.checkCancellation()
            // Injected waits may complete immediately in tests; elapsed wait still has a finite budget.
            for index in queue.indices where queue[index].request.mode == .everyday && queue[index].enqueuedAt <= work.enqueuedAt {
                queue[index].waited += delay
            }
        }
    }

    private func waitFor(_ seconds: TimeInterval, token: UUID) async throws {
        isWaiting = true
        defer { if generation == token { isWaiting = false } }
        try await wait(seconds)
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
                while self.enabled, self.generation == token, !self.queue.isEmpty {
                    try Task.checkCancellation()
                    self.workerMode = self.queue.first?.request.mode
                    try await self.waitForEverydayBoundary(token: token)
                    if let last = self.lastSentAt {
                        let interval: TimeInterval = self.queue.first?.request.mode == .lesson ? self.lessonInterval : 60
                        let remaining = interval - self.now().timeIntervalSince(last)
                        if remaining > 0 {
                            self.status = "Väntar mellan AI-anrop för att begränsa förbrukningen …"
                            try await self.waitFor(remaining, token: token)
                        }
                    }
                    await MioMaintenanceState.shared.waitForExclusive()
                    try Task.checkCancellation()
                    guard self.generation == token, !MioMaintenanceState.shared.blocksWork,
                          let connection = self.connection, self.configurationMatches(connection)
                    else { throw MioCloudError.changedConfiguration }
                    guard !self.queue.isEmpty else { break }
                    let work = self.queue.removeFirst()
                    let prepared = try await self.prepareConnection(connection, work.request.mode == .lesson ? .lesson : .everyday)
                    try Task.checkCancellation()
                    guard self.enabled, self.generation == token, self.configurationMatches(connection),
                          prepared.connection.observedConfigurationRevision == connection.observedConfigurationRevision else {
                        throw MioCloudError.gateway(409, .configurationChanged)
                    }
                    self.quotaResetAt = prepared.status.quota?.resetAt.flatMap(MioAnalysisResult.parseDate)
                    let session = work.request.mode == .everyday ? (self.latestSessions[work.session.id] ?? work.session) : work.session
                    var request = work.request
                    if request.mode == .everyday {
                        request = try MioEverydayContext.request(fragments: request.fragments, session: session,
                            eligibleSegmentIDs: work.eligibleSegmentIDs, continuityStartedAt: work.continuityStartedAt,
                            decisions: assistant.analysisDecisions)
                        if session.captureGaps?.contains(where: { $0.endedAt == work.continuityStartedAt }) == true {
                            request.contextLimited = true
                        }
                    }
                    request.queueSize = self.queue.count + 1
                    self.workerMode = request.mode; self.activeSessionID = session.id; self.isWorking = true
                    self.status = request.mode == .lesson ? "AI skriver detaljerade lektionsanteckningar …" : "AI granskar senaste textutdraget …"
                    self.lastSentAt = self.now()
                    let result: MioAnalysisResult
                    do {
                        // Transport may perform a slow status preflight before model access.
                        // A full minute after completion conservatively spaces actual model calls.
                        defer { self.lastSentAt = self.now() }
                        result = try await self.send(request, prepared.connection)
                    }
                    // A temporary export barrier must queue an already completed result,
                    // then recheck consent/deletion before admitting its local write.
                    await MioMaintenanceState.shared.waitForExclusive()
                    try Task.checkCancellation()
                    guard self.enabled, self.generation == token, !MioMaintenanceState.shared.blocksWork else { return }
                    guard self.configurationMatches(connection) else { throw MioCloudError.changedConfiguration }
                    if let metadata = result.metadata { self.lessonInterval = TimeInterval(metadata.lessonIntervalSeconds) }
                    let count = try await assistant.applyAnalysis(result, request: request, session: session)
                    self.activeSessionID = nil; self.sentBatches += 1
                    self.status = "Senast analyserat \(self.now().formatted(date: .omitted, time: .shortened)). \(count) nya förslag."
                    if request.mode == .lesson { self.status = MioLessonDocument(session: session, records: assistant.analyses).progress }
                    self.isWorking = false
                }
            } catch is CancellationError {
                // Explicit cancellation rejects every late response before persistence.
            } catch {
                if self.generation == token {
                    guard let connection = self.connection, self.configurationMatches(connection) else {
                        MioConnectionDiscovery.shared.invalidate()
                        self.disable()
                        self.errorMessage = "Serveranslutningen ändrades. Granska den och aktivera text-AI igen."
                        self.status = "Text-AI stoppades eftersom serveranslutningen ändrades."
                        return
                    }
                    MioConnectionDiscovery.shared.handle(error: error)
                    var deadline: Date?
                    if case let MioCloudError.rateLimited(seconds) = error { deadline = self.now().addingTimeInterval(TimeInterval(seconds)) }
                    if case let MioCloudError.gatewayRateLimited(code, seconds) = error {
                        let retryDeadline = self.now().addingTimeInterval(TimeInterval(seconds))
                        deadline = code == .localDayLimit ? max(self.quotaResetAt ?? retryDeadline, retryDeadline) : retryDeadline
                    }
                    self.fail(error.localizedDescription)
                    self.pausedUntil = deadline
                }
            }
        }
    }

    private func fail(_ message: String) {
        disable()
        errorMessage = message + " Aktivera läget igen när problemet är löst. Inget automatiskt omförsök görs."
        status = "AI-tolkning stoppad. Lokal transkription fortsätter."
    }
}
