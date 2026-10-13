#if canImport(EventKit)
import EventKit
import Foundation

/// Reminders through EventKit. Apple has no write-only level for reminders, so this needs full
/// access (NSRemindersFullAccessUsageDescription); calendar access is never requested.
/// EventKit objects stay inside this class: only plain values cross its boundary.
@MainActor
final class MioReminderStore {
    static let shared = MioReminderStore()
    private let store = EKEventStore()

    var access: MioReminderAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        // Denied, restricted and the legacy values all mean Mio may not write.
        default: .denied
        }
    }

    func requestAccess() async -> Bool {
        do { return try await store.requestFullAccessToReminders() }
        catch {
            MioLog.error(.storage, "reminders access request failed")
            return false
        }
    }

    func lists() -> [MioReminderList] {
        guard access == .granted else { return [] }
        return store.calendars(for: .reminder).filter(\.allowsContentModifications)
            .map { MioReminderList(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func defaultListID() -> String? {
        guard access == .granted else { return nil }
        return store.defaultCalendarForNewReminders()?.calendarIdentifier
    }

    func save(_ draft: MioReminderDraft) async throws -> String {
        guard access == .granted else { throw MioReminderError.accessDenied }
        // A retry after a failed local record must not create a second reminder.
        if let url = draft.url, let existing = await identifier(of: url) { return existing }
        guard let list = draft.listID.flatMap({ store.calendar(withIdentifier: $0) }) ?? store.defaultCalendarForNewReminders(),
              list.allowsContentModifications else { throw MioReminderError.saveFailed }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = draft.title
        reminder.notes = draft.notes.isEmpty ? nil : draft.notes
        reminder.url = draft.url
        if let due = draft.dueDate {
            let fields: Set<Calendar.Component> = draft.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(fields, from: due)
            // Like setting a time in Reminders yourself: a notification at that time.
            if draft.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
        }
        do { try store.save(reminder, commit: true) }
        catch {
            MioLog.error(.storage, "reminder save failed")
            throw MioReminderError.saveFailed
        }
        return reminder.calendarItemIdentifier
    }

    /// Unfinished reminders due before the end of the interval, overdue ones included.
    func upcoming(in interval: DateInterval) async -> [MioReminderSummary] {
        guard access == .granted else { return [] }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: interval.end, calendars: nil)
        let summaries: [MioReminderSummary] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let values = (reminders ?? []).map { reminder in
                    let components = reminder.dueDateComponents
                    return MioReminderSummary(id: reminder.calendarItemIdentifier, title: reminder.title ?? "",
                                              dueDate: components.flatMap { Calendar.current.date(from: $0) },
                                              hasTime: components?.hour != nil)
                }
                continuation.resume(returning: values)
            }
        }
        return summaries.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    private func identifier(of url: URL) async -> String? {
        let predicate = store.predicateForReminders(in: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).first { $0.url == url }?.calendarItemIdentifier)
            }
        }
    }
}
#endif
