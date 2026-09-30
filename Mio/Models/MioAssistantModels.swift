import Foundation

enum MioSuggestionState: String, Codable, Hashable, Sendable {
    case pending
    case deferred
}

enum MioSuggestionPurpose: String, Codable, Hashable, Sendable {
    case content
    case question
}

struct MioSuggestion: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var kind: MioContentKind
    var title: String
    var body: String
    let createdAt: Date
    var scheduledAt: Date
    var sessionID: UUID?
    let sourceSegmentID: UUID?
    var state: MioSuggestionState
    var deferredAt: Date?
    var purpose: MioSuggestionPurpose
    var evidence: String?
    var needsDateConfirmation: Bool?

    init(
        id: UUID = UUID(),
        kind: MioContentKind,
        title: String,
        body: String = "",
        createdAt: Date = .now,
        scheduledAt: Date? = nil,
        sessionID: UUID? = nil,
        sourceSegmentID: UUID? = nil,
        state: MioSuggestionState = .pending,
        deferredAt: Date? = nil,
        purpose: MioSuggestionPurpose = .content,
        evidence: String? = nil,
        needsDateConfirmation: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.scheduledAt = scheduledAt ?? createdAt
        self.sessionID = sessionID
        self.sourceSegmentID = sourceSegmentID
        self.state = state
        self.deferredAt = deferredAt
        self.purpose = purpose
        self.evidence = evidence
        self.needsDateConfirmation = needsDateConfirmation
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, body, createdAt, scheduledAt, sessionID, sourceSegmentID, state, deferredAt, purpose, evidence, needsDateConfirmation
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(MioContentKind.self, forKey: .kind)
        title = try values.decode(String.self, forKey: .title)
        body = try values.decode(String.self, forKey: .body)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        scheduledAt = try values.decode(Date.self, forKey: .scheduledAt)
        sessionID = try values.decodeIfPresent(UUID.self, forKey: .sessionID)
        sourceSegmentID = try values.decodeIfPresent(UUID.self, forKey: .sourceSegmentID)
        state = try values.decode(MioSuggestionState.self, forKey: .state)
        deferredAt = try values.decodeIfPresent(Date.self, forKey: .deferredAt)
        evidence = try values.decodeIfPresent(String.self, forKey: .evidence)
        needsDateConfirmation = try values.decodeIfPresent(Bool.self, forKey: .needsDateConfirmation)
        // Older assistant documents contain only proposed content items.
        purpose = try values.decodeIfPresent(MioSuggestionPurpose.self, forKey: .purpose) ?? .content
    }

    var questionText: String? {
        guard purpose == .question else { return nil }
        return body.isEmpty ? title : body
    }

    /// The same identity survives a retry if saving content succeeds but dismissing
    /// the proposal fails. Approval is performed by the UI before saving this item.
    func contentItem(now: Date = .now) -> MioContentItem {
        MioContentItem(
            id: id,
            kind: kind,
            title: title,
            body: body,
            createdAt: createdAt,
            updatedAt: now,
            scheduledAt: scheduledAt,
            sessionID: sessionID
        )
    }
}

/// Only identifiers are retained after rejection, never the rejected proposal text.
struct MioProcessedSource: Codable, Hashable, Sendable {
    let sessionID: UUID
    let segmentID: UUID
}

struct MioLesson: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let sessionID: UUID
    var title: String
    var note: String
    var startedAt: Date
    var endedAt: Date
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        title: String,
        note: String = "",
        startedAt: Date,
        endedAt: Date,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.note = note
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// Lesson boundaries filter the display only; no transcript segment is split,
    /// rewritten or removed when a boundary is changed.
    func transcripts(in session: MioSession) -> [TranscriptSegment] {
        guard session.id == sessionID else { return [] }
        return session.transcripts.filter { segment in
            if segment.audioStartedAt == segment.audioEndedAt {
                return segment.audioStartedAt >= startedAt && segment.audioStartedAt < endedAt
            }
            return segment.audioStartedAt < endedAt && segment.audioEndedAt > startedAt
        }
    }
}

/// Retained decisions contain identities only, so rejection cannot preserve proposal text.
struct MioAnalysisDecision: Codable, Hashable, Sendable {
    let id: UUID
    let sessionID: UUID
    let kind: MioContentKind
    var sourceIDs: [String]
    var isClosed: Bool
}

