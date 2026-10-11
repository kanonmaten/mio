import Foundation
import SwiftUI

struct TimelineTabView: View {
    @Environment(MioWorkflowCoordinator.self) private var workflow
    @State private var deletionOutcome: MioOperationOutcome?
    @Bindable var contentModel: MioContentViewModel
    @Bindable var sessionModel: MioViewModel

    @State private var searchText = ""
    @State private var editorRoute: ContentEditorRoute?
    @State private var pendingDeletion: MioContentItem?

    var body: some View {
        NavigationStack {
            List {
                if timelineElements.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "Tidslinjen är tom" : "Inga träffar",
                        systemImage: searchText.isEmpty ? "clock" : "magnifyingglass",
                        description: Text(
                            searchText.isEmpty
                                ? "Lägg till något manuellt eller starta en Mio-session."
                                : "Prova ett annat sökord. Sökningen omfattar både manuellt innehåll och transkript."
                        )
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(timelineElements) { element in
                        switch element {
                        case let .content(item):
                            Button {
                                editorRoute = .edit(item)
                            } label: {
                                ContentItemRow(
                                    item: item,
                                    linkedSessionTitle: linkedSessionTitle(for: item)
                                )
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDeletion = item
                                } label: {
                                    Label("Radera", systemImage: "trash")
                                }
                            }

                        case let .session(session):
                            NavigationLink {
                                SessionEditorView(
                                    sessionID: session.id,
                                    contentModel: contentModel,
                                    sessionModel: sessionModel
                                )
                            } label: {
                                SessionTimelineRow(session: session)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Tidslinje")
            .searchable(text: $searchText, prompt: "Sök i innehåll och sessioner")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(MioContentKind.allCases) { kind in
                            Button {
                                editorRoute = .create(kind)
                            } label: {
                                Label(kind.title, systemImage: kind.symbolName)
                            }
                        }
                    } label: {
                        Label("Lägg till", systemImage: "plus")
                    }
                }
            }
        }
        .alert("Kunde inte slutföra raderingen", isPresented: Binding(
            get: { deletionOutcome?.message != nil },
            set: { if !$0 { deletionOutcome = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionOutcome?.message ?? "Försök igen.")
        }
        .sheet(item: $editorRoute) { route in
            ContentEditorView(
                contentModel: contentModel,
                sessionModel: sessionModel,
                item: route.item,
                initialKind: route.initialKind
            )
        }
        .confirmationDialog(
            "Radera posten?",
            isPresented: deletionConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            if let item = pendingDeletion {
                Button("Radera permanent", role: .destructive) {
                    pendingDeletion = nil
                    Task { deletionOutcome = await workflow.deleteContent(id: item.id) }
                }
            }
            Button("Avbryt", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            if let item = pendingDeletion {
                Text("\(item.kind.title) ”\(item.title)” tas bort från telefonen.")
            }
        }
    }

    private var timelineElements: [TimelineElement] {
        let content = contentModel.filteredItems(searchText: searchText).map(TimelineElement.content)
        let sessions = sessionModel.allSessions
            .filter { $0.matches(searchText: searchText) }
            .map(TimelineElement.session)
        return (content + sessions).sorted {
            if $0.date != $1.date {
                return $0.date > $1.date
            }
            return $0.id < $1.id
        }
    }

    private var deletionConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletion = nil
                }
            }
        )
    }

    private func linkedSessionTitle(for item: MioContentItem) -> String? {
        guard let sessionID = item.sessionID,
              let session = sessionModel.session(id: sessionID)
        else { return nil }
        return displayTitle(for: session)
    }
}

struct CalendarTabView: View {
    @Environment(MioWorkflowCoordinator.self) private var workflow
    @Environment(MioDayContext.self) private var day
    @State private var deletionOutcome: MioOperationOutcome?
    @Bindable var contentModel: MioContentViewModel
    @Bindable var sessionModel: MioViewModel

    @State private var searchText = ""
    @State private var editorRoute: ContentEditorRoute?
    @State private var pendingDeletion: MioContentItem?

