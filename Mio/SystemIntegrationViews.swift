import SwiftUI
import UIKit

/// Inställningar → Notiser (0.9.1): only the optional morning and evening notifications. Tasks,
/// events and their alerts belong to Reminders and Calendar; "Tryck för att fortsätta lyssna"
/// is sent automatically when iOS refuses to restart the microphone.
struct MioNotificationSettingsView: View {
    @Bindable var service: MioSystemServices
    @Environment(\.scenePhase) private var scenePhase

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
            } header: {
                Text("Morgon och kväll")
            } footer: {
                Text("Dagliga notiser är valfria. De innehåller bara en uppmaning att öppna Mio; översikten beräknas på telefonen när du öppnar appen. Att ändra en tid kräver Spara.")
            }
        }
        .navigationTitle("Notiser")
        .disabled(service.isBusy)
        .refreshable { await service.refresh() }
        .task { await service.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await service.refresh() } }
        }
    }
}

@MainActor
private struct DailyReminderControls: View {
    let kind: MioDailyReminder
    @Bindable var service: MioSystemServices
    @State private var time: Date = .now

    private var existing: MioPendingReminder? { service.reminders.first { $0.id == kind.id } }

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
                    Button("Stäng av", role: .destructive) { Task { await service.cancelReminder(id: kind.id) } }
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
