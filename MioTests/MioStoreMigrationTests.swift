import Foundation
import XCTest
@testable import Mio

/// In-memory stand-in for the SwiftData migration target; the decision logic is portable.
private actor FakeMigrationTarget: MioStoreMigrationTarget {
    private(set) var snapshot: MioLegacyStoreSnapshot?
    private(set) var replaceCalls = 0
    private(set) var removeCalls = 0
    var countAdjustment = 0
    var failReplace = false

    func configure(countAdjustment: Int = 0, failReplace: Bool = false) {
        self.countAdjustment = countAdjustment
        self.failReplace = failReplace
    }

    func replaceAll(with snapshot: MioLegacyStoreSnapshot) throws {
        replaceCalls += 1
        if failReplace { throw CocoaError(.fileWriteUnknown) }
        self.snapshot = snapshot
    }

    func removeAll() throws {
        removeCalls += 1
        snapshot = nil
    }

    func counts() throws -> MioStoreCounts {
        guard let snapshot else { return MioStoreCounts() }
        var counts = MioStoreCounts(snapshot: snapshot)
        counts.segments += countAdjustment
        return counts
    }
}

/// Records what the shared core passes as the persisted state before each write.
private final class RecordingSessionStorage: MioSessionStorage {
    var stored: [MioSession]?
    var previousStates: [[MioSession]?] = []

    func stamp() throws -> MioFileStamp? { MioFileStamp(modifiedAt: nil, size: 1, inode: 0) }
    func read() throws -> [MioSession]? { stored }
    func write(_ sessions: [MioSession], replacing previous: [MioSession]?) throws {
        previousStates.append(previous)
        stored = sessions
    }
    func erase() throws { stored = nil }
}

private final class RecordingAssistantStorage: MioAssistantStorage {
    var stored: MioAssistantStoreDocument?
    var previousSuggestionIDs: [[UUID]?] = []

    func stamp() throws -> MioFileStamp? { MioFileStamp(modifiedAt: nil, size: 1, inode: 0) }
    func read() throws -> MioAssistantStoreDocument? { stored }
    func write(_ document: MioAssistantStoreDocument, replacing previous: MioAssistantStoreDocument?) throws {
        previousSuggestionIDs.append(previous?.suggestions.map(\.id))
        stored = document
    }
    func erase() throws { stored = nil }
}

final class MioStoreMigrationTests: XCTestCase {
    private func makeFiles() throws -> (MioLegacyStoreFiles, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioStoreMigrationTests-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("Mio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (MioLegacyStoreFiles(directory: directory), root)
    }

    private func session(segments: Int = 2) -> MioSession {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var session = MioSession(startedAt: start, endedAt: start.addingTimeInterval(60),
                                 transcripts: (0..<segments).map { index in
                                     TranscriptSegment(createdAt: start.addingTimeInterval(Double(index)),
                                                       text: "Syntetisk text \(index)", containsMio: false)
                                 })
        session.captureGaps = [CaptureGap(startedAt: start.addingTimeInterval(10), endedAt: start.addingTimeInterval(12),
                                          reason: "Testlucka")]
        return session
    }

    private func writeLegacyFiles(_ files: MioLegacyStoreFiles, session: MioSession) async throws {
        let sessions = SessionRepository(storageURL: files.sessionsURL)
        let token = try await sessions.operationToken(for: session.id, generation: await sessions.operationGeneration())
        try await sessions.saveCaptureCheckpoint(session, token: token)
        _ = try await MioContentRepository(storageURL: files.contentURL)
            .upsert(MioContentItem(kind: .note, title: "Syntetisk anteckning", sessionID: session.id))
        try await MioAssistantRepository(storageURL: files.assistantURL)
            .addSuggestion(MioSuggestion(kind: .task, title: "Syntetisk uppgift", sessionID: session.id))
    }

    func testUnknownLegacySchemaMigratesNothingAndKeepsFilesUntouched() async throws {
        let (files, root) = try makeFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeLegacyFiles(files, session: session())
        let unknown = Data(#"{"schemaVersion":2,"items":[],"future":"must remain"}"#.utf8)
        try unknown.write(to: files.contentURL)
        let sessionsBefore = try Data(contentsOf: files.sessionsURL)
        let target = FakeMigrationTarget()

        let outcome = await MioStoreMigrator(files: files, target: target).run()

        guard case let .useLegacyFiles(message) = outcome else { return XCTFail("Okänt schema måste avbryta flytten") }
        XCTAssertTrue(message.contains("content-v1.json"))
        let replaceCalls = await target.replaceCalls
        XCTAssertEqual(replaceCalls, 0)
        XCTAssertEqual(try Data(contentsOf: files.contentURL), unknown)
        XCTAssertEqual(try Data(contentsOf: files.sessionsURL), sessionsBefore)
        XCTAssertNil(try files.readMarker())
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.backupDirectory.path))
    }

