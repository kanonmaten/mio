import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Mio

/// Fas 6: the nightly copy to the PC and restoring one, against the contract in
/// docs/DATAMODELL.md, "Säkerhetskopian". No network: the transport is a recorded reply.
final class MioBackupTests: XCTestCase {
    private let connection = MioCloudConnection(endpoint: URL(string: "https://pc.tail.ts.net:8443/v1/ask")!,
                                                token: String(repeating: "t", count: 40))

    private func reply(_ status: Int, _ body: String, type: String = "application/json") -> MioBackupService.Transport {
        { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                              headerFields: ["Content-Type": type])!)
        }
    }

    private final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
    }

    private func export(sessions: [MioSession] = [], content: [MioContentItem] = [],
                        assistant: MioAssistantStoreDocument? = MioAssistantStoreDocument()) throws -> Data {
        try MioBackupService.encode(MioLocalExport(exportedAt: Date(timeIntervalSince1970: 1_800_000_000), content: content,
                                                   sessions: sessions, assistant: assistant))
    }

    func testStatusExposesTheBackupFieldAndToleratesItsAbsence() throws {
        let tasks = ["ask", "everyday", "lesson"].map { task in
            "\"\(task)\":{\"configured\":true,\"provider\":\"mistral\",\"model\":\"m\",\"promptVersion\":\"p\",\"capabilities\":[],\"configurationError\":null}"
        }.joined(separator: ",")
        let base = "\"protocolVersion\":2,\"release\":\"2026-11-21\",\"configurationRevision\":\"\(String(repeating: "a", count: 64))\",\"tasks\":{\(tasks)},\"quota\":null"
        let with = try MioGatewayStatusV2.decode(Data("{\(base),\"backup\":{\"latestAt\":\"2026-11-21T02:00:00Z\",\"count\":3,\"bytes\":900}}".utf8))
        XCTAssertEqual(with.backup, MioGatewayBackupStatus(latestAt: ISO8601DateFormatter().date(from: "2026-11-21T02:00:00Z"), count: 3, bytes: 900))
        let none = try MioGatewayStatusV2.decode(Data("{\(base),\"backup\":{\"latestAt\":null,\"count\":0,\"bytes\":0}}".utf8))
        XCTAssertNil(none.backup?.latestAt)
        XCTAssertEqual(none.backup?.count, 0)
        XCTAssertNil(try MioGatewayStatusV2.decode(Data("{\(base)}".utf8)).backup)
        // A malformed value hides the backup but never the rest of the status.
        XCTAssertNil(try MioGatewayStatusV2.decode(Data("{\(base),\"backup\":{\"count\":99}}".utf8)).backup)
    }

    func testUploadSendsTheExportWithTheTokenAndReadsTheReceipt() async throws {
        let recorder = Recorder()
        let body = try export()
        let receipt = try await MioBackupService.upload(body, connection: connection) { request in
            recorder.requests.append(request)
            return (Data(#"{"id":"20261121T020000Z-0a1b2c3d","createdAt":"2026-11-21T02:00:00Z","bytes":120,"kept":14}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        XCTAssertEqual(receipt.id, "20261121T020000Z-0a1b2c3d")
        XCTAssertEqual(receipt.kept, 14)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://pc.tail.ts.net:8443/v2/backup")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(connection.token)")
        XCTAssertEqual(request.httpBody, body)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(sent["schemaVersion"] as? Int, 2)
        XCTAssertNotNil(sent["exportedAt"] as? String)
        XCTAssertNil(sent["diagnostics"], "The copy is her data, not the phone's logs")
    }

    func testContractStatusesBecomeOneSentenceEach() async throws {
        let cases: [(Int, String, MioBackupError)] = [
            (429, #"{"error":"backup_busy"}"#, .busy), (500, #"{"error":"backup_unreadable"}"#, .unreadable),
            (507, #"{"error":"backup_storage_failed"}"#, .storageFull), (404, #"{"error":"backup_not_found"}"#, .notFound),
            (404, #"{"error":"not_found"}"#, .unsupported), (401, "", .unauthorized), (413, "", .tooLarge),
            (400, #"{"error":"invalid_backup"}"#, .invalidBackup), (408, #"{"error":"request_timeout"}"#, .timeout),
            (502, "<html>", .server)
        ]
        for (status, body, expected) in cases {
            do {
                _ = try await MioBackupService.list(connection: connection, transport: reply(status, body))
                XCTFail("Expected \(expected)")
            } catch let error as MioBackupError {
                XCTAssertEqual(error, expected, "\(status) \(body)")
                let message = try XCTUnwrap(error.errorDescription)
                XCTAssertFalse(message.contains { $0.isNumber }, message)
                XCTAssertFalse(message.contains("backup_"), message)
            }
        }
    }

    func testListIsNewestFirstAndRejectsUnknownShapes() async throws {
        let body = #"{"backups":[{"id":"20261119T020000Z-00000000","createdAt":"2026-11-19T02:00:00Z","bytes":1},{"id":"20261121T020000Z-ffffffff","createdAt":"2026-11-21T02:00:00Z","bytes":2}]}"#
        let backups = try await MioBackupService.list(connection: connection, transport: reply(200, body))
        XCTAssertEqual(backups.map(\.bytes), [2, 1])
        for bad in [#"{"backups":[{"id":"../etc","createdAt":"2026-11-19T02:00:00Z","bytes":1}]}"#, #"{"backups":[],"x":1}"#, "[]"] {
            do {
                _ = try await MioBackupService.list(connection: connection, transport: reply(200, bad))
                XCTFail(bad)
            } catch let error as MioBackupError { XCTAssertEqual(error, .invalidResponse) }
        }
        XCTAssertFalse(MioBackupSummary.isValidID("20261121T020000Z-FFFFFFFF"))
        XCTAssertTrue(MioBackupSummary.isValidID("20261121T020000Z-0a1b2c3d"))
    }

    func testNoAnswerIsANetworkFailure() async {
        do {
            _ = try await MioBackupService.download(id: "20261121T020000Z-0a1b2c3d", connection: connection) { _ in
                throw URLError(.cannotConnectToHost)
            }
            XCTFail("Expected a failure")
        } catch { XCTAssertEqual(error as? MioBackupError, .network) }
    }

    func testTheLastAttemptKeepsOnlyTimeAndResult() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "mio.backup.test.\(UUID().uuidString)"))
        MioBackupAttempt(at: Date(timeIntervalSince1970: 10), failure: MioBackupError.network.code).save(to: defaults)
        XCTAssertEqual(MioBackupAttempt.load(from: defaults), MioBackupAttempt(at: Date(timeIntervalSince1970: 10), failure: "network"))
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: MioBackupAttempt.key))) as? [String: Any])
        XCTAssertEqual(Set(stored.keys), ["at", "failure"])
        XCTAssertEqual(MioBackupError.described(code: "network"), MioBackupError.network.errorDescription)
        XCTAssertEqual(MioBackupError.described(code: "something"), "Kopian kunde inte skickas. Försök igen.")
        MioBackupAttempt.clear(in: defaults)
        XCTAssertNil(MioBackupAttempt.load(from: defaults))
    }

    func testRestoreAcceptsOnlyAKnownSchemaThatPassesTheRepositoryRules() throws {
        let session = MioSession(startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: Date(timeIntervalSince1970: 1_700_000_600))
        let item = MioContentItem(kind: .note, title: "Anteckning")
        let decoded = try MioBackupRestore.snapshot(from: export(sessions: [session], content: [item]))
        XCTAssertEqual(decoded.snapshot.sessions.map(\.id), [session.id])
        XCTAssertEqual(decoded.snapshot.content.map(\.id), [item.id])
        XCTAssertEqual(decoded.exportedAt, Date(timeIntervalSince1970: 1_800_000_000))

        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: export()) as? [String: Any])
        future["schemaVersion"] = 3
        XCTAssertThrowsError(try MioBackupRestore.snapshot(from: JSONSerialization.data(withJSONObject: future))) {
            XCTAssertEqual($0 as? MioBackupError, .unknownSchema)
        }
        var assistant = try XCTUnwrap(JSONSerialization.jsonObject(with: export()) as? [String: Any])
        var document = try XCTUnwrap(assistant["assistant"] as? [String: Any])
        document["schemaVersion"] = 2
        assistant["assistant"] = document
        XCTAssertThrowsError(try MioBackupRestore.snapshot(from: JSONSerialization.data(withJSONObject: assistant))) {
            XCTAssertEqual($0 as? MioBackupError, .unknownSchema)
        }
        XCTAssertThrowsError(try MioBackupRestore.snapshot(from: export(content: [item, item]))) {
            XCTAssertEqual($0 as? MioBackupError, .invalidResponse)
        }
        XCTAssertThrowsError(try MioBackupRestore.snapshot(from: Data("{}".utf8)))
    }

    private actor FakeTarget: MioStoreMigrationTarget {
        var replaced: MioLegacyStoreSnapshot?
        var fails = false
        var stored = MioStoreCounts()
        func failNext() { fails = true }
        func replaceAll(with snapshot: MioLegacyStoreSnapshot) throws {
            if fails { throw CocoaError(.fileWriteUnknown) }
            replaced = snapshot
            stored = MioStoreCounts(snapshot: snapshot)
        }
        func removeAll() throws { stored = MioStoreCounts() }
        func counts() throws -> MioStoreCounts { stored }
    }

    private func files() throws -> MioLegacyStoreFiles {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mio-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return MioLegacyStoreFiles(directory: directory)
    }

    private func defaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "mio.backup.test.\(UUID().uuidString)"))
    }

    private let stagedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func stage(_ data: Data, _ files: MioLegacyStoreFiles, _ defaults: UserDefaults, at date: Date? = nil) throws {
        _ = try MioBackupRestore.stage(data, files: files, deletionGeneration: MioBackupRestore.deletionGeneration(in: defaults),
                                       defaults: defaults, now: date ?? stagedAt)
    }

    private func apply(_ files: MioLegacyStoreFiles, _ target: FakeTarget, _ defaults: UserDefaults,
                       deletionPending: Bool = false, hoursLater: Double = 1) async -> String? {
        await MioBackupRestore.applyPending(files: files, target: target, deletionPending: deletionPending,
                                            deletionGeneration: MioBackupRestore.deletionGeneration(in: defaults),
                                            now: stagedAt.addingTimeInterval(hoursLater * 3_600))
    }

    func testAStagedCopyIsAppliedOnceInOneReplacementAndCanBeCancelledBefore() async throws {
        let files = try files()
        let defaults = try defaults()
        let item = MioContentItem(kind: .note, title: "Återställd")
        try stage(export(content: [item]), files, defaults)
        XCTAssertTrue(MioBackupRestore.hasPending(in: files))
        XCTAssertEqual(MioBackupRestore.readMetadata(in: files)?.stagedAt, stagedAt)
        try MioBackupRestore.cancel(in: files)
        XCTAssertFalse(MioBackupRestore.hasPending(in: files))
        XCTAssertNil(MioBackupRestore.readMetadata(in: files))
        let target = FakeTarget()
        let none = await apply(files, target, defaults)
        XCTAssertNil(none)

        try stage(export(content: [item]), files, defaults)
        let message = await apply(files, target, defaults)
        XCTAssertTrue(message?.hasPrefix("Återställningen är klar.") == true)
        let replaced = await target.replaced
        XCTAssertEqual(replaced?.content.map(\.id), [item.id])
        XCTAssertFalse(MioBackupRestore.hasPending(in: files))
        XCTAssertNil(MioBackupRestore.readMetadata(in: files))
    }

    func testAFailedReplacementIsTriedOnceMoreThenGivenUpAndARefusedOneIsRemoved() async throws {
        let files = try files()
        let defaults = try defaults()
        try stage(export(), files, defaults)
        let target = FakeTarget()
        await target.failNext()
        let failed = await apply(files, target, defaults)
        XCTAssertTrue(failed?.contains("dina data är som förut") == true)
        XCTAssertTrue(MioBackupRestore.hasPending(in: files), "The next launch tries once more")
        let again = await apply(files, target, defaults)
        XCTAssertTrue(again?.contains("borttagen") == true, again ?? "")
        XCTAssertFalse(MioBackupRestore.hasPending(in: files), "Never retried at every launch")

        try stage(export(), files, defaults)
        let blocked = await apply(files, FakeTarget(), defaults, deletionPending: true)
        XCTAssertTrue(blocked?.contains("radering") == true)
        XCTAssertFalse(MioBackupRestore.hasPending(in: files))

        try stage(export(), files, defaults)
        try Data("{\"schemaVersion\":9}".utf8).write(to: MioBackupRestore.pendingURL(in: files))
        let refused = await apply(files, FakeTarget(), defaults)
        XCTAssertTrue(refused?.contains("ingenting ändrades") == true)
        XCTAssertFalse(MioBackupRestore.hasPending(in: files))
    }

    func testStagingRefusesAnUnknownSchemaWithoutWritingAnything() throws {
        let files = try files()
        let defaults = try defaults()
        XCTAssertThrowsError(try stage(Data("{\"schemaVersion\":3,\"exportedAt\":\"2026-11-21T02:00:00Z\"}".utf8), files, defaults))
        XCTAssertFalse(MioBackupRestore.hasPending(in: files))
    }

    func testADeletionAfterTheCopyWasChosenRefusesItEvenWhenTheFileSurvived() async throws {
        let files = try files()
        let defaults = try defaults()
        try stage(export(), files, defaults)
        // The file stayed (removal failed), but a deletion began and finished after it was written.
        MioBackupRestore.noteDeletion(in: defaults)
        let target = FakeTarget()
        let message = await apply(files, target, defaults)
        XCTAssertTrue(message?.contains("raderade data") == true, message ?? "")
        let replaced = await target.replaced
        XCTAssertNil(replaced, "Deleted data never comes back")
        XCTAssertFalse(MioBackupRestore.hasPending(in: files))

        // A deletion while the copy downloaded refuses the staging itself.
        let before = MioBackupRestore.deletionGeneration(in: defaults)
        MioBackupRestore.noteDeletion(in: defaults)
        XCTAssertThrowsError(try MioBackupRestore.stage(export(), files: files, deletionGeneration: before, defaults: defaults))
        XCTAssertFalse(MioBackupRestore.hasPending(in: files))
    }

    func testAPendingCopyIsValidForADayAndNeedsItsMetadata() async throws {
        let files = try files()
        let defaults = try defaults()
        try stage(export(), files, defaults)
        let expired = await apply(files, FakeTarget(), defaults, hoursLater: 25)
        XCTAssertTrue(expired?.contains("mer än ett dygn") == true, expired ?? "")
        XCTAssertFalse(MioBackupRestore.hasPending(in: files))

        try stage(export(), files, defaults)
        try FileManager.default.removeItem(at: MioBackupRestore.metadataURL(in: files))
        let target = FakeTarget()
        let missing = await apply(files, target, defaults)
        XCTAssertTrue(missing?.contains("saknade sina uppgifter") == true, missing ?? "")
        let replaced = await target.replaced
        XCTAssertNil(replaced)
        XCTAssertFalse(MioBackupRestore.hasPending(in: files))
        XCTAssertNil(MioBackupRestore.refusal(for: .init(stagedAt: stagedAt, deletionGeneration: 0),
                                              deletionGeneration: 0, now: stagedAt.addingTimeInterval(23 * 3_600)))
    }

    private actor MismatchTarget: MioStoreMigrationTarget {
        var replacements = 0
        func replaceAll(with snapshot: MioLegacyStoreSnapshot) throws { replacements += 1 }
        func removeAll() throws {}
        func counts() throws -> MioStoreCounts { MioStoreCounts(snapshot: MioLegacyStoreSnapshot(sessions: [], content: [MioContentItem(kind: .note, title: "x")], assistant: MioAssistantStoreDocument())) }
    }

    func testAReplacementThatCannotBeVerifiedIsNotRetriedAtEveryLaunch() async throws {
        let files = try files()
        let defaults = try defaults()
        try stage(export(), files, defaults)
        let target = MismatchTarget()
        let message = await MioBackupRestore.applyPending(files: files, target: target, deletionPending: false,
            deletionGeneration: MioBackupRestore.deletionGeneration(in: defaults), now: stagedAt.addingTimeInterval(60))
        XCTAssertTrue(message?.contains("kunde inte kontrolleras") == true, message ?? "")
        XCTAssertFalse(MioBackupRestore.hasPending(in: files))
        _ = await MioBackupRestore.applyPending(files: files, target: target, deletionPending: false,
            deletionGeneration: MioBackupRestore.deletionGeneration(in: defaults), now: stagedAt.addingTimeInterval(120))
        let replacements = await target.replacements
        XCTAssertEqual(replacements, 1)
    }

    func testTheNightlyScheduleRetriesOnlyNetworkFailuresAndTimeoutsAFewTimes() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hour: TimeInterval = 3_600
        XCTAssertEqual(MioBackupSchedule.nextBegin(after: nil, now: now), now.addingTimeInterval(15 * 60))
        let success = MioBackupAttempt(at: now, failure: nil)
        XCTAssertEqual(MioBackupSchedule.nextBegin(after: success, now: now), now.addingTimeInterval(20 * hour))
        for permanent in [MioBackupError.invalidBackup, .storageFull, .unauthorized, .tooLarge, .localData, .keychainLocked, .dataBusy, .capturing] {
            let attempt = MioBackupAttempt(at: now, failure: permanent.code)
            XCTAssertEqual(MioBackupSchedule.nextBegin(after: attempt, now: now), now.addingTimeInterval(20 * hour), permanent.code)
        }
        XCTAssertNil(MioBackupSchedule.nextBegin(after: MioBackupAttempt(at: now, failure: "unsupported"), now: now))
        XCTAssertNil(MioBackupSchedule.nextBegin(after: MioBackupAttempt(at: now, failure: "not_paired"), now: now))

        // Network: retries after 15 min, 45 min and 2 h, then the next night. Never every 15 minutes.
        var previous: MioBackupAttempt?
        var clock = now
        var waits: [TimeInterval] = []
        for _ in 0..<5 {
            let retry = MioBackupSchedule.retryIndex(previous: previous, now: clock)
            let attempt = MioBackupAttempt(at: clock, failure: MioBackupError.network.code, retry: retry)
            let next = try XCTUnwrap(MioBackupSchedule.nextBegin(after: attempt, now: clock))
            waits.append(next.timeIntervalSince(clock))
            previous = attempt
            clock = next
        }
        XCTAssertEqual(waits, [15 * 60, 45 * 60, 2 * hour, 20 * hour, 15 * 60], "A new night starts a new count")
        let timeout = MioBackupAttempt(at: now, failure: MioBackupError.timeout.code, retry: 1)
        XCTAssertEqual(MioBackupSchedule.nextBegin(after: timeout, now: now), now.addingTimeInterval(45 * 60))
        // A retry never runs sooner than iOS's minimum lead, even when the wait has passed.
        XCTAssertEqual(MioBackupSchedule.nextBegin(after: timeout, now: now.addingTimeInterval(3 * hour)),
                       now.addingTimeInterval(3 * hour + 15 * 60))
    }

    func testALockedKeychainIsItsOwnOutcomeAndNeverNotPaired() throws {
        XCTAssertEqual(MioBackupError.from(connectionError: MioCloudError.keychain), .keychainLocked)
        XCTAssertEqual(MioBackupError.from(connectionError: MioCloudError.notPaired), .notPaired)
        XCTAssertEqual(MioBackupError.from(connectionError: MioCloudError.invalidServer), .notPaired)
        XCTAssertEqual(MioBackupError.from(connectionError: MioBackupError.timeout), .timeout)
        let message = try XCTUnwrap(MioBackupError.keychainLocked.errorDescription)
        XCTAssertTrue(message.contains("Lås upp telefonen"))
        XCTAssertFalse(message.contains("Para"), "A locked phone never asks her to pair again")
        XCTAssertEqual(MioBackupError.described(code: "keychain_locked"), message)
        // The stored attempt keeps a retry number only when there is one.
        let defaults = try defaults()
        MioBackupAttempt(at: Date(timeIntervalSince1970: 10), failure: "network", retry: 2).save(to: defaults)
        XCTAssertEqual(MioBackupAttempt.load(from: defaults)?.retry, 2)
        MioBackupAttempt(at: Date(timeIntervalSince1970: 10), failure: "network", retry: 0).save(to: defaults)
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: MioBackupAttempt.key))) as? [String: Any])
        XCTAssertEqual(Set(stored.keys), ["at", "failure"])
    }

    @MainActor
    func testAnApprovedExamKeepsItsDayAndSubjectAndTheNightlyCopyCarriesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioBackupTests-\(UUID())")
        let assistant = MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json"))
        let content = MioContentRepository(storageURL: root.appendingPathComponent("content.json"), exportDirectoryURL: root)
        let capture = MioViewModel(repository: SessionRepository(storageURL: root.appendingPathComponent("sessions.json")))
        let workflow = MioWorkflowCoordinator(capture: capture, content: MioContentViewModel(repository: content),
            assistant: MioAssistantViewModel(repository: assistant), analysis: MioAnalysisCoordinator(),
            journal: MioDeletionJournal(storageURL: root.appendingPathComponent("operations.json")),
            systemActions: MioSystemActionPort(cancel: { _ in .success }, removeAll: { .success }))
        await workflow.bootstrap()
        let exam = MioSuggestion(kind: .plan, title: "Biologiprov")
        let party = MioSuggestion(kind: .plan, title: "Fest hos Sara")
        try await assistant.addSuggestion(exam)
        try await assistant.addSuggestion(party)
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let approved = await workflow.recordHandoff(id: exam.id, kind: .plan, title: "Biologiprov", destination: .calendar,
                                                    examDate: (date: day, allDay: true), examSubject: "Biologi")
        XCTAssertTrue(approved.isSuccess, "\(approved)")
        let ordinary = await workflow.recordHandoff(id: party.id, kind: .plan, title: "Fest hos Sara", destination: .calendar,
                                                    examDate: (date: day, allDay: true))
        XCTAssertTrue(ordinary.isSuccess)
        let items = try await content.loadItems()
        let saved = try XCTUnwrap(items.first { $0.id == exam.id })
        XCTAssertEqual(saved.exam, MioExamRecord(date: Calendar.current.startOfDay(for: day), isAllDay: true, subject: "Biologi"))
        XCTAssertNil(items.first { $0.id == party.id }?.exam, "Only an exam keeps a date")
        XCTAssertEqual(saved.handoff?.destination, .calendar)

        guard case .success(let data) = await workflow.backupExport() else { return XCTFail("No backup") }
        let restored = try MioBackupRestore.snapshot(from: data).snapshot
        XCTAssertEqual(restored.content.first { $0.id == exam.id }?.exam, saved.exam)

        let subject = await workflow.content.setExamSubject(id: exam.id, subject: "Kemi")
        XCTAssertTrue(subject.isSuccess)
        let changed = try await content.loadItems().first { $0.id == exam.id }
        XCTAssertEqual(changed?.exam?.subject, "Kemi")
        XCTAssertEqual(changed?.handoff, saved.handoff)
    }

    @MainActor
    private func workflowFixture(_ root: URL, defaults: UserDefaults, restoreFiles: MioLegacyStoreFiles?)
        -> (workflow: MioWorkflowCoordinator, capture: MioViewModel, content: MioContentViewModel) {
        let capture = MioViewModel(repository: SessionRepository(storageURL: root.appendingPathComponent("sessions.json")))
        let content = MioContentViewModel(repository: MioContentRepository(storageURL: root.appendingPathComponent("content.json"),
                                                                           exportDirectoryURL: root))
        let workflow = MioWorkflowCoordinator(capture: capture, content: content,
            assistant: MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json"))),
            analysis: MioAnalysisCoordinator(), journal: MioDeletionJournal(storageURL: root.appendingPathComponent("operations.json")),
            diagnostics: MioDiagnosticsRepository(storageURL: root.appendingPathComponent("diagnostics.json")),
            systemActions: MioSystemActionPort(cancel: { _ in .success }, removeAll: { .success }),
            clearCredentials: {}, pendingLessonDefaults: defaults,
            metrics: MioMetricArchive(storageURL: root.appendingPathComponent("metrickit.json")),
            restoreFiles: restoreFiles)
        return (workflow, capture, content)
    }

    @MainActor
    func testEveryDeletionRemovesAPendingRestoreAndAllDataTurnsTheDailyNoticesOff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioBackupTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try defaults()
        let files = try files()
        let fixture = workflowFixture(root, defaults: defaults, restoreFiles: files)
        let workflow = fixture.workflow
        var deletedAll = 0
        workflow.onAllDataDeleted = { deletedAll += 1 }
        await workflow.bootstrap()
        for (key, value) in [("mio.daily.morning.minutes", 420), ("mio.daily.evening.minutes", 1_200)] { defaults.set(value, forKey: key) }
        defaults.set(true, forKey: MioDailyDigest.morningDetailKey)
        defaults.set(true, forKey: "mio.daily.future.setting")

        _ = try workflow.stageRestore(export(), deletionGeneration: workflow.restoreDeletionGeneration)
        XCTAssertTrue(workflow.restorePending)
        // Nothing she records now would survive the restart, so nothing starts.
        fixture.capture.beginListening()
        XCTAssertEqual(fixture.capture.errorMessage, MioWorkflowCoordinator.restorePendingCaptureMessage)
        XCTAssertEqual(fixture.capture.runState, .off)
        await fixture.capture.beginLesson(title: "Biologi")
        XCTAssertFalse(fixture.capture.isLessonActive)

        // A single post's deletion removes the pending copy too and says so.
        let saved = await fixture.content.save(kind: .memory, title: "En post", body: "", scheduledAt: .now, isCompleted: false, sessionID: nil)
        XCTAssertTrue(saved)
        let item = try XCTUnwrap(fixture.content.items.first)
        let deleted = await workflow.deleteContent(id: item.id)
        XCTAssertEqual(deleted, .success)
        XCTAssertFalse(workflow.restorePending)
        XCTAssertFalse(MioBackupRestore.hasPending(in: files))
        XCTAssertNotNil(workflow.restoreNotice)
        workflow.dismissRestoreNotice()

        // "Radera all data" removes the unencrypted copy at once and the daily settings.
        _ = try workflow.stageRestore(export(), deletionGeneration: workflow.restoreDeletionGeneration)
        let generation = workflow.restoreDeletionGeneration
        let all = await workflow.deleteAll()
        XCTAssertEqual(all, .success)
        XCTAssertFalse(MioBackupRestore.hasPending(in: files))
        XCTAssertNil(MioBackupRestore.readMetadata(in: files))
        XCTAssertGreaterThan(workflow.restoreDeletionGeneration, generation, "Never reset: a surviving copy stays refused")
        XCTAssertEqual(deletedAll, 1)
        for key in ["mio.daily.morning.minutes", "mio.daily.evening.minutes", MioDailyDigest.morningDetailKey, "mio.daily.future.setting"] {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        // With nothing pending, capture may start again (it fails later only for lack of a server).
        XCTAssertNil(fixture.capture.captureBlocker())
    }

    @MainActor
    func testACopyOlderThanADayIsRemovedWithANotice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioBackupTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try defaults()
        let files = try files()
        let workflow = workflowFixture(root, defaults: defaults, restoreFiles: files).workflow
        await workflow.bootstrap()
        _ = try workflow.stageRestore(export(), deletionGeneration: workflow.restoreDeletionGeneration, now: stagedAt)
        workflow.refreshRestorePending(now: stagedAt.addingTimeInterval(3_600))
        XCTAssertTrue(workflow.restorePending)
        XCTAssertNil(workflow.restoreNotice)
        workflow.refreshRestorePending(now: stagedAt.addingTimeInterval(25 * 3_600))
        XCTAssertFalse(workflow.restorePending)
        XCTAssertTrue(workflow.restoreNotice?.contains("mer än ett dygn") == true)
        XCTAssertTrue(workflow.cancelPendingRestore())
    }

    @MainActor
    func testTheBackupWaitsForTheLaunchAndSendsNothingWhenBlockedOrCancelled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioBackupTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { MioMaintenanceState.shared.setRecoveryBlocked(false) }
        let fixture = workflowFixture(root, defaults: try defaults(), restoreFiles: nil)
        // iOS started Mio only for the task: the export runs the same bootstrap itself first.
        guard case .success(let data) = await fixture.workflow.backupExport() else { return XCTFail("No backup") }
        XCTAssertNoThrow(try MioBackupRestore.snapshot(from: data))
        let ready = await fixture.workflow.readyForBackgroundWork()
        XCTAssertTrue(ready)

        // iOS ending the task before or while the export is queued gives no data.
        let cancelled = Task { @MainActor in await fixture.workflow.backupExport() }
        cancelled.cancel()
        let result = await cancelled.value
        XCTAssertEqual(try? result.get(), nil)
        if case .failure(let error) = result { XCTAssertEqual(error, .timeout) }

        // A blocked deletion recovery sends nothing.
        MioMaintenanceState.shared.setRecoveryBlocked(true)
        let blocked = await fixture.workflow.backupExport()
        XCTAssertEqual(try? blocked.get(), nil)
        let notReady = await fixture.workflow.readyForBackgroundWork()
        XCTAssertFalse(notReady)
    }

    func testResettingTheDailySettingsRemovesOnlyThem() throws {
        let defaults = try defaults()
        defaults.set(420, forKey: "mio.daily.morning.minutes")
        defaults.set(true, forKey: "mio.daily.morning.detail")
        defaults.set("x", forKey: "mio.cloud.server")
        MioDailyDigest.resetSettings(in: defaults)
        XCTAssertNil(defaults.object(forKey: "mio.daily.morning.minutes"))
        XCTAssertNil(defaults.object(forKey: "mio.daily.morning.detail"))
        XCTAssertEqual(defaults.string(forKey: "mio.cloud.server"), "x")
    }
}