    var body: some View {
        NavigationStack {
            List {
                if matchingPlans.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "Inga manuella planer" : "Inga träffar",
                        systemImage: searchText.isEmpty ? "calendar.badge.plus" : "magnifyingglass",
                        description: Text(
                            searchText.isEmpty
                                ? "Spara en lokal plan och öppna den för att lägga till en kopia i Apple Kalender eller ställa in alarm."
                                : "Prova ett annat sökord."
                        )
                    )
                    .listRowBackground(Color.clear)
                } else {
                    if !upcomingPlans.isEmpty {
                        Section("Kommande") {
                            ForEach(upcomingPlans) { plan in
                                planRow(plan)
                            }
                        }
                    }

                    if !earlierPlans.isEmpty {
                        Section("Tidigare") {
                            ForEach(earlierPlans) { plan in
                                planRow(plan)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Kalender")
            .toolbar { MioSettingsToolbar() }
            .searchable(text: $searchText, prompt: "Sök bland planer")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editorRoute = .create(.plan)
                    } label: {
                        Label("Ny plan", systemImage: "plus")
                    }
                }
            }
        }
        .alert("Kunde inte slutföra raderingen", isPresented: Binding(
            get: { deletionOutcome?.message != nil },
            set: { if !$0 { deletionOutcome = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionOutcome?.message ?? "Försök igen.")
        }
        .sheet(item: $editorRoute) { route in
            ContentEditorView(
                contentModel: contentModel,
                sessionModel: sessionModel,
                item: route.item,
                initialKind: route.initialKind
            )
        }
        .confirmationDialog(
            "Radera planen?",
            isPresented: deletionConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            if let item = pendingDeletion {
                Button("Radera permanent", role: .destructive) {
                    pendingDeletion = nil
                    Task { deletionOutcome = await workflow.deleteContent(id: item.id) }
                }
            }
            Button("Avbryt", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            if let item = pendingDeletion {
                Text("Planen ”\(item.title)” tas bort från telefonen.")
            }
        }
    }

    private var matchingPlans: [MioContentItem] {
        contentModel.filteredItems(kinds: Set([.plan]), searchText: searchText)
    }

    private var upcomingPlans: [MioContentItem] {
        let startOfToday = day.startOfToday
        return matchingPlans
            .filter { $0.scheduledAt >= startOfToday }
            .sorted {
                if $0.scheduledAt != $1.scheduledAt {
                    return $0.scheduledAt < $1.scheduledAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    private var earlierPlans: [MioContentItem] {
        let startOfToday = day.startOfToday
        return matchingPlans
            .filter { $0.scheduledAt < startOfToday }
            .sorted {
                if $0.scheduledAt != $1.scheduledAt {
                    return $0.scheduledAt > $1.scheduledAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    @ViewBuilder
    private func planRow(_ plan: MioContentItem) -> some View {
        Button {
            editorRoute = .edit(plan)
        } label: {
            ContentItemRow(
                item: plan,
                linkedSessionTitle: linkedSessionTitle(for: plan)
            )
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDeletion = plan
            } label: {
                Label("Radera", systemImage: "trash")
            }
        }
    }

    private var deletionConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletion = nil
                }
            }
        )
    }

    private func linkedSessionTitle(for item: MioContentItem) -> String? {
        guard let sessionID = item.sessionID,
              let session = sessionModel.session(id: sessionID)
        else { return nil }
        return displayTitle(for: session)
    }
}

struct NotesTabView: View {
    @Environment(MioWorkflowCoordinator.self) private var workflow
    @State private var deletionOutcome: MioOperationOutcome?
    @Bindable var contentModel: MioContentViewModel
    @Bindable var sessionModel: MioViewModel

    @State private var searchText = ""
    @State private var filter: NotesFilter = .all
    @State private var editorRoute: ContentEditorRoute?
    @State private var pendingDeletion: MioContentItem?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Visa", selection: $filter) {
                        ForEach(NotesFilter.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if visibleItems.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? filter.emptyTitle : "Inga träffar",
                        systemImage: searchText.isEmpty ? filter.symbolName : "magnifyingglass",
                        description: Text(
                            searchText.isEmpty
                                ? "Skapa innehåll manuellt med plusknappen."
                                : "Prova ett annat sökord."
                        )
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(visibleItems) { item in
                            HStack(alignment: .top, spacing: 10) {
                                if item.kind == .task {
                                    Button {
                                        Task {
                                            await contentModel.setTaskCompleted(
                                                id: item.id,
                                                isCompleted: !item.isCompleted
                                            )
                                        }
                                    } label: {
                                        Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .foregroundStyle(item.isCompleted ? .green : .secondary)
                                            .frame(minWidth: 44, minHeight: 44)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(
                                        item.isCompleted ? "Markera \(item.title) som inte klar" : "Markera \(item.title) som klar"
                                    )
                                    .accessibilityIdentifier("mio.task-completion.\(item.id.uuidString)")
                                }

                                Button {
                                    editorRoute = .edit(item)
                                } label: {
                                    ContentItemRow(
                                        item: item,
                                        linkedSessionTitle: linkedSessionTitle(for: item)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDeletion = item
                                } label: {
                                    Label("Radera", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Anteckningar")
            .toolbar { MioSettingsToolbar() }
            .searchable(text: $searchText, prompt: "Sök i anteckningar och uppgifter")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(NotesFilter.creatableKinds) { kind in
                            Button {
                                editorRoute = .create(kind)
                            } label: {
                                Label(kind.title, systemImage: kind.symbolName)
                            }
                        }
                    } label: {
                        Label("Lägg till", systemImage: "plus")
                    }
                }
            }
        }
        .alert("Kunde inte slutföra raderingen", isPresented: Binding(
            get: { deletionOutcome?.message != nil },
            set: { if !$0 { deletionOutcome = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionOutcome?.message ?? "Försök igen.")
        }
        .sheet(item: $editorRoute) { route in
            ContentEditorView(
                contentModel: contentModel,
                sessionModel: sessionModel,
                item: route.item,
                initialKind: route.initialKind
            )
        }
        .confirmationDialog(
            "Radera innehållet?",
            isPresented: deletionConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            if let item = pendingDeletion {
                Button("Radera permanent", role: .destructive) {
                    pendingDeletion = nil
                    Task { deletionOutcome = await workflow.deleteContent(id: item.id) }
                }
            }
            Button("Avbryt", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            if let item = pendingDeletion {
                Text("\(item.kind.title) ”\(item.title)” tas bort från telefonen.")
            }
        }
    }

    private var visibleItems: [MioContentItem] {
        MioContentItem.timelineSorted(
            contentModel.filteredItems(kinds: filter.kinds, searchText: searchText)
        )
    }

    private var deletionConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletion = nil
                }
            }
        )
    }

    private func linkedSessionTitle(for item: MioContentItem) -> String? {
        guard let sessionID = item.sessionID,
              let session = sessionModel.session(id: sessionID)
        else { return nil }
        return displayTitle(for: session)
    }
}

struct MioNotificationPostView: View {
    let postID: UUID
    let contentModel: MioContentViewModel
    let sessionModel: MioViewModel

    var body: some View {
        if let item = contentModel.item(id: postID) {
            ContentEditorView(contentModel: contentModel, sessionModel: sessionModel,
                              item: item, initialKind: item.kind)
        } else {
            NavigationStack {
                ContentUnavailableView("Posten finns inte kvar", systemImage: "doc.questionmark",
                                       description: Text("Stäng vyn för att gå tillbaka till din dag."))
            }
        }
    }
}

private struct ContentEditorRoute: Identifiable {
    let id = UUID()
    let item: MioContentItem?
    let initialKind: MioContentKind

    static func create(_ kind: MioContentKind) -> Self {
        Self(item: nil, initialKind: kind)
    }

    static func edit(_ item: MioContentItem) -> Self {
        Self(item: item, initialKind: item.kind)
    }
}

private enum TimelineElement: Identifiable {
    case content(MioContentItem)
    case session(MioSession)

    var id: String {
        switch self {
        case let .content(item): "content-\(item.id.uuidString)"
        case let .session(session): "session-\(session.id.uuidString)"
        }
    }

    var date: Date {
        switch self {
        case let .content(item): item.scheduledAt
        case let .session(session): session.startedAt
        }
    }
}

private enum NotesFilter: String, CaseIterable, Hashable, Identifiable {
    case all
    case notes
    case tasks
    case memories

    static let creatableKinds: [MioContentKind] = [.note, .task, .memory]

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "Alla"
        case .notes: "Noter"
        case .tasks: "Att göra"
        case .memories: "Minnen"
        }
    }

    var kinds: Set<MioContentKind> {
        switch self {
        case .all: Set(Self.creatableKinds)
        case .notes: Set([.note])
        case .tasks: Set([.task])
        case .memories: Set([.memory])
        }
    }

    var emptyTitle: String {
        switch self {
        case .all: "Inga anteckningar ännu"
        case .notes: "Inga anteckningar"
        case .tasks: "Inga uppgifter"
        case .memories: "Inga uttryckliga minnen"
        }
    }

    var symbolName: String {
        switch self {
        case .all: "note.text"
        case .notes: MioContentKind.note.symbolName
        case .tasks: MioContentKind.task.symbolName
        case .memories: MioContentKind.memory.symbolName
        }
    }
}

private struct ContentEditorView: View {
    @Environment(MioWorkflowCoordinator.self) private var workflow
    @State private var deletionOutcome: MioOperationOutcome?
    @Environment(\.dismiss) private var dismiss

    @Bindable var contentModel: MioContentViewModel
    @Bindable var sessionModel: MioViewModel

    let item: MioContentItem?

    @State private var kind: MioContentKind
    @State private var title: String
    @State private var bodyText: String
    @State private var scheduledAt: Date
    @State private var isCompleted: Bool
    @State private var sessionID: UUID?
    @State private var isSaving = false
    @State private var showDeleteConfirmation = false

    init(
        contentModel: MioContentViewModel,
        sessionModel: MioViewModel,
        item: MioContentItem?,
        initialKind: MioContentKind
    ) {
        self.contentModel = contentModel
        self.sessionModel = sessionModel
        self.item = item
        _kind = State(initialValue: item?.kind ?? initialKind)
        _title = State(initialValue: item?.title ?? "")
        _bodyText = State(initialValue: item?.body ?? "")
        _scheduledAt = State(initialValue: item?.scheduledAt ?? .now)
        _isCompleted = State(initialValue: item?.isCompleted ?? false)
        _sessionID = State(initialValue: item?.sessionID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Typ") {
                    Picker("Typ", selection: $kind) {
                        ForEach(MioContentKind.allCases) { option in
                            Label(option.title, systemImage: option.symbolName)
                                .tag(option)
                        }
                    }
                }

                Section {
                    TextField("Rubrik", text: $title)
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 110)
                        .accessibilityLabel("Text")
                } header: {
                    Text("Innehåll")
                } footer: {
                    Text("Rubriken krävs. Allt sparas lokalt på telefonen.")
                }

                Section("Tid") {
                    DatePicker(
                        dateLabel,
                        selection: $scheduledAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }

                if kind == .task {
                    Section("Uppgift") {
                        Toggle("Klar", isOn: $isCompleted)
                    }
                }

                Section {
                    Picker("Session", selection: $sessionID) {
                        Text("Ingen session")
                            .tag(Optional<UUID>.none)
                        ForEach(sessionModel.allSessions) { session in
                            Text(displayTitle(for: session))
                                .tag(Optional(session.id))
                        }
                    }

                    if let sessionID,
                       sessionModel.session(id: sessionID) != nil {
                        NavigationLink("Öppna sessionsredigering") {
                            SessionEditorView(
                                sessionID: sessionID,
                                contentModel: contentModel,
                                sessionModel: sessionModel
                            )
                        }
                    }
                } header: {
                    Text("Kopplad session")
                } footer: {
                    Text("Kopplingen duplicerar inte transkriptet.")
                }

                if let item, kind == .plan || kind == .task {
                    if title == item.title && bodyText == item.body && scheduledAt == item.scheduledAt && kind == item.kind {
                        ContentSystemActionsView(item: item)
                    } else {
                        Section {
                            Text("Spara ändringarna och öppna posten igen för att använda kalender, alarm eller påminnelser. Befintliga systemtider ändras separat.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if item != nil {
                    Section {
                        Button("Radera innehållet", role: .destructive) {
                            showDeleteConfirmation = true
                        }
                    }
                }
            }
            .navigationTitle(item == nil ? "Nytt innehåll" : "Redigera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Avbryt") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Spara") {
                        Task { await save() }
                    }
                    .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .confirmationDialog(
            "Radera innehållet?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Radera permanent", role: .destructive) {
                Task { await deleteItem() }
            }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Posten och dess Mio-alarm/påminnelse tas bort. Sessionen och eventuella kalenderkopior finns kvar.")
        }
        .alert("Kunde inte slutföra ändringen", isPresented: contentErrorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionOutcome?.message ?? contentModel.errorMessage ?? "Ett okänt fel inträffade.")
        }
    }

    private var dateLabel: String {
        switch kind {
        case .timeline: "Tidpunkt"
        case .note: "Datum"
        case .task: "När"
        case .plan: "Planerad tid"
        case .memory: "Datum"
        }
    }

    private var contentErrorIsPresented: Binding<Bool> {
        Binding(
            get: { deletionOutcome?.message != nil || contentModel.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    contentModel.errorMessage = nil
                    deletionOutcome = nil
                }
            }
        )
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let didSave = await contentModel.save(
            id: item?.id,
            kind: kind,
            title: title,
            body: bodyText,
            scheduledAt: scheduledAt,
            isCompleted: isCompleted,
            sessionID: sessionID
        )
        if didSave {
            MioFeedback.success()
            dismiss()
        }
    }

    private func deleteItem() async {
        guard let item else { return }
        isSaving = true
        let outcome = await workflow.deleteContent(id: item.id)
        deletionOutcome = outcome
        isSaving = false
        if outcome.isSuccess { dismiss() }
    }
}

struct SessionEditorView: View {
    @Environment(MioWorkflowCoordinator.self) private var workflow
    @State private var deletionOutcome: MioOperationOutcome?
    @Environment(MioAssistantViewModel.self) private var assistant
    @Environment(\.dismiss) private var dismiss