struct MioAssistantStoreDocument: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var suggestions: [MioSuggestion]
    var lessons: [MioLesson]
    var processedSources: Set<MioProcessedSource>
    var analyses: [MioAnalysisRecord]?
    var analysisDecisions: [MioAnalysisDecision]?

    init(
        schemaVersion: Int = currentSchemaVersion,
        suggestions: [MioSuggestion] = [],
        lessons: [MioLesson] = [],
        processedSources: Set<MioProcessedSource> = [],
        analyses: [MioAnalysisRecord]? = nil,
        analysisDecisions: [MioAnalysisDecision]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.suggestions = suggestions
        self.lessons = lessons
        self.processedSources = processedSources
        self.analyses = analyses
        self.analysisDecisions = analysisDecisions
    }
}

enum MioAssistantValidationError: LocalizedError {
    case emptyText
    case textTooLong
    case unsupportedKind
    case activeSession
    case emptyLessonTitle
    case lessonTextTooLong
    case invalidLessonInterval
    case overlappingLesson
    case missingSuggestion
    case deletedSession

    var errorDescription: String? {
        switch self {
        case .emptyText:
            "Skriv vad du vill att Mio ska föreslå."
        case .textTooLong:
            "Texten får vara högst 10 000 tecken. Dela upp den i flera förslag."
        case .unsupportedKind:
            "Välj anteckning, uppgift, plan eller uttryckligt minne."
        case .activeSession:
            "Stoppa sessionen innan du delar in den i lektioner."
        case .emptyLessonTitle:
            "Skriv en rubrik för lektionen."
        case .lessonTextTooLong:
            "Lektionsrubriken får vara högst 120 tecken och anteckningen högst 10 000 tecken."
        case .invalidLessonInterval:
            "Lektionen måste börja före den slutar och ligga inom den avslutade sessionen."
        case .overlappingLesson:
            "Lektionen överlappar en annan lektion. Ändra tiderna först."
        case .missingSuggestion:
            "Förslaget finns inte längre."
        case .deletedSession:
            "Sessionen har raderats. Dess förslag och lektioner kan inte sparas igen."
        }
    }
}

enum MioLocalSuggestionEngine {
    static func explicitSuggestion(
        text: String,
        kind: MioContentKind,
        scheduledAt: Date? = nil,
        sessionID: UUID? = nil,
        now: Date = .now
    ) throws -> MioSuggestion {
        guard kind != .timeline else { throw MioAssistantValidationError.unsupportedKind }
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { throw MioAssistantValidationError.emptyText }
        guard cleanText.count <= 10_000 else { throw MioAssistantValidationError.textTooLong }
        let firstLine = cleanText.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? cleanText
        let title = String(firstLine.prefix(120))
        return MioSuggestion(
            kind: kind,
            title: title,
            body: cleanText == title ? "" : cleanText,
            createdAt: now,
            scheduledAt: scheduledAt,
            sessionID: sessionID
        )
    }

    static func explicitQuestion(
        text: String,
        sessionID: UUID? = nil,
        now: Date = .now
    ) throws -> MioSuggestion {
        var suggestion = try explicitSuggestion(text: text, kind: .note, sessionID: sessionID, now: now)
        suggestion.purpose = .question
        return suggestion
    }

    /// A narrow Swedish command grammar is deliberate. A mere mention of Mio or
    /// ordinary conversation must not become a task, plan or personal memory.
    static func suggestion(
        from segment: TranscriptSegment,
        sessionID: UUID,
        now: Date = .now
    ) -> MioSuggestion? {
        suggestions(from: segment, sessionID: sessionID, now: now).first
    }

