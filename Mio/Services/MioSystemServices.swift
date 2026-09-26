import AlarmKit
import Foundation
import Observation
import SwiftUI
import UserNotifications

struct MioAlarmMetadata: AlarmMetadata {}

enum MioDailyReminder: String, CaseIterable, Identifiable {
    case morning
    case evening

    var id: String { "mio.daily.\(rawValue)" }
    var title: String { self == .morning ? "Morgonöversikt" : "Kvällsöversikt" }
    var defaultHour: Int { self == .morning ? 7 : 20 }
}

struct MioPendingReminder: Identifiable {
    let id: String
    let title: String
    let nextDate: Date?
    let repeats: Bool
}

/// System services are the source of truth; no private post text is persisted here.
@MainActor
@Observable
final class MioSystemServices {
    static let shared = MioSystemServices()

    private(set) var alarms: [Alarm] = []
    private(set) var reminders: [MioPendingReminder] = []
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var alarmStatus: AlarmManager.AuthorizationState = .notDetermined
    private(set) var isBusy = false
    var errorMessage: String?
    var statusMessage: String?

    @ObservationIgnored private let notificationCenter = UNUserNotificationCenter.current()
    @ObservationIgnored private let alarmManager = AlarmManager.shared
    @ObservationIgnored private var knownAlarmIDs: Set<UUID> = Set(
        (UserDefaults.standard.stringArray(forKey: "mio.alarm.identities") ?? []).compactMap(UUID.init(uuidString:))
    )

    var notificationStatusText: String {
        switch notificationStatus {
        case .notDetermined: "Efterfrågas när du sparar en påminnelse"
        case .denied: "Nekad – ändra i Inställningar"
        case .authorized: "Tillåten"
        case .provisional: "Tillåten utan ljud"
        case .ephemeral: "Tillfälligt tillåten"
        @unknown default: "Okänd behörighet"
        }
    }

    var alarmStatusText: String {
        switch alarmStatus {
        case .notDetermined: "Efterfrågas när du sparar ett alarm"
        case .denied: "Nekad – ändra i Inställningar"
        case .authorized: "Tillåten"
        @unknown default: "Okänd behörighet"
        }
    }

    func refresh() async {
        notificationStatus = await notificationCenter.notificationSettings().authorizationStatus
        let requests = await notificationCenter.pendingNotificationRequests()
        reminders = requests.filter { $0.identifier.hasPrefix("mio.") }.map { request in
            let trigger = request.trigger as? UNCalendarNotificationTrigger
            let daily = MioDailyReminder.allCases.first { $0.id == request.identifier }
            return MioPendingReminder(
                id: request.identifier,
                title: daily?.title ?? "Påminnelse om en Mio-post",
                nextDate: trigger?.nextTriggerDate(),
                repeats: trigger?.repeats ?? false
            )
        }.sorted {
            if $0.nextDate != $1.nextDate {
                return ($0.nextDate ?? .distantFuture) < ($1.nextDate ?? .distantFuture)
            }
            return $0.id < $1.id
        }
        alarmStatus = alarmManager.authorizationState
        if alarmStatus == .authorized {
            do {
                alarms = try alarmManager.alarms.sorted { $0.id.uuidString < $1.id.uuidString }
                rememberAlarmIDs(Set(alarms.map(\.id)))
            } catch {
                errorMessage = "Kunde inte läsa Mios alarm: \(error.localizedDescription)"
            }
        } else {
            alarms = []
        }
    }

    /// Run only while a management view is visible; cancellation stops observation.
    func observeAlarmUpdates() async {
        for await updated in alarmManager.alarmUpdates {
            guard !Task.isCancelled else { return }
            alarms = updated.sorted { $0.id.uuidString < $1.id.uuidString }
            alarmStatus = alarmManager.authorizationState
        }
    }

