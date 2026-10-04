import Foundation
import XCTest
@testable import Mio

final class MioAssistantTests: XCTestCase {
    func testPartialSessionDeletionCommitCannotBeRecreatedByLateDetection() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = AssistantPartialDeletionFileManager(target: fixture.file)
        let repository = MioAssistantRepository(fileManager: manager, storageURL: fixture.file)
        let session = MioSession(startedAt: Date(timeIntervalSince1970: 10), endedAt: Date(timeIntervalSince1970: 20),
            transcripts: [TranscriptSegment(text: "Mio, anteckna ett syntetiskt underlag", containsMio: true)])
        let original = try await repository.detectSuggestions(in: session)
        XCTAssertEqual(original, 1)
        manager.failAfterCommit = true
        do { try await repository.deleteSessionData(sessionID: session.id); XCTFail("Filskyddsfelet måste visas") }
        catch { }
        let onDisk = try await MioAssistantRepository(storageURL: fixture.file).loadDocument()
        XCTAssertTrue(onDisk.suggestions.isEmpty, "Borttagningen hann bli varaktig före filskyddsfelet")
        let late = try await repository.detectSuggestions(in: session)
        XCTAssertEqual(late, 0, "Raderingsintentionen måste invalidera sena callbacks även efter delvis genomförd skrivning")
        let final = try await repository.loadDocument()
        XCTAssertTrue(final.suggestions.isEmpty)
    }

    func testPartialFullDeletionKeepsItsCutoffBeforeRemovalError() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = AssistantPartialDeletionFileManager(target: fixture.file)
        let repository = MioAssistantRepository(fileManager: manager, storageURL: fixture.file)
        let session = MioSession(startedAt: Date(timeIntervalSince1970: 10), endedAt: Date(timeIntervalSince1970: 20),
            transcripts: [TranscriptSegment(text: "Mio, anteckna ett gammalt underlag", containsMio: true)])
        let original = try await repository.detectSuggestions(in: session)
        XCTAssertEqual(original, 1)
        manager.failAfterRemoval = true
        do { try await repository.deleteAll(now: Date(timeIntervalSince1970: 30)); XCTFail("Borttagningsfelet måste visas") }
        catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        let late = try await repository.detectSuggestions(in: session)
        XCTAssertEqual(late, 0)
        let final = try await repository.loadDocument()
        XCTAssertTrue(final.suggestions.isEmpty)
    }

    @MainActor
    func testFailedDismissalReconcilesExistingEditedContentWithoutClaimDeadlock() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = AssistantFailingFileManager(); manager.shouldFail = false
        let repository = MioAssistantRepository(fileManager: manager, storageURL: fixture.file)
        let suggestion = MioSuggestion(kind: .note, title: "Godkänt original")
        try await repository.addSuggestion(suggestion)
        let model = MioAssistantViewModel(repository: repository)
        await model.bootstrap()
        let claim = try await model.claimSuggestionApproval(id: suggestion.id, expectedRevision: 0)
        let content = MioContentRepository(storageURL: fixture.root.appendingPathComponent("content.json"))
        _ = try await content.upsert(suggestion.contentItem())
        manager.shouldFail = true
        let incomplete = await model.completeSuggestionApproval(claim)
        guard case .failure = incomplete else { return XCTFail("Misslyckad avföring måste visas") }
        var edited = suggestion.contentItem(); edited.title = "Användarens senare rubrik"; edited.body = "Bevara ändringen"
        _ = try await content.upsert(edited)
        manager.shouldFail = false
        let ordinaryRemoval = await model.markAcceptedOutcome(id: suggestion.id)
        guard case .conflict = ordinaryRemoval else { return XCTFail("Ostyrkt avföring får inte forcera ett aktivt godkännande") }
        let existing = try await content.loadItems()
        XCTAssertTrue(existing.contains { $0.id == suggestion.id })
        let reconciled = await model.markAcceptedOutcome(id: suggestion.id, reconcileExistingContent: true)
        XCTAssertEqual(reconciled, .success)
        XCTAssertTrue(model.suggestions.isEmpty)
        let saved = try await content.loadItems()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.title, "Användarens senare rubrik")
        XCTAssertEqual(saved.first?.body, "Bevara ändringen")
        do { try await repository.completeApproval(claim); XCTFail("Den avförda reservationen ska vara ogiltig") }
        catch let error as MioAssistantRepositoryError { guard case .invalidApproval = error else { return XCTFail("Fel tokenkonflikt") } }
    }

    @MainActor
    func testCommittedApprovalCanCompleteDespiteTaskCancellation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = MioAssistantRepository(storageURL: fixture.file)
        let suggestion = MioSuggestion(kind: .note, title: "Redan sparat")
        try await repository.addSuggestion(suggestion)
        let model = MioAssistantViewModel(repository: repository)
        await model.bootstrap()
        let claim = try await model.claimSuggestionApproval(id: suggestion.id, expectedRevision: 0)
        let completion = Task { await model.completeSuggestionApproval(claim) }
        completion.cancel()
        let outcome = await completion.value
        XCTAssertEqual(outcome, .success)
        XCTAssertTrue(model.suggestions.isEmpty, "Efter ett godkänt innehållscommit får avbryt inte lämna ett låst förslag")
    }

    @MainActor
    func testCancelledContentWorkCanReleaseItsApprovalReservation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = MioAssistantRepository(storageURL: fixture.file)
        let suggestion = MioSuggestion(kind: .note, title: "Behåll vid avbryt")
        try await repository.addSuggestion(suggestion)
        let model = MioAssistantViewModel(repository: repository)
        await model.bootstrap()
        let claim = try await model.claimSuggestionApproval(id: suggestion.id, expectedRevision: 0)
        let cleanup = Task { await model.releaseSuggestionApproval(claim) }
        cleanup.cancel()
        let outcome = await cleanup.value
        XCTAssertEqual(outcome, .success)
        let retry = try await model.claimSuggestionApproval(id: suggestion.id, expectedRevision: 0)
        let completed = await model.completeSuggestionApproval(retry)
        XCTAssertEqual(completed, .success)
        XCTAssertTrue(model.suggestions.isEmpty)
    }

    func testAssistantDeletionInvalidatesActiveApprovalToken() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = MioAssistantRepository(storageURL: fixture.file)
        let sessionID = UUID()
        let suggestion = MioSuggestion(kind: .note, title: "Raderad", sessionID: sessionID)
        try await repository.addSuggestion(suggestion)
        let claim = try await repository.claimSuggestion(id: suggestion.id, expectedRevision: 0)
        try await repository.deleteSessionData(sessionID: sessionID)
        do { try await repository.completeApproval(claim); XCTFail("Raderad sessions godkännande får inte slutföras") }
        catch let error as MioAssistantRepositoryError { guard case .invalidApproval = error else { return XCTFail("Fel tokenkonflikt") } }
        let stored = try await repository.loadDocument()
        XCTAssertTrue(stored.suggestions.isEmpty)
    }

    @MainActor
    func testStoredLessonOutcomeDoesNotDependOnPresentationRefreshSuccess() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = AssistantRefreshFailingFileManager()
        let model = MioAssistantViewModel(repository: MioAssistantRepository(fileManager: manager, storageURL: fixture.file))
        await model.bootstrap()
        let start = Date(timeIntervalSince1970: 2_000)
        let session = MioSession(startedAt: start, endedAt: start.addingTimeInterval(60))
        let id = UUID()
        let outcome = await model.saveLessonOutcome(id: id, session: session, title: "Matematik", note: "", startedAt: start,
                                                   endedAt: start.addingTimeInterval(60))
        XCTAssertEqual(outcome, .success, "Slutregistrering ska följa lagringsresultatet även om senare UI-refresh misslyckas")
        XCTAssertNotNil(model.errorMessage, "Refresh-felet ska fortfarande vara synligt")
        let stored = try await MioAssistantRepository(storageURL: fixture.file).loadDocument()
        XCTAssertEqual(stored.lessons.map(\.id), [id])
    }

    func testApprovalReservationClosesDecisionAndBlocksLateAnalysisReplacement() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = MioAssistantRepository(storageURL: fixture.file)
        let first = TranscriptSegment(text: "Vi ses på biblioteket", containsMio: false)
        let second = TranscriptSegment(text: "på tisdag", containsMio: false)
        let session = MioSession(transcripts: [first, second])
        let a = MioAnalysisFragment.make(from: first)[0], b = MioAnalysisFragment.make(from: second)[0]
        let initial = MioAnalysisRequest(mode: .everyday, timeZone: "Europe/Stockholm", fragments: [a], usesContextContract: true)
        let original = MioAnalysisCandidate(kind: .plan, title: "Bibliotek", body: "", scheduledAt: nil,
            sourceIDs: [a.id], evidence: first.text)
        _ = try await repository.applyAnalysis(MioAnalysisResult(candidates: [original], highlights: [], uncertainties: []),
                                                request: initial, session: session)
        let before = try await repository.loadDocument()
        let suggestion = try XCTUnwrap(before.suggestions.first)
        let claim = try await repository.claimSuggestion(id: suggestion.id, expectedRevision: suggestion.reviewRevision)
        let reserved = try await repository.loadDocument()
        XCTAssertEqual(reserved.analysisDecisions?.first?.isClosed, true)
        let follow = MioAnalysisRequest(mode: .everyday, timeZone: "Europe/Stockholm", fragments: [b],
            contextFragments: [a], priorDecisions: [.init(id: suggestion.id, kind: .plan, sourceIDs: [a.id], isOpen: true)],
            usesContextContract: true)
        let update = MioAnalysisCandidate(kind: .plan, title: "Ändrat bibliotek", body: "Tisdag", scheduledAt: nil,
            sourceIDs: [a.id, b.id], evidence: second.text, replacesID: suggestion.id)
        _ = try await repository.applyAnalysis(MioAnalysisResult(candidates: [update], highlights: [], uncertainties: []),
                                                request: follow, session: session)
        let after = try await repository.loadDocument()
        XCTAssertEqual(after.suggestions.first?.title, "Bibliotek")
        do { try await repository.deferSuggestion(id: suggestion.id); XCTFail("Ett reserverat godkännande får inte skjutas upp") }
        catch let error as MioAssistantRepositoryError { guard case .approvalInProgress = error else { return XCTFail("Fel konflikt") } }
        do { try await repository.removeSuggestion(id: suggestion.id); XCTFail("Ett reserverat godkännande får inte avföras parallellt") }
        catch let error as MioAssistantRepositoryError { guard case .approvalInProgress = error else { return XCTFail("Fel konflikt") } }
        try await repository.completeApproval(claim)
        let completed = try await repository.loadDocument()
        XCTAssertTrue(completed.suggestions.isEmpty)
        XCTAssertEqual(completed.analysisDecisions?.first?.isClosed, true)
    }

    func testAnalysisReplacementVersionsDraftAndOldApprovalConflicts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = MioAssistantRepository(storageURL: fixture.file)
        let first = TranscriptSegment(text: "Bibliotek", containsMio: false)
        let second = TranscriptSegment(text: "Tisdag", containsMio: false)
        let session = MioSession(transcripts: [first, second])
        let a = MioAnalysisFragment.make(from: first)[0], b = MioAnalysisFragment.make(from: second)[0]
        let initial = MioAnalysisRequest(mode: .everyday, timeZone: "Europe/Stockholm", fragments: [a], usesContextContract: true)
        _ = try await repository.applyAnalysis(MioAnalysisResult(candidates: [.init(kind: .plan, title: "Bibliotek", body: "", scheduledAt: nil,
            sourceIDs: [a.id], evidence: first.text)], highlights: [], uncertainties: []), request: initial, session: session)
        let before = try await repository.loadDocument()
        let id = try XCTUnwrap(before.suggestions.first?.id)
        let follow = MioAnalysisRequest(mode: .everyday, timeZone: "Europe/Stockholm", fragments: [b], contextFragments: [a],
            priorDecisions: [.init(id: id, kind: .plan, sourceIDs: [a.id], isOpen: true)], usesContextContract: true)
        _ = try await repository.applyAnalysis(MioAnalysisResult(candidates: [.init(kind: .plan, title: "Bibliotek tisdag", body: "Tisdag", scheduledAt: nil,
            sourceIDs: [a.id, b.id], evidence: second.text, replacesID: id)], highlights: [], uncertainties: []), request: follow, session: session)
        let after = try await repository.loadDocument()
        XCTAssertEqual(after.suggestions.first?.reviewRevision, 1)
        do { _ = try await repository.claimSuggestion(id: id, expectedRevision: 0); XCTFail("Gammalt utkast måste granskas igen") }
        catch let error as MioAssistantRepositoryError { guard case .suggestionChanged = error else { return XCTFail("Fel revisionskonflikt") } }
        XCTAssertEqual(after.analysisDecisions?.first?.isClosed, false)
    }

    func testFailedApprovalCanReleaseAndRetryWithoutRemovingProposal() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = MioAssistantRepository(storageURL: fixture.file)
        let suggestion = MioSuggestion(kind: .note, title: "Bevarat utkast")
        try await repository.addSuggestion(suggestion)
        let first = try await repository.claimSuggestion(id: suggestion.id, expectedRevision: 0)
        try await repository.releaseApproval(first)
        let document = try await repository.loadDocument()
        XCTAssertEqual(document.suggestions.first?.title, suggestion.title)
        let retry = try await repository.claimSuggestion(id: suggestion.id, expectedRevision: 0)
        do { try await repository.completeApproval(first); XCTFail("En frisläppt token får inte avsluta ett nytt godkännande") }
        catch let error as MioAssistantRepositoryError { guard case .invalidApproval = error else { return XCTFail("Fel tokenkonflikt") } }
        try await repository.completeApproval(retry)
        let final = try await repository.loadDocument()
        XCTAssertTrue(final.suggestions.isEmpty)
    }

    func testExternalAssistantReplacementInvalidatesCacheAndUnknownSchemaCannotBeWritten() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = MioAssistantRepository(storageURL: fixture.file)
        let first = MioSuggestion(kind: .note, title: "Första")
        try await repository.addSuggestion(first)
        _ = try await repository.loadDocument()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let external = MioSuggestion(kind: .note, title: "Extern uppdatering")
        try encoder.encode(MioAssistantStoreDocument(suggestions: [external])).write(to: fixture.file, options: .atomic)
        let refreshed = try await repository.loadDocument()
        XCTAssertEqual(refreshed.suggestions.map(\.id), [external.id])
        let unknown = Data(#"{"schemaVersion":99,"privateFixture":"untouched"}"#.utf8)
        try unknown.write(to: fixture.file, options: .atomic)
        do { try await repository.addSuggestion(first); XCTFail("Extern okänd fil får inte ersättas av cache") }
        catch let error as MioAssistantRepositoryError { guard case .unsupportedSchemaVersion(99) = error else { return XCTFail("Fel schemaspärr") } }
        XCTAssertEqual(try Data(contentsOf: fixture.file), unknown)
        try FileManager.default.removeItem(at: fixture.file)
        let removed = try await repository.loadDocument()
        XCTAssertTrue(removed.suggestions.isEmpty)
    }

    @MainActor
    func testLessonSaveOutcomeReportsActualStorageFailureAndRetry() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = AssistantFailingFileManager()
        let model = MioAssistantViewModel(repository: MioAssistantRepository(fileManager: manager, storageURL: fixture.file))
        await model.bootstrap()
        let start = Date(timeIntervalSince1970: 2_000)
        let session = MioSession(startedAt: start, endedAt: start.addingTimeInterval(60))
        let id = UUID()
        let failed = await model.saveLessonOutcome(id: id, session: session, title: "Matematik", note: "", startedAt: start,
                                                  endedAt: start.addingTimeInterval(60))
        guard case .failure = failed else { return XCTFail("Lagringsfel måste vara uttryckliga") }
        XCTAssertTrue(model.lessons.isEmpty)
        manager.shouldFail = false
        let saved = await model.saveLessonOutcome(id: id, session: session, title: "Matematik", note: "", startedAt: start,
                                                 endedAt: start.addingTimeInterval(60))
        XCTAssertEqual(saved, .success)
        XCTAssertEqual(model.lessons.map(\.id), [id])
        XCTAssertGreaterThan(model.stateRevision, 0)
        let revision = model.stateRevision
        await model.bootstrap()
        XCTAssertEqual(model.stateRevision, revision)
    }

    @MainActor
    func testAutomaticLessonSaveIsNotDroppedWhileProposalWriteIsBusy() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = AssistantWriteGate()
        let repository = MioAssistantRepository(fileManager: AssistantHeldFileManager(gate: gate), storageURL: fixture.file)
        let model = MioAssistantViewModel(repository: repository)
        await model.bootstrap()
        let proposal = Task { await model.propose(text: "Lokal anteckning", kind: .note) }
        await gate.waitForEntry()
        XCTAssertTrue(model.isBusy)
        let start = Date(timeIntervalSince1970: 2_000)
        let session = MioSession(startedAt: start, endedAt: start.addingTimeInterval(60))
        var lessonTask: Task<Bool, Never>?
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            lessonTask = Task {
                started.resume()
                return await model.saveLesson(session: session, title: "Matematik", note: "", startedAt: start,
                                              endedAt: start.addingTimeInterval(60))
            }
        }
        gate.release()
        let proposalSaved = await proposal.value
        let lessonSaved = await lessonTask!.value
        XCTAssertTrue(proposalSaved)
        XCTAssertTrue(lessonSaved, "Automatisk lektionslagring får inte försvinna bakom ett annat UI-kommando")
        let stored = try await repository.loadDocument()
        XCTAssertEqual(stored.lessons.map(\.sessionID), [session.id])
    }

    func testSubsecondLessonRemainsReadableAfterLegacyDatePrecisionRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("assistant-v1.json")
        let start = Date(timeIntervalSince1970: 2_000.1), end = Date(timeIntervalSince1970: 2_000.2)
        let session = MioSession(startedAt: start, endedAt: end)
        let lesson = MioLesson(sessionID: session.id, title: "Kort syntetisk lektion", startedAt: start, endedAt: end)
        try await MioAssistantRepository(storageURL: url).saveLesson(lesson, session: session)
        let restored = try await MioAssistantRepository(storageURL: url).loadDocument()
        XCTAssertEqual(restored.lessons.first?.id, lesson.id)
        try await MioAssistantRepository(storageURL: url).deleteLesson(id: lesson.id)
    }

    func testMalformedAssistantIdentitiesAreRejectedWithoutOverwritingFixture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("assistant-v1.json")
        let duplicate = MioSuggestion(kind: .note, title: "synthetic")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(MioAssistantStoreDocument(suggestions: [duplicate, duplicate]))
        try data.write(to: url)
        do { _ = try await MioAssistantRepository(storageURL: url).loadDocument(); XCTFail("Duplicate IDs must be rejected") }
        catch { XCTAssertEqual(try Data(contentsOf: url), data) }
    }

    func testOnlyExplicitAddressedCommandsProduceSuggestions() throws {
        let sessionID = UUID()
        let cases: [(String, MioContentKind)] = [
            ("Mio, kom ihåg att jag föredrar en blå penna", .memory),
            ("MIO påminn mig att köpa mjölk", .task),
            ("Mio. Påminn mig om att lämna boken på fredag", .task),
            ("Mio, påminn mig om läxan", .task),
            ("Mio: planera middag på fredag", .plan),
            ("Mio, anteckna att provet gäller procent", .note)
        ]
        for (text, kind) in cases {
            let segment = TranscriptSegment(text: text, containsMio: true)
            let suggestion = try XCTUnwrap(MioLocalSuggestionEngine.suggestion(from: segment, sessionID: sessionID))
            XCTAssertEqual(suggestion.kind, kind)
            XCTAssertEqual(suggestion.sourceSegmentID, segment.id)
            XCTAssertEqual(suggestion.sessionID, sessionID)
            XCTAssertFalse(suggestion.title.lowercased().hasPrefix("mio"))
        }
        for text in ["Jag borde köpa mjölk", "Jag pratade med Mio", "Mio jag är ledsen", "Mios anteckna något", "Mio kom ihåg att "] {
            let segment = TranscriptSegment(text: text, containsMio: true)
            XCTAssertNil(MioLocalSuggestionEngine.suggestion(from: segment, sessionID: sessionID), text)
        }
    }

    func testCommandsAtSentenceBoundariesProduceSeparateSuggestions() {
        let segment = TranscriptSegment(
            text: "Vi arbetar med procent. Mio, anteckna exemplet. Mio, påminn mig att ta med boken",
            containsMio: true
        )
        let suggestions = MioLocalSuggestionEngine.suggestions(from: segment, sessionID: UUID())
        XCTAssertEqual(suggestions.map(\.kind), [.note, .task])
        XCTAssertEqual(suggestions.map(\.title), ["exemplet", "ta med boken"])
        XCTAssertEqual(Set(suggestions.map(\.id)).count, 2)
        XCTAssertEqual(Set(suggestions.compactMap(\.sourceSegmentID)), [segment.id])
        let ordinary = TranscriptSegment(text: "Jag sa Mio, anteckna detta", containsMio: true)
        XCTAssertTrue(MioLocalSuggestionEngine.suggestions(from: ordinary, sessionID: UUID()).isEmpty)
    }

    func testExplicitSuggestionRequiresTextAndNeverInfersOtherContent() throws {
        XCTAssertThrowsError(try MioLocalSuggestionEngine.explicitSuggestion(text: "  \n ", kind: .note))
        XCTAssertThrowsError(try MioLocalSuggestionEngine.explicitSuggestion(text: "text", kind: .timeline))
        XCTAssertThrowsError(try MioLocalSuggestionEngine.explicitSuggestion(text: String(repeating: "a", count: 10_001), kind: .memory))
        let date = Date(timeIntervalSince1970: 2_000)
        let suggestion = try MioLocalSuggestionEngine.explicitSuggestion(
            text: "  Köp mjölk\nTvå liter  ", kind: .task, scheduledAt: date, now: date
        )
        XCTAssertEqual(suggestion.title, "Köp mjölk")
        XCTAssertEqual(suggestion.body, "Köp mjölk\nTvå liter")
        XCTAssertEqual(suggestion.contentItem(now: date).id, suggestion.id)
        XCTAssertEqual(suggestion.contentItem(now: date.addingTimeInterval(20)).id, suggestion.id)
        XCTAssertEqual(suggestion.scheduledAt, date)
        XCTAssertEqual(suggestion.state, .pending)
    }

    func testLessonBoundariesPreserveOriginalTranscriptionEvidence() throws {
        let date = Date(timeIntervalSince1970: 5_000)
        let segment = TranscriptSegment(
            createdAt: date,
            audioStartedAt: date,
            audioEndedAt: date.addingTimeInterval(10),
            text: "Originaltext",
            correctedText: "Rättad text",
            containsMio: false,
            wasObservedInBackground: true
        )
        let session = MioSession(startedAt: date, endedAt: date.addingTimeInterval(30), transcripts: [segment])
        let lesson = MioLesson(
            sessionID: session.id, title: "Matematik", startedAt: date, endedAt: date.addingTimeInterval(15)
        )
        try MioLocalSuggestionEngine.validateLesson(lesson, session: session, otherLessons: [])
        XCTAssertEqual(lesson.transcripts(in: session), [segment])
        XCTAssertEqual(lesson.transcripts(in: session).first?.text, "Originaltext")
        XCTAssertEqual(lesson.transcripts(in: session).first?.displayText, "Rättad text")
        XCTAssertTrue(lesson.transcripts(in: session).first?.wasObservedInBackground == true)
        XCTAssertEqual(session.transcripts, [segment])
        let adjacent = MioLesson(
            sessionID: session.id, title: "Svenska", startedAt: date.addingTimeInterval(15), endedAt: date.addingTimeInterval(30)
        )
        XCTAssertNoThrow(try MioLocalSuggestionEngine.validateLesson(adjacent, session: session, otherLessons: [lesson]))
        XCTAssertTrue(adjacent.transcripts(in: session).isEmpty)
        var overlapping = adjacent
        overlapping.startedAt = date.addingTimeInterval(14)
        XCTAssertThrowsError(try MioLocalSuggestionEngine.validateLesson(overlapping, session: session, otherLessons: [lesson]))
        var outside = lesson
        outside.startedAt = date.addingTimeInterval(-1)
        XCTAssertThrowsError(try MioLocalSuggestionEngine.validateLesson(outside, session: session, otherLessons: []))
        var active = session
        active.endedAt = nil
        XCTAssertThrowsError(try MioLocalSuggestionEngine.validateLesson(lesson, session: active, otherLessons: []))
    }

    func testBriefingUsesDayBoundariesAndCompletionTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25))!
        let yesterday = today.addingTimeInterval(-86_400)
        let tomorrow = today.addingTimeInterval(86_400)
        let plan = MioContentItem(kind: .plan, title: "Plan", scheduledAt: today)
        let task = MioContentItem(kind: .task, title: "Uppgift", scheduledAt: today)
        let overdue = MioContentItem(kind: .task, title: "Försenad", scheduledAt: yesterday)
        let completed = MioContentItem(kind: .task, title: "Klar idag", scheduledAt: yesterday, completedAt: today)
        let completedYesterday = MioContentItem(kind: .task, title: "Klar igår", scheduledAt: today, completedAt: yesterday)
        let future = MioContentItem(kind: .task, title: "Imorgon", scheduledAt: tomorrow)
        let note = MioContentItem(kind: .note, title: "Anteckning", createdAt: today)
        let session = MioSession(startedAt: today, endedAt: today.addingTimeInterval(60))
        let lesson = MioLesson(sessionID: session.id, title: "Lektion", startedAt: today, endedAt: today.addingTimeInterval(60))
        let briefing = MioBriefing.make(
            content: [plan, task, overdue, completed, completedYesterday, future, note],
            sessions: [session], lessons: [lesson], date: today.addingTimeInterval(3_600), calendar: calendar
        )
        XCTAssertEqual(briefing.plans.map(\.id), [plan.id])
        XCTAssertEqual(briefing.tasks.map(\.id), [task.id])
        XCTAssertEqual(briefing.overdueTasks.map(\.id), [overdue.id])
        XCTAssertEqual(briefing.completedTasks.map(\.id), [completed.id])
        XCTAssertEqual(briefing.notes.map(\.id), [note.id])
        XCTAssertEqual(briefing.sessionCount, 1)
        XCTAssertEqual(briefing.lessonCount, 1)
    }

    func testRejectionAndDeferPersistWithoutKeepingRejectedText() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = MioAssistantRepository(storageURL: fixture.file)
        let session = MioSession(transcripts: [
            TranscriptSegment(text: "Mio, anteckna integritetsexempel-123", containsMio: true),
            TranscriptSegment(text: "Mio, påminn mig att köpa mjölk", containsMio: true)
        ])
        let created = try await repository.detectSuggestions(in: session)
        XCTAssertEqual(created, 2)
        let initial = try await repository.loadDocument()
        let rejected = try XCTUnwrap(initial.suggestions.first { $0.kind == .note })
        let deferred = try XCTUnwrap(initial.suggestions.first { $0.kind == .task })
        try await repository.removeSuggestion(id: rejected.id)
        let date = Date(timeIntervalSince1970: 8_000)
        try await repository.deferSuggestion(id: deferred.id, now: date)
        let reloadedRepository = MioAssistantRepository(storageURL: fixture.file)
        let repeated = try await reloadedRepository.detectSuggestions(in: session)
        XCTAssertEqual(repeated, 0)
        let document = try await reloadedRepository.loadDocument()
        XCTAssertEqual(document.suggestions.count, 1)
        XCTAssertEqual(document.suggestions.first?.state, .deferred)
        XCTAssertEqual(document.suggestions.first?.deferredAt, date)
        XCTAssertEqual(document.processedSources.count, 2)
        let stored = try String(contentsOf: fixture.file, encoding: .utf8)
        XCTAssertFalse(stored.contains("integritetsexempel-123"))
    }

    func testConcurrentDetectionIsIdempotent() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = MioAssistantRepository(storageURL: fixture.file)
        let session = MioSession(transcripts: [TranscriptSegment(text: "Mio, anteckna något", containsMio: true)])
        async let first = repository.detectSuggestions(in: session)
        async let second = repository.detectSuggestions(in: session)
        let counts = try await [first, second]
        XCTAssertEqual(counts.reduce(0, +), 1)
        let document = try await repository.loadDocument()
        XCTAssertEqual(document.suggestions.count, 1)
    }

    func testUnknownSchemaCannotBeOverwritten() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unknown = Data(#"{"schemaVersion":999,"futurePrivateData":"keep"}"#.utf8)
        try unknown.write(to: fixture.file)
        let repository = MioAssistantRepository(storageURL: fixture.file)
        do {
            try await repository.addSuggestion(MioSuggestion(kind: .note, title: "Får inte sparas"))
            XCTFail("An unknown schema must reject mutation")
        } catch MioAssistantRepositoryError.unsupportedSchemaVersion(let version) {
            XCTAssertEqual(version, 999)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.file), unknown)
        do {
            try await repository.deleteSessionData(sessionID: UUID())
            XCTFail("Partial deletion must not overwrite an unknown schema")
        } catch MioAssistantRepositoryError.unsupportedSchemaVersion { }
        XCTAssertEqual(try Data(contentsOf: fixture.file), unknown)
        try await repository.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    func testSessionDeletionRemovesOnlyAssociatedAssistantData() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = MioAssistantRepository(storageURL: fixture.file)
        let date = Date(timeIntervalSince1970: 9_000)
        let session = MioSession(
            startedAt: date, endedAt: date.addingTimeInterval(60),
            transcripts: [TranscriptSegment(text: "Mio, anteckna en lektion", containsMio: true)]
        )
        try await repository.detectSuggestions(in: session)
        let manual = MioSuggestion(kind: .note, title: "Fristående förslag")
        try await repository.addSuggestion(manual)
        let lesson = MioLesson(
            sessionID: session.id, title: "Lektion", startedAt: date, endedAt: date.addingTimeInterval(60), createdAt: date
        )
        try await repository.saveLesson(lesson, session: session)
        let stored = try await repository.loadDocument()
        XCTAssertEqual(stored.lessons, [lesson])
        try await repository.deleteSessionData(sessionID: session.id)
        let document = try await repository.loadDocument()
        XCTAssertEqual(document.suggestions.map(\.id), [manual.id])
        XCTAssertTrue(document.lessons.isEmpty)
        XCTAssertTrue(document.processedSources.isEmpty)
        try await repository.deleteAll()
        let empty = try await repository.loadDocument()
        XCTAssertTrue(empty.suggestions.isEmpty)
    }

    func testLateDetectionCannotRecreateDeletedSessionData() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = MioAssistantRepository(storageURL: fixture.file)
        let date = Date(timeIntervalSince1970: 20_000)
        let session = MioSession(
            startedAt: date, endedAt: date.addingTimeInterval(60),
            transcripts: [TranscriptSegment(text: "Mio, anteckna sen återkoppling", containsMio: true)]
        )
        // The session did not have to occur in the assistant store before deletion.
        try await repository.deleteSessionData(sessionID: session.id)
        let count = try await repository.detectSuggestions(in: session)
        XCTAssertEqual(count, 0)
        let document = try await repository.loadDocument()
        XCTAssertTrue(document.suggestions.isEmpty)
        let lesson = MioLesson(sessionID: session.id, title: "Sen lektion", startedAt: date, endedAt: date.addingTimeInterval(30))
        do {
            try await repository.saveLesson(lesson, session: session)
            XCTFail("A late lesson save must not recreate deleted session metadata")
        } catch MioAssistantValidationError.deletedSession { }
    }

    func testTotalDeletionRejectsUnknownOldSessionAndAllowsNewSession() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = MioAssistantRepository(storageURL: fixture.file)
        let deletionTime = Date(timeIntervalSince1970: 30_000)
        let oldSession = MioSession(
            startedAt: deletionTime.addingTimeInterval(-60),
            transcripts: [TranscriptSegment(text: "Mio, anteckna gammal text", containsMio: true)]
        )
        try await repository.deleteAll(now: deletionTime)
        let lateCount = try await repository.detectSuggestions(in: oldSession)
        XCTAssertEqual(lateCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        let newSession = MioSession(
            startedAt: deletionTime.addingTimeInterval(1),
            transcripts: [TranscriptSegment(text: "Mio, anteckna ny text", containsMio: true)]
        )
        let newCount = try await repository.detectSuggestions(in: newSession)
        XCTAssertEqual(newCount, 1)
        let document = try await repository.loadDocument()
        XCTAssertEqual(document.suggestions.first?.title, "ny text")
    }

    func testOnlyAddressedQuestionsBecomeLocalQuestionSuggestions() throws {
        let questions = [
            "Mio, fråga vad procent betyder",
            "Mio, vad betyder procent?",
            "Mio, hur räknar jag ut tio procent?",
            "Mio, varför använder vi procent?",
            "Mio, när används procent?",
            "Mio, var hittar jag exemplet?",
            "Mio, vem skrev boken?",
            "Mio, kan du förklara procent?"
        ]
        let sessionID = UUID()
        for text in questions {
            let segment = TranscriptSegment(text: text, containsMio: true)
            let suggestion = try XCTUnwrap(MioLocalSuggestionEngine.suggestion(from: segment, sessionID: sessionID))
            XCTAssertEqual(suggestion.purpose, .question, text)
            XCTAssertEqual(suggestion.state, .pending)
            XCTAssertNotNil(suggestion.questionText)
            XCTAssertEqual(suggestion.sourceSegmentID, segment.id)
            XCTAssertEqual(suggestion.sessionID, sessionID)
            XCTAssertEqual(segment.text, text)
        }
        let explicit = try MioLocalSuggestionEngine.explicitQuestion(text: "  Hur fungerar procent?  ")
        XCTAssertEqual(explicit.questionText, "Hur fungerar procent?")
        XCTAssertNil(try MioLocalSuggestionEngine.explicitSuggestion(text: "En anteckning", kind: .note).questionText)
        XCTAssertThrowsError(try MioLocalSuggestionEngine.explicitQuestion(text: "   "))
        for text in ["Vad betyder procent?", "Jag undrar vad Mio tycker", "Mio tycker om matematik", "Mio, fråga "] {
            let segment = TranscriptSegment(text: text, containsMio: true)
            XCTAssertTrue(MioLocalSuggestionEngine.suggestions(from: segment, sessionID: sessionID).isEmpty, text)
        }
        XCTAssertEqual(Set(MioContentKind.allCases.map(\.rawValue)), ["timeline", "note", "task", "plan", "memory"])
    }

    func testOlderSuggestionDecodesAsContentAndQuestionRetainsFullText() throws {
        let oldSuggestion = MioSuggestion(kind: .task, title: "Ta med boken")
        let encoded = try JSONEncoder().encode(oldSuggestion)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "purpose")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(MioSuggestion.self, from: legacyData)
        XCTAssertEqual(decoded.purpose, .content)
        XCTAssertEqual(decoded.id, oldSuggestion.id)
        XCTAssertEqual(decoded.title, oldSuggestion.title)
        XCTAssertNil(decoded.revision)
        XCTAssertEqual(decoded.reviewRevision, 0)
        let fullQuestion = "Hur fungerar " + String(repeating: "procent och andelar ", count: 12)
        let question = try MioLocalSuggestionEngine.explicitQuestion(text: fullQuestion)
        XCTAssertEqual(question.title.count, 120)
        XCTAssertEqual(question.questionText, fullQuestion.trimmingCharacters(in: .whitespacesAndNewlines))
        let reloaded = try JSONDecoder().decode(MioSuggestion.self, from: JSONEncoder().encode(question))
        XCTAssertEqual(reloaded, question)
    }

    func testQuestionDeferRejectAndDedupStayLocal() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = MioAssistantRepository(storageURL: fixture.file)
        let segment = TranscriptSegment(text: "Mio, vad betyder frågeexempel-456?", containsMio: true)
        let session = MioSession(transcripts: [segment])
        let count = try await repository.detectSuggestions(in: session)
        XCTAssertEqual(count, 1)
        let initial = try await repository.loadDocument()
        let question = try XCTUnwrap(initial.suggestions.first)
        XCTAssertEqual(question.purpose, .question)
        try await repository.deferSuggestion(id: question.id)
        let deferred = try await repository.loadDocument()
        XCTAssertEqual(deferred.suggestions.first?.state, .deferred)
        XCTAssertEqual(deferred.suggestions.first?.purpose, .question)
        try await repository.removeSuggestion(id: question.id)
        let newRepository = MioAssistantRepository(storageURL: fixture.file)
        let repeated = try await newRepository.detectSuggestions(in: session)
        XCTAssertEqual(repeated, 0)
        let final = try await newRepository.loadDocument()
        XCTAssertTrue(final.suggestions.isEmpty)
        XCTAssertEqual(final.processedSources.count, 1)
        let stored = try String(contentsOf: fixture.file, encoding: .utf8)
        XCTAssertFalse(stored.contains("frågeexempel-456"))
        XCTAssertEqual(session.transcripts, [segment])
    }

    private func makeFixture() throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Mio-assistant-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, root.appendingPathComponent("assistant-v1.json"))
    }
}