    static func suggestions(
        from segment: TranscriptSegment,
        sessionID: UUID,
        now: Date = .now
    ) -> [MioSuggestion] {
        let text = segment.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expression = try? NSRegularExpression(
            pattern: #"(?:^|[.!?\n])\s*mio\b[\s,.:;!–—-]*"#,
            options: .caseInsensitive
        ) else { return [] }
        let addresses = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) }
        return addresses.enumerated().compactMap { index, address in
            let commandEnd = index + 1 < addresses.count ? addresses[index + 1].lowerBound : text.endIndex
            let command = String(text[address.upperBound..<commandEnd])
            return parseCommand(command, sourceSegmentID: segment.id, sessionID: sessionID, now: now)
        }
    }

    private static func parseCommand(
        _ command: String,
        sourceSegmentID: UUID,
        sessionID: UUID,
        now: Date
    ) -> MioSuggestion? {
        let questionText: String?
        if let prefix = command.range(of: #"^fråga\s+"#, options: [.regularExpression, .caseInsensitive]) {
            questionText = String(command[prefix.upperBound...])
        } else if command.range(
            of: #"^(?:vad|hur|varför|när|var|vem|kan du förklara)\s+"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            questionText = command
        } else {
            questionText = nil
        }
        if let questionText,
           let draft = try? explicitQuestion(text: questionText, sessionID: sessionID, now: now) {
            return MioSuggestion(
                kind: draft.kind, title: draft.title, body: draft.body,
                createdAt: draft.createdAt, scheduledAt: draft.scheduledAt,
                sessionID: sessionID, sourceSegmentID: sourceSegmentID, purpose: .question
            )
        }
        let rules: [(String, MioContentKind)] = [
            (#"^(?:kom ihåg att|kom ihåg|minns att)\s+"#, .memory),
            (#"^(?:påminn mig (?:om att|att|om)|lägg till en uppgift att|lägg till uppgiften|skapa en uppgift att|skapa en uppgift)\s+"#, .task),
            (#"^(?:planera att|planera|lägg till en plan för|lägg till en plan|boka in)\s+"#, .plan),
            (#"^(?:anteckna att|anteckna|skriv en anteckning om|skriv en anteckning|spara en anteckning om)\s+"#, .note)
        ]
        for (pattern, kind) in rules {
            guard let prefix = command.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
                continue
            }
            let body = String(command[prefix.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !["att", "om", "för"].contains(body.lowercased(with: Locale(identifier: "sv-SE"))),
                  let draft = try? explicitSuggestion(text: body, kind: kind, sessionID: sessionID, now: now) else {
                return nil
            }
            return MioSuggestion(
                kind: draft.kind,
                title: draft.title,
                body: draft.body,
                createdAt: draft.createdAt,
                scheduledAt: draft.scheduledAt,
                sessionID: sessionID,
                sourceSegmentID: sourceSegmentID
            )
        }
        return nil
    }

    static func validateLesson(_ lesson: MioLesson, session: MioSession, otherLessons: [MioLesson]) throws {
        guard let sessionEnd = session.endedAt else { throw MioAssistantValidationError.activeSession }
        guard !lesson.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MioAssistantValidationError.emptyLessonTitle
        }
        guard lesson.title.count <= 120, lesson.note.count <= 10_000 else {
            throw MioAssistantValidationError.lessonTextTooLong
        }
        guard lesson.sessionID == session.id,
              lesson.startedAt.timeIntervalSinceReferenceDate.isFinite,
              lesson.endedAt.timeIntervalSinceReferenceDate.isFinite,
              lesson.startedAt < lesson.endedAt,
              lesson.startedAt >= session.startedAt,
              lesson.endedAt <= sessionEnd else {
            throw MioAssistantValidationError.invalidLessonInterval
        }
        guard !otherLessons.contains(where: {
            $0.id != lesson.id && $0.sessionID == lesson.sessionID
                && $0.startedAt < lesson.endedAt && $0.endedAt > lesson.startedAt
        }) else { throw MioAssistantValidationError.overlappingLesson }
    }
}

/// A deterministic local overview. It quotes saved titles and counts; it does not
/// claim to understand or summarize the meaning of a transcript.
struct MioBriefing: Sendable {
    let date: Date
    let plans: [MioContentItem]
    let tasks: [MioContentItem]
    let overdueTasks: [MioContentItem]
    let completedTasks: [MioContentItem]
    let notes: [MioContentItem]
    let sessionCount: Int
    let lessonCount: Int

    static func make(
        content: [MioContentItem],
        sessions: [MioSession],
        lessons: [MioLesson],
        date: Date = .now,
        calendar: Calendar = .current
    ) -> MioBriefing {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        func isToday(_ date: Date) -> Bool { date >= start && date < end }
        let sorted = content.sorted {
            if $0.scheduledAt != $1.scheduledAt { return $0.scheduledAt < $1.scheduledAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        return MioBriefing(
            date: date,
            plans: sorted.filter { $0.kind == .plan && isToday($0.scheduledAt) },
            tasks: sorted.filter { $0.kind == .task && !$0.isCompleted && isToday($0.scheduledAt) },
            overdueTasks: sorted.filter { $0.kind == .task && !$0.isCompleted && $0.scheduledAt < start },
            completedTasks: sorted.filter { $0.kind == .task && $0.completedAt.map(isToday) == true },
            notes: sorted.filter { ($0.kind == .note || $0.kind == .memory) && isToday($0.createdAt) },
            sessionCount: sessions.filter { isToday($0.startedAt) }.count,
            lessonCount: lessons.filter { isToday($0.startedAt) }.count
        )
    }
}
