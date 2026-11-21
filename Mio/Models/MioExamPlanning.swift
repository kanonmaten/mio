import Foundation

/// An approved exam (fas 5, user decision 2026-11-19): the day she approved and, once known, the
/// subject. Stored on the content item that recorded the handoff, as an additive optional field.
/// It is the one exception to "the record keeps no date": Mio never reads Calendar or Reminders
/// back, so the countdown on Hem and "Inför provet" need the day she confirmed in Mio. A change
/// she later makes in Calendar is not seen; the countdown follows the day she said Ja to.
struct MioExamRecord: Codable, Hashable, Sendable {
    /// Start of the day for an all-day exam, otherwise the time she approved.
    var date: Date
    var isAllDay: Bool
    /// Her subject (1–40 characters, `MioLessonSubject.clean`). Nil until she picks one.
    var subject: String?

    /// An exam record for an approved plan or task whose title reads as an exam, with the date
    /// she approved. Anything else (no date, another kind, an ordinary event) gives nil.
    static func make(kind: MioContentKind, title: String, date: Date?, isAllDay: Bool, subject: String?,
                     knownSubjects: [String] = [], calendar: Calendar = .current) -> Self? {
        guard kind == .plan || kind == .task, let date, MioExamDetector.looksLikeExam(title) else { return nil }
        let chosen = MioLessonSubject.clean(subject) ?? MioExamSubjects.match(title: title, known: knownSubjects)
        return Self(date: isAllDay ? calendar.startOfDay(for: date) : date, isAllDay: isAllDay, subject: chosen)
    }

    /// The last moment that still belongs to the exam: its time, or the end of its day.
    func end(calendar: Calendar) -> Date {
        guard isAllDay else { return date }
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }
}

/// Local word rules, no AI: a title reads as an exam when a word is "prov" or ends in "prov",
/// "provet" or "proven" ("Biologiprov", "glosprovet"), or is a hearing or test word. "Prova",
/// "provat" and "prover" do not count, so "prova klänningen" is never an exam. Neither do the
/// everyday samples and tests that are not school exams ("blodprov", "stickprov", "covid-prov"):
/// a hyphenated compound is read as one word, and a compound whose first part is in
/// `nonSchoolStems` is never an exam.
enum MioExamDetector {
    private static let exactWords: Set<String> = [
        "prov", "provet", "proven", "förhör", "förhöret", "läxförhör", "läxförhöret", "tenta", "tentan",
        "skrivning", "skrivningen", "provskrivning", "provskrivningen", "np"
    ]
    private static let provSuffixes = ["provet", "proven", "prov"]

    /// First parts of "-prov" compounds that are samples or medical, product or work tests, never
    /// a school exam (review of fas 5, 2026-11-21). Kept small and common; a miss only means one
    /// plan without a countdown, never a lost plan.
    static let nonSchoolStems: Set<String> = [
        "blod", "stick", "urin", "smak", "prov", "alkohol", "drog", "narkotika", "covid", "corona", "pcr",
        "saliv", "cell", "vävnads", "avförings", "allergi", "graviditets", "dna", "hår", "hud", "vatten",
        "jord", "luft", "varu", "gratis", "parfym", "doft", "färg", "tyg", "material", "arbets", "snabb",
        "antigen", "antikropps", "sekret", "svalg", "näs", "gen", "mögel", "radon", "mjölk", "foder"
    ]

    static func looksLikeExam(_ text: String) -> Bool {
        words(in: text).contains { word in
            if let suffix = provSuffixes.first(where: { word.hasSuffix($0) }) {
                let stem = String(word.dropLast(suffix.count))
                if stem.isEmpty { return true }
                return word.count > 4 && !nonSchoolStems.contains(stem)
            }
            return exactWords.contains(word) || word.hasSuffix("förhör") || word.hasSuffix("förhöret")
        }
    }

    /// Lowercased words; a hyphen inside a word joins its parts ("covid-prov" is "covidprov").
    static func words(in text: String) -> [String] {
        text.lowercased(with: MioExamSubjects.swedish)
            .split { !$0.isLetter && $0 != "-" }
            .map { $0.split(separator: "-").joined() }
            .filter { !$0.isEmpty }
    }
}

/// The subjects she has confirmed on her lessons, for choosing an exam's subject.
enum MioExamSubjects {
    static let swedish = Locale(identifier: "sv-SE")

    /// Distinct confirmed lesson subjects, most recent lesson first. Case and diacritics do not
    /// make two subjects different; the most recent spelling wins.
    static func known(in sessions: [MioSession]) -> [String] {
        var seen: Set<String> = []
        return sessions.filter(\.isLesson).sorted { $0.startedAt > $1.startedAt }.compactMap { session in
            guard let subject = session.subject.flatMap(MioLessonSubject.clean) else { return nil }
            return seen.insert(key(subject)).inserted ? subject : nil
        }
    }

    /// A known subject named in the title: "Biologiprov" and "prov i biologi" both match "Biologi".
    /// The longest match wins, so "Moderna språk" beats "Språk".
    static func match(title: String, known: [String]) -> String? {
        let folded = key(title)
        return known.filter { subject in
            let name = key(subject)
            return !name.isEmpty && folded.contains(name)
        }.max { key($0).count < key($1).count }
    }

    /// The comparison form: trimmed, case-, diacritic- and width-insensitive.
    static func key(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: swedish)
            .lowercased(with: swedish)
    }

    static func same(_ left: String?, _ right: String?) -> Bool {
        guard let left, let right else { return false }
        return key(left) == key(right)
    }
}

/// One approved exam, as Hem and "Inför provet" use it.
struct MioExamPlan: Identifiable, Hashable, Sendable {
    /// The content item's ID.
    let id: UUID
    let title: String
    let exam: MioExamRecord

