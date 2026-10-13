import AlarmKit
import EventKit
import EventKitUI
import SwiftUI
import UIKit

/// EventKitUI runs the editor outside this process. Mio requests no calendar read access.
@MainActor
struct CalendarEventComposer: UIViewControllerRepresentable {
    let item: MioContentItem
    var onCompletion: (Bool) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        let store = context.coordinator.store
        let event = EKEvent(eventStore: store)
        event.title = item.title
        event.notes = item.body.isEmpty ? nil : item.body
        event.startDate = item.scheduledAt
        event.endDate = item.scheduledAt.addingTimeInterval(60 * 60)
        event.isAllDay = item.allDay
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let store = EKEventStore()
        let parent: CalendarEventComposer

        init(parent: CalendarEventComposer) { self.parent = parent }

        nonisolated func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            let didSave = action == .saved
            // The delegate requirement is nonisolated; only the outcome crosses to UI state.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.parent.onCompletion(didSave)
                self.parent.dismiss()
            }
        }
    }
}

/// Insert in a Form for an already-saved item; edits to the item remain local.
@MainActor
struct ContentSystemActionsView: View {
    let item: MioContentItem
    @Bindable var service: MioSystemServices
    @State private var showCalendarReview = false
    @State private var showCalendarComposer = false
    @State private var showAlarmEditor = false
    @State private var showReminderEditor = false
    @State private var calendarMessage: String?

    init(item: MioContentItem, service: MioSystemServices? = nil) {
        self.item = item
        self.service = service ?? .shared
    }

