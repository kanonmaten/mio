import Foundation
import XCTest
@testable import Mio

final class MioDeletionRecoveryTests: XCTestCase {
    private func fixture() throws -> (root: URL, file: URL, journal: MioDeletionJournal) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("operations-v1.json")
        return (root, file, MioDeletionJournal(storageURL: file))
    }

    @MainActor
    func testIntentIsDurableBeforeCancellationAndFullDeletionEffects() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var events: [String] = []
        let recovery = MioDeletionRecovery(journal: f.journal, cancelWork: { _ in
            events.append("cancel")
            let intents = try? await f.journal.pendingOperations()
            XCTAssertEqual(intents?.count, 1)
            XCTAssertEqual(intents?.first?.completedSteps, [])
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.file.path))
        }, performStep: { step, operation in
            events.append(step.rawValue)
            let intents = try? await f.journal.pendingOperations()
            XCTAssertEqual(intents?.first?.id, operation.id)
            return .success
        })
        let outcome = await recovery.begin(scope: .all)
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(events, ["cancel", "systemActions", "credentials", "sessions", "content", "assistant", "diagnostics"])
        let pending = try await f.journal.pendingOperations()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertNil(recovery.pendingOperationID)
        XCTAssertNil(recovery.blockedStep)
        XCTAssertNil(recovery.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.file.path))
    }

    @MainActor
    func testBlockedSystemCleanupRetainsIntentAndNeverReachesCredentialsUntilRetry() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var cancelCount = 0
        var firstSteps: [MioDeletionStep] = []
        let first = MioDeletionRecovery(journal: f.journal, cancelWork: { _ in cancelCount += 1 }, performStep: { step, _ in
            firstSteps.append(step)
            return .failure("Tillåt radering av alarm och försök igen.")
        })
        let failed = await first.begin(scope: .all)
        XCTAssertEqual(failed, .failure("Tillåt radering av alarm och försök igen."))
        XCTAssertEqual(firstSteps, [.systemActions])
        XCTAssertEqual(first.blockedStep, .systemActions)
        XCTAssertNotNil(first.pendingOperationID)
        let pending = try await f.journal.pendingOperations()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.completedSteps, [])
        let bytes = try Data(contentsOf: f.file)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("Tillåt"))
        var retried: [MioDeletionStep] = []
        let restarted = MioDeletionRecovery(journal: MioDeletionJournal(storageURL: f.file),
            cancelWork: { _ in cancelCount += 1 }, performStep: { step, _ in retried.append(step); return .success })
        let resumed = await restarted.resumePending()
        XCTAssertEqual(resumed, .success)
        XCTAssertEqual(retried, [.systemActions, .credentials, .sessions, .content, .assistant, .diagnostics])
        XCTAssertEqual(cancelCount, 2)
    }

    @MainActor
    func testRestartResumesOnlyIncompleteSessionStepsWithOpaqueTargetID() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let target = UUID()
        var attempted: [MioDeletionStep] = []
        let first = MioDeletionRecovery(journal: f.journal, cancelWork: { operation in
            XCTAssertEqual(operation.scope, .session)
            XCTAssertEqual(operation.targetID, target)
        }, performStep: { step, operation in
            XCTAssertEqual(operation.targetID, target)
            attempted.append(step)
            return step == .sessions ? .failure("Försök radera sessionen igen.") : .success
        })
        let failed = await first.begin(scope: .session, targetID: target)
        XCTAssertFalse(failed.isSuccess)
        XCTAssertEqual(attempted, [.contentLinks, .assistant, .sessions])
        let pending = try await f.journal.pendingOperations()
        XCTAssertEqual(pending.first?.completedSteps, [.contentLinks, .assistant])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "operations"])
        let operation = try XCTUnwrap((object["operations"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(operation.keys), ["id", "scope", "targetID", "completedSteps"])
        XCTAssertEqual(operation["targetID"] as? String, target.uuidString)
        var resumedSteps: [MioDeletionStep] = []
        let restarted = MioDeletionRecovery(journal: MioDeletionJournal(storageURL: f.file), cancelWork: { _ in},
            performStep: { step, _ in resumedSteps.append(step); return .success })
        let resumed = await restarted.resumePending()
        XCTAssertEqual(resumed, .success)
        XCTAssertEqual(resumedSteps, [.sessions])
    }

    @MainActor
    func testCancelledStepRetainsIntentAndCanBeRetriedWithoutMarkingCompletion() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let target = UUID()
        let recovery = MioDeletionRecovery(journal: f.journal, cancelWork: { _ in}, performStep: { _, _ in .cancelled })
        let outcome = await recovery.begin(scope: .content, targetID: target)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(recovery.blockedStep, .systemActions)
        let pending = try await f.journal.pendingOperations()
        XCTAssertEqual(pending.first?.completedSteps, [])
        let repeated = try await f.journal.begin(scope: .content, targetID: target)
        XCTAssertEqual(repeated.id, pending.first?.id)
        let count = try await f.journal.pendingOperations().count
        XCTAssertEqual(count, 1)
    }

    func testJournalRequiresStepOrderAndCompletionBeforeRemovingIntent() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let operation = try await f.journal.begin(scope: .content, targetID: UUID())
        do { try await f.journal.markCompleted(operationID: operation.id, step: .content); XCTFail("Out-of-order deletion was accepted") }
        catch { XCTAssertTrue(error is MioDeletionJournalError) }
        do { try await f.journal.removeCompleted(operationID: operation.id); XCTFail("Incomplete intent was removed") }
        catch { XCTAssertTrue(error is MioDeletionJournalError) }
        try await f.journal.markCompleted(operationID: operation.id, step: .systemActions)
        try await f.journal.markCompleted(operationID: operation.id, step: .systemActions)
        let pending = try await f.journal.pendingOperations()
        XCTAssertEqual(pending.first?.completedSteps, [.systemActions])
        try await f.journal.markCompleted(operationID: operation.id, step: .content)
        try await f.journal.removeCompleted(operationID: operation.id)
        let empty = try await f.journal.pendingOperations()
        XCTAssertTrue(empty.isEmpty)
    }

    func testInvalidTargetsUnknownSchemaDuplicateIdentitiesAndMalformedStepsPreserveBytes() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        for (scope, target): (MioDeletionScope, UUID?) in [(.all, UUID()), (.session, nil), (.content, nil)] {
            do { _ = try await f.journal.begin(scope: scope, targetID: target); XCTFail("Invalid target accepted") }
            catch { XCTAssertTrue(error is MioDeletionJournalError) }
        }
        let id = UUID().uuidString
        let target = UUID().uuidString
        let valid: [String: Any] = ["id": id, "scope": "content", "targetID": target, "completedSteps": []]
        let invalidDocuments: [[String: Any]] = [
            ["schemaVersion": 2, "operations": []],
            ["schemaVersion": 1, "operations": [valid, valid]],
            ["schemaVersion": 1, "operations": [valid, ["id": UUID().uuidString, "scope": "content", "targetID": target, "completedSteps": []]]],
            ["schemaVersion": 1, "operations": [["id": id, "scope": "content", "targetID": target, "completedSteps": ["content"]]]],
            ["schemaVersion": 1, "operations": [["id": id, "scope": "all", "targetID": target, "completedSteps": []]]],
            ["schemaVersion": 1, "operations": [["id": id, "scope": "content", "targetID": target, "completedSteps": [], "text": "Private data"]]],
            ["schemaVersion": 1, "operations": [valid], "credentials": "Must never be retained"]
        ]
        for document in invalidDocuments {
            let bytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            try bytes.write(to: f.file)
            do { _ = try await f.journal.begin(scope: .all); XCTFail("Malformed journal was overwritten") }
            catch { XCTAssertTrue(error is MioDeletionJournalError) }
            XCTAssertEqual(try Data(contentsOf: f.file), bytes)
        }
    }

    @MainActor
    func testJournalWriteFailureAfterSuccessfulEffectCannotReportCompleteDeletion() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let futureSchema = Data("{\"schemaVersion\":99,\"operations\":[]}".utf8)
        var attempted: [MioDeletionStep] = []
        let recovery = MioDeletionRecovery(journal: f.journal, cancelWork: { _ in}, performStep: { step, _ in
            attempted.append(step)
            try? futureSchema.write(to: f.file)
            return .success
        })
        let outcome = await recovery.begin(scope: .all)
        XCTAssertFalse(outcome.isSuccess)
        XCTAssertEqual(attempted, [.systemActions])
        XCTAssertNotNil(recovery.pendingOperationID)
        XCTAssertEqual(recovery.blockedStep, .systemActions)
        XCTAssertEqual(try Data(contentsOf: f.file), futureSchema)
    }

    @MainActor
    func testSimultaneousAttemptReturnsConflictWithoutDuplicatingSystemEffects() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = DeletionStepGate()
        let entered = expectation(description: "First deletion is suspended in a system action")
        var systemEffects = 0
        let recovery = MioDeletionRecovery(journal: f.journal, cancelWork: { _ in}, performStep: { step, _ in
            if step == .systemActions {
                systemEffects += 1
                entered.fulfill()
                await gate.wait()
            }
            return .success
        })
        let first = Task { await recovery.begin(scope: .all) }
        await fulfillment(of: [entered], timeout: 2)
        let second = await recovery.resumePending()
        if case .conflict = second {} else { XCTFail("Concurrent recovery must be an explicit conflict") }
        XCTAssertEqual(systemEffects, 1)
        gate.release()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .success)
    }

    @MainActor
    func testTaskCancellationRecordsSuccessfulEffectBeforeStoppingLaterSteps() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = DeletionStepGate()
        let entered = expectation(description: "System deletion started")
        var attempted: [MioDeletionStep] = []
        let recovery = MioDeletionRecovery(journal: f.journal, cancelWork: { _ in}, performStep: { step, _ in
            attempted.append(step)
            if step == .systemActions { entered.fulfill(); await gate.wait() }
            return .success
        })
        let operation = Task { await recovery.begin(scope: .all) }
        await fulfillment(of: [entered], timeout: 2)
        operation.cancel()
        gate.release()
        let outcome = await operation.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(attempted, [.systemActions])
        let pending = try await f.journal.pendingOperations()
        XCTAssertEqual(pending.first?.completedSteps, [.systemActions])
    }

    @MainActor
    func testFinalJournalRemovalFailureRetainsCompletedIntentForEffectFreeRetry() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let failingManager = DeletionRemovalFailureFileManager()
        failingManager.blockedURL = f.file
        var attempted: [MioDeletionStep] = []
        let recovery = MioDeletionRecovery(journal: MioDeletionJournal(storageURL: f.file, fileManager: failingManager),
            cancelWork: { _ in}, performStep: { step, _ in attempted.append(step); return .success })
        let outcome = await recovery.begin(scope: .content, targetID: UUID())
        XCTAssertFalse(outcome.isSuccess)
        XCTAssertNotNil(recovery.pendingOperationID)
        let pending = try await f.journal.pendingOperations()
        XCTAssertEqual(pending.first?.completedSteps, [.systemActions, .content])
        XCTAssertEqual(attempted, [.systemActions, .content])
        var cancellationCount = 0
        let restarted = MioDeletionRecovery(journal: f.journal, cancelWork: { _ in cancellationCount += 1 },
            performStep: { _, _ in XCTFail("Completed effects must not repeat when only journal removal failed"); return .success })
        let resumed = await restarted.resumePending()
        XCTAssertEqual(resumed, .success)
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.file.path))
    }
}

@MainActor
private final class DeletionStepGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class DeletionRemovalFailureFileManager: FileManager, @unchecked Sendable {
    var blockedURL: URL?
    override func removeItem(at url: URL) throws {
        if url == blockedURL { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: url)
    }
}
