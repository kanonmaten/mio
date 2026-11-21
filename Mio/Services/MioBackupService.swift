import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `backup` in `/v2/status` (contract "Säkerhetskopian"). Absent at a gateway without backups;
/// the app shows and schedules the nightly copy only when it is there.
struct MioGatewayBackupStatus: Equatable, Sendable {
    let latestAt: Date?
    let count: Int
    let bytes: Int

    /// Nil for anything but the contract's object. A malformed value only hides the backup; it
    /// never makes the rest of the status unreadable.
    init?(json value: Any?) {
        guard let object = value as? [String: Any], Set(object.keys) == ["latestAt", "count", "bytes"],
              let count = object["count"] as? Int, (0...14).contains(count),
              let bytes = object["bytes"] as? Int, bytes >= 0 else { return nil }
        if object["latestAt"] is NSNull {
            latestAt = nil
        } else if let text = object["latestAt"] as? String, let date = MioBackupService.parseDate(text) {
            latestAt = date
        } else { return nil }
        self.count = count
        self.bytes = bytes
    }

    init(latestAt: Date?, count: Int, bytes: Int) {
        self.latestAt = latestAt; self.count = count; self.bytes = bytes
    }
}

/// One copy on the PC, as `GET /v2/backups` lists it.
struct MioBackupSummary: Identifiable, Equatable, Sendable {
    let id: String
    let createdAt: Date
    let bytes: Int

    /// `ÅÅÅÅMMDDTHHMMSSZ-<8 hex>`; anything else is never put in a URL.
    static func isValidID(_ id: String) -> Bool {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 16, parts[1].count == 8 else { return false }
        let stamp = Array(parts[0])
        let digits = stamp.enumerated().allSatisfy { index, character in
            index == 8 ? character == "T" : index == 15 ? character == "Z" : character.isASCII && character.isNumber
        }
        return digits && parts[1].allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
    }
}

/// What the gateway said after a copy was stored.
struct MioBackupReceipt: Equatable, Sendable {
    let id: String
    let createdAt: Date
    let bytes: Int
    let kept: Int
}

/// Every failure as one sentence and one thing to do, in plain Swedish (fas 6). `code` is the
/// text-free name kept for the last attempt and the error report.
enum MioBackupError: Error, Equatable, LocalizedError, CaseIterable {
    case notPaired
    /// The Keychain could not be read, usually because the phone is locked. Never "not paired":
    /// the pairing and AI stay as they are (CLAUDE.md: a locked Keychain never turns AI off).
    case keychainLocked
    case unsupported
    case capturing
    case dataBusy
    case unauthorized
    case network
    case timeout
    case busy
    case tooLarge
    case invalidBackup
    case storageFull
    case unreadable
    case notFound
    case unknownSchema
    case invalidResponse
    case server
    case localData

    var errorDescription: String? {
        switch self {
        case .notPaired: "Datorn är inte parad. Para den under Inställningar → Avancerat → Parning."
        case .keychainLocked: "Mio kunde inte läsa parningen eftersom telefonen var låst. Lås upp telefonen och försök igen; parningen och AI är som förut."
        case .unsupported: "Datorn tar inte emot säkerhetskopior än. Uppdatera Mio på datorn med install.sh."
        case .capturing: "Mio lyssnar just nu. Stoppa lyssningen och försök igen."
        case .dataBusy: "Mio arbetar med dina data just nu. Vänta en stund och försök igen."
        case .unauthorized: "Datorn kände inte igen telefonen. Para om den under Inställningar → Avancerat → Parning."
        case .network: "Mio når inte datorn. Kontrollera att Tailscale är på och att datorn är igång."
        case .timeout: "Datorn svarade inte i tid. Försök igen om en stund."
        case .busy: "Datorn arbetar redan med en kopia. Försök igen om några minuter."
        case .tooLarge: "Dina data är för stora för en kopia. Exportera dem under Lagring i stället."
        case .invalidBackup: "Datorn tog inte emot kopian. Försök igen i morgon, och skicka en felrapport om det upprepas."
        case .storageFull: "Datorns disk är full. Frigör utrymme på datorn och försök igen."
        case .unreadable: "Kopian på datorn går inte att läsa. Välj en annan kopia."
        case .notFound: "Kopian finns inte längre på datorn. Välj en annan kopia."
        case .unknownSchema: "Kopian kommer från en annan version av Mio och kan inte läsas här. Uppdatera Mio och försök igen."
        case .invalidResponse: "Datorn gav ett svar Mio inte förstår. Uppdatera Mio på datorn och försök igen."
        case .server: "Något gick fel på datorn. Försök igen om en stund."
        case .localData: "Mio kunde inte läsa dina data för kopian. Starta om Mio och försök igen."
        }
    }