    var body: some View {
        Section {
            Button("Lägg en kopia i Kalender", systemImage: "calendar.badge.plus") {
                showCalendarReview = true
            }
            Button("Påminn mig om posten", systemImage: "bell.badge") {
                showReminderEditor = true
            }
            Button("Skapa eller ändra postens alarm", systemImage: "alarm") {
                showAlarmEditor = true
            }
            if let reminder = service.reminders.first(where: { $0.id == MioSystemServices.reminderID(for: item.id) }) {
                if let date = reminder.nextDate {
                    LabeledContent("Påminnelse", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                Button("Ta bort postens påminnelse", role: .destructive) {
                    Task { await service.cancelReminder(id: reminder.id) }
                }
            }
            if let alarm = service.alarms.first(where: { $0.id == item.id }) {
                LabeledContent("Alarm", value: MioSystemServices.alarmDescription(alarm))
                Button("Ta bort postens alarm", role: .destructive) {
                    Task { await service.cancelAlarm(id: item.id) }
                }
            }
            if let calendarMessage { Text(calendarMessage).font(.footnote) }
            SystemServiceMessages(service: service)
        } header: {
            Text("Kalender och påminnelser")
        } footer: {
            Text("Åtgärderna använder den sparade posten. Kalendern får en fristående kopia som kan synkas via ditt kalenderkonto. Ändringar här uppdaterar inte kopian. Alarm och notiser visar bara generell Mio-text på låsskärmen.")
        }
        .disabled(service.isBusy)
        .task { await service.refresh() }
        .confirmationDialog("Förhandsgranska kalenderkopian?", isPresented: $showCalendarReview, titleVisibility: .visible) {
            Button("Öppna kalenderns editor") { showCalendarComposer = true }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Rubrik, text och vald tid visas i kalenderns editor. Kontrollera kalenderkonto, sluttid och innehåll innan du väljer Lägg till. En ny kopia skapas varje gång du sparar där.")
        }
        .sheet(isPresented: $showCalendarComposer) {
            CalendarEventComposer(item: item) { saved in
                if saved { calendarMessage = "En kopia sparades i den valda kalendern. Hantera kopian i Kalender." }
            }
        }
        .sheet(isPresented: $showAlarmEditor) {
            MioAlarmEditor(
                service: service,
                alarm: service.alarms.first(where: { $0.id == item.id }),
                itemID: item.id,
                initialDate: item.scheduledAt
            )
        }
        .sheet(isPresented: $showReminderEditor) {
            MioReminderEditor(service: service, item: item)
        }
    }
}

@MainActor
struct SystemRemindersView: View {
    @Bindable var service: MioSystemServices
    @Environment(\.scenePhase) private var scenePhase
    @State private var showNewAlarm = false
    @State private var alarmToEdit: Alarm?
    @State private var showRemoveAll = false

    init(service: MioSystemServices? = nil) { self.service = service ?? .shared }

    var body: some View {
        List {
            Section {
                LabeledContent("Alarm", value: service.alarmStatusText)
                LabeledContent("Notiser", value: service.notificationStatusText)
                Button("Öppna iPhones inställningar", systemImage: "gear") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            } header: {
                Text("Behörigheter")
            } footer: {
                Text("Alarm kan höras även i tyst läge och under Fokus. Vanliga påminnelser följer notis- och fokusinställningarna. Ingenting startar mikrofonen.")
            }

            Section {
                SystemServiceMessages(service: service)
            }

            Section {
                Button("Nytt alarm", systemImage: "alarm.waves.left.and.right") { showNewAlarm = true }
                if service.alarms.isEmpty {
                    Text("Inga Mio-alarm är schemalagda.").foregroundStyle(.secondary)
                }
                ForEach(service.alarms, id: \.id) { alarm in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(MioSystemServices.alarmDescription(alarm)).font(.headline)
                        if alarm.state == .alerting {
                            Text("Ringer nu").foregroundStyle(.secondary)
                            Button("Stoppa", systemImage: "stop.circle") {
                                Task { await service.stopAlarm(id: alarm.id) }
                            }
                        }
                        HStack {
                            Button("Ändra") { alarmToEdit = alarm }
                            Spacer()
                            Button("Ta bort", role: .destructive) {
                                Task { await service.cancelAlarm(id: alarm.id) }
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Alarm")
            } footer: {
                Text("Alarm har systemljud och en stoppknapp. Engångsalarm försvinner när de har ringt och stoppats. Återkommande alarm fortsätter tills du tar bort dem. Ingen snooze ingår.")
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

            Section("Andra kommande påminnelser") {
                let others = service.reminders.filter { reminder in
                    !MioDailyReminder.allCases.contains(where: { $0.id == reminder.id })
                }
                if others.isEmpty {
                    Text("Öppna en sparad post och välj Påminn mig om posten.").foregroundStyle(.secondary)
                }
                ForEach(others) { reminder in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(reminder.title)
                        if let date = reminder.nextDate {
                            Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                        }
                        Button("Ta bort påminnelse", role: .destructive) {
                            Task { await service.cancelReminder(id: reminder.id) }
                        }
                    }
                }
            }

            Section {
                Button("Ta bort Mios alla alarm och påminnelser", role: .destructive) { showRemoveAll = true }
            } footer: {
                Text("Visar bara alarm och notiser skapade av Mio. Kalenderkopior hanteras separat i Kalender. Prova ett alarm på din telefon innan du använder funktionen för något viktigt.")
            }
        }
        .navigationTitle("Alarm och påminnelser")
        .disabled(service.isBusy)
        .refreshable { await service.refresh() }
        .task {
            await service.refresh()
            await service.observeAlarmUpdates()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await service.refresh() } }
        }
        .sheet(isPresented: $showNewAlarm) { MioAlarmEditor(service: service) }
        .sheet(item: $alarmToEdit) { alarm in MioAlarmEditor(service: service, alarm: alarm) }
        .confirmationDialog("Ta bort alla Mio-alarm och påminnelser?", isPresented: $showRemoveAll, titleVisibility: .visible) {
            Button("Ta bort alla", role: .destructive) { Task { await service.removeAll() } }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Även dagliga morgon- och kvällsnotiser tas bort. Dina lokala poster och kalenderkopior finns kvar.")
        }
    }
}

@MainActor
private struct MioAlarmEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var service: MioSystemServices
    let alarmID: UUID
    let isEditing: Bool
    @State private var date: Date
    @State private var repeats: Bool
    @State private var weekdays: Set<MioAlarmWeekday>

    init(service: MioSystemServices, alarm: Alarm? = nil, itemID: UUID? = nil, initialDate: Date? = nil) {
        self.service = service
        alarmID = alarm?.id ?? itemID ?? UUID()
        isEditing = alarm != nil
        var selectedDate = max(initialDate ?? .now.addingTimeInterval(120), .now.addingTimeInterval(120))
        var selectedDays: Set<MioAlarmWeekday> = []
        if let schedule = alarm?.schedule {
            switch schedule {
            case .fixed(let alarmDate): selectedDate = alarmDate
            case .relative(let relative):
                selectedDate = Calendar.current.date(bySettingHour: relative.time.hour, minute: relative.time.minute, second: 0, of: .now) ?? selectedDate
                if case .weekly(let days) = relative.repeats {
                    selectedDays = Set(MioAlarmWeekday.allCases.filter { days.contains($0.value) })
                }
            @unknown default: break
            }
        }
        _date = State(initialValue: selectedDate)
        _repeats = State(initialValue: !selectedDays.isEmpty)
        _weekdays = State(initialValue: selectedDays)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Upprepa varje vecka", isOn: $repeats)
                    DatePicker("Alarmtid", selection: $date, displayedComponents: repeats ? [.hourAndMinute] : [.date, .hourAndMinute])
                    if repeats {
                        ForEach(MioAlarmWeekday.allCases) { day in
                            Toggle(day.title, isOn: Binding(
                                get: { weekdays.contains(day) },
                                set: { enabled in
                                    if enabled { weekdays.insert(day) } else { weekdays.remove(day) }
                                }
                            ))
                        }
                    }
                } footer: {
                    Text(repeats ? "Välj minst en veckodag. Tiden följer telefonens tidszon." : "Engångsalarmet gäller det valda datumet och tidpunkten, även om du senare byter tidszon.")
                }
                Section {
                    Label("Låsskärmen visar Mio-alarm", systemImage: "lock")
                    Text("Systemljud och Stoppa. Alarm kan bryta igenom tyst läge och Fokus. Alarmet startar ingen inspelning.")
                    SystemServiceMessages(service: service)
                }
            }
            .navigationTitle(isEditing ? "Ändra alarm" : "Nytt alarm")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Spara alarm") {
                        Task {
                            let days = repeats ? MioAlarmWeekday.allCases.filter { weekdays.contains($0) }.map(\.value) : []
                            if await service.scheduleAlarm(id: alarmID, date: date, weekdays: days) { MioFeedback.success(); dismiss() }
                        }
                    }
                    .disabled(service.isBusy || (repeats && weekdays.isEmpty))
                }
            }
            .disabled(service.isBusy)
            .interactiveDismissDisabled(service.isBusy)
        }
    }
}

@MainActor
private struct MioReminderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var service: MioSystemServices
    let item: MioContentItem
    @State private var date: Date

    init(service: MioSystemServices, item: MioContentItem) {
        self.service = service
        self.item = item
        let existing = service.reminders.first { $0.id == MioSystemServices.reminderID(for: item.id) }?.nextDate
        _date = State(initialValue: max(existing ?? item.scheduledAt, .now.addingTimeInterval(120)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.title)
                    DatePicker("Påminn mig", selection: $date, displayedComponents: [.date, .hourAndMinute])
                } footer: {
                    Text("Spara ersätter en eventuell tidigare påminnelse för posten. Notisen visar bara generell Mio-text och öppnar appen. Ljud och Fokus styrs av iPhones inställningar.")
                }
                SystemServiceMessages(service: service)
            }
            .navigationTitle("Påminnelse")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Spara påminnelse") {
                        Task { if await service.scheduleReminder(for: item.id, at: date) { MioFeedback.success(); dismiss() } }
                    }
                }
            }
            .disabled(service.isBusy)
            .interactiveDismissDisabled(service.isBusy)
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
