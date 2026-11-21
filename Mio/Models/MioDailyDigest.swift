import Foundation

/// One local notification Mio plans ahead: its ID, the local day and time it fires, and its text.
struct MioDailyNotice: Equatable, Sendable {
    let id: String
    /// Year, month, day, hour and minute in the device's calendar.
    let components: DateComponents
    let body: String
}

/// The morning and evening notifications (fas 5, user decision 2026-11-19).
///
/// Morning: off until she turns it on. With "Visa prov och läxor" off (the default) the text is
/// the old generic one and the notification repeats. With it on, the text names only subjects and
/// the words "prov" and "läxa" (never a title or a note), so each day gets its own notification,
/// planned `horizonDays` ahead and replanned whenever Mio runs.
///
/// Evening: the number of proposals to review today; opening it shows Förslag. Today's text is
/// replanned when the count changes; later days say only that the day's proposals can be reviewed,
/// since their count is not known yet.
enum MioDailyDigest {
    static let horizonDays = 14
    /// Bool, absent = off. Whether the morning text names today's exams and homework.
    static let morningDetailKey = "mio.daily.morning.detail"

    /// Minutes after midnight for `mio.daily.<kind>`, so one-day notifications can be replanned.
    static func timeKey(_ base: String) -> String { "\(base).minutes" }

    // MARK: Morning

    /// Reminders due on `day` that are homework: one Mio sent from a lesson, or one whose title says
    /// so ("läxa", "inlämning", "lämna in"). The subject comes from the lesson she confirmed.
    static func homework(on day: Date, reminders: [MioReminderSummary], items: [MioContentItem],
                         sessions: [MioSession], calendar: Calendar = .current) -> [String?] {
        let lessons = Dictionary(sessions.filter(\.isLesson).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let records = Dictionary(items.compactMap { item in item.handoff?.externalIdentifier.map { ($0, item) } },
                                 uniquingKeysWith: { first, _ in first })
        return reminders.compactMap { reminder in
            guard let due = reminder.dueDate, calendar.isDate(due, inSameDayAs: day) else { return nil }
            let lesson = records[reminder.id]?.sessionID.flatMap { lessons[$0] }
            let words = reminder.title.lowercased(with: MioExamSubjects.swedish)
            guard lesson != nil || ["läx", "inlämning", "lämna in"].contains(where: words.contains) else { return nil }
            // An exam reminder is counted as the exam, not as homework.
            guard records[reminder.id]?.exam == nil else { return nil }
            return .some(lesson?.subject.flatMap(MioLessonSubject.clean))
        }
    }

    /// "I dag: Biologiprov, läxa i Kemi, 1 annan läxa." Only subjects and the words prov and läxa.
    static func morningBody(exams: [MioExamPlan], homework: [String?]) -> String {
        var parts = exams.map(\.name)
        var subjects: [String] = []
        for subject in homework.compactMap({ $0 }) where !subjects.contains(where: { MioExamSubjects.same($0, subject) }) {
            subjects.append(subject)
        }
        parts += subjects.map { "läxa i \($0)" }
        let others = homework.filter { $0 == nil }.count
        if others > 0 {
            parts.append(subjects.isEmpty ? (others == 1 ? "1 läxa" : "\(others) läxor")
                                          : (others == 1 ? "1 annan läxa" : "\(others) andra läxor"))
        }
        guard !parts.isEmpty else { return "Inga prov eller läxor i dag." }
        return "I dag: " + parts.joined(separator: ", ") + "."
    }

    /// Exams on `day` (by the day she approved).
    static func exams(on day: Date, in plans: [MioExamPlan], calendar: Calendar = .current) -> [MioExamPlan] {
        plans.filter { calendar.isDate($0.exam.date, inSameDayAs: day) }
    }

    // MARK: Evening

    static func eveningBody(pendingCount: Int, isToday: Bool) -> String {
        guard isToday else { return "Granska dagens förslag i Mio." }
        switch pendingCount {
        case 0: return "Inga förslag att granska i dag."
        case 1: return "1 förslag att granska i Mio."
        default: return "\(pendingCount) förslag att granska i Mio."
        }
    }

    // MARK: Planning

    /// One notification per day from today, at `minutes` after midnight, skipping a time that has
    /// already passed today. IDs are `<base>.<ÅÅÅÅMMDD>`, so replanning replaces the same day.
    static func plan(base: String, minutes: Int, now: Date, calendar: Calendar = .current,
                     days: Int = horizonDays, body: (_ day: Date, _ isToday: Bool) -> String) -> [MioDailyNotice] {
        guard (0..<(24 * 60)).contains(minutes) else { return [] }
        let today = calendar.startOfDay(for: now)
        return (0..<max(0, days)).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let fire = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day),
                  fire > now else { return nil }
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            components.calendar = nil
            let stamp = String(format: "%04d%02d%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
            return MioDailyNotice(id: "\(base).\(stamp)", components: components, body: body(day, offset == 0))
        }
    }

    /// Whether a pending notification ID belongs to the daily kind `base` (the repeating one or a day).
    static func belongs(_ identifier: String, to base: String) -> Bool {
        identifier == base || (identifier.hasPrefix(base + ".") && identifier.dropFirst(base.count + 1).count == 8
            && identifier.dropFirst(base.count + 1).allSatisfy(\.isNumber))
    }
}