    let sessionID: UUID
    @Bindable var contentModel: MioContentViewModel
    @Bindable var sessionModel: MioViewModel

    @State private var title = ""
    @State private var note = ""
    @State private var transcriptDrafts: [UUID: String] = [:]
    @State private var didLoadDrafts = false
    @State private var isSavingMetadata = false
    @State private var savingSegmentID: UUID?
    @State private var isDeleting = false
    @State private var showDeleteConfirmation = false
    @State private var renamingSpeaker: Int?
    @State private var speakerNameDraft = ""

    var body: some View {
        Group {
            if let session = sessionModel.session(id: sessionID) {
                Form {
                    sessionSection(session)
                    Section("Ordna sessionen") {
                        NavigationLink("Lektionsindelning") {
                            LessonManagementView(session: session)
                        }
                        .disabled(session.endedAt == nil)
                        Button("Hitta lokala Mio-förslag") {
                            Task { _ = await assistant.detectSuggestions(in: session) }
                        }
                        Text("Endast uttryckliga Mio-kommandon blir förslag. Granska dem i Mio → Förslag.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let error = assistant.errorMessage { Text(error).foregroundStyle(.red) }
                    }
                    transcriptSection(session)
                    linkedContentSection
                    deletionSection(session)
                }
                .navigationTitle(displayTitle(for: session))
                .navigationBarTitleDisplayMode(.inline)
                .alert("Byt namn på talare", isPresented: speakerRenameIsPresented) {
                    TextField("Namn", text: $speakerNameDraft)
                    Button("Spara") {
                        // Dismissal clears renamingSpeaker before the task runs.
                        let speaker = renamingSpeaker, name = speakerNameDraft
                        Task { await saveSpeakerName(speaker, name: name) }
                    }
                    Button("Avbryt", role: .cancel) { renamingSpeaker = nil }
                } message: {
                    Text("Namnet visas bara på telefonen; AI ser bara \(MioSpeakerLabel.defaultName(renamingSpeaker ?? 1)). Lämna tomt för att återgå.")
                }
            } else {
                ContentUnavailableView(
                    "Sessionen finns inte",
                    systemImage: "waveform.slash",
                    description: Text("Den kan redan ha raderats från telefonen.")
                )
                .navigationTitle("Session")
            }
        }
        .task(id: sessionID) {
            loadDraftsIfNeeded()
        }
        .confirmationDialog(
            "Radera sessionen?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Radera permanent", role: .destructive) {
                Task { await deleteSession() }
            }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Transkript, diagnostik och sessionsmetadata tas bort. Kopplat manuellt innehåll behålls men kopplas loss.")
        }
        .alert("Kunde inte slutföra ändringen", isPresented: combinedErrorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionOutcome?.message ?? contentModel.errorMessage ?? sessionModel.errorMessage ?? "Ett okänt fel inträffade.")
        }
    }