    @discardableResult
    func scheduleAlarm(id: UUID = UUID(), date: Date, weekdays: [Locale.Weekday] = []) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }
        guard !weekdays.isEmpty || date > .now.addingTimeInterval(5) else {
            errorMessage = "Välj en alarmtid minst några sekunder framåt."
            return false
        }
        do {
            alarmStatus = alarmManager.authorizationState
            if alarmStatus == .notDetermined {
                alarmStatus = try await alarmManager.requestAuthorization()
            }
            guard alarmStatus == .authorized else {
                errorMessage = "Alarm är inte tillåtna. Du kan ändra detta i iPhones Inställningar för Mio."
                return false
            }
            // A fixed/weekly alert uses the system stop action. No countdown or
            // snooze is offered, so no custom Live Activity extension is needed.
            let presentation = AlarmPresentation(alert: AlarmPresentation.Alert(
                title: "Mio-alarm",
                stopButton: AlarmButton(text: "Stoppa", textColor: .white, systemImageName: "stop.circle")
            ))
            let attributes = AlarmAttributes<MioAlarmMetadata>(presentation: presentation, tintColor: .indigo)
            let schedule: Alarm.Schedule
            if weekdays.isEmpty {
                schedule = .fixed(date)
            } else {
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                schedule = .relative(.init(
                    time: .init(hour: components.hour ?? 7, minute: components.minute ?? 0),
                    repeats: .weekly(weekdays)
                ))
            }
            let configuration = AlarmManager.AlarmConfiguration<MioAlarmMetadata>.alarm(
                schedule: schedule,
                attributes: attributes
            )
            _ = try await alarmManager.schedule(id: id, configuration: configuration)
            rememberAlarmIDs(knownAlarmIDs.union([id]))
            await refresh()
            statusMessage = "Alarmet är sparat hos iOS."
            return true
        } catch {
            errorMessage = "Kunde inte spara alarmet: \(error.localizedDescription)"
            await refresh()
            return false
        }
    }

    @discardableResult
    func cancelAlarm(id: UUID) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }
        do {
            try alarmManager.cancel(id: id)
            rememberAlarmIDs(knownAlarmIDs.subtracting([id]))
            await refresh()
            statusMessage = "Alarmet är borttaget."
            return true
        } catch {
            errorMessage = "Kunde inte ta bort alarmet: \(error.localizedDescription)"
            return false
        }
    }

    func stopAlarm(id: UUID) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }
        do {
            try alarmManager.stop(id: id)
            await refresh()
            statusMessage = "Alarmet är stoppat. Ett återkommande alarm finns kvar till nästa tillfälle."
        } catch {
            errorMessage = "Kunde inte stoppa alarmet: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func scheduleReminder(for itemID: UUID, at date: Date) async -> Bool {
        guard date > .now.addingTimeInterval(5) else {
            errorMessage = "Välj en påminnelsetid minst några sekunder framåt."
            return false
        }
        // The fixed timezone preserves the chosen instant if the user travels.
        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        components.timeZone = .current
        return await saveReminder(
            id: Self.reminderID(for: itemID),
            body: "Du har en påminnelse i Mio. Öppna appen för att se dina poster.",
            components: components,
            repeats: false
        )
    }

    @discardableResult
    func scheduleDailyReminder(_ kind: MioDailyReminder, time: Date) async -> Bool {
        // Hour/minute without a fixed timezone follows the device's local day.
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        let body = kind == .morning
            ? "Din morgonöversikt finns i Mio. Öppna appen när det passar."
            : "Din kvällsöversikt finns i Mio. Öppna appen när det passar."
        return await saveReminder(id: kind.id, body: body, components: components, repeats: true)
    }

    func cancelReminder(id: String) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [id])
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [id])
        await refresh()
        statusMessage = "Påminnelsen är borttagen."
    }

    /// Call before deleting a post, so a failed system cancellation remains visible.
    @discardableResult
    func cancelActions(for itemID: UUID) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }
        do {
            if alarmManager.authorizationState == .authorized {
                if try alarmManager.alarms.contains(where: { $0.id == itemID }) {
                    try alarmManager.cancel(id: itemID)
                }
                rememberAlarmIDs(knownAlarmIDs.subtracting([itemID]))
            } else if knownAlarmIDs.contains(itemID) {
                errorMessage = "Posten har haft ett Mio-alarm. Tillåt alarm i Inställningar igen så att Mio kan kontrollera och ta bort det innan posten raderas."
                return false
            }
            let id = Self.reminderID(for: itemID)
            notificationCenter.removePendingNotificationRequests(withIdentifiers: [id])
            notificationCenter.removeDeliveredNotifications(withIdentifiers: [id])
            await refresh()
            return true
        } catch {
            errorMessage = "Kunde inte ta bort postens alarm. Posten har inte raderats: \(error.localizedDescription)"
            return false
        }
    }

    /// Calendar copies belong to the user-selected calendar and are not deleted here.
    @discardableResult
    func removeAll() async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }
        do {
            if alarmManager.authorizationState == .authorized {
                let currentAlarms = try alarmManager.alarms
                for alarm in currentAlarms {
                    try alarmManager.cancel(id: alarm.id)
                }
                rememberAlarmIDs([])
            } else if !knownAlarmIDs.isEmpty {
                errorMessage = "Tillåt alarm i Inställningar igen så att Mio kan kontrollera tidigare alarm före total radering."
                return false
            }
            notificationCenter.removeAllPendingNotificationRequests()
            notificationCenter.removeAllDeliveredNotifications()
            await refresh()
            statusMessage = "Mios alarm och påminnelser är borttagna."
            return true
        } catch {
            errorMessage = "Alla alarm kunde inte tas bort. Kontrollera listan och försök igen: \(error.localizedDescription)"
            await refresh()
            return false
        }
    }

    static func reminderID(for itemID: UUID) -> String { "mio.reminder.\(itemID.uuidString)" }

    private func rememberAlarmIDs(_ ids: Set<UUID>) {
        knownAlarmIDs = ids
        if ids.isEmpty {
            UserDefaults.standard.removeObject(forKey: "mio.alarm.identities")
        } else {
            // Only identities are retained, so denied permission cannot silently
            // orphan a known alarm when its source post is deleted.
            UserDefaults.standard.set(ids.map(\.uuidString).sorted(), forKey: "mio.alarm.identities")
        }
    }

    static func alarmDescription(_ alarm: Alarm) -> String {
        guard let schedule = alarm.schedule else { return "Alarm" }
        switch schedule {
        case .fixed(let date):
            return date.formatted(date: .abbreviated, time: .shortened)
        case .relative(let relative):
            let time = String(format: "%02d:%02d", relative.time.hour, relative.time.minute)
            switch relative.repeats {
            case .never: return "\(time), nästa tillfälle"
            case .weekly(let weekdays):
                let names = MioAlarmWeekday.allCases.filter { weekdays.contains($0.value) }.map(\.shortTitle)
                return "\(time), \(names.joined(separator: ", "))"
            @unknown default: return time
            }
        @unknown default: return "Alarm"
        }
    }

    private func saveReminder(id: String, body: String, components: DateComponents, repeats: Bool) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }
        do {
            notificationStatus = await notificationCenter.notificationSettings().authorizationStatus
            if notificationStatus == .notDetermined {
                _ = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
                notificationStatus = await notificationCenter.notificationSettings().authorizationStatus
            }
            guard notificationStatus == .authorized || notificationStatus == .provisional else {
                errorMessage = "Notiser är inte tillåtna. Du kan ändra detta i iPhones Inställningar för Mio."
                return false
            }
            // Only generic text leaves the private app UI for notification surfaces.
            let content = UNMutableNotificationContent()
            content.title = "Mio"
            content.body = body
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: repeats)
            guard trigger.nextTriggerDate() != nil else {
                errorMessage = "Tidpunkten kunde inte schemaläggas. Välj en annan tid."
                return false
            }
            let pending = await notificationCenter.pendingNotificationRequests()
            // Leave room below iOS's pending notification limit; never silently evict.
            guard pending.contains(where: { $0.identifier == id }) || pending.count < 60 else {
                errorMessage = "Du har många kommande påminnelser. Ta bort någon innan du sparar fler."
                return false
            }
            try await notificationCenter.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            await refresh()
            statusMessage = "Påminnelsen är sparad. Notiser följer iPhones ljud- och fokusinställningar."
            return true
        } catch {
            errorMessage = "Kunde inte spara påminnelsen: \(error.localizedDescription)"
            return false
        }
    }
}

enum MioAlarmWeekday: Int, CaseIterable, Identifiable {
    case monday, tuesday, wednesday, thursday, friday, saturday, sunday

    var id: Int { rawValue }
    var value: Locale.Weekday {
        switch self {
        case .monday: .monday
        case .tuesday: .tuesday
        case .wednesday: .wednesday
        case .thursday: .thursday
        case .friday: .friday
        case .saturday: .saturday
        case .sunday: .sunday
        }
    }
    var title: String {
        switch self {
        case .monday: "Måndag"
        case .tuesday: "Tisdag"
        case .wednesday: "Onsdag"
        case .thursday: "Torsdag"
        case .friday: "Fredag"
        case .saturday: "Lördag"
        case .sunday: "Söndag"
        }
    }
    var shortTitle: String { String(title.prefix(3)).lowercased() }
}
