import BackgroundTasks
import Foundation
import Observation
import os

/// The nightly backup (fas 6): a `BGProcessingTask` that needs external power and a network, so
/// iOS runs it while the phone charges, usually at night. It sends the versioned export through
/// Tailscale to the gateway on the PC, which encrypts it and keeps 14 copies. Never to the cloud.
/// Only the time and the result of the latest attempt are kept (`MioBackupAttempt`).
///
/// Timing rules (review of fas 6, 2026-11-21): when the next attempt runs follows
/// `MioBackupSchedule` (a few growing retries the same night only after a network failure or a
/// timeout, otherwise the next night). A run started by iOS before any view exists waits for the
/// same launch bootstrap and deletion recovery as the app and sends nothing unless both
/// succeeded. iOS ending the task cancels the export and skips the replanning, and
/// `setTaskCompleted` is called exactly once. The scheduled request is cancelled after
/// "Radera all data" and whenever the pairing is forgotten or replaced.
/// **Ej verifierat** on the phone: when iOS actually starts the task.
@MainActor @Observable
final class MioBackupTask {
    /// Listed in Info.plist under BGTaskSchedulerPermittedIdentifiers.
    nonisolated static let identifier = "app.mio.assistant.backup"

    private(set) var lastAttempt: MioBackupAttempt? = MioBackupAttempt.load(from: .standard)
    private(set) var isRunning = false
    @ObservationIgnored private let workflow: MioWorkflowCoordinator
    @ObservationIgnored private let logger = Logger(subsystem: "app.mio.assistant", category: "backup")
    @ObservationIgnored private var registered = false
    @ObservationIgnored private var pairingObserver: NSObjectProtocol?

