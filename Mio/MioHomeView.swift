import EventKit
import SwiftUI

/// Hem: the week planner. Week number and seven days on top, then the next reminder, what
/// waits for review, the chosen day's morning or evening overview, and twelve weeks of use.
/// From 0.9.1 tasks come from Reminders, read on demand and never stored; Calendar is not read.
struct MioHomeView: View {
    @Bindable var model: MioViewModel
    @Bindable var contentModel: MioContentViewModel
    @Environment(MioAssistantViewModel.self) private var assistant
    @Environment(MioDayContext.self) private var day
    @Environment(MioNavigationCoordinator.self) private var navigation
    @Environment(MioAnalysisCoordinator.self) private var analysis
    @Environment(MioWorkflowCoordinator.self) private var workflow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openMioSettings) private var openSettings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(MioCloudSettings.serverKey) private var server = ""
    @AppStorage(MioAIPreference.enabledKey) private var aiEnabled = MioAIPreference.defaultEnabled
    @State private var showAsk = false
    @State private var reminders: [MioReminderSummary] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    weekHeader
                    MioWeekRibbon(week: week, selectedDate: day.overviewDate, calendar: day.calendar) { day.select($0) }
                    errors
                    if isTodaySelected {
                        MioSectionTitle("Nästa")
                        nextPanel
                    }
                    reviewRow
                    aiStatus
                    overview
                    MioSectionTitle("Tolv veckor")
                    MioPanel { MioStreakGridView(grid: streak) }
                }
                .frame(maxWidth: 680)
                .padding(.horizontal)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .mioGround()
            .navigationTitle("v. \(String(week.weekNumber))")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fråga Mio", systemImage: "bubble.left.and.text.bubble.right") { showAsk = true }
                        .accessibilityIdentifier("mio.home.ask")
                }
                MioSettingsToolbar()
            }
            .sheet(isPresented: $showAsk) {
                MioAskSheet(items: contentModel.items, sessions: model.allSessions)
            }
            .task(id: day.overviewDate) { await loadReminders() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await loadReminders() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
                Task { await loadReminders() }
            }
        }
    }

    /// Overdue reminders and those due up to the end of the later of today and the chosen day.
    private func loadReminders() async {
        let chosen = day.calendar.startOfDay(for: day.overviewDate)
        let end = day.calendar.date(byAdding: .day, value: 1, to: max(chosen, day.startOfToday)) ?? chosen
        reminders = await workflow.reminders.upcoming(DateInterval(start: .distantPast, end: end))
    }

    // MARK: Week

    private var activity: [Date: Int] {
        MioWeekPlanner.activity(content: contentModel.items, sessionStarts: model.allSessions.map(\.startedAt),
                                calendar: day.calendar)
    }

    private var week: MioWeekOverview {
        MioWeekOverview.make(containing: day.overviewDate, today: day.startOfToday, activity: activity, calendar: day.calendar)
    }

    private var streak: MioStreakGrid {
        MioStreakGrid.make(today: day.startOfToday, activity: activity, calendar: day.calendar)
    }

    private var isTodaySelected: Bool { day.calendar.isDate(day.overviewDate, inSameDayAs: day.startOfToday) }

    private var weekHeader: some View {
        HStack(spacing: 4) {
            Text(day.overviewDate.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(MioTheme.swedish)).mioSentenceCased)
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            if !isTodaySelected {
                Button("I dag") { day.select(day.startOfToday) }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
            Button { shiftWeek(-1) } label: {
                Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Förra veckan")
            Button { shiftWeek(1) } label: {
                Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Nästa vecka")
        }
    }

    private func shiftWeek(_ weeks: Int) {
        guard let date = day.calendar.date(byAdding: .day, value: 7 * weeks, to: day.overviewDate) else { return }
        day.select(date)
    }

    // MARK: Next

    @ViewBuilder
    private var nextPanel: some View {
        let next = nextUp
        MioPanel {
            switch next {
            case .upcoming(let reminder):
                reminderLine(reminder, timeText: dueText(reminder, relativeTo: .now))
            case .overdue(let reminder):
                reminderLine(reminder, timeText: "Kvar sedan \(dueText(reminder, relativeTo: .now))")
            case .none where server.isEmpty:
                // Unpaired, pairing is the one real next step, so it leads instead of "Klart för i dag".
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        Text("Para datorn för text och AI.")
                    } else {
                        Label("Para datorn för text och AI.", systemImage: "desktopcomputer")
                    }
                }
                .font(.body)
                .foregroundStyle(.secondary)
                Button(action: openSettings) {
                    Text("Para")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .accessibilityIdentifier("mio.home.pair")
            case .none:
                Text(emptyNextText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                if canStartListening {
                    Button {
                        navigation.selectedTab = .capture
                        model.beginListening()
                    } label: {
                        Label("Starta Mio", systemImage: "mic.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .accessibilityIdentifier("mio.home.start")
                }
            }
        }
    }

    private var nextUp: MioReminderNext {
        MioReminderNext.make(reminders: reminders, now: .now, calendar: day.calendar)
    }

    private var emptyNextText: String {
        switch MioDayPhase.at(.now, calendar: day.calendar) {
        case .morning: "Inget planerat i dag."
        case .school: "Inget mer planerat i dag."
        case .evening: "Klart för i dag."
        }
    }

    private var canStartListening: Bool {
        [.off, .failed, .unavailable].contains(model.runState) && !server.isEmpty
    }

    /// A reminder as Reminders shows it; Mio does not change or complete it.
    private func reminderLine(_ reminder: MioReminderSummary, timeText: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "checklist")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title).font(.body.weight(.medium))
                Text(timeText).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private func dueText(_ reminder: MioReminderSummary, relativeTo date: Date) -> String {
        guard let due = reminder.dueDate else { return "Utan datum" }
        return MioTimeText.describe(due, relativeTo: date, calendar: day.calendar, allDay: !reminder.hasTime)
    }

    // MARK: Review and status

    @ViewBuilder
    private var reviewRow: some View {
        let pending = assistant.pendingCount
        let waiting = assistant.suggestions.count - pending
        if pending > 0 || waiting > 0 {
            NavigationLink {
                SuggestionInboxView(contentModel: contentModel, sessionModel: model)
                    .mioListGround()
            } label: {
                MioPanel {
                    HStack(spacing: 12) {
                        Image(systemName: pending > 0 ? "tray.full.fill" : "tray")
                            .font(.title3)
                            .foregroundStyle(MioTheme.tint)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pending > 0 ? "\(pending) att granska" : "Inget nytt att granska")
                                .font(.headline)
                            if waiting > 0 {
                                Text("\(waiting) sparade till senare")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mio.home.review")
        }
    }

    /// Unpaired, paused by the user or waiting on quota; otherwise when AI last answered, so an
    /// answer without proposals still shows that AI ran.
    @ViewBuilder
    private var aiStatus: some View {
        if server.isEmpty {
            // The Nästa panel already carries the pairing step when nothing else is next.
            if !(isTodaySelected && nextUp == .none) {
                statusLine("Para datorn för att få text och AI.", symbol: "desktopcomputer", action: "Para", perform: openSettings)
            }
        } else if !aiEnabled {
            statusLine("AI är pausad.", symbol: "pause.circle", action: "Slå på") { aiEnabled = true }
        } else if let until = analysis.pausedUntil, until > .now {
            statusLine("AI fortsätter \(MioTimeText.describe(until, relativeTo: .now, calendar: day.calendar)).",
                       symbol: "clock", action: nil, perform: {})
        } else if let lag = MioAnalysisSchedule.lagMinutes(oldest: analysis.pendingEverydaySince, now: .now) {
            statusLine("AI ligger \(lag) min efter. Förslag kan komma senare.", symbol: "hourglass", action: nil, perform: {})
        } else if let review = latestReview {
            // Opens the session, where every AI answer and its questions about the text are listed.
            NavigationLink {
                SessionEditorView(sessionID: review.sessionID, contentModel: contentModel, sessionModel: model)
            } label: {
                HStack(spacing: 10) {
                    Label("AI granskade senast \(MioTimeText.describe(review.reviewedAt, relativeTo: .now, calendar: day.calendar)) · \(review.outcome)",
                          systemImage: "text.magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mio.home.ai-review")
        }
    }

    private var latestReview: MioEverydayReview? {
        MioEverydayReview.make(records: assistant.analyses, decisions: assistant.analysisDecisions,
                               excludingSessionIDs: Set(model.allSessions.filter(\.isLesson).map(\.id))).first
    }

    private func statusLine(_ text: String, symbol: String, action: String?, perform: @escaping () -> Void) -> some View {
        // At accessibility sizes the button moves below the text instead of squeezing it.
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            Label(text, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !stacked { Spacer(minLength: 8) }
            if let action {
                Button(action, action: perform)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var errors: some View {
        ForEach(Array([model.errorMessage, contentModel.errorMessage, assistant.errorMessage].compactMap { $0 }.enumerated()),
                id: \.offset) { _, message in
            MioPanel {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: Day overview (formerly Morgon and Kväll)

    private var briefing: MioBriefing {
        MioBriefing.make(content: contentModel.items, sessions: model.allSessions, lessons: assistant.lessons,
                         date: day.overviewDate, calendar: day.calendar)
    }

    private var reminderDay: MioReminderDay {
        MioReminderDay.make(reminders: reminders, date: day.overviewDate, today: day.startOfToday, calendar: day.calendar)
    }

    /// Records of what was handed to Apple's apps on the chosen day.
    private var sentToday: [MioContentItem] {
        contentModel.items.filter { item in
            item.handoff.map { day.calendar.isDate($0.sentAt, inSameDayAs: day.overviewDate) } ?? false
        }.sorted { ($0.handoff?.sentAt ?? .distantPast) < ($1.handoff?.sentAt ?? .distantPast) }
    }

    @ViewBuilder
    private var overview: some View {
        @Bindable var navigation = navigation
        let stacked = dynamicTypeSize.isAccessibilitySize
        let header = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout())
        header {
            MioSectionTitle(isTodaySelected ? "I dag" : "Dagen")
            Picker("Översikt", selection: $navigation.dailyPeriod) {
                Text("Morgon").tag(MioDailyPeriod.morning)
                Text("Kväll").tag(MioDailyPeriod.evening)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: stacked ? .infinity : 200)
            .padding(.top, stacked ? 0 : 8)
        }
        MioPanel {
            if navigation.dailyPeriod == .evening {
                if sentToday.isEmpty {
                    Text("Inget skickat den här dagen.").foregroundStyle(.secondary)
                } else {
                    groupTitle("Skickat")
                    ForEach(sentToday) { item in
                        MioItemRow(item: item, timeText: item.handoff.map {
                            "\($0.destination.title) · \(MioTimeText.describe($0.sentAt, relativeTo: day.overviewDate, calendar: day.calendar))"
                        } ?? "")
                    }
                }
                Divider()
                Label("\(briefing.sessionCount) sessioner · \(briefing.lessonCount) lektioner", systemImage: "waveform")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                let today = reminderDay
                if today.due.isEmpty && today.overdue.isEmpty {
                    Text(reminders.isEmpty && workflow.reminders.access() != .granted
                         ? "Att göra visas här när Mio får läsa Påminnelser. Det frågar Mio första gången du skickar en att göra-post."
                         : "Inget att göra den här dagen.")
                        .foregroundStyle(.secondary)
                }
                if !today.due.isEmpty {
                    groupTitle("Att göra")
                    ForEach(today.due) { reminderLine($0, timeText: dueText($0, relativeTo: day.overviewDate)) }
                }
                if !today.overdue.isEmpty {
                    groupTitle("Kvar sedan tidigare")
                    ForEach(today.overdue) { reminderLine($0, timeText: dueText($0, relativeTo: day.overviewDate)) }
                }
            }
        }
    }

    private func groupTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Fråga Mio as its own sheet, reachable from Hem and Fånga.
struct MioAskSheet: View {
    let items: [MioContentItem]
    let sessions: [MioSession]
    @Environment(\.dismiss) private var dismiss
    @Environment(MioDayContext.self) private var day

    var body: some View {
        NavigationStack {
            CloudAssistantView(items: items, sessions: sessions, suggestions: suggestions)
                .mioListGround()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Stäng") { dismiss() }
                    }
                }
        }
    }

    private var suggestions: [String] {
        let lessons = sessions.filter { $0.isLesson && $0.endedAt != nil }.compactMap(\.title)
        return MioSuggestedQuestions.make(content: items, lessonTitles: lessons, now: .now, calendar: day.calendar)
    }
}

private extension String {
    /// Swedish dates capitalize only the first letter ("Söndag 11 oktober").
    var mioSentenceCased: String { prefix(1).uppercased() + dropFirst() }
}