    var code: String {
        switch self {
        case .notPaired: "not_paired"
        case .keychainLocked: "keychain_locked"
        case .unsupported: "unsupported"
        case .capturing: "capturing"
        case .dataBusy: "data_busy"
        case .unauthorized: "unauthorized"
        case .network: "network"
        case .timeout: "timeout"
        case .busy: "backup_busy"
        case .tooLarge: "too_large"
        case .invalidBackup: "invalid_backup"
        case .storageFull: "backup_storage_failed"
        case .unreadable: "backup_unreadable"
        case .notFound: "backup_not_found"
        case .unknownSchema: "unknown_schema"
        case .invalidResponse: "invalid_response"
        case .server: "server_error"
        case .localData: "local_data"
        }
    }
}

extension MioBackupError {
    /// The sentence for a stored `code`; an unknown code gets a general one.
    static func described(code: String?) -> String {
        allCases.first { $0.code == code }?.errorDescription ?? "Kopian kunde inte skickas. Försök igen."
    }

    /// The pairing read from the Keychain failed. Only a missing or invalid pairing is
    /// `.notPaired`; a Keychain that cannot be read (locked phone) is its own outcome.
    static func from(connectionError error: Error) -> MioBackupError {
        if let error = error as? MioBackupError { return error }
        if case .keychain? = error as? MioCloudError { return .keychainLocked }
        return .notPaired
    }

    /// Network failures and timeouts may clear the same night; every other failure waits a night.
    var isTransient: Bool { self == .network || self == .timeout }
}

/// When the nightly copy runs next (review of fas 6, 2026-11-21). A copy at most once per
/// `interval`. After a network failure or a timeout a few more tries the same night with a
/// growing wait; after any other failure, or when those tries are used up, the next night.
/// `.unsupported` and `.notPaired` stop scheduling until the status or pairing changes.
enum MioBackupSchedule {
    static let interval: TimeInterval = 20 * 60 * 60
    /// The earliest start iOS is asked for when nothing else applies.
    static let minimumLead: TimeInterval = 15 * 60
    /// Waits before the 1st, 2nd and 3rd retry after a network failure or timeout.
    static let retryDelays: [TimeInterval] = [15 * 60, 45 * 60, 2 * 60 * 60]
    /// A failure older than this starts a new night's count.
    static let retryWindow: TimeInterval = 8 * 60 * 60

    /// The retry number for an attempt starting now: 0 for the night's first attempt, otherwise
    /// one more than the previous attempt when that was a recent network failure or timeout.
    static func retryIndex(previous: MioBackupAttempt?, now: Date) -> Int {
        guard let previous, let failure = previous.failure,
              MioBackupError.allCases.first(where: { $0.code == failure })?.isTransient == true,
              now.timeIntervalSince(previous.at) >= 0, now.timeIntervalSince(previous.at) < retryWindow else { return 0 }
        return (previous.retry ?? 0) + 1
    }

    /// The earliest begin date to ask iOS for after `attempt`, or nil to schedule nothing.
    static func nextBegin(after attempt: MioBackupAttempt?, now: Date) -> Date? {
        let soonest = now.addingTimeInterval(minimumLead)
        guard let attempt else { return soonest }
        let error = attempt.failure.flatMap { code in MioBackupError.allCases.first { $0.code == code } }
        if error == .unsupported || error == .notPaired { return nil }
        let retry = attempt.retry ?? 0
        if let error, error.isTransient, retry < retryDelays.count {
            return max(soonest, attempt.at.addingTimeInterval(retryDelays[retry]))
        }
        // A copy that worked, any other failure, or the night's tries used up: the next night.
        // An attempt dated in the future (a clock change) never pushes the copy further away.
        return max(soonest, min(attempt.at, now).addingTimeInterval(interval))
    }
}

