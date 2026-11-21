import Foundation

/// Who a speaker is in a lesson, sent with lesson notes version 2 (`speakerRole`). Never a name.
enum MioSpeakerRole: String, Codable, Hashable, Sendable {
    case teacher, student
}

/// Display labels and roles for a lesson's speakers (user decision 2026-11-19). The speaker
/// who said the most characters in the original segments is the teacher, the others students.
/// A display layer only: the stored speaker numbers and texts never change, and the roles do
/// not follow the names she gives the speakers herself.
enum MioSpeakerRoles {
    /// Roles per speaker number; empty for an everyday session or a lesson without labels.
    /// A tie goes to the lower speaker number, so the result never depends on dictionary order.
    static func roles(in session: MioSession) -> [Int: MioSpeakerRole] {
        guard session.isLesson else { return [:] }
        var characters: [Int: Int] = [:]
        for segment in session.transcripts {
            guard let speaker = segment.speaker else { continue }
            // Original text: a correction is a display layer and must not move the teacher label.
            characters[speaker, default: 0] += segment.text.count
        }
        guard let teacher = characters.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value })?.key
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: characters.keys.map { ($0, $0 == teacher ? .teacher : .student) })
    }

    /// "Lärare" and "Elev 1, 2…" (students numbered by speaker number) in a lesson, otherwise
    /// the neutral "Talare N".
    static func defaultName(for speaker: Int, roles: [Int: MioSpeakerRole]) -> String {
        switch roles[speaker] {
        case .teacher?: return "Lärare"
        case .student?:
            let students = roles.filter { $0.value == .student }.keys.sorted()
            return "Elev \((students.firstIndex(of: speaker) ?? 0) + 1)"
        case nil: return MioSpeakerLabel.defaultName(speaker)
        }
    }
}

/// Counts during a lesson for the calm view: exam hints and homework the teacher seems to point
/// out so far. Local word cues only, without AI and without storing anything; the notes after
/// the lesson are what counts. Matched on the display text without regard to case (å, ä and ö
/// stay distinct letters).
struct MioLessonCues: Equatable, Sendable {
    let examHints: Int
    let homework: Int

    static let examPhrases = ["på provet", "till provet", "kommer på prov", "provfråga", "kom ihåg", "viktigt", "det här ska ni kunna",
                              "det ska ni kunna", "lär er det här", "skriv upp det här"]
    static let homeworkPhrases = ["läxa", "läxan", "läxor", "till nästa gång", "till nästa lektion", "lämna in", "inlämning",
                                  "ska vara klart", "ska vara klar", "läs kapitel", "gör uppgift", "gör uppgifterna"]

    init(examHints: Int, homework: Int) { self.examHints = examHints; self.homework = homework }

    init(session: MioSession) {
        var exam = 0, homework = 0
        for segment in session.transcripts {
            let text = Self.folded(segment.displayText)
            // One count per segment and kind: a teacher repeating "viktigt" twice in a sentence
            // is still one hint.
            if Self.examPhrases.contains(where: { text.contains($0) }) { exam += 1 }
            if Self.homeworkPhrases.contains(where: { text.contains($0) }) { homework += 1 }
        }
        self.init(examHints: exam, homework: homework)
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "sv-SE"))
            .lowercased(with: Locale(identifier: "sv-SE"))
    }

    var examText: String { examHints == 1 ? "1 provtips" : "\(examHints) provtips" }
    var homeworkText: String { homework == 1 ? "1 läxa" : "\(homework) läxor" }
}

/// Time from the end of a lesson to finished notes, kept on the phone without any text
/// (plan phase 3). Only identities, seconds and times; the goal is under five minutes.
struct MioLessonNotesLatencyLog: Codable, Equatable, Sendable {
    static let key = "mio.lesson.notesLatency.v1"
    static let maximumEntries = 30
    static let goalSeconds = 300

    struct Entry: Codable, Equatable, Sendable {
        let sessionID: UUID
        let seconds: Int
        let completedAt: Date
    }

    var entries: [Entry] = []

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: key), let log = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return log
    }

    /// Once per lesson: notes finished again later (for example after a correction) keep the first time.
    @discardableResult
    static func record(sessionID: UUID, endedAt: Date, completedAt: Date, in defaults: UserDefaults) -> Entry? {
        let seconds = completedAt.timeIntervalSince(endedAt)
        guard seconds.isFinite, seconds >= 0, seconds < 7 * 86_400 else { return nil }
        var log = load(from: defaults)
        guard !log.entries.contains(where: { $0.sessionID == sessionID }) else { return nil }
        let entry = Entry(sessionID: sessionID, seconds: Int(seconds.rounded()), completedAt: completedAt)
        log.entries.append(entry)
        log.entries = Array(log.entries.suffix(maximumEntries))
        if let data = try? JSONEncoder().encode(log) { defaults.set(data, forKey: key) }
        return entry
    }

    static func reset(in defaults: UserDefaults) { defaults.removeObject(forKey: key) }

    var latest: Entry? { entries.max { $0.completedAt < $1.completedAt } }
    var medianSeconds: Int? {
        let sorted = entries.map(\.seconds).sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
    var withinGoal: Int { entries.filter { $0.seconds < Self.goalSeconds }.count }

    /// "4 min 10 s", "45 s".
    static func duration(_ seconds: Int) -> String {
        let minutes = seconds / 60, rest = seconds % 60
        if minutes == 0 { return "\(rest) s" }
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }
}

/// What the review sheet after a lesson shows: the lesson's proposals waiting for Ja or Nej, and
/// the AI's subject suggestion next to the subject she confirmed (fas 5 builds on the latter).
struct MioLessonReviewContent: Sendable {
    let sessionID: UUID
    let suggestions: [MioSuggestion]
    let examHints: [MioLessonHighlight]
    let subjectSuggestion: String?
    let confirmedSubject: String?

    init(session: MioSession, suggestions: [MioSuggestion], records: [MioAnalysisRecord]) {
        sessionID = session.id
        self.suggestions = suggestions
            .filter { $0.sessionID == session.id && $0.purpose == .content }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
        let document = MioLessonDocument(session: session, records: records)
        examHints = document.examHints
        subjectSuggestion = document.subjectSuggestion
        confirmedSubject = session.subject
    }

    /// The text the subject field starts with: what she confirmed, else the AI's suggestion.
    var initialSubject: String { confirmedSubject ?? subjectSuggestion ?? "" }

    /// A proposal's date is filled in only when the AI gave a safe day; otherwise the field is empty.
    static func hasPrefilledDate(_ suggestion: MioSuggestion) -> Bool {
        suggestion.needsDateConfirmation != true
    }
}

/// The confirmed subject of a lesson: 1–40 characters on one line, or nothing.
enum MioLessonSubject {
    static let maximumLength = 40

    static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= maximumLength,
              !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return clean
    }
}
