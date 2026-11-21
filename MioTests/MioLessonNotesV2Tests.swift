import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Mio

/// Lesson notes version 2 (fas 3): exam hints, speaker roles, subject, the review sheet's data
/// and the time to finished notes. Contract: docs/DATAMODELL.md, "Lektionsanteckningar version 2".
final class MioLessonNotesV2Tests: XCTestCase {
    private let revision = String(repeating: "a", count: 64)
    private var metadata: MioAnalysisMetadata {
        MioAnalysisMetadata(provider: "mistral", model: "mistral-large-4-0", promptVersion: "lesson-v2-test", lessonIntervalSeconds: 60)
    }

    private func segment(_ text: String, speaker: Int?) -> TranscriptSegment {
        var segment = TranscriptSegment(text: text, containsMio: false)
        segment.speaker = speaker
        return segment
    }

    private func lesson(_ segments: [TranscriptSegment]) -> MioSession {
        MioSession(endedAt: .now, transcripts: segments, title: "Biologi", captureMode: .lesson)
    }

    func testTheSpeakerWithMostCharactersIsTheTeacherAndOthersAreNumberedStudents() {
        var session = lesson([segment("Kort fråga?", speaker: 2), segment("Celler delar sig genom mitos, och det kommer på provet.", speaker: 1),
                              segment("Okej.", speaker: 3), segment("Jag har en till fråga om meios.", speaker: 2)])
        XCTAssertEqual(MioSpeakerRoles.roles(in: session), [1: .teacher, 2: .student, 3: .student])
        XCTAssertEqual(session.speakerName(for: 1), "Lärare")
        XCTAssertEqual(session.speakerName(for: 2), "Elev 1")
        XCTAssertEqual(session.speakerName(for: 3), "Elev 2")
        // Her own name wins, and the role does not follow names.
        session.speakerNames = [1: "Anna"]
        XCTAssertEqual(session.speakerName(for: 1), "Anna")
        XCTAssertEqual(MioSpeakerRoles.roles(in: session)[1], .teacher)
        // A correction is a display layer: the original text decides who talked most.
        session.transcripts[0].correctedText = String(repeating: "lång rättning ", count: 20)
        XCTAssertEqual(MioSpeakerRoles.roles(in: session)[1], .teacher)
        // Renaming to the default label removes the custom name.
        XCTAssertNil(MioSpeakerLabel.renamed([2: "Bo"], speaker: 2, to: "Elev 1", defaultName: session.defaultSpeakerName(for: 2)))
        // Everyday sessions keep neutral labels; a tie goes to the lower number.
        let everyday = MioSession(transcripts: [segment("Hej", speaker: 1), segment("Hej", speaker: 2)])
        XCTAssertEqual(everyday.speakerName(for: 1), "Talare 1")
        XCTAssertEqual(MioSpeakerRoles.roles(in: lesson([segment("Hej", speaker: 2), segment("Hej", speaker: 1)])), [1: .teacher, 2: .student])
    }