    init(workflow: MioWorkflowCoordinator) {
        self.workflow = workflow
        workflow.onAllDataDeleted = { [weak self] in self?.forgetAfterDeletion() }
        // Posted when the pairing is saved (also a new PC) and when it is forgotten. A new
        // pairing schedules again once its status shows `backup`.
        pairingObserver = NotificationCenter.default.addObserver(forName: MioCloudSettings.didResetNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelScheduled() }
        }
    }

    /// Must run before the app finishes launching; iOS refuses a later registration.
    func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let processing = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.run(processing)
            }
        }
        if !registered { logger.error("Backup task was not registered") }
    }

    /// Schedules the next night only when the gateway's status has `backup`; otherwise any
    /// scheduled request is cancelled. Uses the status Mio already has, no extra request.
    func schedule(status: MioGatewayStatusV2, now: Date = .now) {
        guard registered else { return }
        guard status.backup != nil, MioCloudSettings.isPaired else {
            cancelScheduled()
            return
        }
        // A status with `backup` means the PC takes copies now, whatever an older attempt said.
        let stopping: Set<String> = [MioBackupError.unsupported.code, MioBackupError.notPaired.code]
        let attempt = lastAttempt.flatMap { last in last.failure.map { stopping.contains($0) } == true ? nil : last }
        submit(earliest: MioBackupSchedule.nextBegin(after: attempt, now: now))
    }

    private func submit(earliest: Date?) {
        guard let earliest else {
            cancelScheduled()
            return
        }
        let request = BGProcessingTaskRequest(identifier: Self.identifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = earliest
        do { try BGTaskScheduler.shared.submit(request) }
        catch { logger.error("Backup request failed: \(String(describing: error), privacy: .public)") }
    }

    private func cancelScheduled() {
        guard registered else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
    }

    /// After "Radera all data": no scheduled copy and no remembered attempt, in memory or stored.
    private func forgetAfterDeletion() {
        cancelScheduled()
        MioBackupAttempt.clear(in: .standard)
        lastAttempt = nil
    }

    private func run(_ task: BGProcessingTask) {
        // The work is one task, so cancelling it reaches the export: `backupExport` runs its
        // operation in the command queue behind a cancellation handler that cancels it there.
        let work = Task { @MainActor [weak self] () -> MioBackupAttempt? in
            guard let self else { return nil }
            // iOS may launch Mio only for this task. Nothing is read, sent or planned before the
            // same bootstrap and deletion recovery as the app have succeeded.
            guard await self.workflow.readyForBackgroundWork(), !Task.isCancelled else { return nil }
            let attempt = await self.backUpNow()
            // The night's run also replans the morning and evening texts, never after iOS ended it.
            if !Task.isCancelled { await MioSystemServices.shared.replanDailyNotices() }
            return attempt
        }
        task.expirationHandler = { work.cancel() }
        Task { @MainActor [weak self] in
            let attempt = await work.value
            // The only call, whether the work finished, failed, was skipped or was cancelled.
            task.setTaskCompleted(success: attempt?.succeeded == true)
            guard let self else { return }
            // A relaunch in the background has no status yet. The task exists only because a
            // status with `backup` scheduled it, so it follows `MioBackupSchedule`. A skipped run
            // (bootstrap or deletion recovery did not succeed) tries again the next night.
            if let attempt {
                self.submit(earliest: MioBackupSchedule.nextBegin(after: attempt, now: .now))
            } else if MioCloudSettings.isPaired {
                self.submit(earliest: Date.now.addingTimeInterval(MioBackupSchedule.interval))
            }
        }
    }

    /// One copy now, from the nightly task or from "Säkerhetskopiera nu" in settings.
    @discardableResult
    func backUpNow(now: Date = .now) async -> MioBackupAttempt {
        guard !isRunning else { return lastAttempt ?? MioBackupAttempt(at: now, failure: MioBackupError.dataBusy.code) }
        isRunning = true
        defer { isRunning = false }
        let retry = MioBackupSchedule.retryIndex(previous: lastAttempt, now: now)
        let failure: MioBackupError?
        do {
            // A Keychain that cannot be read (locked phone) is its own outcome, never "Para datorn".
            let connection: MioCloudConnection
            do { connection = try MioCloudSettings.connection() }
            catch { throw MioBackupError.from(connectionError: error) }
            switch await workflow.backupExport() {
            case .success(let data):
                try Task.checkCancellation()
                _ = try await MioBackupService.upload(data, connection: connection, transport: MioBackupTransport.native)
                failure = nil
            case .failure(let error):
                failure = error
            }
        } catch let error as MioBackupError {
            failure = error
        } catch is CancellationError {
            failure = .timeout
        } catch {
            failure = .server
        }
        let attempt = MioBackupAttempt(at: now, failure: failure?.code, retry: failure?.isTransient == true ? retry : nil)
        attempt.save(to: .standard)
        lastAttempt = attempt
        if let failure { logger.notice("Backup failed: \(failure.code, privacy: .public)") }
        return attempt
    }

    /// The copies on the PC, newest first.
    func listBackups() async throws -> [MioBackupSummary] {
        try await MioBackupService.list(connection: try connection(), transport: MioBackupTransport.native)
    }

    /// Downloads, validates and stages a copy; it replaces the data at the next launch. A deletion
    /// that begins while the copy downloads refuses it (`MioBackupRestore.stage`).
    func stageRestore(id: String) async throws -> Date {
        if let blocker = workflow.restoreBlocker { throw blocker }
        let generation = workflow.restoreDeletionGeneration
        let data = try await MioBackupService.download(id: id, connection: try connection(), transport: MioBackupTransport.native)
        return try workflow.stageRestore(data, deletionGeneration: generation)
    }

    private func connection() throws -> MioCloudConnection {
        do { return try MioCloudSettings.connection() } catch { throw MioBackupError.from(connectionError: error) }
    }
}

/// The backup's own URLSession: ephemeral, no cookies or cache, no redirects (the token must
/// never follow one), and the same short retry as the AI calls while the on-demand VPN comes up.
enum MioBackupTransport {
    static let native: MioBackupService.Transport = { request in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval + 10
        let session = URLSession(configuration: configuration, delegate: MioBackupRedirectGuard(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var attempt = 1
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw MioBackupError.invalidResponse }
                return (data, http)
            } catch let error as NSError where error.domain == NSURLErrorDomain {
                guard let delay = MioCloudRetry.delay(urlErrorCode: error.code, attempt: attempt) else { throw error }
                attempt += 1
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }
}

private final class MioBackupRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The app's own `embedded.mobileprovision`, read once. Nil in the simulator and from the App Store.
enum MioSigningInfo {
    static let expiration: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return MioSigning.expirationDate(fromProvisioningProfile: data)
    }()
}
