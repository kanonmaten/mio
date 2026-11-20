import Foundation

/// The only two ways to address Mio directly (user decision 2026-11-19): "Mio, kom ihåg …" and
/// "Mio, notera …". A lone "Mio" is no longer direct address, so a name said in conversation
/// never saves anything or vibrates. The grammar is local and uses no AI.
enum MioWakePhrase: String, Codable, Hashable, Sendable {
    /// "Mio, kom ihåg …"
    case remember
    /// "Mio, notera …"
    case note
}

/// Where a direct instruction ends up, decided by its words (user decision 2026-11-19).
enum MioDirectDestination: String, Codable, Hashable, Sendable {
    /// "kom ihåg" without a time and a place: saved straight to Reminders.
    case reminders
    /// "notera" without a time and a place: saved straight in Mio.
    case mioNote
    /// A clock time and a place: never saved silently. It waits under Förslag and Ja opens
    /// Calendar's own sheet (rule changed with the user's approval 2026-11-20).
    case calendar

    var title: String {
        switch self {
        case .reminders: "Påminnelser"
        case .mioNote: "Mio-anteckning"
        case .calendar: "Kalender"
        }
    }
}

/// Stored on a proposal that came from a direct instruction. Additive and optional, so older
/// assistant documents decode unchanged.
struct MioDirectOrigin: Codable, Hashable, Sendable {
    var destination: MioDirectDestination
    /// The words named a day; without one a reminder has no due date.
    var hasDate: Bool
    /// The words named a clock time; a reminder then also alerts at that time.
    var hasTime: Bool
}

/// Stored on a content item saved straight from a direct instruction. A direct instruction
/// counts as Yes, and Ångra undoes it for 24 hours; after that the item stays and only the
/// button goes away (rule changed with the user's approval 2026-11-20).
struct MioDirectRecord: Codable, Hashable, Sendable {
    static let undoWindow: TimeInterval = 24 * 60 * 60

    var destination: MioDirectDestination
    var savedAt: Date

    /// A clock set backwards (negative age) still allows undo rather than hiding it.
    func canUndo(at now: Date) -> Bool { now.timeIntervalSince(savedAt) < Self.undoWindow }
}

/// What the phone tells her after a direct instruction, only after direct address: two short
/// vibrations when it was saved (or put under Förslag for Calendar), one long when it was not
/// understood or could not be saved. Proposals AI picks up in the background never vibrate.
enum MioDirectFeedback: Equatable, Sendable {
    case saved
    case notUnderstood
}

struct MioDirectCommand: Equatable, Sendable {
    let phrase: MioWakePhrase
    /// Her words after the wake phrase, without a leading "att". Reminders and calendar events
    /// keep only the first sentence; a note keeps everything up to the next address.
    let text: String
    let destination: MioDirectDestination
    let date: Date?
    let hasTime: Bool
}

enum MioDirectParse: Equatable, Sendable {
    case command(MioDirectCommand)
    /// The wake phrase was heard but nothing usable followed it.
    case notUnderstood
}

/// A narrow Swedish grammar on purpose: only an address at the start of a sentence counts, so
/// "Jag sa Mio, kom ihåg det" in a conversation is not an instruction.
enum MioDirectCommandGrammar {
    static let maximumTextLength = 10_000
    private static var swedish: Locale { Locale(identifier: "sv-SE") }

    // `[.!?\n]` before the address is a sentence boundary; "Mio" must be a whole word.
    // Quotes, brackets and dashes may stand between the boundary and "Mio" ("—Mio—kom ihåg").
    // After the phrase a full stop is left alone: it may be the boundary of the next address.
    private static let addressPattern = #"(?:^|[.!?\n])[\s"'“”«»(—–-]*mio\b[\s,.:;!)–—-]*(kom\s*ih[åa]g|notera)(?!\p{L})[\s,:;–—-]*"#
    private static let leadingFillerPattern = #"^(?:om att|att|om)\s+"#
    // "kl." is a clock abbreviation, not the end of a sentence.
    private static let sentenceEndPattern = #"(?<![Kk]l)[.!?](?=\s|$)"#

    static func containsWakePhrase(_ text: String) -> Bool { !addresses(in: text).isEmpty }

    static func parse(_ text: String, now: Date = .now, calendar: Calendar = .current) -> [MioDirectParse] {
        let found = addresses(in: text)
        return found.enumerated().map { index, address in
            let end = index + 1 < found.count ? found[index + 1].range.lowerBound : text.endIndex
            return parseCommand(String(text[address.range.upperBound..<end]), phrase: address.phrase, now: now, calendar: calendar)
        }
    }