    func testVerifiedMigrationMarksDoneMovesFilesAndCleansBackupOnNextLaunch() async throws {
        let (files, root) = try makeFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = session(segments: 3)
        try await writeLegacyFiles(files, session: original)
        let target = FakeMigrationTarget()

        let first = await MioStoreMigrator(files: files, target: target).run()

        XCTAssertEqual(first, .useStore(message: nil))
        let migrated = await target.snapshot
        XCTAssertEqual(migrated?.sessions.map(\.id), [original.id])
        XCTAssertEqual(migrated?.sessions.first?.transcripts.count, 3)
        XCTAssertEqual(migrated?.content.count, 1)
        XCTAssertEqual(migrated?.assistant.suggestions.count, 1)
        let marker = try XCTUnwrap(try files.readMarker())
        XCTAssertEqual(marker.state, .backedUp)
        XCTAssertEqual(marker.counts.segments, 3)
        XCTAssertEqual(marker.counts.captureGaps, 1)
        XCTAssertTrue(files.presentLegacyURLs.isEmpty)
        for name in ["sessions.json", "content-v1.json", "assistant-v1.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: files.backupDirectory.appendingPathComponent(name).path))
        }

        let second = await MioStoreMigrator(files: files, target: target).run()

        XCTAssertEqual(second, .useStore(message: nil))
        let replaceCalls = await target.replaceCalls
        XCTAssertEqual(replaceCalls, 1, "Flytten får bara göras en gång")
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.backupDirectory.path))
    }

    func testCountMismatchRemovesRowsAndLeavesNoMarker() async throws {
        let (files, root) = try makeFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeLegacyFiles(files, session: session())
        let target = FakeMigrationTarget()
        await target.configure(countAdjustment: -1)

        let outcome = await MioStoreMigrator(files: files, target: target).run()

        XCTAssertEqual(outcome, .useLegacyFiles(message: MioStoreMigrator.verificationMessage))
        let removeCalls = await target.removeCalls
        XCTAssertEqual(removeCalls, 1)
        XCTAssertNil(try files.readMarker())
        XCTAssertEqual(files.presentLegacyURLs.count, 3)
    }

    func testFailedTransactionKeepsLegacyFilesAndRetriesNextLaunch() async throws {
        let (files, root) = try makeFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeLegacyFiles(files, session: session())
        let target = FakeMigrationTarget()
        await target.configure(failReplace: true)

        let failed = await MioStoreMigrator(files: files, target: target).run()
        XCTAssertEqual(failed, .useLegacyFiles(message: MioStoreMigrator.saveMessage))
        XCTAssertNil(try files.readMarker())

        await target.configure()
        let retried = await MioStoreMigrator(files: files, target: target).run()
        XCTAssertEqual(retried, .useStore(message: nil))
        XCTAssertEqual(try files.readMarker()?.state, .backedUp)
    }

    func testFreshInstallWritesMarkerWithoutTouchingTheStore() async throws {
        let (files, root) = try makeFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = FakeMigrationTarget()

        let outcome = await MioStoreMigrator(files: files, target: target).run()

        XCTAssertEqual(outcome, .useStore(message: nil))
        let calls = await (target.replaceCalls, target.removeCalls)
        XCTAssertEqual(calls.0, 0)
        XCTAssertEqual(calls.1, 0)
        XCTAssertEqual(try files.readMarker()?.counts, MioStoreCounts())
    }

    func testVerifiedMarkerAfterCrashMovesRemainingFilesWithoutRemigrating() async throws {
        let (files, root) = try makeFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeLegacyFiles(files, session: session())
        try files.writeMarker(MioStoreMigrationMarker(state: .verified, migratedAt: .now, counts: MioStoreCounts()))
        let target = FakeMigrationTarget()

        let outcome = await MioStoreMigrator(files: files, target: target).run()

        XCTAssertEqual(outcome, .useStore(message: nil))
        let replaceCalls = await target.replaceCalls
        XCTAssertEqual(replaceCalls, 0)
        XCTAssertTrue(files.presentLegacyURLs.isEmpty)
        XCTAssertEqual(try files.readMarker()?.state, .backedUp)
    }

    func testUnknownMarkerFallsBackWithoutChanges() async throws {
        let (files, root) = try makeFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeLegacyFiles(files, session: session())
        let marker = Data(#"{"schemaVersion":7}"#.utf8)
        try marker.write(to: files.markerURL)
        let target = FakeMigrationTarget()

        let outcome = await MioStoreMigrator(files: files, target: target).run()

        XCTAssertEqual(outcome, .useLegacyFiles(message: MioStoreMigrator.markerMessage))
        XCTAssertEqual(try Data(contentsOf: files.markerURL), marker)
        XCTAssertEqual(files.presentLegacyURLs.count, 3)
    }

    func testBackupMoveNeverOverwritesAnExistingBackup() async throws {
        let (files, root) = try makeFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: files.backupDirectory, withIntermediateDirectories: true)
        let older = Data("äldre".utf8)
        try older.write(to: files.backupDirectory.appendingPathComponent("sessions.json"))
        try Data("[]".utf8).write(to: files.sessionsURL)

        try files.moveLegacyFilesToBackup()

        XCTAssertEqual(try Data(contentsOf: files.backupDirectory.appendingPathComponent("sessions.json")), older)
        let names = try FileManager.default.contentsOfDirectory(atPath: files.backupDirectory.path)
        XCTAssertEqual(names.filter { $0.hasPrefix("sessions-") }.count, 1)
    }

    func testCoreHandsStorageTheLastPersistedStateForRowLevelWrites() async throws {
        let storage = RecordingSessionStorage()
        let core = SessionRepositoryCore(storage: storage)
        var live = session(segments: 1)
        live.endedAt = nil
        let token = try core.operationToken(for: live.id, generation: core.operationGeneration())
        try core.saveCaptureCheckpoint(live, token: token)
        live.transcripts.append(TranscriptSegment(createdAt: live.startedAt.addingTimeInterval(30),
                                                  text: "Syntetisk fortsättning", containsMio: false))
        let stored = try core.saveCaptureCheckpoint(live, token: token)

        XCTAssertEqual(storage.previousStates.count, 2)
        XCTAssertEqual(storage.previousStates[0]?.count, 0)
        XCTAssertEqual(storage.previousStates[1]?.first?.transcripts.count, 1)
        XCTAssertEqual(stored.transcripts.count, 2)
        XCTAssertEqual(storage.stored?.first?.mutationRevision, 2)
    }

    func testAssistantCoreReplacesFullyOnlyAfterCacheInvalidation() async throws {
        let storage = RecordingAssistantStorage()
        let core = MioAssistantRepositoryCore(storage: storage)
        let first = MioSuggestion(kind: .note, title: "Syntetisk första")
        try core.addSuggestion(first)
        try core.addSuggestion(MioSuggestion(kind: .note, title: "Syntetisk andra"))
        core.invalidateCache()
        try core.removeSuggestion(id: first.id)

        XCTAssertEqual(storage.previousSuggestionIDs.count, 3)
        XCTAssertEqual(storage.previousSuggestionIDs[0], [])
        XCTAssertEqual(storage.previousSuggestionIDs[1], [first.id])
        XCTAssertEqual(storage.previousSuggestionIDs[2]?.count, 2, "En omläsning ger lagrat tillstånd som jämförelse")
        XCTAssertEqual(storage.stored?.suggestions.count, 1)
    }

    func testDeferredStoresWaitForResolutionAndForward() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioDeferred-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resolved = MioResolvedStores(
            sessions: SessionRepository(storageURL: root.appendingPathComponent("sessions.json")),
            content: MioContentRepository(storageURL: root.appendingPathComponent("content.json")),
            assistant: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json")),
            message: nil)
        let deferred = MioDeferredStores(resolve: { resolved })
        let item = MioContentItem(kind: .note, title: "Syntetisk")
        let saved = try await deferred.content.upsert(item)
        XCTAssertEqual(saved.map(\.id), [item.id])
        let reloaded = try await MioContentRepository(storageURL: root.appendingPathComponent("content.json")).loadItems()
        XCTAssertEqual(reloaded.map(\.id), [item.id])
        let sessions = try await deferred.sessions.loadSessions()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testMetricArchiveDeduplicatesCapsAndKeepsUnknownSchema() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioMetrics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("metrickit-v1.json")
        let archive = MioMetricArchive(storageURL: url)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let payload = Data(#"{"crashDiagnostics":[{"signal":9}]}"#.utf8)
        let report = MioMetricReport(receivedAt: now, periodStart: now.addingTimeInterval(-60), periodEnd: now,
                                     kind: .crash, summary: "1 krasch", payload: payload)
        await archive.add([report], now: now)
        await archive.add([MioMetricReport(receivedAt: now, periodStart: report.periodStart, periodEnd: now,
                                           kind: .crash, summary: "1 krasch", payload: payload)], now: now)
        let oversized = MioMetricReport(receivedAt: now, periodStart: now, periodEnd: now, kind: .metrics, summary: "Stor",
                                        payload: Data(("{\"x\":\"" + String(repeating: "a", count: MioMetricArchive.maxPayloadBytes) + "\"}").utf8))
        XCTAssertNil(oversized.payload)
        await archive.add((0..<(MioMetricArchive.maxReports + 5)).map { index in
            MioMetricReport(receivedAt: now.addingTimeInterval(Double(-index)), periodStart: now.addingTimeInterval(Double(index)),
                            periodEnd: now, kind: .metrics, summary: "Mätvärden", payload: Data("{}".utf8))
        }, now: now)

        let restored = await MioMetricArchive(storageURL: url).reports(now: now)
        XCTAssertEqual(restored.count, MioMetricArchive.maxReports)
        XCTAssertEqual(restored.filter { $0.kind == .crash }.count, 1, "Samma leverans sparas en gång")

        let unknown = Data(#"{"schemaVersion":5,"reports":[]}"#.utf8)
        try unknown.write(to: url)
        let blocked = MioMetricArchive(storageURL: url)
        await blocked.add([report], now: now)
        XCTAssertEqual(try Data(contentsOf: url), unknown)
        let status = await blocked.status
        XCTAssertEqual(status, .unsupportedSchema)
    }

    func testExportCarriesMetricReportsAndOlderExportsStillDecode() throws {
        var diagnostics = MioDiagnosticsExport(
            configuration: .init(cloudEnabled: false, serverConfigured: false, accessConfigured: false),
            journal: .init(events: [], storageStatus: .available))
        diagnostics.metricReports = [MioMetricReport(periodStart: .now, periodEnd: .now, kind: .hang,
                                                     summary: "1 häng", payload: Data("{}".utf8))]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(diagnostics)
        XCTAssertEqual(try decoder.decode(MioDiagnosticsExport.self, from: data).metricReports?.first?.kind, .hang)
        diagnostics.metricReports = nil
        let older = try encoder.encode(diagnostics)
        XCTAssertFalse(String(decoding: older, as: UTF8.self).contains("metricReports"))
        XCTAssertNil(try decoder.decode(MioDiagnosticsExport.self, from: older).metricReports)
    }
}
