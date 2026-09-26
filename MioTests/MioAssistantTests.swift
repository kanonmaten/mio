import Foundation
import XCTest
@testable import Mio

final class MioAssistantTests: XCTestCase {
    func testOnlyExplicitAddressedCommandsProduceSuggestions() throws {
        let sessionID = UUID()
        let cases: [(String, MioContentKind)] = [
            ("Mio, kom ihåg att jag föredrar en blå penna", .memory),
            ("MIO påminn mig att köpa mjölk", .task),
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
