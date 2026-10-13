import SwiftUI
import UIKit

struct SuggestionInboxView: View {
    @Environment(MioAssistantViewModel.self) private var assistant
    let contentModel: MioContentViewModel
    let sessionModel: MioViewModel
    @State private var showComposer = false

    var body: some View {
        List {
            Section {
                Text("Inget förslag blir en sparad post förrän du väljer Ja. Inte nu behåller frågan här. Nej tar bort förslaget; originaltranskriptet påverkas inte.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if assistant.suggestions.isEmpty {
                ContentUnavailableView("Inga väntande frågor", systemImage: "checkmark.bubble", description: Text("När AI är på kommer förslag ur vanliga samtal hit. Du kan också använda ett lokalt Mio-kommando eller skriva med plusknappen."))
            }
            suggestionSection("Att granska", state: .pending)
            suggestionSection("Inte nu", state: .deferred)
            if let error = assistant.errorMessage {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
        }
        .navigationTitle("Förslag")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showComposer = true } label: { Label("Skriv förslag", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showComposer) {
            SuggestionComposerView()
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
                            Label(suggestion.purpose == .question ? "Fråga till AI" : suggestion.kind.title,
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

private struct SuggestionComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MioAssistantViewModel.self) private var assistant
    @State private var kind: MioContentKind = .task
    @State private var isQuestion = false
    @State private var text = ""
    @State private var date = Date.now
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Vad vill du spara?") {
                    Toggle("Fråga till AI", isOn: $isQuestion)
                    if !isQuestion {
                        Picker("Typ", selection: $kind) {
                            ForEach(MioContentKind.allCases.filter { $0 != .timeline }) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                    }
                    TextEditor(text: $text).frame(minHeight: 140).accessibilityLabel("Förslagets text")
                    if !isQuestion { DatePicker("Datum och tid", selection: $date) }
                }
                Section {
                    Text("Mio skapar en lokal fråga som du får granska. Inget skickas till AI och inget alarm skapas här.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let error = assistant.errorMessage { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Nytt förslag")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lägg i inkorgen") {
                        saving = true
                        Task {
                            let saved: Bool
                            if isQuestion {
                                saved = await assistant.proposeQuestion(text: text, sessionID: nil)
                            } else {
                                saved = await assistant.propose(text: text, kind: kind, scheduledAt: date, sessionID: nil)
                            }
                            saving = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .disabled(saving)
            .interactiveDismissDisabled(saving)
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
private struct SuggestionReviewView: View {
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
        _hasDueDate = State(initialValue: suggestion.evidence != nil && suggestion.needsDateConfirmation != true)
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
        .onChange(of: date) { _, _ in dateChosen = true; reviewedDate = false }
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
                Text("Skapa anteckningar, att göra, händelser och minnen med plusknappen i flikarna. Allt detta fungerar utan mikrofon eller AI.")
                Text("Para din dator under Inställningar → Dator: kör mio-pair på datorn och skanna QR-koden. Starta Mio skickar ljud till din dator för svensk text. Starta Mio för vardagslyssning. Starta lektion pausar vardags-Mio och samlar lektionsunderlag separat. Paus och stopp stänger mikrofonen. Historik och rättningar finns under Lektioner → Historik och råtext.")
            }
            Section("Tilltala Mio") {
                Text("Mio, anteckna att vi arbetar med procent.")
                Text("Mio, påminn mig att ta med boken.")
                Text("Mio, planera tandläkaren.")
                Text("Mio, kom ihåg att jag föredrar blå pennor.")
                Text("Mio, fråga varför himlen är blå.")
                Text("Använd kommandot i början av en mening. Granska sedan förslaget från Hem: kontrollera typ, text och tid. Lokala kommandon tolkar inte datum; även AI-tolkade tider måste granskas. Vibration ges när Mio upptäcks i förgrunden; i bakgrunden kan du behöva öppna appen för att se frågor.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Planera dagen") {
                Text("Öppna en sparad händelse eller att göra-post för att skapa en separat systempåminnelse eller ett alarm. En händelse kan också kopieras till Apple Kalender i dess redigeringsruta. Kalenderkopior synkas inte tillbaka till Mio.")
                Text("Hem visar veckan, nästa sak och dagens händelser. Välj en dag i veckoraden för att se den. Byt till Kväll för avklarade att göra-poster, anteckningar och dagens sessioner. Alarm och dagliga påminnelser finns under Inställningar → Påminnelser.")
            }
            Section("AI") {
                Text("AI är på när datorn är parad. Nytt vardagstal skickas samlat högst var femte minut och kan ge förslag på händelser och att göra utan tilltalet Mio. Avslutade lektioner får AI-anteckningar med textunderlag. Alla föreslagna poster kräver Ja. Frågor skickas direkt. Pausa AI på Fånga eller under Inställningar → AI; pausen sparas.")
            }
            Section("Din kontroll") {
                Text("Inget råljud sparas. Spela bara in andra med tydligt samtycke och enligt lokala regler. Du kan ändra och radera synliga minnen i Anteckningar.")
                Text("Export innehåller lokal text, förslag, lektioner och diagnostik. Förvara den privat. Radera all lokal data tar också bort Mios alarm, notiser och AI-konfiguration. Redan delade filer och kalenderkopior finns kvar där du sparade dem.")
                Text("Långvarig bakgrundslyssning och batteritid måste provas på din telefon. iOS startar inte om lyssningen när appen tvångsavslutats. Kontrollera alarm på enheten innan du förlitar dig på dem.")
            }
        }
        .navigationTitle("Så använder du Mio")
    }
}