/// The latest attempt only, without content (contract "Säkerhetskopian"): when it ran and how it
/// ended. Kept in UserDefaults under `mio.backup.lastAttempt.v1`.
struct MioBackupAttempt: Codable, Equatable, Sendable {
    static let key = "mio.backup.lastAttempt.v1"

    let at: Date
    /// Nil when the copy was stored; otherwise `MioBackupError.code`.
    let failure: String?
    /// Which retry of the night this was (additive, absent for the night's first attempt). Only
    /// a number, never content; see `MioBackupSchedule`.
    var retry: Int? = nil

    init(at: Date, failure: String?, retry: Int? = nil) {
        self.at = at
        self.failure = failure
        self.retry = retry == 0 ? nil : retry
    }

    var succeeded: Bool { failure == nil }

    static func load(from defaults: UserDefaults) -> Self? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }

    static func clear(in defaults: UserDefaults) { defaults.removeObject(forKey: key) }
}

/// The app's side of `PUT /v2/backup`, `GET /v2/backups` and `GET /v2/backups/<id>`. The body is
/// never sent anywhere else; the transport is injected so the tests run without a network.
enum MioBackupService {
    /// The gateway's own limit (32 MiB).
    static let maximumBytes = 32 * 1024 * 1024
    /// Contract deadline for an upload.
    static let uploadTimeout: TimeInterval = 120
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static func origin(of connection: MioCloudConnection) -> URL {
        connection.endpoint.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The export as JSON, without diagnostics: a copy of her data, not of the phone's logs.
    /// Pure and free of actor state, so the caller runs it off the main actor (it may take seconds).
    static func encode(_ export: MioLocalExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export)
    }

    static func upload(_ body: Data, connection: MioCloudConnection, transport: Transport) async throws -> MioBackupReceipt {
        guard body.count <= maximumBytes else { throw MioBackupError.tooLarge }
        var request = request(origin(of: connection).appendingPathComponent("v2/backup"), token: connection.token, method: "PUT")
        request.httpBody = body
        request.timeoutInterval = uploadTimeout
        let data = try await perform(request, transport: transport, expected: 201)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["id", "createdAt", "bytes", "kept"],
              let id = object["id"] as? String, MioBackupSummary.isValidID(id),
              let created = (object["createdAt"] as? String).flatMap(parseDate),
              let bytes = object["bytes"] as? Int, let kept = object["kept"] as? Int else { throw MioBackupError.invalidResponse }
        return MioBackupReceipt(id: id, createdAt: created, bytes: bytes, kept: kept)
    }

    static func list(connection: MioCloudConnection, transport: Transport) async throws -> [MioBackupSummary] {
        let request = request(origin(of: connection).appendingPathComponent("v2/backups"), token: connection.token, method: "GET")
        let data = try await perform(request, transport: transport, expected: 200)
        guard data.count <= 65_536, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["backups"], let rows = object["backups"] as? [[String: Any]], rows.count <= 64
        else { throw MioBackupError.invalidResponse }
        let backups = try rows.map { row -> MioBackupSummary in
            guard Set(row.keys) == ["id", "createdAt", "bytes"], let id = row["id"] as? String, MioBackupSummary.isValidID(id),
                  let created = (row["createdAt"] as? String).flatMap(parseDate), let bytes = row["bytes"] as? Int, bytes >= 0
            else { throw MioBackupError.invalidResponse }
            return MioBackupSummary(id: id, createdAt: created, bytes: bytes)
        }
        return backups.sorted { $0.createdAt > $1.createdAt }
    }

