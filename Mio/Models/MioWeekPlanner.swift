import Foundation

/// Date logic for Hem's week planner. Weeks follow the Swedish (ISO 8601) rule: Monday
/// first, and week 1 is the week with the year's first Thursday.
enum MioWeekPlanner {
    static func weekCalendar(from calendar: Calendar) -> Calendar {
        var week = Calendar(identifier: .gregorian)
        week.timeZone = calendar.timeZone
        week.locale = calendar.locale
        week.firstWeekday = 2
        week.minimumDaysInFirstWeek = 4
        return week
    }

    static func weekNumber(of date: Date, calendar: Calendar) -> Int {
        weekCalendar(from: calendar).component(.weekOfYear, from: date)
    }

    /// Monday 00:00 of the week containing `date`.
    static func startOfWeek(containing date: Date, calendar: Calendar) -> Date {
        let week = weekCalendar(from: calendar)
        let day = week.startOfDay(for: date)
        let weekday = week.component(.weekday, from: day)
        let offset = (weekday - week.firstWeekday + 7) % 7
        return week.date(byAdding: .day, value: -offset, to: day) ?? day
    }

    /// Things the user did per day (start of day): sessions started, posts saved and tasks
    /// finished. Counts only; no text is read.
    static func activity(content: [MioContentItem], sessionStarts: [Date], calendar: Calendar) -> [Date: Int] {
        var counts: [Date: Int] = [:]
        func add(_ date: Date) { counts[calendar.startOfDay(for: date), default: 0] += 1 }
        sessionStarts.forEach(add)
        for item in content where item.kind != .timeline {
            add(item.createdAt)
            if let completed = item.completedAt { add(completed) }
        }
        return counts
    }
}

enum MioDayPhase: String, Sendable, Equatable {
    case morning, school, evening

    /// 05–10 morgon, 10–17 skoldag, otherwise kväll.
    static func at(_ date: Date, calendar: Calendar) -> MioDayPhase {
        switch calendar.component(.hour, from: date) {
        case 5..<10: .morning
        case 10..<17: .school
        default: .evening
        }
    }
}

struct MioWeekDay: Identifiable, Hashable, Sendable {
    let date: Date
    let isToday: Bool
    let isFuture: Bool
    let activity: Int
    var id: Date { date }

    /// 0 to 3 for the ribbon's fill marks.
    var level: Int { min(activity, 3) }
}

struct MioWeekOverview: Sendable, Equatable {
    let weekNumber: Int
    let days: [MioWeekDay]

    static func make(containing date: Date, today: Date, activity: [Date: Int], calendar: Calendar) -> MioWeekOverview {
        let monday = MioWeekPlanner.startOfWeek(containing: date, calendar: calendar)
        let startOfToday = calendar.startOfDay(for: today)
        let days = (0..<7).compactMap { offset -> MioWeekDay? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: monday) else { return nil }
            let start = calendar.startOfDay(for: day)
            return MioWeekDay(date: start, isToday: start == startOfToday, isFuture: start > startOfToday,
                              activity: activity[start] ?? 0)
        }
        return MioWeekOverview(weekNumber: MioWeekPlanner.weekNumber(of: date, calendar: calendar), days: days)
    }
}

/// Twelve week columns, Monday at the top, ending with the current week.
struct MioStreakGrid: Sendable, Equatable {
    static let weekCount = 12

    let weeks: [[MioWeekDay]]
    let weekNumbers: [Int]
    let activeDays: Int
    /// Days in a row with activity, counted back from today. An empty today does not break it yet.
    let currentRun: Int

