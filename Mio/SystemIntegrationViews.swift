import SwiftUI
import UIKit

/// Inställningar → Notiser (0.9.1, fas 5): the optional morning and evening notifications and
/// their times. Tasks,
/// events and their alerts belong to Reminders and Calendar; "Tryck för att fortsätta lyssna"
/// is sent automatically when iOS refuses to restart the microphone.
struct MioNotificationSettingsView: View {
    @Bindable var service: MioSystemServices
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MioDailyDigest.morningDetailKey) private var morningDetail = false

    init(service: MioSystemServices? = nil) { self.service = service ?? .shared }

    var body: some View {
        List {
            Section {
                LabeledContent("Notiser", value: service.notificationStatusText)
                Button("Öppna iPhones inställningar", systemImage: "gear") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            } header: {
                Text("Behörighet")
            } footer: {
                Text("Påminnelser om att göra och händelser kommer från Påminnelser och Kalender. Ingen notis startar mikrofonen.")
            }

            Section {
                SystemServiceMessages(service: service)
            }

            Section {
                ForEach(MioDailyReminder.allCases) { kind in
                    DailyReminderControls(kind: kind, service: service)
                }
                Toggle("Visa dagens prov och läxor i morgonnotisen", isOn: $morningDetail)
                    .accessibilityIdentifier("mio.notifications.morning-detail")
            } header: {
                Text("Morgon och kväll")
            } footer: {
                Text("Båda är avstängda tills du sparar en tid. Morgonnotisen säger bara att översikten finns, om du inte slår på prov och läxor: då står ämnen och orden prov och läxa på låsskärmen, men aldrig rubriker eller anteckningar. Kvällsnotisen säger hur många förslag som väntar och öppnar Förslag.")
            }
        }
        .mioListGround()
        .navigationTitle("Notiser")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(service.isBusy)
        .refreshable { await service.refresh() }
        .task { await service.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await service.refresh() } }
        }
        .onChange(of: morningDetail) { _, _ in Task { await service.replanDailyNotices() } }
    }
}

@MainActor
private struct DailyReminderControls: View {
    let kind: MioDailyReminder
    @Bindable var service: MioSystemServices
    @State private var time: Date = .now

    /// The repeating request or the next planned day (fas 5 plans the evening one day at a time).
    private var existing: MioPendingReminder? {
        service.reminders.filter { MioDailyDigest.belongs($0.id, to: kind.id) }
            .min { ($0.nextDate ?? .distantFuture) < ($1.nextDate ?? .distantFuture) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind.title).font(.headline)
            if let next = existing?.nextDate {
                Text("Aktiv, nästa \(next.formatted(date: .abbreviated, time: .shortened))").font(.footnote)
            } else {
                Text("Av").font(.footnote).foregroundStyle(.secondary)
            }
            DatePicker("Tid", selection: $time, displayedComponents: .hourAndMinute)
            HStack {
                Button("Spara") { Task { await service.scheduleDailyReminder(kind, time: time) } }
                    .accessibilityLabel("Spara \(kind.title.lowercased())")
                if existing != nil {
                    Spacer()
                    Button("Stäng av", role: .destructive) { Task { await service.cancelDailyReminder(kind) } }
                        .accessibilityLabel("Stäng av \(kind.title.lowercased())")
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .onAppear {
            time = existing?.nextDate ?? Calendar.current.date(bySettingHour: kind.defaultHour, minute: 0, second: 0, of: .now) ?? .now
        }
    }
}

@MainActor
private struct SystemServiceMessages: View {
    @Bindable var service: MioSystemServices

    var body: some View {
        if let error = service.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
        }
        if let status = service.statusMessage {
            Label(status, systemImage: "info.circle").font(.footnote)
        }
        if service.isBusy { ProgressView("Arbetar…") }
    }
}