/// Holds actual repository I/O so the second command runs during the first suspension.
private final class AssistantWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let resumed = DispatchSemaphore(value: 0)
    private var shouldHold = true

    func holdOnce() {
        lock.lock()
        let hold = shouldHold
        shouldHold = false
        lock.unlock()
        guard hold else { return }
        entered.signal()
        resumed.wait()
    }

    func waitForEntry() async { await Task.detached { self.entered.wait() }.value }
    func release() { resumed.signal() }
}

private final class AssistantHeldFileManager: FileManager, @unchecked Sendable {
    private let gate: AssistantWriteGate
    init(gate: AssistantWriteGate) { self.gate = gate; super.init() }
    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        gate.holdOnce()
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}

private final class AssistantFailingFileManager: FileManager, @unchecked Sendable {
    var shouldFail = true
    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        if shouldFail { throw CocoaError(.fileWriteNoPermission) }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}

private final class AssistantRefreshFailingFileManager: FileManager, @unchecked Sendable {
    private var stampReads = 0
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        stampReads += 1
        if stampReads == 2 { throw CocoaError(.fileReadNoPermission) }
        return try super.attributesOfItem(atPath: path)
    }
}

private final class AssistantPartialDeletionFileManager: FileManager, @unchecked Sendable {
    private let target: URL
    var failAfterCommit = false
    var failAfterRemoval = false
    init(target: URL) { self.target = target; super.init() }
    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if failAfterCommit, path == target.path {
            failAfterCommit = false
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
    override func removeItem(at url: URL) throws {
        try super.removeItem(at: url)
        if failAfterRemoval, url == target {
            failAfterRemoval = false
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}