    static func download(id: String, connection: MioCloudConnection, transport: Transport) async throws -> Data {
        guard MioBackupSummary.isValidID(id) else { throw MioBackupError.notFound }
        var request = request(origin(of: connection).appendingPathComponent("v2/backups").appendingPathComponent(id),
                              token: connection.token, method: "GET")
        // A busy gateway queues a second download for up to 120 s before answering 429.
        request.timeoutInterval = uploadTimeout + 30
        let data = try await perform(request, transport: transport, expected: 200)
        guard data.count <= maximumBytes else { throw MioBackupError.invalidResponse }
        return data
    }

    static func request(_ url: URL, token: String, method: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "PUT" { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func perform(_ request: URLRequest, transport: Transport, expected: Int) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as MioBackupError { throw error }
        catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut { throw MioBackupError.timeout }
            throw MioBackupError.network
        }
        guard response.statusCode == expected else { throw failure(status: response.statusCode, body: data) }
        guard response.mimeType == "application/json" else { throw MioBackupError.invalidResponse }
        return data
    }

    /// The contract's statuses, and the gateway's `error` code when it gives one.
    static func failure(status: Int, body: Data) -> MioBackupError {
        let code = MioCloudService.gatewayCode(from: body)?.rawValue
            ?? ((try? JSONSerialization.jsonObject(with: body.prefix(4096))) as? [String: Any])?["error"] as? String
        switch (status, code) {
        case (401, _), (403, _): return .unauthorized
        case (404, "backup_not_found"): return .notFound
        case (404, _), (405, _): return .unsupported
        case (408, _), (504, _): return .timeout
        case (413, _): return .tooLarge
        case (400, _), (415, _): return .invalidBackup
        case (429, _): return .busy
        case (500, "backup_unreadable"): return .unreadable
        case (507, _): return .storageFull
        default: return .server
        }
    }