    static func make(today: Date, activity: [Date: Int], calendar: Calendar) -> MioStreakGrid {
        let thisMonday = MioWeekPlanner.startOfWeek(containing: today, calendar: calendar)
        var weeks: [[MioWeekDay]] = []
        var numbers: [Int] = []
        for back in stride(from: weekCount - 1, through: 0, by: -1) {
            guard let monday = calendar.date(byAdding: .day, value: -7 * back, to: thisMonday) else { continue }
            let week = MioWeekOverview.make(containing: monday, today: today, activity: activity, calendar: calendar)
            weeks.append(week.days)
            numbers.append(week.weekNumber)
        }
        let active = weeks.joined().filter { !$0.isFuture && $0.activity > 0 }.count

        var run = 0
        var day = calendar.startOfDay(for: today)
        if (activity[day] ?? 0) == 0, let yesterday = calendar.date(byAdding: .day, value: -1, to: day) {
            day = calendar.startOfDay(for: yesterday)
        }
        while (activity[day] ?? 0) > 0 {
            run += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = calendar.startOfDay(for: previous)
        }
        return MioStreakGrid(weeks: weeks, weekNumbers: numbers, activeDays: active, currentRun: run)
    }
}

/// The single next thing Hem shows. Plans and tasks for the chosen day come first, then the
/// oldest unfinished task from earlier days.
enum MioNextUp: Equatable, Sendable {
    case upcoming(MioContentItem)
    case overdue(MioContentItem)
    case none

    /// Items that started up to 30 minutes ago still count as next, so a lesson that just
    /// began stays on screen.
    static func make(content: [MioContentItem], now: Date, calendar: Calendar) -> MioNextUp {
        let startOfToday = calendar.startOfDay(for: now)
        guard let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) else { return .none }
        let open = content.filter { ($0.kind == .plan || ($0.kind == .task && !$0.isCompleted)) }
            .sorted { $0.scheduledAt == $1.scheduledAt ? $0.id.uuidString < $1.id.uuidString : $0.scheduledAt < $1.scheduledAt }
        let recent = now.addingTimeInterval(-30 * 60)
        if let next = open.first(where: { $0.scheduledAt >= max(recent, startOfToday) && $0.scheduledAt < endOfToday }) {
            return .upcoming(next)
        }
        if let late = open.first(where: { $0.kind == .task && $0.scheduledAt < startOfToday }) { return .overdue(late) }
        return .none
    }
}

/// Hem from 0.9.1: Reminders owns tasks, so Nästa reads unfinished reminders on demand (never
/// stored). Calendar is never read. A reminder without a clock time counts for its whole day.
enum MioReminderNext: Equatable, Sendable {
    case upcoming(MioReminderSummary)
    case overdue(MioReminderSummary)
    case none

    /// Today's next reminder, timed ones up to 30 minutes late included; otherwise the oldest
    /// one left from an earlier day.
    static func make(reminders: [MioReminderSummary], now: Date, calendar: Calendar) -> MioReminderNext {
        let startOfToday = calendar.startOfDay(for: now)
        guard let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) else { return .none }
        let dated = MioReminderDay.sortedByDue(reminders)
        let recent = now.addingTimeInterval(-30 * 60)
        for reminder in dated {
            guard let due = reminder.dueDate, due >= startOfToday, due < endOfToday else { continue }
            if !reminder.hasTime || due >= recent { return .upcoming(reminder) }
        }
        if let late = dated.first(where: { ($0.dueDate ?? .distantFuture) < startOfToday }) { return .overdue(late) }
        return .none
    }
}

/// The reminders shown in Hem's morning overview for one day.
struct MioReminderDay: Equatable, Sendable {
    let due: [MioReminderSummary]
    /// Left from earlier days; only listed for today.
    let overdue: [MioReminderSummary]

    static func make(reminders: [MioReminderSummary], date: Date, today: Date, calendar: Calendar) -> MioReminderDay {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let sorted = sortedByDue(reminders)
        let isToday = calendar.isDate(date, inSameDayAs: today)
        let due = sorted.filter { reminder in reminder.dueDate.map { $0 >= start && $0 < end } ?? false }
        let overdue = isToday ? sorted.filter { reminder in reminder.dueDate.map { $0 < start } ?? false } : []
        return MioReminderDay(due: due, overdue: overdue)
    }

    /// Dated reminders by due time, then identifier; undated ones are left out.
    static func sortedByDue(_ reminders: [MioReminderSummary]) -> [MioReminderSummary] {
        reminders.filter { $0.dueDate != nil }.sorted { left, right in
            let a = left.dueDate ?? .distantFuture, b = right.dueDate ?? .distantFuture
            return a == b ? left.id < right.id : a < b
        }
    }
}
