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
    /// Start of the everyday batch currently being sent; see `MioAnalysisSchedule`.
    @ObservationIgnored private var windowOpenedAt: Date?
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var resumeRequested = false
    @ObservationIgnored private let isWanted: @MainActor () -> Bool
    @ObservationIgnored private var lessonInterval: TimeInterval = 60
    @ObservationIgnored private var deletedSessionIDs: Set<UUID> = []
    @ObservationIgnored private let loadConnection: @MainActor () throws -> MioCloudConnection
    @ObservationIgnored private let configurationMatches: @MainActor (MioCloudConnection) -> Bool
    @ObservationIgnored private let prepareConnection: @MainActor (MioCloudConnection, MioAITaskID) async throws -> MioPreparedConnection
    @ObservationIgnored private var quotaResetAt: Date?
    @ObservationIgnored private let send: @MainActor (MioAnalysisRequest, MioCloudConnection) async throws -> MioAnalysisResult
    @ObservationIgnored private let wait: @MainActor (TimeInterval) async throws -> Void
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let credentialsReadable: @MainActor () -> Bool
    @ObservationIgnored private let waitForUnlock: @MainActor () async throws -> Void
    @ObservationIgnored private let consentLog: @MainActor () -> MioAIConsentLog
    @ObservationIgnored private let recordConsent: @MainActor (MioAIConsentLog.Kind, Date, Date?) -> Void

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
        now: @escaping @MainActor () -> Date = { .now },
        isWanted: @escaping @MainActor () -> Bool = {
            MioAIPreference.shouldRun(paired: MioCloudSettings.isPaired, defaults: .standard)
        },
        credentialsReadable: @escaping @MainActor () -> Bool = { MioCloudSettings.credentialsReadable },
        waitForUnlock: @escaping @MainActor () async throws -> Void = { try await MioCloudSettings.waitUntilCredentialsReadable() },
        consentLog: @escaping @MainActor () -> MioAIConsentLog = { .load(from: .standard) },
        recordConsent: @escaping @MainActor (MioAIConsentLog.Kind, Date, Date?) -> Void = {
            MioAIConsentLog.record($0, at: $1, until: $2, in: .standard)
        }
    ) {
        self.loadConnection = loadConnection
        self.configurationMatches = configurationMatches
        self.prepareConnection = prepareConnection
        self.send = send
        self.wait = wait
        self.now = now
        self.isWanted = isWanted
        self.credentialsReadable = credentialsReadable
        self.waitForUnlock = waitForUnlock
        self.consentLog = consentLog
        self.recordConsent = recordConsent
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

    /// Starts analysis when the PC is paired and AI is not paused: at launch, on return to the
    /// foreground and after re-pairing. Overlapping calls coalesce into one activation, and an
    /// activation superseded by a newer request is retried instead of reported.
    func resumeIfWanted(existingSessions: () -> [MioSession], assistant: MioAssistantViewModel? = nil) async {
        resumeRequested = true
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        while resumeRequested {
            resumeRequested = false
            guard !enabled, isWanted() else { continue }
            do { try await enable(existingSessions: existingSessions(), assistant: assistant) }
            catch {
                if resumeRequested || !isWanted() || error is CancellationError { continue }
                errorMessage = error.localizedDescription
                status = "AI kunde inte starta. Lokal transkription fortsätter; AI provas igen när du öppnar Mio."
            }
        }
    }

    /// Consent follows capture time, including delayed transcription callbacks.
    /// A known server wait (Retry-After) survives re-activation; the worker honours it.
    /// With `assistant`, everyday text captured while AI was on but never analysed (app closed,
    /// phone locked) within the last 12 hours is queued again (user decision 2026-10-12).
    func enable(existingSessions: [MioSession], task: MioAITaskID = .everyday,
                assistant: MioAssistantViewModel? = nil) async throws {
        guard !MioMaintenanceState.shared.blocksWork else { throw MioCloudError.disabled }
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
        if let pausedUntil, pausedUntil <= now() { self.pausedUntil = nil }
        for session in existingSessions { observed[session.id] = Set(session.transcripts.map(\.id)) }
        consentStartedAt = now()
        enabled = true
        MioDiagnosticsRuntime.analysisEnabled = true
        status = pausedUntil.map { "AI fortsätter kl. \($0.formatted(date: .omitted, time: .shortened))." }
            ?? "AI är på: nytt vardagstal skickas samlat högst var femte minut."
        errorMessage = nil
        recordConsent(.on, consentStartedAt, nil)
        if let assistant { catchUp(existingSessions, assistant: assistant) }
    }

    /// Queues unanalysed everyday text from before this activation that was captured inside a
    /// recorded consent interval. Context never crosses that interval's start; the newest text
    /// wins when the backlog would exceed the queue bound.
    private func catchUp(_ sessions: [MioSession], assistant: MioAssistantViewModel) {
        let log = consentLog()
        let oldest = consentStartedAt.addingTimeInterval(-MioAIConsentLog.catchUpWindow)
        struct Backlog { let session: MioSession; let start: Date; var fragments: [MioAnalysisFragment]; let segmentIDs: Set<UUID> }
        var backlog: [Backlog] = []
        for session in sessions where !session.isLesson && !deletedSessionIDs.contains(session.id) {
            let processed = assistant.analyzedFragmentIDs(for: session.id)
            var groups: [Date: [TranscriptSegment]] = [:]
            for segment in session.transcripts where segment.audioStartedAt >= oldest && segment.audioStartedAt < consentStartedAt {
                guard let start = log.consentStart(covering: segment.audioStartedAt), Self.captured(segment, after: start) else { continue }
                groups[start, default: []].append(segment)
            }
            for (start, segments) in groups {
                let fragments = segments.flatMap(MioAnalysisFragment.make).filter { !processed.contains($0.id) }
                if !fragments.isEmpty {
                    backlog.append(Backlog(session: session, start: start, fragments: fragments, segmentIDs: Set(segments.map(\.id))))
                }
            }
        }
        var budget = Self.catchUpBatchLimit
        backlog.sort { ($0.fragments.map(\.occurredAt).max() ?? "") > ($1.fragments.map(\.occurredAt).max() ?? "") }
        var kept: [Backlog] = []
        for var item in backlog where budget > 0 {
            let batches = MioEverydayContext.batches(item.fragments)
            item.fragments = batches.suffix(budget).flatMap { $0 }
            budget -= min(budget, batches.count)
            kept.append(item)
        }
        for item in kept.sorted(by: { $0.start < $1.start }) {
            eligible[item.session.id, default: []].formUnion(item.segmentIDs)
            latestSessions[item.session.id] = latestSessions[item.session.id] ?? item.session
            enqueueEveryday(session: item.session, fragments: item.fragments, boundary: item.start, assistant: assistant, final: true)
        }
    }

    /// Leaves room under the 100-item queue bound for text captured after the restart.
    static let catchUpBatchLimit = 60

    /// A locked phone cannot read the gateway token. That is not a changed pairing: wait for
    /// unlock and keep the queue, then compare credentials as usual.
    private func connectionStillMatches(_ connection: MioCloudConnection, token: UUID) async throws -> Bool {
        while !credentialsReadable() {
            status = "Väntar på att telefonen låses upp. Väntande text ligger kvar."
            try await waitForUnlock()
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
        }
        return configurationMatches(connection)
    }

    func disable() {
        generation = UUID()
        worker?.cancel(); worker = nil; workerMode = nil; isWaiting = false
        queue.removeAll(); observed.removeAll(); eligible.removeAll(); latestSessions.removeAll()
        continuityStarts.removeAll(); endingSessionIDs.removeAll()
        connection = nil; activeSessionID = nil
        // A server-imposed wait and the batch window survive disable/re-enable;
        // pausing or re-pairing must not bypass them.
        quotaResetAt = nil
        enabled = false; isWorking = false
        MioDiagnosticsRuntime.analysisEnabled = false
        status = "AI är pausad. Inga fler utdrag skickas."
    }

    func beginEndingEveryday(sessionID: UUID) {
        guard enabled, !deletedSessionIDs.contains(sessionID) else { return }
        endingSessionIDs.insert(sessionID)
    }

    /// Pause, stop, an interruption or a capture failure drains already captured text of the
    /// ending session (nil: only sessions already ending); it is never dropped, and a request
    /// in flight is kept. Future capture begins a new context boundary.
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
        if let pausedUntil, MioAnalysisSchedule.dropsEverydayWork(pausedUntil: pausedUntil, now: now()) {
            // A long quota pause skips this text; it stays local and is not later used as context.
            continuityStarts[session.id] = now()
            recordConsent(.skipped, now(), pausedUntil)
            return
        }
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

    private func enqueueEveryday(session: MioSession, fragments: [MioAnalysisFragment], boundary: Date,
                                 assistant: MioAssistantViewModel, final: Bool = false) {
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
        append(fragments, base: boundary, enqueuedAt: now(), waited: 0, allowed: eligible[session.id] ?? [], final: final)
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

    /// One wait until the schedule allows the head of the queue. Text arriving meanwhile is
    /// merged into queued everyday work, which is what batches it.
    private func waitUntilDue(token: UUID) async throws {
        guard generation == token, let work = queue.first else { return }
        let input = MioAnalysisSchedule.Input(kind: work.request.mode == .lesson ? .lesson : .everyday,
            enqueuedAt: work.enqueuedAt, isFinal: work.isFinal, lastSentAt: lastSentAt, windowOpenedAt: windowOpenedAt,
            lessonInterval: lessonInterval, pausedUntil: pausedUntil)
        let current = now()
        let delay = MioAnalysisSchedule.nextSendTime(input, now: current).timeIntervalSince(current)
        guard delay > 0 else { return }
        if pausedUntil.map({ $0 <= current }) ?? true {
            status = work.request.mode == .lesson ? "Väntar mellan lektionsdelar för att begränsa förbrukningen …"
                : "Samlar vardagstext. Nästa AI-utskick sker inom fem minuter."
        }
        try await waitFor(delay, token: token)
        try Task.checkCancellation()
    }

    private func pause(until deadline: Date, after error: Error) {
        pausedUntil = deadline
        if MioAnalysisSchedule.dropsEverydayWork(pausedUntil: deadline, now: now()) {
            recordConsent(.skipped, now(), deadline)
            queue.removeAll { $0.request.mode == .everyday }
            eligible.removeAll()
            for id in continuityStarts.keys { continuityStarts[id] = now() }
        }
        let reason = switch error as? MioCloudError {
        case .network?: "Datorn svarar inte."
        case .gatewayRateLimited(.localTokenLimit, _)?: "Dagens AI-token är slut."
        default: "AI-gränsen är nådd."
        }
        errorMessage = nil
        status = "\(reason) AI fortsätter kl. \(deadline.formatted(date: .omitted, time: .shortened))."
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
                    try await self.waitUntilDue(token: token)
                    await MioMaintenanceState.shared.waitForExclusive()
                    try Task.checkCancellation()
                    guard self.generation == token, !MioMaintenanceState.shared.blocksWork,
                          let connection = self.connection, try await self.connectionStillMatches(connection, token: token)
                    else { throw MioCloudError.changedConfiguration }
                    guard !self.queue.isEmpty else { break }
                    let work = self.queue.removeFirst()
                    do {
                        let prepared = try await self.prepareConnection(connection, work.request.mode == .lesson ? .lesson : .everyday)
                        try Task.checkCancellation()
                        guard self.enabled, self.generation == token, try await self.connectionStillMatches(connection, token: token),
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
                        if request.mode == .everyday, self.windowOpenedAt.map({ work.enqueuedAt > $0 }) ?? true {
                            self.windowOpenedAt = self.now()
                        }
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
                        guard try await self.connectionStillMatches(connection, token: token) else { throw MioCloudError.changedConfiguration }
                        if let metadata = result.metadata { self.lessonInterval = TimeInterval(metadata.lessonIntervalSeconds) }
                        let count = try await assistant.applyAnalysis(result, request: request, session: session)
                        self.activeSessionID = nil; self.sentBatches += 1
                        self.status = "Senast analyserat \(self.now().formatted(date: .omitted, time: .shortened)). \(count) nya förslag."
                        if request.mode == .lesson { self.status = MioLessonDocument(session: session, records: assistant.analyses).progress }
                        self.isWorking = false
                    } catch {
                        // Quota, rate limits and an unreachable PC pause instead of stopping AI.
                        guard self.generation == token, !(error is CancellationError),
                              (try? await self.connectionStillMatches(connection, token: token)) == true,
                              let deadline = MioAnalysisSchedule.retryDeadline(after: error, now: self.now(),
                                                                                quotaResetAt: self.quotaResetAt)
                        else { throw error }
                        MioConnectionDiscovery.shared.handle(error: error)
                        self.queue.insert(work, at: 0)
                        self.isWorking = false; self.activeSessionID = nil
                        self.pause(until: deadline, after: error)
                    }
                }
            } catch is CancellationError {
                // Explicit cancellation rejects every late response before persistence.
            } catch {
                if self.generation == token {
                    guard let connection = self.connection, self.configurationMatches(connection) else {
                        MioConnectionDiscovery.shared.invalidate()
                        self.disable()
                        self.errorMessage = "Anslutningen till datorn ändrades. AI startar igen när parningen är klar."
                        self.status = "AI stoppades eftersom anslutningen till datorn ändrades."
                        return
                    }
                    MioConnectionDiscovery.shared.handle(error: error)
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    private func fail(_ message: String) {
        disable()
        errorMessage = message + " AI startar igen nästa gång du öppnar Mio, eller med Starta AI igen i Inställningar."
        status = "AI stoppad. Lokal transkription fortsätter."
    }
}
