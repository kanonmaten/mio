import SwiftUI
import UIKit

/// Förslag (0.9.1): proposals waiting for Ja, Nej or Inte nu, then what was handed to Apple's
/// apps. Nothing is created here by hand; write in Calendar, Reminders or Notes directly.
/// From 2026-11-20 also what "Mio, kom ihåg/notera" saved straight away, with Ångra for 24 hours.
struct SuggestionInboxView: View {
    @Environment(MioAssistantViewModel.self) private var assistant
    @Environment(MioWorkflowCoordinator.self) private var workflow
    let contentModel: MioContentViewModel
    let sessionModel: MioViewModel
    @State private var pendingDeletion: MioContentItem?
    @State private var deletionOutcome: MioOperationOutcome?
    @State private var undoOutcome: MioOperationOutcome?
    @State private var undoing: UUID?

    var body: some View {
        List {
            Section {
                Text("Förslag som Mio hittar skickas inte förrän du väljer Ja. Det du säger efter ”Mio, kom ihåg” eller ”Mio, notera” räknas som ett Ja och sparas direkt; du kan ångra det i 24 timmar. Kalenderhändelser väntar alltid här. Nej tar bort förslaget; originaltranskriptet påverkas inte.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if assistant.suggestions.isEmpty {
                ContentUnavailableView("Inga väntande förslag", systemImage: "checkmark.bubble", description: Text("När AI är på kommer förslag ur vanliga samtal hit. Kalenderhändelser du säger till Mio väntar också här."))
            }
            suggestionSection("Att granska", state: .pending)
            suggestionSection("Inte nu", state: .deferred)
            if !direct.isEmpty {
                Section {
                    ForEach(direct) { item in
                        directRow(item)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDeletion = item } label: { Label("Glöm", systemImage: "trash") }
                            }
                    }
                } header: {
                    Text("Sparat med rösten")
                } footer: {
                    Text("”Mio, kom ihåg” hamnar i Påminnelser och ”Mio, notera” sparas här som en Mio-anteckning. Ångra tar bort det helt och går att använda i 24 timmar.")
                }
            }
            if !sent.isEmpty {
                Section {
                    ForEach(sent) { item in
                        sentRow(item)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDeletion = item } label: { Label("Glöm", systemImage: "trash") }
                            }
                    }
                } header: {
                    Text("Skickat")
                } footer: {
                    Text("Ändra och bocka av i Kalender, Påminnelser eller Anteckningar. Mio sparar bara vart posten skickades och från vilken session.")
                }
            }
            if let error = assistant.errorMessage {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
        }
        .navigationTitle("Förslag")
        .confirmationDialog("Glöm att posten skickades?", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible) {
            if let item = pendingDeletion {
                Button("Glöm", role: .destructive) {
                    pendingDeletion = nil
                    Task { deletionOutcome = await workflow.deleteContent(id: item.id) }
                }
            }
            Button("Avbryt", role: .cancel) { pendingDeletion = nil }
        } message: {
            if let item = pendingDeletion, let handoff = item.handoff {
                Text("Posten i \(handoff.destination.title) finns kvar. Bara Mios notering försvinner.")
            } else if pendingDeletion != nil {
                Text("Mio-anteckningen raderas.")
            }
        }
        .alert("Kunde inte ångra", isPresented: Binding(
            get: { undoOutcome?.message != nil }, set: { if !$0 { undoOutcome = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(undoOutcome?.message ?? "Försök igen.")
        }
        .alert("Kunde inte glömma posten", isPresented: Binding(
            get: { deletionOutcome?.message != nil }, set: { if !$0 { deletionOutcome = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionOutcome?.message ?? "Försök igen.")
        }
    }

    private var sent: [MioContentItem] {
        contentModel.items.filter { $0.handoff != nil && $0.direct == nil }
            .sorted { ($0.handoff?.sentAt ?? .distantPast) > ($1.handoff?.sentAt ?? .distantPast) }
    }

    private var direct: [MioContentItem] {
        contentModel.items.filter { $0.direct != nil }
            .sorted { ($0.direct?.savedAt ?? .distantPast) > ($1.direct?.savedAt ?? .distantPast) }
    }

    /// A plain row, no navigation, so the Ångra button is the only thing to tap. A Mio note shows
    /// its whole text, which can be selected and copied.
    @ViewBuilder
    private func directRow(_ item: MioContentItem) -> some View {
        let destination = item.direct?.destination ?? .mioNote
        VStack(alignment: .leading, spacing: 6) {
            Label("\(destination.title) · \((item.direct?.savedAt ?? item.createdAt).formatted(date: .abbreviated, time: .shortened))",
                  systemImage: destination == .reminders ? "checklist" : "note.text")
                .font(.caption).foregroundStyle(.secondary)
            Text(item.title).font(.headline).textSelection(.enabled)
            if !item.body.isEmpty {
                Text(item.body).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if item.direct?.canUndo(at: .now) == true {
                Button(undoing == item.id ? "Ångrar …" : "Ångra") { undo(item) }
                    .buttonStyle(.bordered)
                    .disabled(undoing != nil)
                    .accessibilityHint(destination == .reminders ? "Tar bort påminnelsen ur Påminnelser" : "Raderar Mio-anteckningen")
            }
        }
        .padding(.vertical, 2)
    }

    private func undo(_ item: MioContentItem) {
        undoing = item.id
        Task {
            let result = await workflow.undoDirect(id: item.id)
            undoing = nil
            if !result.isSuccess { undoOutcome = result }
        }
    }

    @ViewBuilder
    private func sentRow(_ item: MioContentItem) -> some View {
        let session = item.sessionID.flatMap { sessionModel.session(id: $0) }
        if let session {
            NavigationLink {
                SessionEditorView(sessionID: session.id, contentModel: contentModel, sessionModel: sessionModel)
            } label: {
                ContentItemRow(item: item, linkedSessionTitle: nil)
            }
        } else {
            ContentItemRow(item: item, linkedSessionTitle: nil)
        }
    }

    @ViewBuilder
    private func suggestionSection(_ title: String, state: MioSuggestionState) -> some View {
        let suggestions = assistant.suggestions.filter { $0.state == state }
        if !suggestions.isEmpty {
            Section(title) {
                ForEach(suggestions) { suggestion in
                    NavigationLink {
                        if suggestion.purpose == .question {
                            SuggestedQuestionReviewView(suggestion: suggestion, contentModel: contentModel, sessionModel: sessionModel)
                        } else {
                            SuggestionReviewView(suggestion: suggestion, contentModel: contentModel, sessionModel: sessionModel)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(suggestion.purpose == .question ? "Fråga till AI"
                                    : suggestion.direct != nil ? "\(suggestion.kind.title), sagt till Mio" : suggestion.kind.title,
                                  systemImage: suggestion.purpose == .question ? "questionmark.bubble" : suggestion.kind.symbolName)
                                .font(.caption).foregroundStyle(.secondary)
                            Text(suggestion.title)
                        }
                    }
                }
            }
        }
    }
}

private struct SuggestedQuestionReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MioAssistantViewModel.self) private var assistant
    @Environment(MioWorkflowCoordinator.self) private var workflow
    @State private var outcome: MioOperationOutcome?
    let suggestion: MioSuggestion
    let contentModel: MioContentViewModel
    let sessionModel: MioViewModel
    @State private var question: String
    @State private var busy = false
    @State private var answered = false

    init(suggestion: MioSuggestion, contentModel: MioContentViewModel, sessionModel: MioViewModel) {
        self.suggestion = suggestion
        self.contentModel = contentModel
        self.sessionModel = sessionModel
        _question = State(initialValue: suggestion.questionText ?? suggestion.title)
    }

    var body: some View {
        Form {
            Section("Din lokala fråga") {
                TextEditor(text: $question).frame(minHeight: 120).accessibilityLabel("Fråga till AI")
                Text("Frågan har inte skickats. Du väljer eventuell kontext och godkänner den exakta sändningen i nästa steg.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if answered {
                    Text("Svaret har hämtats. Avsluta frågan för att ta bort den från inkorgen.")
                    Button("Avsluta frågan") { Task { await finishAnsweredQuestion() } }
                } else {
                    NavigationLink("Ja, förbered AI-frågan") {
                        CloudAssistantView(items: contentModel.items, sessions: sessionModel.allSessions,
                                           initialQuestion: question, onAnswerReceived: { answered = true })
                    }
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Button("Inte nu") {
                    Task {
                        busy = true
                        let result = await workflow.deferSuggestion(id: suggestion.id)
                        outcome = result
                        if result.isSuccess { dismiss() }
                        busy = false
                    }
                }
                Button("Nej, glöm frågan", role: .destructive) {
                    Task {
                        busy = true
                        let result = await workflow.rejectSuggestion(id: suggestion.id)
                        outcome = result
                        if result.isSuccess { dismiss() }
                        busy = false
                    }
                }
            }
            if let error = outcome?.message { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Vill du fråga Mio?")
        .disabled(busy)
        .task {
            // Keep the answer visible in the child view; close this completed
            // question only when the user returns from that view.
            if answered { await finishAnsweredQuestion() }
            else if !assistant.suggestions.contains(where: { $0.id == suggestion.id }) { dismiss() }
        }
    }

    private func finishAnsweredQuestion() async {
        busy = true
        let result = await workflow.finishQuestion(id: suggestion.id)
        outcome = result
        if result.isSuccess { MioFeedback.success(); dismiss() }
        busy = false
    }
}

/// Reviews one proposal and hands it to the Apple app that owns its kind (user decision
/// 2026-10-13, version 0.9.1): Händelse → Calendar's editor, Att göra → Reminders,
/// Anteckning and Minne → the share sheet for Notes. Nothing leaves Mio without Ja.
struct SuggestionReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(MioAssistantViewModel.self) private var assistant
    @Environment(MioWorkflowCoordinator.self) private var workflow
    let suggestion: MioSuggestion
    let contentModel: MioContentViewModel
    let sessionModel: MioViewModel
    @State private var kind: MioContentKind
    @State private var title: String
    @State private var text: String
    @State private var date: Date
    @State private var isAllDay: Bool
    @State private var hasDueDate: Bool
    @State private var listID: String?
    @State private var lists: [MioReminderList] = []
    @State private var reviewedDate = false
    @State private var dateChosen = false
    /// The date just copied from an updated suggestion. Its onChange is not a user edit, so it
    /// must not mark the date as chosen (ultrareview E4).
    @State private var appliedDate: Date?
    @State private var reviewedRevision: Int
    @State private var reviewedSuggestion: MioSuggestion
    @State private var outcome: MioOperationOutcome?
    @State private var busy = false
    @State private var showCalendar = false
    @State private var showShare = false

    init(suggestion: MioSuggestion, contentModel: MioContentViewModel, sessionModel: MioViewModel) {
        self.suggestion = suggestion
        self.contentModel = contentModel
        self.sessionModel = sessionModel
        _kind = State(initialValue: suggestion.kind == .timeline ? .note : suggestion.kind)
        _title = State(initialValue: suggestion.title)
        _text = State(initialValue: suggestion.body)
        _date = State(initialValue: suggestion.scheduledAt)
        _isAllDay = State(initialValue: suggestion.isAllDay == true)
        // A proposal from AI without a safe day has no due date until the user picks one.
        // A day she said herself after "Mio, kom ihåg" is kept as the due date.
        _hasDueDate = State(initialValue: (suggestion.evidence != nil && suggestion.needsDateConfirmation != true)
                            || suggestion.direct?.hasDate == true)
        _reviewedRevision = State(initialValue: suggestion.reviewRevision)
        _reviewedSuggestion = State(initialValue: suggestion)
    }

    var body: some View {
        Form {
            Section("Förhandsgranska och rätta") {
                Picker("Typ", selection: $kind) {
                    ForEach([MioContentKind.plan, .task, .note, .memory]) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                TextField("Rubrik", text: $title)
                TextEditor(text: $text).frame(minHeight: 100).accessibilityLabel("Det du sa")
                if kind == .task {
                    Toggle("Förfallodag", isOn: $hasDueDate)
                }
                if showsDate {
                    Toggle("Heldag", isOn: $isAllDay)
                    DatePicker(isAllDay ? "Datum" : "Datum och tid", selection: $date, displayedComponents: dateComponents)
                }
                if kind == .task, !lists.isEmpty {
                    Picker("Lista", selection: $listID) {
                        ForEach(lists) { list in Text(list.title).tag(Optional(list.id)) }
                    }
                }
            }
            if let evidence = reviewedSuggestion.evidence {
                Section("AI-förslagets textunderlag") {
                    Text(evidence).textSelection(.enabled)
                    Text("AI kan misstolka transkriptionen. Jämför förslaget med underlaget.").font(.footnote).foregroundStyle(.secondary)
                    if requiresDateCheck {
                        if reviewedSuggestion.needsDateConfirmation == true { Text("Säker dag saknas i underlaget. Välj datum ovan.") }
                        else if reviewedSuggestion.isAllDay == true { Text("Inget klockslag hördes, så förslaget gäller hela dagen.") }
                        Toggle(isAllDay ? "Jag har kontrollerat datumet" : "Jag har kontrollerat datum och tid", isOn: $reviewedDate)
                    }
                }
            }
            if needsReview, let current = currentSuggestion {
                Section("Förslaget har uppdaterats") {
                    Text(current.title).font(.headline)
                    if !current.body.isEmpty { Text(current.body) }
                    if let evidence = current.evidence { Text(evidence).font(.footnote).foregroundStyle(.secondary) }
                    Text("Dina ändringar ovan finns kvar. Granska det uppdaterade underlaget innan du godkänner.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Jag har granskat det uppdaterade förslaget") {
                        // A later clock time ("klockan 15") replaces the all-day guess unless the
                        // user already picked a date themselves.
                        if !dateChosen, current.needsDateConfirmation != true,
                           current.isAllDay != reviewedSuggestion.isAllDay || current.scheduledAt != reviewedSuggestion.scheduledAt {
                            if date != current.scheduledAt { appliedDate = current.scheduledAt }
                            date = current.scheduledAt; isAllDay = current.isAllDay == true; hasDueDate = true
                        }
                        reviewedSuggestion = current
                        reviewedRevision = current.reviewRevision
                        reviewedDate = false
                        dateChosen = false
                        outcome = nil
                    }
                }
            }
            Section {
                Text(destinationNote).font(.footnote).foregroundStyle(.secondary)
                Button(approveTitle) { approve() }
                    .disabled(!canApprove)
                if outcome == .failure(MioReminderPort.deniedMessage), let settings = URL(string: UIApplication.openSettingsURLString) {
                    Button("Öppna Inställningar") { openURL(settings) }
                }
                Button("Inte nu") {
                    Task {
                        busy = true
                        let result = await workflow.deferSuggestion(id: suggestion.id)
                        outcome = result
                        if result.isSuccess { dismiss() }
                        busy = false
                    }
                }
                Button("Nej, glöm förslaget", role: .destructive) {
                    Task {
                        busy = true
                        let result = await workflow.rejectSuggestion(id: suggestion.id)
                        outcome = result
                        if result.isSuccess { dismiss() }
                        busy = false
                    }
                }
            }
            if let error = outcome?.message {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Vill du spara detta?")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .navigationBarBackButtonHidden(busy)
        .task { loadLists() }
        .sheet(isPresented: $showCalendar) {
            CalendarHandoffComposer(draft: eventDraft) { saved in
                guard saved else { return }
                record(.calendar)
            }
        }
        .sheet(isPresented: $showShare) {
            MioShareSheet(text: shareText) { destination in
                showShare = false
                guard let destination else { return }
                record(destination)
            }
            .presentationDetents([.medium, .large])
        }
        .onChange(of: date) { _, new in
            if let applied = appliedDate, applied == new { appliedDate = nil } else { appliedDate = nil; dateChosen = true }
            reviewedDate = false
        }
        .onChange(of: title) { _, _ in reviewedDate = false }
        .onChange(of: text) { _, _ in reviewedDate = false }
        .onChange(of: kind) { _, _ in reviewedDate = false }
        .onChange(of: isAllDay) { _, _ in reviewedDate = false }
        .onChange(of: hasDueDate) { _, _ in reviewedDate = false }
        .onChange(of: currentSuggestion?.reviewRevision) { _, _ in
            if needsReview { reviewedDate = false }
        }
    }

    private var showsDate: Bool { kind == .plan || (kind == .task && hasDueDate) }
    private var dateComponents: DatePickerComponents { isAllDay ? .date : [.date, .hourAndMinute] }
    /// Calendar's editor shows the date itself; a reminder is created directly, so its AI date is
    /// confirmed here first.
    private var requiresDateCheck: Bool { kind == .task && hasDueDate }
    private var currentSuggestion: MioSuggestion? { assistant.suggestions.first { $0.id == suggestion.id } }
    private var needsReview: Bool { currentSuggestion.map { $0.reviewRevision != reviewedRevision } ?? false }
    private var link: URL? {
        suggestion.sessionID.flatMap { MioLink.session($0, proposal: suggestion.id) } ?? MioLink.proposal(suggestion.id)
    }

    private var canApprove: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !needsReview else { return false }
        guard reviewedSuggestion.evidence != nil, requiresDateCheck else { return true }
        return reviewedDate && (reviewedSuggestion.needsDateConfirmation != true || dateChosen)
    }

    private var approveTitle: String {
        switch kind {
        case .plan: "Ja, lägg till i Kalender"
        case .task: "Ja, skicka till Påminnelser"
        default: "Ja, spara i Anteckningar"
        }
    }

    private var destinationNote: String {
        switch kind {
        case .plan: "Kalender öppnas med rubrik, tid och det du sa ifyllt. Välj kalender och notis där och tryck Lägg till. Mio läser aldrig din kalender."
        case .task: "Påminnelsen skapas direkt i listan ovan, med en notis om du valt ett klockslag. Ändra den sedan i Påminnelser."
        default: "Dela-arket öppnas med texten. Välj Anteckningar och en ny eller befintlig anteckning."
        }
    }

    private var eventDraft: MioEventDraft {
        MioEventDraft(title: title.trimmingCharacters(in: .whitespacesAndNewlines), notes: text, url: link, start: date, isAllDay: isAllDay)
    }

    private var shareText: String {
        let parts = [title.trimmingCharacters(in: .whitespacesAndNewlines), text.trimmingCharacters(in: .whitespacesAndNewlines),
                     link?.absoluteString ?? ""]
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private func loadLists() {
        guard workflow.reminders.access() == .granted else { return }
        lists = workflow.reminders.lists()
        let remembered = UserDefaults.standard.string(forKey: MioReminderPort.lastListKey)
        listID = lists.first { $0.id == remembered }?.id ?? workflow.reminders.defaultListID() ?? lists.first?.id
    }

    private func approve() {
        outcome = nil
        switch kind {
        case .plan: showCalendar = true
        case .task: Task { await sendReminder() }
        default: showShare = true
        }
    }

    private func sendReminder() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let result = await workflow.sendToReminders(id: suggestion.id, expectedRevision: reviewedRevision, title: title, notes: text,
            dueDate: hasDueDate ? date : nil, hasTime: hasDueDate && !isAllDay, listID: listID)
        outcome = result
        if lists.isEmpty { loadLists() }
        if result.isSuccess { MioFeedback.success(); dismiss() }
    }

    private func record(_ destination: MioHandoffDestination) {
        Task {
            busy = true
            defer { busy = false }
            let result = await workflow.recordHandoff(id: suggestion.id, kind: kind, title: title, destination: destination)
            outcome = result
            if result.isSuccess { MioFeedback.success(); dismiss() }
        }
    }
}

struct LessonManagementView: View {
    @Environment(MioAssistantViewModel.self) private var assistant
    let session: MioSession
    @State private var route: LessonEditorRoute?

    var body: some View {
        List {
            Section {
                Text("Dela in den avslutade sessionen i namngivna lektioner. Tiderna filtrerar visningen; originaltext och ljudtider bevaras.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(lessons) { lesson in
                Button { route = LessonEditorRoute(lesson: lesson) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(lesson.title).font(.headline)
                        Text("\(lesson.startedAt.formatted(date: .omitted, time: .standard))–\(lesson.endedAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                        if !lesson.note.isEmpty { Text(lesson.note).foregroundStyle(.secondary) }
                        Text("\(lesson.transcripts(in: session).count) textdelar").font(.caption)
                        Text(lesson.freshness(in: session).message).font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }
            if lessons.isEmpty {
                ContentUnavailableView("Inga lektioner ännu", systemImage: "books.vertical", description: Text("Lägg till en lektion med plusknappen."))
            }
        }
        .navigationTitle("Lektioner")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { route = LessonEditorRoute(lesson: nil) } label: { Label("Ny lektion", systemImage: "plus") }
                    .disabled(session.endedAt == nil)
            }
        }
        .sheet(item: $route) { route in
            LessonEditorView(session: session, lesson: route.lesson, suggestedStart: lessons.last?.endedAt ?? session.startedAt)
        }
    }

    private var lessons: [MioLesson] {
        assistant.lessons.filter { $0.sessionID == session.id }.sorted { $0.startedAt < $1.startedAt }
    }
}

private struct LessonEditorRoute: Identifiable {
    let id = UUID()
    let lesson: MioLesson?
}

private struct LessonEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MioAssistantViewModel.self) private var assistant
    let session: MioSession
    let lesson: MioLesson?
    @State private var title: String
    @State private var note: String
    @State private var start: Date
    @State private var end: Date
    @State private var busy = false
    @State private var confirmDelete = false

    init(session: MioSession, lesson: MioLesson?, suggestedStart: Date) {
        self.session = session
        self.lesson = lesson
        _title = State(initialValue: lesson?.title ?? "")
        _note = State(initialValue: lesson?.note ?? "")
        _start = State(initialValue: lesson?.startedAt ?? suggestedStart)
        _end = State(initialValue: lesson?.endedAt ?? session.endedAt ?? session.startedAt)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Lektion") {
                    TextField("Rubrik", text: $title)
                    TextEditor(text: $note).frame(minHeight: 90).accessibilityLabel("Lektionsanteckning")
                    DatePicker("Börjar", selection: $start, in: session.startedAt...(session.endedAt ?? .now))
                    DatePicker("Slutar", selection: $end, in: session.startedAt...(session.endedAt ?? .now))
                    Stepper("Start: \(Int(start.timeIntervalSince(session.startedAt))) s efter sessionsstart", value: startOffset, in: 0...sessionDuration)
                    Stepper("Slut: \(Int(end.timeIntervalSince(session.startedAt))) s efter sessionsstart", value: endOffset, in: 0...sessionDuration)
                }
                Section("Text inom tiden") {
                    ForEach(preview.transcripts(in: session)) { segment in
                        Text(segment.displayText).textSelection(.enabled)
                    }
                    Text("En textdel som korsar en lektionsgräns kan visas i båda lektionerna.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let lesson {
                    Section("Källans aktualitet") {
                        Text(lesson.freshness(in: session).message).font(.footnote).foregroundStyle(.secondary)
                        Text("Att ändra rubrik, egen anteckning eller tidsgräns ändrar inte det sparade revisionsunderlaget. Ingen rättad text skickas automatiskt till AI.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error = assistant.errorMessage { Section { Text(error).foregroundStyle(.red) } }
                if lesson != nil {
                    Section { Button("Radera indelningen", role: .destructive) { confirmDelete = true } }
                }
            }
            .navigationTitle(lesson == nil ? "Ny lektion" : "Redigera lektion")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Spara") {
                        Task {
                            busy = true
                            let saved = await assistant.saveLesson(id: lesson?.id, session: session, title: title, note: note, startedAt: start, endedAt: end)
                            busy = false
                            if saved { dismiss() }
                        }
                    }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || start >= end)
                }
            }
            .disabled(busy)
            .interactiveDismissDisabled(busy)
            .confirmationDialog("Radera lektionsindelningen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Radera", role: .destructive) {
                    Task {
                        busy = true
                        if let lesson, await assistant.deleteLesson(id: lesson.id) { dismiss() }
                        busy = false
                    }
                }
            } message: { Text("Sessionen och dess originaltext finns kvar.") }
        }
    }

    private var preview: MioLesson {
        MioLesson(sessionID: session.id, title: title, note: note, startedAt: start, endedAt: end)
    }

    private var sessionDuration: Int {
        max(0, Int((session.endedAt ?? session.startedAt).timeIntervalSince(session.startedAt)))
    }

    private var startOffset: Binding<Int> {
        Binding(get: { max(0, Int(start.timeIntervalSince(session.startedAt))) },
                set: { start = session.startedAt.addingTimeInterval(TimeInterval($0)) })
    }

    private var endOffset: Binding<Int> {
        Binding(get: { max(0, Int(end.timeIntervalSince(session.startedAt))) },
                set: { end = session.startedAt.addingTimeInterval(TimeInterval($0)) })
    }
}

struct MioGuideView: View {
    var body: some View {
        List {
            Section("Börja här") {
                Text("Mio fångar och föreslår; Apples appar sparar. Godkänner du ett förslag hamnar en händelse i Kalender, en att göra-post i Påminnelser och en anteckning eller ett minne i Anteckningar.")
                Text("Para din dator under Inställningar → Parning: kör mio-pair på datorn och skanna QR-koden. Starta Mio skickar ljud till din dator för svensk text. Starta Mio för vardagslyssning. Starta lektion pausar vardags-Mio och samlar lektionsunderlag separat. Paus och stopp stänger mikrofonen. Historik och rättningar finns under Lektioner → Historik och råtext.")
            }
            Section("Säg till Mio") {
                Text("Mio, kom ihåg att köpa mjölk.")
                Text("Mio, kom ihåg att lämna in uppsatsen på fredag.")
                Text("Mio, notera att provet gäller kapitel tre.")
                Text("Mio, kom ihåg tandläkaren i morgon klockan 14 hos Folktandvården.")
                Text("Börja meningen med ”Mio, kom ihåg” eller ”Mio, notera”. Bara ”Mio” räcker inte. ”Kom ihåg” sparas direkt i Påminnelser, med datum om du säger en dag (i dag, i morgon, på fredag) och en notis om du säger en tid. ”Notera” sparas som en Mio-anteckning under Förslag. Säger du både tid och plats väntar det som en händelse under Förslag, och Ja öppnar Kalender. Ångra finns under Förslag i 24 timmar.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Två korta vibrationer betyder sparat. En lång betyder att Mio inte förstod eller inte kunde spara; titta då under Förslag. Det AI hittar i vanliga samtal vibrerar aldrig. Under en lektion tar Mio inte emot sådant. Frågor till AI ställer du med Fråga Mio.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Batteri, tystnad och lagring") {
                Text("Under 20 % batteri eller i strömsparläge pausar vardags-Mio och visar varför. Tryck Fortsätt för att lyssna ändå; då pausar Mio inte igen förrän batteriet har varit över 20 % eller laddats. Lektioner pausas aldrig av batteriet.")
                Text("Efter 20 minuter utan tal frågar en notis ”Lyssnar Mio fortfarande?”. Svarar du Ja fortsätter Mio. Annars pausar Mio efter fem minuter till, och startar inte igen av sig själv.")
                Text("Vardagstranskript raderas efter 30 dagar. Lektioner, anteckningar och det du sagt Ja till sparas.")
            }
            Section("Planera dagen") {
                Text("Ja på en händelse öppnar Kalenders egen ruta, där du väljer kalender och notis. Ja på en att göra-post skapar den i Påminnelser, i den lista du väljer. Ändra och bocka av där; Mio skriver aldrig över dina poster.")
                Text("Hem visar veckan, nästa påminnelse och dagens att göra från Påminnelser. Mio läser inte din kalender. Byt till Kväll för det du skickat och dagens sessioner. Morgon- och kvällsnotis finns under Inställningar → Notiser.")
            }
            Section("AI") {
                Text("AI är på när datorn är parad. Nytt vardagstal skickas samlat högst var femte minut och kan ge förslag på händelser och att göra utan tilltalet Mio. Avslutade lektioner får AI-anteckningar med textunderlag. Alla föreslagna poster kräver Ja. Frågor skickas direkt. Pausa AI med pausknappen på Fånga eller under Inställningar → AI; pausen sparas. Är AI-tjänsten upptagen väntar Mio och försöker igen av sig själv.")
            }
            Section("Din kontroll") {
                Text("Inget råljud sparas. Spela bara in andra med tydligt samtycke och enligt lokala regler. Minnen sparas i Apples Anteckningar, där du ändrar och raderar dem.")
                Text("Export innehåller lokal text, förslag, lektioner och diagnostik. Förvara den privat. Radera all lokal data tar också bort Mios notiser och AI-konfiguration. Det du skickat till Kalender, Påminnelser och Anteckningar finns kvar där.")
                Text("Långvarig bakgrundslyssning och batteritid måste provas på din telefon. iOS startar inte om lyssningen när appen tvångsavslutats.")
            }
        }
        .mioListGround()
        .navigationTitle("Så använder du Mio")
        .navigationBarTitleDisplayMode(.inline)
    }
}