    private static func addresses(in text: String) -> [(phrase: MioWakePhrase, range: Range<String.Index>)] {
        guard let address = try? NSRegularExpression(pattern: addressPattern, options: [.caseInsensitive]) else { return [] }
        return address.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text), let word = Range(match.range(at: 1), in: text) else { return nil }
            let phrase: MioWakePhrase = text[word].lowercased(with: swedish).hasPrefix("kom") ? .remember : .note
            return (phrase, range)
        }
    }

    private static func parseCommand(_ raw: String, phrase: MioWakePhrase, now: Date, calendar: Calendar) -> MioDirectParse {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let leadingFiller = try? NSRegularExpression(pattern: leadingFillerPattern, options: [.caseInsensitive]),
           let filler = leadingFiller.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(filler.range, in: text) {
            text = String(text[range.upperBound...])
        }
        let full = trimmedEnd(text)
        let first = trimmedEnd(firstSentence(of: full))
        let fillers: Set<String> = ["att", "om", "det", "den", "detta", "för", "och"]
        guard !first.isEmpty, !fillers.contains(first.lowercased(with: swedish)), full.count <= maximumTextLength else {
            return .notUnderstood
        }
        let when = spokenWhen(in: first, now: now, calendar: calendar)
        let destination: MioDirectDestination
        if when?.hasTime == true, namesPlace(first) {
            destination = .calendar
        } else {
            destination = phrase == .remember ? .reminders : .mioNote
        }
        switch destination {
        case .mioNote:
            return .command(MioDirectCommand(phrase: phrase, text: capitalized(full), destination: .mioNote, date: nil, hasTime: false))
        case .reminders, .calendar:
            return .command(MioDirectCommand(phrase: phrase, text: capitalized(first), destination: destination,
                                             date: when?.date, hasTime: when?.hasTime ?? false))
        }
    }

    private static func firstSentence(of text: String) -> String {
        guard let sentenceEnd = try? NSRegularExpression(pattern: sentenceEndPattern),
              let match = sentenceEnd.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return text }
        return String(text[..<range.lowerBound])
    }

    private static func trimmedEnd(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = result.last, ".,;:!?–—-".contains(last) || last.isWhitespace { result.removeLast() }
        return result
    }

    private static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased(with: swedish) + text.dropFirst()
    }

    // MARK: Day and clock time, without AI

    struct SpokenWhen: Equatable, Sendable {
        let date: Date
        let hasTime: Bool
    }

    static let hourWords: [String: Int] = [
        "ett": 1, "en": 1, "två": 2, "tre": 3, "fyra": 4, "fem": 5, "sex": 6, "sju": 7, "åtta": 8, "nio": 9,
        "tio": 10, "elva": 11, "tolv": 12, "tretton": 13, "fjorton": 14, "femton": 15, "sexton": 16,
        "sjutton": 17, "arton": 18, "nitton": 19, "tjugo": 20, "tjugoett": 21, "tjugoen": 21,
        "tjugotvå": 22, "tjugotre": 23
    ]
    private static let weekdays: [String: Int] = [
        "söndag": 1, "måndag": 2, "tisdag": 3, "onsdag": 4, "torsdag": 5, "fredag": 6, "lördag": 7
    ]

    /// "i dag", "i morgon", "i övermorgon" or a weekday, and "klockan 14", "kl. 14.30", "14:30" or
    /// "klockan tre". A bare hour from 1 to 6 means the afternoon, since she is at school in the
    /// morning. A weekday that is today means next week; a time already passed today means
    /// tomorrow. Nil when neither a day nor a time was said.
    static func spokenWhen(in text: String, now: Date, calendar: Calendar) -> SpokenWhen? {
        let lower = text.lowercased(with: swedish)
        var dayOffset: Int?
        if matches(#"\bi\s?övermorgon\b"#, lower) { dayOffset = 2 }
        else if matches(#"\bi\s?morgon\b"#, lower) { dayOffset = 1 }
        else if matches(#"\bi\s?(?:dag|kväll|eftermiddag)\b"#, lower) { dayOffset = 0 }
        else if let name = firstCapture(#"\b(måndag|tisdag|onsdag|torsdag|fredag|lördag|söndag)(?:en)?\b"#, lower),
                let target = weekdays[name] {
            let today = calendar.component(.weekday, from: now)
            let offset = (target - today + 7) % 7
            dayOffset = offset == 0 ? 7 : offset
        }
        let time = clockTime(in: lower)
        guard dayOffset != nil || time != nil else { return nil }
        let today = calendar.startOfDay(for: now)
        guard var day = calendar.date(byAdding: .day, value: dayOffset ?? 0, to: today) else { return nil }
        guard let time else { return SpokenWhen(date: day, hasTime: false) }
        guard var date = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day) else { return nil }
        if dayOffset == nil, date <= now, let tomorrow = calendar.date(byAdding: .day, value: 1, to: day),
           let later = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: tomorrow) {
            day = tomorrow
            date = later
        }
        return SpokenWhen(date: date, hasTime: true)
    }

    private static func clockTime(in lower: String) -> (hour: Int, minute: Int)? {
        var hour: Int?
        var minute = 0
        if let groups = captures(#"\b(?:klockan|kl\.?)\s*(\d{1,2})(?:[.:](\d{2}))?(?!\d)"#, lower) {
            hour = groups[0].flatMap { Int($0) }; minute = groups[1].flatMap { Int($0) } ?? 0
        } else if let groups = captures(#"(?<![\d.:])(\d{1,2})[:.](\d{2})(?!\d)"#, lower) {
            hour = groups[0].flatMap { Int($0) }; minute = groups[1].flatMap { Int($0) } ?? 0
        } else if let word = firstCapture(#"\b(?:klockan|kl\.?)\s+(\p{L}+)"#, lower) {
            hour = hourWords[word]
        }
        guard var hour, (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        if (1...6).contains(hour) { hour += 12 }
        return (hour, minute)
    }

    /// "hos tandläkaren", "på gymmet", "i skolan", "vid stationen": a preposition followed by a
    /// word that is not a day, a time or a number.
    static func namesPlace(_ text: String) -> Bool {
        let lower = text.lowercased(with: swedish)
        let pattern = #"\b(?:hos|på|i|vid)\s+(?:(?:en|ett|min|mitt|mina|din|ditt|hans|hennes|deras|vårt|den|det)\s+)?(\p{L}+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let timeStems = ["dag", "morgon", "övermorgon", "kväll", "eftermiddag", "förmiddag", "natt", "helg", "veck",
                         "måndag", "tisdag", "onsdag", "torsdag", "fredag", "lördag", "söndag", "klock", "tid",
                         "lunch", "månad", "år", "minut", "timm", "sekund", "kvart", "halv", "början", "slutet"]
        let other: Set<String> = ["kl", "att", "nästa", "morgon", "så", "fall", "alla", "stället", "vår", "sommar",
                                  "höst", "vinter"]
        return expression.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)).contains { match in
            guard let range = Range(match.range(at: 1), in: lower) else { return false }
            let word = String(lower[range])
            return !other.contains(word) && hourWords[word] == nil && !timeStems.contains { word.hasPrefix($0) }
        }
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func captures(_ pattern: String, _ text: String) -> [String?]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    private static func firstCapture(_ pattern: String, _ text: String) -> String? {
        captures(pattern, text)?.first ?? nil
    }
}

/// Local, text-free count of how often she undoes or rejects a direct instruction, to see
/// whether the wake phrases fire by mistake. Only numbers; cleared with all local data.
struct MioDirectNoteTally: Codable, Equatable, Sendable {
    static let key = "mio.direct.tally.v1"

    enum Event: Sendable { case saved, waiting, undone, rejected }

    /// Saved straight to Reminders or as a Mio note.
    var saved = 0
    /// Calendar events put under Förslag, and instructions that could not be saved.
    var waiting = 0
    /// Ångra within 24 hours.
    var undone = 0
    /// Nej on a proposal that came from a direct instruction.
    var rejected = 0

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: key),
              let tally = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return tally
    }

    static func record(_ event: Event, in defaults: UserDefaults) {
        var tally = load(from: defaults)
        switch event {
        case .saved: tally.saved += 1
        case .waiting: tally.waiting += 1
        case .undone: tally.undone += 1
        case .rejected: tally.rejected += 1
        }
        if let data = try? JSONEncoder().encode(tally) { defaults.set(data, forKey: key) }
    }

    static func reset(in defaults: UserDefaults) { defaults.removeObject(forKey: key) }
}
