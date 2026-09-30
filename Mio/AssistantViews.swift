import SwiftUI

struct AssistantHubView: View {
    @Environment(\.openMioSettings) private var openSettings
    @Environment(MioAssistantViewModel.self) private var assistant
    let contentModel: MioContentViewModel
    let sessionModel: MioViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                NavigationLink {
                    SuggestionInboxView(contentModel: contentModel, sessionModel: sessionModel)
                } label: {
                    Label("Förslag att granska (\(assistant.suggestions.count))", systemImage: "tray.full")
                        .font(.headline)
                }
                Text("Med AI-tolkning aktiverad kan Mio föreslå planer och uppgifter ur vanliga samtal. Mio-kommandon tolkas lokalt efter transkription via din server. Kontrollera alltid innehåll, datum och tid.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Divider()
                Button { openSettings() } label: {
                    Label("AI-assistent och inställningar", systemImage: "gear").frame(minHeight: 44)
                }
                NavigationLink {
                    CloudAssistantView(items: contentModel.items, sessions: sessionModel.allSessions)
                } label: {
                    Label("Fråga Mio med AI", systemImage: "bubble.left.and.text.bubble.right")
                        .frame(minHeight: 44)
                }
                NavigationLink {
                    SystemRemindersView()
                } label: {
                    Label("Alarm och påminnelser", systemImage: "alarm")
                        .frame(minHeight: 44)
                }
                NavigationLink {
                    MioGuideView()
                } label: {
                    Label("Så använder du Mio", systemImage: "questionmark.circle")
                        .frame(minHeight: 44)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

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
                ContentUnavailableView("Inga väntande frågor", systemImage: "checkmark.bubble", description: Text("Aktivera AI-tolkning för förslag ur vanliga samtal, använd ett lokalt Mio-kommando eller skriv med plusknappen."))
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
                        if await assistant.deferSuggestion(id: suggestion.id) { dismiss() }
                        busy = false
                    }
                }
                Button("Nej, glöm frågan", role: .destructive) {
                    Task {
                        busy = true
                        if await assistant.rejectSuggestion(id: suggestion.id) { dismiss() }
                        busy = false
                    }
                }
            }
            if let error = assistant.errorMessage { Section { Text(error).foregroundStyle(.red) } }
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
        if await assistant.markAccepted(id: suggestion.id) { MioFeedback.success(); dismiss() }
        busy = false
    }
}