    func testRolesGoOnlyToLessonNotesV2AndNeverAnyName() throws {
        var session = lesson([segment("Det här kommer på provet: fotosyntes.", speaker: 1), segment("Vad är klorofyll?", speaker: 2),
                              segment("Utan talare.", speaker: nil)])
        session.speakerNames = [1: "Anna Lärarsson"]
        let fragments = MioAnalysisFragment.lessonFragments(in: session)
        XCTAssertEqual(fragments.map(\.speakerRole), [.teacher, .student, nil])
        // Identities and text are exactly those of v1 (the repository compares them).
        XCTAssertEqual(fragments.map(\.id), session.transcripts.flatMap(MioAnalysisFragment.make).map(\.id))
        XCTAssertEqual(fragments.map(\.text), session.transcripts.flatMap(MioAnalysisFragment.make).map(\.text))
        var request = MioAnalysisRequest(mode: .lesson, timeZone: "Europe/Stockholm", fragments: fragments)
        let v1 = try XCTUnwrap(JSONSerialization.jsonObject(with: request.validatedData()) as? [String: Any])
        let v1Fragments = try XCTUnwrap(v1["fragments"] as? [[String: Any]])
        XCTAssertTrue(v1Fragments.allSatisfy { Set($0.keys) == ["id", "text", "occurredAt"] })
        request.usesLessonNotesV2 = true
        let data = try request.validatedData()
        let v2 = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let v2Fragments = try XCTUnwrap(v2["fragments"] as? [[String: Any]])
        XCTAssertEqual(v2Fragments.map { $0["speakerRole"] as? String }, ["teacher", "student", nil])
        XCTAssertEqual(Set(v2.keys), ["mode", "timeZone", "fragments"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Anna"))
        // v2 is for lessons only.
        var everyday = MioAnalysisRequest(mode: .everyday, timeZone: "Europe/Stockholm", fragments: fragments)
        everyday.usesLessonNotesV2 = true
        XCTAssertThrowsError(try everyday.validatedData())
    }

    private func v2Reply(hints: [[String: Any]], subject: Any = "Biologi", fragment: MioAnalysisFragment) -> [String: Any] {
        ["examHints": hints, "subject": subject, "candidates": [],
         "sections": [["heading": "Fotosyntes", "body": "Växter gör socker av ljus.", "sourceIDs": [fragment.id], "evidence": fragment.text]],
         "uncertainties": [],
         "metadata": ["provider": metadata.provider, "model": metadata.model, "promptVersion": metadata.promptVersion,
                      "lessonIntervalSeconds": 60]]
    }

    func testV2WireRequiresExamHintsAndSubjectAndRejectsUnknownFields() throws {
        let session = lesson([segment("Det här kommer på provet: fotosyntes.", speaker: 1)])
        let fragment = try XCTUnwrap(MioAnalysisFragment.lessonFragments(in: session).first)
        let hint: [String: Any] = ["text": "Fotosyntes kommer på provet", "sourceIDs": [fragment.id], "evidence": "kommer på provet"]
        let valid = v2Reply(hints: [hint], fragment: fragment)
        XCTAssertNoThrow(try MioCloudService.validateWire(JSONSerialization.data(withJSONObject: valid), lesson: true, lessonV2: true))
        XCTAssertNoThrow(try MioCloudService.validateWire(JSONSerialization.data(withJSONObject: v2Reply(hints: [], subject: NSNull(), fragment: fragment)),
                                                          lesson: true, lessonV2: true))
        // A v2 answer is not a v1 answer and the other way round.
        XCTAssertThrowsError(try MioCloudService.validateWire(JSONSerialization.data(withJSONObject: valid), lesson: true))
        var missing = valid; missing["subject"] = nil
        XCTAssertThrowsError(try MioCloudService.validateWire(JSONSerialization.data(withJSONObject: missing), lesson: true, lessonV2: true))
        var extra = hint; extra["page"] = 3
        XCTAssertThrowsError(try MioCloudService.validateWire(JSONSerialization.data(withJSONObject: v2Reply(hints: [extra], fragment: fragment)),
                                                              lesson: true, lessonV2: true))
        XCTAssertThrowsError(try MioCloudService.validateWire(JSONSerialization.data(withJSONObject: v2Reply(hints: [], subject: 3, fragment: fragment)),
                                                              lesson: true, lessonV2: true))
    }

    func testV2RouteDropsInvalidExamHintsAndSubjectButKeepsTheRest() async throws {
        let session = lesson([segment("Kom ihåg att mitokondrien är cellens kraftverk.", speaker: 1)])
        let fragment = try XCTUnwrap(MioAnalysisFragment.lessonFragments(in: session).first)
        var request = MioAnalysisRequest(mode: .lesson, timeZone: "Europe/Stockholm", fragments: [fragment])
        request.usesLessonNotesV2 = true
        let good: [String: Any] = ["text": "Mitokondrien är cellens kraftverk", "sourceIDs": [fragment.id], "evidence": "mitokondrien är cellens kraftverk"]
        let invented: [String: Any] = ["text": "Påhittat", "sourceIDs": [fragment.id], "evidence": "står inte i texten"]
        let unknownSource: [String: Any] = ["text": "Fel källa", "sourceIDs": ["\(UUID().uuidString):0"], "evidence": "Kom ihåg"]
        let transport = LessonTransport(reply: try JSONSerialization.data(withJSONObject:
            v2Reply(hints: [good, invented, unknownSource], subject: String(repeating: "x", count: 41), fragment: fragment)))
        let connection = MioCloudConnection(endpoint: URL(string: "https://mio.example.ts.net/v1/ask")!, token: "synthetic",
                                            observedConfigurationRevision: revision)
        let result = try await MioCloudService.analyze(request, connection: connection, transport: { try await transport.send($0) })
        XCTAssertEqual(result.examHints?.map { $0.text }, ["Mitokondrien är cellens kraftverk"])
        XCTAssertEqual(result.uncertainties, [MioAnalysisResult.droppedExamHintsNotice(2)], "the note shows that hints fell away")
        XCTAssertNil(result.subjectSuggestion)
        XCTAssertEqual(result.sections?.count, 1)
        XCTAssertNoThrow(try result.validate(against: request))
        let sent = await transport.requests()
        XCTAssertEqual(sent.compactMap { $0.url?.path }, ["/v2/lesson-notes"])

        // Nine hints break the schema's maximum of eight: the whole answer is invalid.
        let nine = Array(repeating: good, count: 9)
        let tooMany = LessonTransport(reply: try JSONSerialization.data(withJSONObject: v2Reply(hints: nine, fragment: fragment)))
        do {
            _ = try await MioCloudService.analyze(request, connection: connection, transport: { try await tooMany.send($0) })
            XCTFail("More than eight exam hints must be rejected")
        } catch MioCloudError.invalidResponse {} catch { XCTFail("Unexpected error \(error)") }

        // Without the flag the old route and the old answer shape are used.
        request.usesLessonNotesV2 = false
        var v1 = v2Reply(hints: [], fragment: fragment); v1["examHints"] = nil; v1["subject"] = nil
        let old = LessonTransport(reply: try JSONSerialization.data(withJSONObject: v1))
        let oldResult = try await MioCloudService.analyze(request, connection: connection, transport: { try await old.send($0) })
        XCTAssertNil(oldResult.examHints)
        let oldSent = await old.requests()
        XCTAssertEqual(oldSent.compactMap { $0.url?.path }, ["/v1/lesson-notes"])
        XCTAssertEqual(MioCloudService.lessonNotesTimeout, 200)
    }

    func testExamHintsComeFirstInTheNoteAndCopyInSourceOrderWithoutDuplicates() throws {
        var session = lesson([segment("Första delen: kom ihåg formeln.", speaker: 1), segment("Andra delen: viktigt med enheter.", speaker: 1)])
        session.subject = "Fysik"
        let fragments = MioAnalysisFragment.lessonFragments(in: session)
        func record(_ index: Int, hints: [String], subject: String?) -> MioAnalysisRecord {
            MioAnalysisRecord(id: UUID(), sessionID: session.id, fragmentIDs: [fragments[index].id], highlights: [], uncertainties: [],
                              createdAt: .now, sections: [MioLessonSection(heading: "Del \(index + 1)", body: fragments[index].text,
                                                                           sourceIDs: [fragments[index].id], evidence: fragments[index].text)],
                              metadata: metadata,
                              examHints: hints.map { MioLessonHighlight(text: $0, sourceIDs: [fragments[index].id], evidence: fragments[index].text) },
                              subjectSuggestion: subject)
        }
        let document = MioLessonDocument(session: session, records: [record(1, hints: ["Enheter", "Formeln"], subject: "Fysik"),
                                                                    record(0, hints: ["Formeln"], subject: "Matematik")])
        XCTAssertEqual(document.examHints.map(\.text), ["Formeln", "Enheter"])
        let markdown = document.markdown
        let hints = try XCTUnwrap(markdown.range(of: "## Viktigt till provet"))
        let firstSection = try XCTUnwrap(markdown.range(of: "## Del 1"))
        XCTAssertLessThan(hints.lowerBound, firstSection.lowerBound)
        XCTAssertTrue(markdown.contains("Ämne: Fysik"))
        XCTAssertTrue(markdown.contains("Citat: ”\(fragments[0].text)”"))
        XCTAssertEqual(markdown.components(separatedBy: "- Formeln").count, 2, "an exact duplicate is listed once")
        // Most parts' subject wins; on a tie the earliest part's.
        XCTAssertEqual(document.subjectSuggestion, "Matematik")
        // Older records without the fields decode and show no section.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record(0, hints: [], subject: nil))) as! [String: Any]
        legacy["examHints"] = nil; legacy["subjectSuggestion"] = nil
        let decoded = try JSONDecoder().decode(MioAnalysisRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.examHints)
        XCTAssertFalse(MioLessonDocument(session: session, records: [decoded]).markdown.contains("Viktigt till provet"))
        // An unprocessed marker carries no exam hints.
        var marker = record(0, hints: ["x"], subject: nil); marker.isUnprocessed = true; marker.sections = []
        XCTAssertFalse(marker.unprocessedShapeIsValid)
    }

    func testLessonTaskNoLongerRequiresReasoningOffButAskAndEverydayDo() throws {
        XCTAssertFalse(MioAITaskID.lesson.requiredCapabilities.contains("reasoning-off"))
        XCTAssertTrue(MioAITaskID.ask.requiredCapabilities.contains("reasoning-off"))
        XCTAssertTrue(MioAITaskID.everyday.requiredCapabilities.contains("reasoning-off"))
        func task(_ capabilities: [String], reasoning: String) -> [String: Any] {
            ["configured": true, "provider": "mistral", "model": "mistral-large-4-0", "promptVersion": "v2", "capabilities": capabilities,
             "configurationError": NSNull(), "reasoning": reasoning, "schemaDialect": "json-schema"]
        }
        let base = ["reasoning-off", "temperature-zero", "strict-json"]
        var root: [String: Any] = ["protocolVersion": 2, "release": "wave-3", "configurationRevision": revision,
            "tasks": ["ask": task(base + ["ask-v1"], reasoning: "off"), "everyday": task(base + ["analysis-context-v2"], reasoning: "off"),
                      "lesson": task(["temperature-zero", "strict-json", "lesson-notes-v1", "lesson-notes-v2"], reasoning: "medium")],
            "quota": NSNull(),
            "usage": ["month": "2026-11", "currency": "USD", "estimatedCost": 3.42, "entries": []]]
        let status = try MioGatewayStatusV2.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertEqual(status.tasks.lesson.reasoning, "medium")
        XCTAssertTrue(status.tasks.lesson.reasons)
        XCTAssertEqual(status.tasks.everyday.schemaDialect, "json-schema")
        for id in MioAITaskID.allCases { XCTAssertNoThrow(try status.requireTask(id)) }
        // A reasoning everyday pair is refused, like the gateway refuses to start with one.
        var tasks = root["tasks"] as! [String: Any]
        tasks["everyday"] = task(base + ["analysis-context-v2"], reasoning: "low")
        root["tasks"] = tasks
        let reasoningEveryday = try MioGatewayStatusV2.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertThrowsError(try reasoningEveryday.requireTask(.everyday))
        // Other unknown keys are still refused.
        root["surprise"] = true
        XCTAssertThrowsError(try MioGatewayStatusV2.decode(JSONSerialization.data(withJSONObject: root)))
    }

    @MainActor
    func testCoordinatorUsesV2OnlyWhenTheGatewayOffersItAndReportsFinishedNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json")))
        var sessions: [Bool: MioSession] = [:]
        for offersV2 in [true, false] {
            let session = lesson([segment("Det här kommer på provet: cellens delar.", speaker: 1)])
            sessions[offersV2] = session
            let fragment = try XCTUnwrap(MioAnalysisFragment.lessonFragments(in: session).first)
            let sent = expectation(description: "part sent")
            let finished = expectation(description: "notes complete")
            let connection = MioCloudConnection(endpoint: URL(string: "https://example.invalid/v1/ask")!, token: "synthetic")
            let metadata = metadata
            let coordinator = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true },
                prepareConnection: { connection, task in
                    let prepared = try await syntheticPreparedConnection(connection, task: task)
                    return offersV2 ? Self.addingV2(to: prepared) : prepared
                }, send: { request, _ in
                    XCTAssertEqual(request.usesLessonNotesV2, offersV2)
                    XCTAssertEqual(request.fragments.first?.speakerRole, .teacher)
                    sent.fulfill()
                    let hints = offersV2 ? [MioLessonHighlight(text: "Cellens delar", sourceIDs: [fragment.id], evidence: "kommer på provet")] : nil
                    return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [],
                        sections: [MioLessonSection(heading: "Cellen", body: "Delar.", sourceIDs: [fragment.id], evidence: fragment.text)],
                        metadata: metadata, examHints: hints, subjectSuggestion: offersV2 ? "Biologi" : nil)
                }, wait: { _ in })
            coordinator.onLessonNotesComplete = { finishedSession in
                XCTAssertEqual(finishedSession.id, session.id)
                finished.fulfill()
            }
            try await coordinator.enable(existingSessions: [session])
            coordinator.summarizeLesson(session, assistant: assistant)
            await fulfillment(of: [sent, finished], timeout: 2)
            coordinator.disable()
        }
        let v2 = try XCTUnwrap(assistant.analyses.first { $0.sessionID == sessions[true]?.id })
        XCTAssertEqual(v2.examHints?.map(\.text), ["Cellens delar"])
        XCTAssertEqual(v2.subjectSuggestion, "Biologi")
        let v1 = try XCTUnwrap(assistant.analyses.first { $0.sessionID == sessions[false]?.id })
        XCTAssertNil(v1.examHints)
    }

    static func addingV2(to prepared: MioPreparedConnection) -> MioPreparedConnection {
        let status = prepared.status
        let lesson = status.tasks.lesson
        let upgraded = MioGatewayTaskStatus(configured: lesson.configured, provider: lesson.provider, model: lesson.model,
                                            promptVersion: lesson.promptVersion, capabilities: lesson.capabilities + ["lesson-notes-v2"],
                                            configurationError: nil, reasoning: "medium")
        return .init(connection: prepared.connection,
                     status: MioGatewayStatusV2(protocolVersion: status.protocolVersion, release: status.release,
                                                configurationRevision: status.configurationRevision,
                                                tasks: .init(ask: status.tasks.ask, everyday: status.tasks.everyday, lesson: upgraded),
                                                quota: status.quota))
    }

    @MainActor
    func testFinishedNotesAreMeasuredOnceWithoutTextAndOpenTheReviewSheet() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MioLessonNotesV2Tests-\(UUID())"))
        let ended = Date(timeIntervalSince1970: 1_800_000_000)
        let id = UUID()
        let first = MioLessonNotesLatencyLog.record(sessionID: id, endedAt: ended, completedAt: ended.addingTimeInterval(250), in: defaults)
        XCTAssertEqual(first?.seconds, 250)
        XCTAssertNil(MioLessonNotesLatencyLog.record(sessionID: id, endedAt: ended, completedAt: ended.addingTimeInterval(900), in: defaults))
        XCTAssertNil(MioLessonNotesLatencyLog.record(sessionID: UUID(), endedAt: ended, completedAt: ended.addingTimeInterval(-5), in: defaults))
        MioLessonNotesLatencyLog.record(sessionID: UUID(), endedAt: ended, completedAt: ended.addingTimeInterval(410), in: defaults)
        let log = MioLessonNotesLatencyLog.load(from: defaults)
        XCTAssertEqual(log.entries.count, 2)
        XCTAssertEqual(log.medianSeconds, 330)
        XCTAssertEqual(log.withinGoal, 1)
        XCTAssertEqual(MioLessonNotesLatencyLog.duration(250), "4 min 10 s")
        let stored = try XCTUnwrap(defaults.data(forKey: MioLessonNotesLatencyLog.key))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["entries"])
        MioLessonNotesLatencyLog.reset(in: defaults)
        XCTAssertTrue(MioLessonNotesLatencyLog.load(from: defaults).entries.isEmpty)
    }

    func testLessonReviewRouteCarriesOnlyAnOpaqueIdentity() {
        let id = UUID()
        let route = MioNotificationRoute.lessonReview(id)
        XCTAssertEqual(route.userInfo, ["mioRoute": "lessonReview", "mioSessionID": id.uuidString])
        XCTAssertEqual(MioNotificationRoute(userInfo: route.userInfo), route)
        XCTAssertNil(MioNotificationRoute(userInfo: ["mioRoute": "lessonReview", "mioSessionID": id.uuidString, "title": "Biologi"]))
        XCTAssertNil(MioNotificationRoute(userInfo: ["mioRoute": "lessonReview", "mioSessionID": "nej"]))
        XCTAssertEqual(route.notificationBody, "Anteckningarna från lektionen är klara.")
    }

    @MainActor
    func testReviewRouteOpensTheSheetOnLessonsOrFallsBackToHem() {
        let navigation = MioNavigationCoordinator()
        let id = UUID()
        navigation.receive(.lessonReview(id))
        navigation.resolvePending(using: { _ in nil }, lessonExists: { $0 == id })
        XCTAssertEqual(navigation.selectedTab, .lessons)
        XCTAssertEqual(navigation.presentedLessonReview?.id, id)
        navigation.receive(.lessonReview(UUID()))
        navigation.resolvePending(using: { _ in nil }, lessonExists: { $0 == id })
        XCTAssertEqual(navigation.selectedTab, .home)
        XCTAssertNil(navigation.presentedLessonReview)
    }

    func testReviewContentListsTheLessonsProposalsAndSubject() {
        var session = lesson([segment("Läxa till fredag: läs kapitel 3.", speaker: 1)])
        let withDate = MioSuggestion(kind: .task, title: "Läs kapitel 3", createdAt: Date(timeIntervalSince1970: 2), sessionID: session.id,
                                     evidence: "läs kapitel 3", needsDateConfirmation: false)
        let withoutDate = MioSuggestion(kind: .plan, title: "Prov", createdAt: Date(timeIntervalSince1970: 1), sessionID: session.id,
                                        evidence: "prov", needsDateConfirmation: true)
        let other = MioSuggestion(kind: .task, title: "Annat", sessionID: UUID())
        var question = MioSuggestion(kind: .note, title: "Fråga", sessionID: session.id); question.purpose = .question
        var content = MioLessonReviewContent(session: session, suggestions: [withDate, other, withoutDate, question], records: [])
        XCTAssertEqual(content.suggestions.map(\.title), ["Prov", "Läs kapitel 3"])
        XCTAssertTrue(MioLessonReviewContent.hasPrefilledDate(withDate))
        XCTAssertFalse(MioLessonReviewContent.hasPrefilledDate(withoutDate))
        XCTAssertEqual(content.initialSubject, "")
        session.subject = "Svenska"
        content = MioLessonReviewContent(session: session, suggestions: [], records: [])
        XCTAssertEqual(content.initialSubject, "Svenska")
        XCTAssertEqual(MioLessonSubject.clean("  Biologi \n"), "Biologi")
        XCTAssertNil(MioLessonSubject.clean(String(repeating: "x", count: 41)))
        XCTAssertNil(MioLessonSubject.clean("   "))
    }

    func testSubjectIsSavedOnTheEndedLessonOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioSubject-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SessionRepository(storageURL: root.appendingPathComponent("sessions.json"))
        var session = MioSession(transcripts: [segment("Hej", speaker: 1)], captureMode: .lesson)
        let token = try await repository.operationToken(for: session.id, generation: await repository.operationGeneration())
        try await repository.saveCaptureCheckpoint(session, token: token)
        do { _ = try await repository.setSubject(sessionID: session.id, subject: "Biologi", token: token); XCTFail("Live lessons keep no subject") }
        catch { }
        session.endedAt = .now
        try await repository.saveCaptureCheckpoint(session, token: token)
        let saved = try await repository.setSubject(sessionID: session.id, subject: " Biologi ", token: token)
        XCTAssertEqual(saved.subject, "Biologi")
        XCTAssertEqual(saved.transcripts, session.transcripts)
        let cleared = try await repository.setSubject(sessionID: session.id, subject: "", token: token)
        XCTAssertNil(cleared.subject)
        // Older sessions decode without the field.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        legacy["subject"] = nil
        XCTAssertNil(try JSONDecoder().decode(MioSession.self, from: JSONSerialization.data(withJSONObject: legacy)).subject)
    }

    func testExamHintsKeepLongExactQuotesUpToTheGatewayLimitAndCountWhatIsDropped() throws {
        // A long teacher passage: the gateway passes exact quotes up to 2 400 bytes.
        let long = String(repeating: "Kom ihåg att cellen delar sig. ", count: 100)
        let session = lesson([segment(long, speaker: 1)])
        let fragment = try XCTUnwrap(MioAnalysisFragment.lessonFragments(in: session).first)
        var request = MioAnalysisRequest(mode: .lesson, timeZone: "Europe/Stockholm", fragments: [fragment])
        request.usesLessonNotesV2 = true
        func quote(bytes: Int) -> String {
            var text = ""
            for character in fragment.text {
                guard text.utf8.count + String(character).utf8.count <= bytes else { break }
                text.append(character)
            }
            return text
        }
        let seven = quote(bytes: 700), limit = quote(bytes: 2_400)
        XCTAssertGreaterThan(seven.utf8.count, 600)
        XCTAssertTrue(fragment.text.contains(limit))
        let overLimit = quote(bytes: 2_500)
        XCTAssertEqual(MioAnalysisFragment.lessonFragments(in: session).count, 1, "one fragment holds the whole passage")
        XCTAssertGreaterThan(overLimit.utf8.count, 2_400)
        let section = MioLessonSection(heading: "Cellen", body: "Delning.", sourceIDs: [fragment.id], evidence: seven)
        let result = MioAnalysisResult(candidates: [], highlights: [], uncertainties: ["Ett ord hördes otydligt."],
            sections: [section], metadata: metadata,
            examHints: [MioLessonHighlight(text: "Celldelning", sourceIDs: [fragment.id], evidence: seven),
                        MioLessonHighlight(text: "Hela genomgången", sourceIDs: [fragment.id], evidence: limit),
                        MioLessonHighlight(text: "För långt", sourceIDs: [fragment.id], evidence: overLimit)])
            .droppingInvalidLessonExtras(for: request)
        // Quotes are never shortened: the long exact ones stay whole, the one over the limit goes.
        XCTAssertEqual(result.examHints?.map(\.evidence), [seven, limit])
        XCTAssertEqual(result.uncertainties, ["Ett ord hördes otydligt.", MioAnalysisResult.droppedExamHintsNotice(1)])
        XCTAssertFalse(result.uncertainties.last?.contains("cellen") ?? true, "the notice carries no transcript text")
        // Sections and candidates follow the same limit, and the notice is valid beside six model uncertainties.
        XCTAssertNoThrow(try result.validate(against: request))
        var full = result
        full.uncertainties = (1...6).map { "Osäkerhet \($0)" } + [MioAnalysisResult.droppedExamHintsNotice(1)]
        XCTAssertNoThrow(try full.validate(against: request))
        full.uncertainties.append(MioAnalysisResult.droppedExamHintsNotice(2))
        XCTAssertThrowsError(try full.validate(against: request), "one notice per part")
        // Cleaning twice adds nothing more.
        XCTAssertEqual(result.droppingInvalidLessonExtras(for: request).uncertainties, result.uncertainties)
        let tooLongSection = MioLessonSection(heading: "Cellen", body: "Delning.", sourceIDs: [fragment.id], evidence: overLimit)
        let rejected = MioAnalysisResult(candidates: [], highlights: [], uncertainties: [], sections: [tooLongSection], metadata: metadata,
                                         examHints: [], subjectSuggestion: nil)
        XCTAssertThrowsError(try rejected.validate(against: request))
    }

    @MainActor
    func testFinishedNotesAreAnnouncedOnceEvenWhenTheTimeIsNotMeasured() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioReadyOnce-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "MioLessonNotesV2Tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SessionRepository(storageURL: root.appendingPathComponent("sessions.json"))
        // Ended more than a week ago: the latency log refuses the time, so it cannot tell.
        let ended = Date(timeIntervalSinceNow: -10 * 86_400)
        let session = MioSession(startedAt: ended.addingTimeInterval(-600), endedAt: ended,
                                 transcripts: [segment("Det här kommer på provet.", speaker: 1)], title: "Biologi", captureMode: .lesson)
        let token = try await repository.operationToken(for: session.id, generation: await repository.operationGeneration())
        _ = try await repository.saveCaptureCheckpoint(session, token: token)
        let capture = MioViewModel(repository: repository)
        let assistant = MioAssistantViewModel(repository: MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json")))
        let content = MioContentViewModel(repository: MioContentRepository(storageURL: root.appendingPathComponent("content.json")))
        let workflow = MioWorkflowCoordinator(capture: capture, content: content, assistant: assistant, analysis: MioAnalysisCoordinator(),
            journal: MioDeletionJournal(storageURL: root.appendingPathComponent("operations.json")),
            diagnostics: MioDiagnosticsRepository(storageURL: root.appendingPathComponent("diagnostics.json")),
            systemActions: MioSystemActionPort(cancel: { _ in .success }, removeAll: { .success }),
            clearCredentials: {}, pendingLessonDefaults: defaults)
        await workflow.bootstrap()
        var announced: [UUID] = []
        workflow.onLessonNotesReady = { announced.append($0) }
        workflow.lessonNotesCompleted(session)
        workflow.lessonNotesCompleted(session)
        XCTAssertEqual(announced, [session.id], "notes finished again are not announced again")
        XCTAssertNil(workflow.lastLessonNotesLatency, "an implausible time is not measured")
        XCTAssertTrue(MioLessonNotesLatencyLog.load(from: defaults).entries.isEmpty)
        XCTAssertEqual(MioLessonNotesReadyLog.load(from: defaults), [session.id])
        XCTAssertEqual(defaults.stringArray(forKey: MioLessonNotesReadyLog.key), [session.id.uuidString], "only the identity")
    }

    func testTheReadyLogIsBoundedAndResets() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MioLessonNotesV2Tests-\(UUID())"))
        let first = UUID()
        XCTAssertTrue(MioLessonNotesReadyLog.claim(first, in: defaults))
        XCTAssertFalse(MioLessonNotesReadyLog.claim(first, in: defaults))
        for _ in 0..<MioLessonNotesReadyLog.maximumEntries { _ = MioLessonNotesReadyLog.claim(UUID(), in: defaults) }
        let ids = MioLessonNotesReadyLog.load(from: defaults)
        XCTAssertEqual(ids.count, MioLessonNotesReadyLog.maximumEntries)
        XCTAssertFalse(ids.contains(first), "the oldest goes first")
        MioLessonNotesReadyLog.reset(in: defaults)
        XCTAssertTrue(MioLessonNotesReadyLog.load(from: defaults).isEmpty)
    }

    func testTheRenameDialogSaysWhatAISees() {
        XCTAssertEqual(MioSpeakerLabel.renameNote(speaker: 2, isLesson: true),
                       "Namnet visas bara på telefonen. AI ser bara ”Talare 2” och om det är läraren eller en elev, aldrig namnet. Lämna tomt för att återgå.")
        XCTAssertEqual(MioSpeakerLabel.renameNote(speaker: 1, isLesson: false),
                       "Namnet visas bara på telefonen. AI ser bara ”Talare 1”, aldrig namnet. Lämna tomt för att återgå.")
    }

    func testCalmViewCountsExamHintsAndHomeworkLocally() {
        let session = lesson([segment("Det här kommer på provet, och det är viktigt.", speaker: 1),
                              segment("Läxa till nästa gång: läs kapitel fyra.", speaker: 1),
                              segment("Kom ihåg att ta med boken.", speaker: 1), segment("Vanlig mening.", speaker: 2)])
        let cues = MioLessonCues(session: session)
        XCTAssertEqual(cues.examHints, 2)
        XCTAssertEqual(cues.homework, 1)
        XCTAssertEqual(cues.examText, "2 provtips")
        XCTAssertEqual(cues.homeworkText, "1 läxa")
    }
}

private actor LessonTransport {
    let reply: Data
    private var sent: [URLRequest] = []
    init(reply: Data) { self.reply = reply }
    func requests() -> [URLRequest] { sent }
    func send(_ request: URLRequest) throws -> (AsyncThrowingStream<UInt8, Error>, URLResponse) {
        sent.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        let data = reply
        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            for byte in data { continuation.yield(byte) }
            continuation.finish()
        }
        return (stream, response)
    }
}