    /// Exams from approved items: the stored exam record, or an older plan kept in Mio with its
    /// own date (before 0.9.1, when plans were not handed to Calendar) whose title reads as an exam.
    static func all(in items: [MioContentItem], calendar: Calendar = .current) -> [Self] {
        items.compactMap { item -> Self? in
            if let exam = item.exam { return Self(id: item.id, title: item.title, exam: exam) }
            guard item.handoff == nil, item.kind == .plan, MioExamDetector.looksLikeExam(item.title) else { return nil }
            return Self(id: item.id, title: item.title,
                        exam: MioExamRecord(date: item.allDay ? calendar.startOfDay(for: item.scheduledAt) : item.scheduledAt,
                                            isAllDay: item.allDay, subject: nil))
        }.sorted { $0.exam.date == $1.exam.date ? $0.id.uuidString < $1.id.uuidString : $0.exam.date < $1.exam.date }
    }

    /// "Biologiprov", or "Prov i svenska 2" when the subject is several words, has digits or is an
    /// abbreviation; "Prov" without a subject.
    var name: String { Self.name(subject: exam.subject) }

    static func name(subject: String?) -> String {
        guard let subject = subject.flatMap(MioLessonSubject.clean) else { return "Prov" }
        let simple = subject.allSatisfy(\.isLetter) && subject != subject.uppercased()
        guard simple else { return "Prov i \(subject)" }
        return subject.prefix(1).uppercased() + subject.dropFirst().lowercased() + "prov"
    }
}

/// The countdown on Hem (user decision 2026-11-19): from a week before, "Biologiprov om 3 dagar".
struct MioExamCountdown: Identifiable, Hashable, Sendable {
    static let visibleDays = 7

    let plan: MioExamPlan
    /// Whole calendar days from today; 0 is today.
    let daysLeft: Int

    var id: UUID { plan.id }

    var text: String {
        switch daysLeft {
        case 0: "\(plan.name) i dag"
        case 1: "\(plan.name) i morgon"
        default: "\(plan.name) om \(daysLeft) dagar"
        }
    }

    /// Exams from today through seven days ahead, soonest first. An exam earlier today with a
    /// time stays until that time has passed; an all-day exam stays all day.
    static func upcoming(_ plans: [MioExamPlan], now: Date, calendar: Calendar = .current) -> [Self] {
        let today = calendar.startOfDay(for: now)
        return plans.compactMap { plan in
            guard plan.exam.end(calendar: calendar) > now,
                  let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: plan.exam.date)).day,
                  (0...visibleDays).contains(days) else { return nil }
            return Self(plan: plan, daysLeft: days)
        }
    }
}

/// "Inför provet" (user decision 2026-11-19): the subject's exam hints and lesson notes since the
/// previous exam, as one text to copy. Each lesson is the same text as its own copy
/// (`MioLessonDocument.markdown`): no internal source IDs, and incomplete notes are marked.
struct MioExamPrep: Sendable {
    let subject: String
    let lessons: [MioSession]
    /// The previous approved exam in the same subject, or nil when every lesson is included.
    let previousExam: MioExamPlan?

    /// Ended lessons with the same subject after the previous approved exam in that subject and
    /// before this exam (or now, when the exam is not known yet). With no previous exam, all of them.
    static func make(subject: String, exam: MioExamPlan?, sessions: [MioSession], exams: [MioExamPlan],
                     now: Date, calendar: Calendar = .current) -> Self {
        let reference = exam?.exam.date ?? now
        let previous = exams.filter { other in
            other.id != exam?.id && MioExamSubjects.same(other.exam.subject, subject)
                && other.exam.end(calendar: calendar) <= reference
        }.max { $0.exam.date < $1.exam.date }
        let since = previous?.exam.end(calendar: calendar)
        let until = exam?.exam.end(calendar: calendar) ?? now
        let lessons = sessions.filter { session in
            session.isLesson && session.endedAt != nil && MioExamSubjects.same(session.subject, subject)
                && session.startedAt < until && since.map { session.startedAt >= $0 } != false
        }.sorted { $0.startedAt < $1.startedAt }
        return Self(subject: subject, lessons: lessons, previousExam: previous)
    }

    /// The text that is copied. `records` are every lesson's saved note parts.
    func text(records: [MioAnalysisRecord], exam: MioExamPlan?, calendar: Calendar = .current) -> String {
        let dateStyle = Date.FormatStyle(date: .long, time: .omitted, locale: MioExamSubjects.swedish, calendar: calendar,
                                         timeZone: calendar.timeZone)
        var parts = ["# Inför provet: \(subject)"]
        if let exam {
            parts.append("\(exam.title) · \(exam.exam.date.formatted(dateStyle))")
        }
        let documents = lessons.map { MioLessonDocument(session: $0, records: records) }
        let count = documents.count == 1 ? "1 lektion" : "\(documents.count) lektioner"
        if let previous = previousExam {
            parts.append("\(count) sedan förra provet \(previous.exam.date.formatted(dateStyle)).")
        } else {
            parts.append("\(count) i ämnet. Inget tidigare prov i ämnet är sparat, så alla lektioner är med.")
        }
        let incomplete = documents.filter { !$0.isComplete || $0.unprocessedCount > 0 }.count
        if incomplete > 0 {
            parts.append("Ofullständigt: \(incomplete == 1 ? "1 lektion saknar" : "\(incomplete) lektioner saknar") färdiga anteckningar. Kontrollera dem i Mio.")
        }
        if documents.isEmpty {
            parts.append("Inga lektioner med ämnet \(subject) är sparade under den tiden.")
        }
        parts += documents.map(\.markdown)
        return parts.joined(separator: "\n\n")
    }
}