private struct SuggestionReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MioAssistantViewModel.self) private var assistant
    let suggestion: MioSuggestion
    let contentModel: MioContentViewModel
    let sessionModel: MioViewModel
    @State private var kind: MioContentKind
    @State private var title: String
    @State private var text: String
    @State private var date: Date
    @State private var reviewedDate = false
    @State private var busy = false

    init(suggestion: MioSuggestion, contentModel: MioContentViewModel, sessionModel: MioViewModel) {
        self.suggestion = suggestion
        self.contentModel = contentModel
        self.sessionModel = sessionModel
        _kind = State(initialValue: suggestion.kind)
        _title = State(initialValue: suggestion.title)
        _text = State(initialValue: suggestion.body)
        _date = State(initialValue: suggestion.scheduledAt)
    }

    var body: some View {
        Form {
            Section("Förhandsgranska och rätta") {
                Picker("Typ", selection: $kind) {
                    ForEach(MioContentKind.allCases.filter { $0 != .timeline }) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                TextField("Rubrik", text: $title)
                TextEditor(text: $text).frame(minHeight: 100).accessibilityLabel("Beskrivning")
                DatePicker("Datum och tid", selection: $date)
            }
            .disabled(alreadySaved)
            if let evidence = suggestion.evidence {
                Section("AI-förslagets textunderlag") {
                    Text(evidence).textSelection(.enabled)
                    Text("AI kan misstolka transkriptionen. Jämför förslaget med underlaget.").font(.footnote).foregroundStyle(.secondary)
                    if kind == .plan || kind == .task {
                        if suggestion.needsDateConfirmation == true { Text("Säker tid saknas i underlaget. Välj datum och tid ovan.") }
                        Toggle("Jag har kontrollerat datum och tid", isOn: $reviewedDate)
                    }
                }
            }
            Section {
                Text(alreadySaved
                     ? "Posten har sparats. Tryck Ja igen för att avsluta frågan utan att skapa en dubblett."
                     : "Ja sparar denna post i Mio. Kalender och alarm aktiveras separat när du öppnar den sparade posten. Kontrollera alltid tiden ovan; AI-tolkade datum är också förslag.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Ja, spara") { Task { await accept() } }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (!alreadySaved && suggestion.evidence != nil && (kind == .plan || kind == .task) && !reviewedDate))
                Button("Inte nu") {
                    Task {
                        busy = true
                        if await assistant.deferSuggestion(id: suggestion.id) { dismiss() }
                        busy = false
                    }
                }.disabled(alreadySaved)
                Button("Nej, glöm förslaget", role: .destructive) {
                    Task {
                        busy = true
                        if await assistant.rejectSuggestion(id: suggestion.id) { dismiss() }
                        busy = false
                    }
                }.disabled(alreadySaved)
            }
            if let error = assistant.errorMessage ?? contentModel.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Vill du spara detta?")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .navigationBarBackButtonHidden(busy)
    }

    private var alreadySaved: Bool { contentModel.item(id: suggestion.id) != nil }

    private func accept() async {
        guard !busy else { return }
        guard MioMaintenanceState.shared.beginWrite() else { return }
        defer { MioMaintenanceState.shared.endWrite() }
        busy = true
        defer { busy = false }
        let linkedID = suggestion.sessionID.flatMap { sessionModel.session(id: $0)?.id }
        // A retry after a partial disk failure must never create a duplicate or
        // overwrite a post the user already edited outside the inbox.
        if !alreadySaved {
            guard await contentModel.save(id: suggestion.id, kind: kind, title: title, body: text,
                                          scheduledAt: date, isCompleted: false, sessionID: linkedID) else { return }
        }
        if await assistant.markAccepted(id: suggestion.id) { MioFeedback.success(); dismiss() }
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

struct DailyOverviewView: View {
    @Environment(MioAssistantViewModel.self) private var assistant
    let contentModel: MioContentViewModel
    let sessionModel: MioViewModel
    @State private var selectedDate = Date.now
    @State private var evening = false

    var body: some View {
        List {
            Section {
                Picker("Översikt", selection: $evening) {
                    Text("Morgon").tag(false)
                    Text("Kväll").tag(true)
                }.pickerStyle(.segmented)
                DatePicker("Dag", selection: $selectedDate, displayedComponents: .date)
                Text(evening ? "Se tillbaka på det du har sparat och gjort." : "Här är dina sparade planer och uppgifter för dagen.")
                    .foregroundStyle(.secondary)
            }
            if evening {
                overviewSection("Avklarat", items: briefing.completedTasks)
                overviewSection("Anteckningar och minnen", items: briefing.notes)
                Section("Fångat under dagen") {
                    Label("\(briefing.sessionCount) sessioner · \(briefing.lessonCount) lektioner", systemImage: "waveform")
                    Text("Översikten räknar sparat innehåll. Den är inte en AI-sammanfattning av vad som sades.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            overviewSection("Dagens planer", items: briefing.plans)
            overviewSection("Dagens uppgifter", items: briefing.tasks)
            overviewSection("Kvar sedan tidigare", items: briefing.overdueTasks)
            Section {
                NavigationLink { SystemRemindersView() } label: { Label("Alarm och dagliga påminnelser", systemImage: "alarm") }
                NavigationLink { SuggestionInboxView(contentModel: contentModel, sessionModel: sessionModel) } label: {
                    Label("Väntande frågor (\(assistant.suggestions.count))", systemImage: "tray")
                }
            }
        }
        .navigationTitle(evening ? "Kväll" : "Morgon")
        .toolbar { MioSettingsToolbar() }
    }

    private var briefing: MioBriefing {
        MioBriefing.make(content: contentModel.items, sessions: sessionModel.allSessions, lessons: assistant.lessons, date: selectedDate)
    }

    private func overviewSection(_ title: String, items: [MioContentItem]) -> some View {
        Section(title) {
            if items.isEmpty { Text("Inget sparat här.").foregroundStyle(.secondary) }
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 12) {
                    if item.kind == .task {
                        Button {
                            Task { await contentModel.setTaskCompleted(id: item.id, isCompleted: !item.isCompleted) }
                        } label: { Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle").font(.title2) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(item.isCompleted ? "Markera \(item.title) som inte klar" : "Markera \(item.title) som klar")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                        Text(item.scheduledAt, format: .dateTime.day().month().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                        if !item.body.isEmpty { Text(item.body).font(.subheadline).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
}

struct MioGuideView: View {
    var body: some View {
        List {
            Section("Börja här") {
                Text("Skapa anteckningar, uppgifter, planer och egna minnen med plusknappen i flikarna. Allt detta fungerar utan mikrofon eller AI.")
                Text("Konfigurera Pianissimo-server och Tailscale under Inställningar → Transkription. Starta Mio skickar ljud till din dator för svensk text. Starta Mio för vardagslyssning. Starta lektion pausar vardags-Mio och samlar lektionsunderlag separat. Paus och stopp stänger mikrofonen. Historik och rättningar finns under Lektioner → Historik och råtext.")
            }
            Section("Tilltala Mio") {
                Text("Mio, anteckna att vi arbetar med procent.")
                Text("Mio, påminn mig att ta med boken.")
                Text("Mio, planera tandläkaren.")
                Text("Mio, kom ihåg att jag föredrar blå pennor.")
                Text("Mio, fråga varför himlen är blå.")
                Text("Använd kommandot i början av en mening. Gå sedan till Förslag och granska typ, text och tid. Lokala kommandon tolkar inte datum; även AI-tolkade tider måste granskas. Vibration ges när Mio upptäcks i förgrunden; i bakgrunden kan du behöva öppna appen för att se frågor.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Planera dagen") {
                Text("Öppna en sparad plan eller uppgift för att skapa en separat systempåminnelse eller ett alarm. En plan kan också kopieras till Apple Kalender i dess redigeringsruta. Kalenderkopior synkas inte tillbaka till Mio.")
                Text("Morgon visar dagens planer och uppgifter. Byt till Kväll för avklarade uppgifter, anteckningar och dagens sessioner. Alarm och dagliga påminnelser ställs in separat.")
            }
            Section("Valfri AI") {
                Text("Konfigurera din server först. Aktivera sedan AI-tolkning om du vill att nya textutdrag analyseras löpande för planer och uppgifter utan tilltalet Mio. Avslutade lektioner får AI-anteckningar med textunderlag. Läget är av vid appstart; alla föreslagna poster kräver Ja. Enskilda AI-frågor har en separat förhandsvisning före Skicka.")
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
