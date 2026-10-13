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
    @ObservationIgnored private var notificationDelegate: MioNotificationDelegate?
    @ObservationIgnored private let alarmManager = AlarmManager.shared
    @ObservationIgnored private var knownAlarmIDs: Set<UUID> = Set(
        (UserDefaults.standard.stringArray(forKey: "mio.alarm.identities") ?? []).compactMap(UUID.init(uuidString:))
    )

    func configureNotificationRouting(_ receive: @escaping @MainActor @Sendable (MioNotificationRoute) -> Void) {
        let delegate = MioNotificationDelegate(receive: receive)
        notificationDelegate = delegate
        notificationCenter.delegate = delegate
    }

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
                // The alarm list is a synchronous daemon read; keep it off the main actor.
                let current = try await Task.detached(priority: .userInitiated) { try AlarmManager.shared.alarms }.value
                alarms = current.sorted { $0.id.uuidString < $1.id.uuidString }
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
                alarmStatus = try await Self.requestAlarmAuthorization()
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
            _ = try await Self.scheduleAlarm(id: id, configuration: configuration)
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
            route: .post(itemID),
            components: components,
            repeats: false
        )
    }

    @discardableResult
    func scheduleDailyReminder(_ kind: MioDailyReminder, time: Date) async -> Bool {
        // Hour/minute without a fixed timezone follows the device's local day.
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        let route = kind == .morning ? MioNotificationRoute.morning : .evening
        return await saveReminder(id: kind.id, route: route, components: components, repeats: true)
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
        guard !isBusy else {
            // A stale message from another operation must not explain this failure.
            errorMessage = "En annan alarm- eller påminnelseåtgärd pågår. Vänta tills den är klar och försök igen."
            return false
        }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }
        let reminderID = Self.reminderID(for: itemID)
        let hadAlarm = knownAlarmIDs.contains(itemID)
        guard hadAlarm else {
            // Every alarm Mio schedules is remembered, so an unknown item has none. Skipping
            // AlarmKit here keeps completing a task independent of the alarm daemon, which can
            // stall; the simulator UI test never saw a completed task while this path ran.
            notificationCenter.removePendingNotificationRequests(withIdentifiers: [reminderID])
            notificationCenter.removeDeliveredNotifications(withIdentifiers: [reminderID])
            reminders.removeAll { $0.id == reminderID }
            return true
        }
        do {
            // AlarmKit and notification removal are synchronous daemon calls; running them
            // off the main actor keeps "Markera som klar" from freezing the UI.
            let removed = try await Task.detached(priority: .userInitiated) {
                try MioSystemServices.removeSystemEntries(itemID: itemID, reminderID: reminderID, hadAlarm: hadAlarm)
            }.value
            guard removed else {
                errorMessage = "Posten har haft ett Mio-alarm. Tillåt alarm i Inställningar igen så att Mio kan kontrollera och ta bort det innan posten raderas."
                return false
            }
            rememberAlarmIDs(knownAlarmIDs.subtracting([itemID]))
            await refresh()
            return true
        } catch {
            errorMessage = "Kunde inte ta bort postens alarm. Posten har inte raderats: \(error.localizedDescription)"
            return false
        }
    }

    // AlarmManager is not Sendable and its async methods are @concurrent. Calling them on the
    // main-actor `alarmManager` property would send main-actor state off the actor, so the two
    // async calls run nonisolated on the shared manager and only Sendable results come back.
    nonisolated private static func requestAlarmAuthorization() async throws -> AlarmManager.AuthorizationState {
        try await AlarmManager.shared.requestAuthorization()
    }

    nonisolated private static func scheduleAlarm(
        id: UUID, configuration: AlarmManager.AlarmConfiguration<MioAlarmMetadata>
    ) async throws -> Alarm {
        try await AlarmManager.shared.schedule(id: id, configuration: configuration)
    }

    /// Returns false, without removing anything, when a known Mio alarm cannot be checked
    /// because alarm permission was withdrawn. Uses only Sendable inputs and shared managers.
    nonisolated private static func removeSystemEntries(itemID: UUID, reminderID: String, hadAlarm: Bool) throws -> Bool {
        let manager = AlarmManager.shared
        if manager.authorizationState == .authorized {
            if try manager.alarms.contains(where: { $0.id == itemID }) {
                try manager.cancel(id: itemID)
            }
        } else if hadAlarm {
            return false
        }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminderID])
        center.removeDeliveredNotifications(withIdentifiers: [reminderID])
        return true
    }

    /// Calendar copies belong to the user-selected calendar and are not deleted here.
    @discardableResult
    func removeAll() async -> Bool {
        guard !isBusy else {
            // A stale message from another operation must not explain this failure.
            errorMessage = "En annan alarm- eller påminnelseåtgärd pågår. Vänta tills den är klar och försök igen."
            return false
        }
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

    /// One-time cleanup for 0.9.1 (user decision 2026-10-13): Mio no longer has alarms or post
    /// reminders, so every Mio alarm and every `mio.reminder.*` notification is removed. The
    /// morning and evening notifications and the resume notice stay.
    func removeLegacyActions() async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            // Without alarm permission no Mio alarm can ring, so nothing is left to cancel.
            if alarmManager.authorizationState == .authorized {
                for alarm in try alarmManager.alarms { try alarmManager.cancel(id: alarm.id) }
            }
            rememberAlarmIDs([])
        } catch {
            MioLog.error(.storage, "legacy alarm cleanup failed")
            return false
        }
        let pending = await notificationCenter.pendingNotificationRequests().map(\.identifier)
        let delivered = await notificationCenter.deliveredNotifications().map(\.request.identifier)
        let legacy = Array(Set(pending + delivered).filter { $0.hasPrefix("mio.reminder.") })
        notificationCenter.removePendingNotificationRequests(withIdentifiers: legacy)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: legacy)
        await refresh()
        return true
    }

    /// Outside the "mio." prefix so it never appears among the user's reminders.
    static let resumeListeningID = "app.mio.capture.resume-listening"

    /// Fallback when iOS refused a background microphone restart. Generic text only; it is
    /// delivered immediately and replaced rather than stacked. Failures stay silent because
    /// the session's event log already records the interruption.
    func handleResumeNotice(_ notice: MioResumeNotice) async {
        switch notice {
        case .prepare:
            let status = await notificationCenter.notificationSettings().authorizationStatus
            notificationStatus = status
            guard status == .notDetermined else { return }
            _ = try? await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
            notificationStatus = await notificationCenter.notificationSettings().authorizationStatus
        case .post:
            let status = await notificationCenter.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            let route = MioNotificationRoute.resumeListening
            let content = UNMutableNotificationContent()
            content.title = "Mio"
            content.body = route.notificationBody
            content.userInfo = route.userInfo
            content.sound = .default
            notificationCenter.removeDeliveredNotifications(withIdentifiers: [Self.resumeListeningID])
            try? await notificationCenter.add(UNNotificationRequest(identifier: Self.resumeListeningID,
                                                                   content: content, trigger: nil))
        case .withdraw:
            notificationCenter.removePendingNotificationRequests(withIdentifiers: [Self.resumeListeningID])
            notificationCenter.removeDeliveredNotifications(withIdentifiers: [Self.resumeListeningID])
        }
    }

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

    private func saveReminder(id: String, route: MioNotificationRoute, components: DateComponents, repeats: Bool) async -> Bool {
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
            content.body = route.notificationBody
            content.userInfo = route.userInfo
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

private final class MioNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let receive: @MainActor @Sendable (MioNotificationRoute) -> Void

    init(receive: @escaping @MainActor @Sendable (MioNotificationRoute) -> Void) { self.receive = receive }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        // Dismissal and unknown payloads only finish the native callback. Copy a
        // Sendable ID-only route before crossing to the main actor.
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let route = MioNotificationRoute(userInfo: response.notification.request.content.userInfo) else {
            completionHandler()
            return
        }
        Task { @MainActor [receive] in
            receive(route)
            completionHandler()
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
