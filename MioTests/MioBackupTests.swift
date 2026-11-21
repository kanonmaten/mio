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

    func testAStagedCopyIsAppliedOnceInOneReplacementAndCanBeCancelledBefore() async throws {
        let files = try files()
        let item = MioContentItem(kind: .note, title: "Återställd")
        _ = try MioBackupRestore.stage(export(content: [item]), files: files)
        XCTAssertTrue(MioBackupRestore.hasPending(in: files))
        try MioBackupRestore.cancel(in: files)
        XCTAssertFalse(MioBackupRestore.hasPending(in: files))
        let target = FakeTarget()
        let none = await MioBackupRestore.applyPending(files: files, target: target, deletionPending: false)
        XCTAssertNil(none)

        _ = try MioBackupRestore.stage(export(content: [item]), files: files)
        let message = await MioBackupRestore.applyPending(files: files, target: target, deletionPending: false)
        XCTAssertTrue(message?.hasPrefix("Återställningen är klar.") == true)
        let replaced = await target.replaced
        XCTAssertEqual(replaced?.content.map(\.id), [item.id])
        XCTAssertFalse(MioBackupRestore.hasPending(in: files))
    }

    func testAFailedReplacementKeepsTheCopyAndARefusedOneIsRemoved() async throws {
        let files = try files()
        _ = try MioBackupRestore.stage(export(), files: files)
        let target = FakeTarget()
        await target.failNext()
        let failed = await MioBackupRestore.applyPending(files: files, target: target, deletionPending: false)
        XCTAssertTrue(failed?.contains("dina data är som förut") == true)
        XCTAssertTrue(MioBackupRestore.hasPending(in: files), "The next launch tries once more")

        let blocked = await MioBackupRestore.applyPending(files: files, target: FakeTarget(), deletionPending: true)
        XCTAssertTrue(blocked?.contains("radering") == true)
        XCTAssertFalse(MioBackupRestore.hasPending(in: files))

        try Data("{\"schemaVersion\":9}".utf8).write(to: MioBackupRestore.pendingURL(in: files))
        let refused = await MioBackupRestore.applyPending(files: files, target: FakeTarget(), deletionPending: false)
        XCTAssertTrue(refused?.contains("ingenting ändrades") == true)
        XCTAssertFalse(MioBackupRestore.hasPending(in: files))
    }

    func testStagingRefusesAnUnknownSchemaWithoutWritingAnything() throws {
        let files = try files()
        XCTAssertThrowsError(try MioBackupRestore.stage(Data("{\"schemaVersion\":3,\"exportedAt\":\"2026-11-21T02:00:00Z\"}".utf8), files: files))
        XCTAssertFalse(MioBackupRestore.hasPending(in: files))
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
}