    static func parseDate(_ text: String) -> Date? {
        guard text.utf8.count <= 40 else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

/// Restoring a copy is an import of her own export, done in two steps so nothing is ever half
/// replaced (fas 6). In the app the copy is validated with the repositories' own rules and kept
/// as a pending file; the next launch replaces every row in one SwiftData transaction before any
/// repository opens, so no capture, AI or other write can run beside it. A failed transaction
/// leaves the current rows untouched, and "Avbryt" before the restart removes the pending file.
///
/// Privacy rules (review of fas 6, 2026-11-21): the pending file is a full unencrypted copy, so
/// every deletion (all data, a session or a post) removes it at once and bumps a deletion
/// generation. The pending copy records the generation it was chosen under, and a launch refuses
/// it when any deletion has begun since, even if removing the file failed. It is valid for at
/// most 24 hours, and a replacement that cannot be verified is not retried at every launch.
enum MioBackupRestore {
    static let pendingFileName = "restore-pending.json"
    static let metadataFileName = "restore-pending-meta.json"
    /// Counts deletions that have begun. Never reset, not even by "Radera all data".
    static let deletionGenerationKey = "mio.restore.deletionGeneration.v1"
    /// How long a chosen copy may wait for the restart.
    static let validity: TimeInterval = 24 * 60 * 60
    /// Launches that may try a replacement before the pending copy is given up.
    static let maximumAttempts = 2

    /// What is known about the pending copy, without any of its content.
    struct Metadata: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1
        var schemaVersion = Self.currentSchemaVersion
        let stagedAt: Date
        let deletionGeneration: Int
        var failedAttempts = 0
    }

    static func pendingURL(in files: MioLegacyStoreFiles) -> URL {
        files.directory.appendingPathComponent(pendingFileName, isDirectory: false)
    }

    static func metadataURL(in files: MioLegacyStoreFiles) -> URL {
        files.directory.appendingPathComponent(metadataFileName, isDirectory: false)
    }

    static func deletionGeneration(in defaults: UserDefaults) -> Int { defaults.integer(forKey: deletionGenerationKey) }

    /// Called when any deletion begins, before its first step.
    static func noteDeletion(in defaults: UserDefaults) {
        defaults.set(deletionGeneration(in: defaults) &+ 1, forKey: deletionGenerationKey)
    }

    /// Decodes and validates a copy. Only a known export schema (1 or 2) and the assistant
    /// schema this app writes are accepted; anything else is refused and never stored.
    static func snapshot(from data: Data) throws -> (snapshot: MioLegacyStoreSnapshot, exportedAt: Date) {
        struct Header: Decodable { let schemaVersion: Int }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let header = try? decoder.decode(Header.self, from: data) else { throw MioBackupError.invalidResponse }
        guard (1...2).contains(header.schemaVersion) else { throw MioBackupError.unknownSchema }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let assistant = root["assistant"] as? [String: Any],
           assistant["schemaVersion"] as? Int != MioAssistantStoreDocument.currentSchemaVersion {
            throw MioBackupError.unknownSchema
        }
        guard let export = try? decoder.decode(MioLocalExport.self, from: data) else { throw MioBackupError.invalidResponse }
        let snapshot = MioLegacyStoreSnapshot(sessions: export.sessions, content: export.content,
                                              assistant: export.assistant ?? MioAssistantStoreDocument())
        // The repositories' own load rules: duplicate identities, relationships and intervals.
        do {
            _ = try SessionRepositoryCore(storage: MioRestoreSessionStorage(snapshot.sessions)).loadSessions()
            _ = try MioContentRepositoryCore(storage: MioRestoreContentStorage(snapshot.content)).loadItems()
            _ = try MioAssistantRepositoryCore(storage: MioRestoreAssistantStorage(snapshot.assistant)).loadDocument()
        } catch { throw MioBackupError.invalidResponse }
        return (snapshot, export.exportedAt)
    }

    /// Validates first, then writes the metadata and the pending file. The current data is not
    /// touched here. `deletionGeneration` is the generation read before the copy was downloaded;
    /// a deletion since then refuses the copy instead of bringing deleted data back.
    static func stage(_ data: Data, files: MioLegacyStoreFiles, deletionGeneration: Int,
                      defaults: UserDefaults, now: Date = .now) throws -> Date {
        let exportedAt = try snapshot(from: data).exportedAt
        guard self.deletionGeneration(in: defaults) == deletionGeneration else { throw MioBackupError.dataBusy }
        try files.prepareOwnedDirectory(files.directory)
        let metadata = Metadata(stagedAt: now, deletionGeneration: deletionGeneration)
        try MioProtectedFileWriter.write(encodeMetadata(metadata), to: metadataURL(in: files))
        try MioProtectedFileWriter.write(data, to: pendingURL(in: files))
        return exportedAt
    }

    static func hasPending(in files: MioLegacyStoreFiles) -> Bool {
        FileManager.default.fileExists(atPath: pendingURL(in: files).path)
    }

    /// Removes the pending copy and its metadata. Throws only when the copy itself is still there.
    static func cancel(in files: MioLegacyStoreFiles) throws {
        try? FileManager.default.removeItem(at: metadataURL(in: files))
        let url = pendingURL(in: files)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func readMetadata(in files: MioLegacyStoreFiles) -> Metadata? {
        guard let data = try? Data(contentsOf: metadataURL(in: files)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let metadata = try? decoder.decode(Metadata.self, from: data),
              metadata.schemaVersion == Metadata.currentSchemaVersion else { return nil }
        return metadata
    }

    private static func encodeMetadata(_ metadata: Metadata) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(metadata)
    }

    /// Why the pending copy may no longer be applied, or nil when it may: it must have usable
    /// metadata, be chosen under the current deletion generation and less than 24 hours ago (a
    /// date in the future, after a clock change, is not trusted either).
    static func refusal(for metadata: Metadata?, deletionGeneration: Int, now: Date) -> String? {
        guard let metadata else {
            return "Den väntande återställningen saknade sina uppgifter och togs bort. Dina data är som förut. Välj kopian igen under Säkerhetskopia."
        }
        guard metadata.deletionGeneration == deletionGeneration else {
            return "Återställningen gjordes inte, eftersom du raderade data efter att du valde kopian. Dina data är som förut."
        }
        let age = now.timeIntervalSince(metadata.stagedAt)
        guard age < validity, age > -5 * 60 else {
            return "Den valda kopian väntade i mer än ett dygn och togs bort. Dina data är som förut. Välj kopian igen under Säkerhetskopia om du vill återställa."
        }
        return nil
    }

    /// Run at launch before the repositories open. Returns the one message to show, or nil when
    /// nothing was pending. The pending file is removed after a verified replacement, after a
    /// refused or expired copy, and after a replacement whose result could not be verified. It
    /// stays only when the store could not be written, and then for at most `maximumAttempts`
    /// launches, so a failure is never retried at every start.
    static func applyPending(files: MioLegacyStoreFiles, target: any MioStoreMigrationTarget,
                             deletionPending: Bool, deletionGeneration: Int, now: Date = .now) async -> String? {
        let url = pendingURL(in: files)
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? FileManager.default.removeItem(at: metadataURL(in: files))
            return nil
        }
        guard !deletionPending else {
            try? cancel(in: files)
            return "Återställningen gjordes inte, eftersom en radering inte hade slutförts. Dina data är som förut."
        }
        let metadata = readMetadata(in: files)
        if let refused = refusal(for: metadata, deletionGeneration: deletionGeneration, now: now) {
            try? cancel(in: files)
            return refused
        }
        let decoded: (snapshot: MioLegacyStoreSnapshot, exportedAt: Date)
        do {
            decoded = try snapshot(from: Data(contentsOf: url))
        } catch {
            try? cancel(in: files)
            return "Kopian kunde inte läsas, så ingenting ändrades. Välj en annan kopia under Säkerhetskopia."
        }
        do {
            try await target.replaceAll(with: decoded.snapshot)
        } catch {
            MioLog.error(.storage, "restore transaction failed")
            var failed = metadata ?? Metadata(stagedAt: now, deletionGeneration: deletionGeneration)
            failed.failedAttempts += 1
            guard failed.failedAttempts < maximumAttempts,
                  (try? MioProtectedFileWriter.write(encodeMetadata(failed), to: metadataURL(in: files))) != nil else {
                try? cancel(in: files)
                return "Återställningen misslyckades igen och den valda kopian är borttagen. Dina data är som förut. Välj kopian igen under Säkerhetskopia om du vill försöka på nytt."
            }
            return "Återställningen misslyckades och dina data är som förut. Starta om Mio för att försöka igen."
        }
        let verified = (try? await target.counts()) == MioStoreCounts(snapshot: decoded.snapshot)
        // The transaction has committed either way, so the copy is never applied again.
        try? cancel(in: files)
        guard verified else {
            MioLog.error(.storage, "restore count mismatch")
            return "Återställningen kunde inte kontrolleras, och den valda kopian är borttagen. Kontrollera dina data, och välj kopian igen under Säkerhetskopia om något saknas."
        }
        let date = decoded.exportedAt.formatted(date: .long, time: .shortened)
        return "Återställningen är klar. Mio visar nu kopian från \(date)."
    }
}

// In-memory storages that hand a copy to the repository cores, only to run their load validation.
private final class MioRestoreSessionStorage: MioSessionStorage {
    let sessions: [MioSession]
    init(_ sessions: [MioSession]) { self.sessions = sessions }
    func stamp() throws -> MioFileStamp? { nil }
    func read() throws -> [MioSession]? { sessions }
    func write(_ sessions: [MioSession], replacing previous: [MioSession]?) throws {}
    func erase() throws {}
}

private final class MioRestoreContentStorage: MioContentStorage {
    let items: [MioContentItem]
    init(_ items: [MioContentItem]) { self.items = items }
    func stamp() throws -> MioFileStamp? { nil }
    func read() throws -> [MioContentItem]? { items }
    func write(_ items: [MioContentItem], replacing previous: [MioContentItem]?) throws {}
    func erase() throws {}
}

private final class MioRestoreAssistantStorage: MioAssistantStorage {
    let document: MioAssistantStoreDocument
    init(_ document: MioAssistantStoreDocument) { self.document = document }
    func stamp() throws -> MioFileStamp? { nil }
    func read() throws -> MioAssistantStoreDocument? { document }
    func write(_ document: MioAssistantStoreDocument, replacing previous: MioAssistantStoreDocument?) throws {}
    func erase() throws {}
}
