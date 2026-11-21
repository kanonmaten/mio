import BackgroundTasks
import Foundation
import Observation
import os

/// The nightly backup (fas 6): a `BGProcessingTask` that needs external power and a network, so
/// iOS runs it while the phone charges, usually at night. It sends the versioned export through
/// Tailscale to the gateway on the PC, which encrypts it and keeps 14 copies. Never to the cloud.
/// Only the time and the result of the latest attempt are kept (`MioBackupAttempt`).
/// **Ej verifierat** on the phone: when iOS actually starts the task.
@MainActor @Observable
final class MioBackupTask {
    /// Listed in Info.plist under BGTaskSchedulerPermittedIdentifiers.
    nonisolated static let identifier = "app.mio.assistant.backup"
    /// A copy at most once in this many hours; iOS decides the exact time.
    private static let interval: TimeInterval = 20 * 60 * 60

    private(set) var lastAttempt: MioBackupAttempt? = MioBackupAttempt.load(from: .standard)
    private(set) var isRunning = false
    @ObservationIgnored private let workflow: MioWorkflowCoordinator
    @ObservationIgnored private let logger = Logger(subsystem: "app.mio.assistant", category: "backup")
    @ObservationIgnored private var registered = false

    init(workflow: MioWorkflowCoordinator) { self.workflow = workflow }

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
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
            return
        }
        submit(now: now)
    }

    private func submit(now: Date = .now) {
        let request = BGProcessingTaskRequest(identifier: Self.identifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        let last = lastAttempt.flatMap { $0.succeeded ? $0.at : nil } ?? .distantPast
        request.earliestBeginDate = max(now.addingTimeInterval(15 * 60), last.addingTimeInterval(Self.interval))
        do { try BGTaskScheduler.shared.submit(request) }
        catch { logger.error("Backup request failed: \(String(describing: error), privacy: .public)") }
    }

    private func run(_ task: BGProcessingTask) {
        let work = Task { @MainActor [weak self] in
            guard let self else { return nil as MioBackupAttempt? }
            let attempt = await self.backUpNow()
            // The night's run also replans the morning and evening texts for the coming days.
            await MioSystemServices.shared.replanDailyNotices()
            return attempt
        }
        task.expirationHandler = { work.cancel() }
        Task { @MainActor [weak self] in
            let attempt = await work.value
            task.setTaskCompleted(success: attempt?.succeeded == true)
            // A relaunch in the background has no status yet. The task only exists because a
            // status with `backup` scheduled it, so the next night follows unless the PC said it
            // no longer takes copies.
            guard let self, attempt?.failure != MioBackupError.unsupported.code else { return }
            self.submit()
        }
    }

    /// One copy now, from the nightly task or from "Säkerhetskopiera nu" in settings.
    @discardableResult
    func backUpNow(now: Date = .now) async -> MioBackupAttempt {
        guard !isRunning else { return lastAttempt ?? MioBackupAttempt(at: now, failure: MioBackupError.dataBusy.code) }
        isRunning = true
        defer { isRunning = false }
        let failure: MioBackupError?
        do {
            let connection = try MioCloudSettings.connection()
            switch await workflow.backupExport() {
            case .success(let data):
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
            failure = .notPaired
        }
        let attempt = MioBackupAttempt(at: now, failure: failure?.code)
        attempt.save(to: .standard)
        lastAttempt = attempt
        if let failure { logger.notice("Backup failed: \(failure.code, privacy: .public)") }
        return attempt
    }

    /// The copies on the PC, newest first.
    func listBackups() async throws -> [MioBackupSummary] {
        try await MioBackupService.list(connection: try connection(), transport: MioBackupTransport.native)
    }

    /// Downloads, validates and stages a copy; it replaces the data at the next launch.
    func stageRestore(id: String) async throws -> Date {
        if let blocker = workflow.restoreBlocker { throw blocker }
        let data = try await MioBackupService.download(id: id, connection: try connection(), transport: MioBackupTransport.native)
        if let blocker = workflow.restoreBlocker { throw blocker }
        return try MioBackupRestore.stage(data, files: .standard)
    }

    private func connection() throws -> MioCloudConnection {
        do { return try MioCloudSettings.connection() } catch { throw MioBackupError.notPaired }
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