    @ViewBuilder
    private func sessionSection(_ session: MioSession) -> some View {
        Section {
            TextField("Titel", text: $title)
                .disabled(session.endedAt == nil)
            TextEditor(text: $note)
                .frame(minHeight: 90)
                .disabled(session.endedAt == nil)
                .accessibilityLabel("Sessionsanteckning")

            if session.endedAt == nil {
                Label(
                    "Stoppa sessionen innan den redigeras.",
                    systemImage: "mic.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            } else {
                Button {
                    Task { await saveMetadata() }
                } label: {
                    if isSavingMetadata {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Spara titel och anteckning")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(isSavingMetadata || isDeleting)
            }
        } header: {
            Text("Session")
        } footer: {
            Text(sessionDateDescription(session))
        }
    }

    @ViewBuilder
    private func transcriptSection(_ session: MioSession) -> some View {
        Section {
            if session.transcripts.isEmpty {
                Text("Sessionen innehåller ingen färdig text.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(session.transcripts.enumerated()), id: \.element.id) { index, segment in
                    if let label = session.speakerLabel(at: index), let speaker = segment.speaker {
                        speakerRow(label: label, speaker: speaker, isEditable: session.endedAt != nil)
                    }
                    transcriptEditor(segment, isEditable: session.endedAt != nil)
                }
            }
        } header: {
            Text("Transkript")
        } footer: {
            Text("Originaltext, ljudtider, talarnummer och bakgrundsbevis ändras aldrig. Korrigeringar och talarnamn sparas separat i sessionen.")
        }
    }

    @ViewBuilder
    private func speakerRow(label: String, speaker: Int, isEditable: Bool) -> some View {
        HStack {
            Label(label, systemImage: "person.wave.2")
                .font(.subheadline.weight(.semibold))
            Spacer()
            if isEditable {
                Button("Byt namn") {
                    speakerNameDraft = sessionModel.session(id: sessionID)?.speakerNames?[speaker] ?? ""
                    renamingSpeaker = speaker
                }
                .font(.subheadline)
                .accessibilityLabel("Byt namn på \(label)")
            }
        }
    }

    private var speakerRenameIsPresented: Binding<Bool> {
        Binding(get: { renamingSpeaker != nil }, set: { if !$0 { renamingSpeaker = nil } })
    }

    private func saveSpeakerName(_ speaker: Int?, name: String) async {
        guard let speaker else { return }
        _ = await sessionModel.renameSpeaker(sessionID: sessionID, speaker: speaker, name: name)
    }

    @ViewBuilder
    private func transcriptEditor(_ segment: TranscriptSegment, isEditable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(segment.createdAt.formatted(date: .omitted, time: .standard))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if let correctedText = segment.correctedText {
                Text("Original: \(segment.text)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Korrigerad text: \(correctedText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: transcriptBinding(for: segment))
                .frame(minHeight: 90)
                .disabled(!isEditable)
                .accessibilityLabel(
                    "Transkript från \(segment.createdAt.formatted(date: .omitted, time: .shortened))"
                )

            if isEditable {
                HStack {
                    Button("Spara korrigering") {
                        Task {
                            await saveCorrection(
                                segmentID: segment.id,
                                text: transcriptDrafts[segment.id] ?? segment.displayText
                            )
                        }
                    }
                    .disabled(correctionIsDisabled(for: segment))

                    if segment.correctedText != nil {
                        Button("Återställ original") {
                            transcriptDrafts[segment.id] = segment.text
                            Task {
                                await saveCorrection(
                                    segmentID: segment.id,
                                    text: segment.text
                                )
                            }
                        }
                        .disabled(savingSegmentID != nil)
                    }
                }
                .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var linkedContentSection: some View {
        if !linkedItems.isEmpty {
            Section {
                ForEach(linkedItems) { item in
                    ContentItemRow(item: item, linkedSessionTitle: nil)
                }
            } header: {
                Text("Kopplat innehåll")
            } footer: {
                Text("Kopplingarna tas bort innan en session raderas. Innehållet behålls.")
            }
        }
    }

    @ViewBuilder
    private func deletionSection(_ session: MioSession) -> some View {
        if session.endedAt != nil {
            Section {
                Button("Radera sessionen", role: .destructive) {
                    showDeleteConfirmation = true
                }
                .disabled(isDeleting)
            }
        }
    }

    private var linkedItems: [MioContentItem] {
        MioContentItem.timelineSorted(
            contentModel.items.filter { $0.sessionID == sessionID }
        )
    }

    private var combinedErrorIsPresented: Binding<Bool> {
        Binding(
            get: {
                deletionOutcome?.message != nil || contentModel.errorMessage != nil || sessionModel.errorMessage != nil
            },
            set: { isPresented in
                if !isPresented {
                    contentModel.errorMessage = nil
                    sessionModel.errorMessage = nil
                    deletionOutcome = nil
                }
            }
        )
    }

    private func loadDraftsIfNeeded() {
        guard !didLoadDrafts,
              let session = sessionModel.session(id: sessionID)
        else { return }
        title = session.title ?? ""
        note = session.manualNote ?? ""
        var drafts: [UUID: String] = [:]
        for segment in session.transcripts {
            drafts[segment.id] = segment.displayText
        }
        transcriptDrafts = drafts
        didLoadDrafts = true
    }

    private func transcriptBinding(for segment: TranscriptSegment) -> Binding<String> {
        Binding(
            get: { transcriptDrafts[segment.id] ?? segment.displayText },
            set: { transcriptDrafts[segment.id] = $0 }
        )
    }

    private func correctionIsDisabled(for segment: TranscriptSegment) -> Bool {
        savingSegmentID != nil
            || (transcriptDrafts[segment.id] ?? segment.displayText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
    }

    private func saveMetadata() async {
        isSavingMetadata = true
        _ = await sessionModel.editSession(id: sessionID, title: title, note: note)
        isSavingMetadata = false
    }

    private func saveCorrection(segmentID: UUID, text: String) async {
        savingSegmentID = segmentID
        let didSave = await sessionModel.correctTranscript(
            sessionID: sessionID,
            segmentID: segmentID,
            text: text
        )
        if didSave,
           let segment = sessionModel.session(id: sessionID)?.transcripts.first(where: { $0.id == segmentID }) {
            transcriptDrafts[segmentID] = segment.displayText
        }
        savingSegmentID = nil
    }

    private func deleteSession() async {
        isDeleting = true
        let outcome = await workflow.deleteSession(id: sessionID)
        deletionOutcome = outcome
        isDeleting = false
        if outcome.isSuccess { dismiss() }
    }
}

private struct ContentItemRow: View {
    let item: MioContentItem
    let linkedSessionTitle: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind.symbolName)
                .font(.title3)
                .foregroundStyle(item.isCompleted ? Color.green : Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.headline)
                    .strikethrough(item.isCompleted)
                    .foregroundStyle(.primary)

                if !item.body.isEmpty {
                    Text(item.body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                HStack(spacing: 10) {
                    Label(
                        item.scheduledAt.formatted(date: .abbreviated, time: .shortened),
                        systemImage: "calendar"
                    )
                    Text(item.kind.title)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let linkedSessionTitle {
                    Label(linkedSessionTitle, systemImage: "link")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct SessionTimelineRow: View {
    let session: MioSession

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: session.endedAt == nil ? "waveform.and.mic" : "waveform")
                .font(.title3)
                .foregroundStyle(session.endedAt == nil ? .green : .blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(displayTitle(for: session))
                        .font(.headline)
                    if session.endedAt == nil {
                        Text("AKTIV")
                            .font(.caption2.bold())
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.12), in: Capsule())
                    }
                }

                if let note = session.manualNote, !note.isEmpty {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let latest = session.transcripts.last {
                    Text(latest.displayText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 10) {
                    Label(
                        session.startedAt.formatted(date: .abbreviated, time: .shortened),
                        systemImage: "clock"
                    )
                    Label("\(session.transcripts.count) textdelar", systemImage: "text.alignleft")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private func displayTitle(for session: MioSession) -> String {
    let cleanTitle = session.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !cleanTitle.isEmpty {
        return cleanTitle
    }
    return "Session \(session.startedAt.formatted(date: .abbreviated, time: .shortened))"
}

private func sessionDateDescription(_ session: MioSession) -> String {
    let start = session.startedAt.formatted(date: .abbreviated, time: .shortened)
    guard let endedAt = session.endedAt else {
        return "Startad \(start). Sessionen pågår."
    }
    let end = endedAt.formatted(date: .omitted, time: .shortened)
    let totalSeconds = max(0, Int(endedAt.timeIntervalSince(session.startedAt)))
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let duration = hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
    return "\(start)–\(end), \(duration)."
}
