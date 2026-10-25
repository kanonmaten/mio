import Foundation
import SwiftUI

struct TimelineTabView: View {
    @Environment(MioWorkflowCoordinator.self) private var workflow
    @State private var deletionOutcome: MioOperationOutcome?
    @Bindable var contentModel: MioContentViewModel
    @Bindable var sessionModel: MioViewModel

    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var pendingDeletion: MioContentItem?
    @State private var timelineElementsSnapshot: [TimelineElement] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if timelineElementsSnapshot.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "Tidslinjen är tom" : "Inga träffar",
                        systemImage: searchText.isEmpty ? "clock" : "magnifyingglass",
                        description: Text(
                            searchText.isEmpty
                                ? "Starta en Mio-session. Det du skickar till Apples appar syns också här."
                                : "Prova ett annat sökord. Sökningen omfattar både manuellt innehåll och transkript."
                        )
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(timelineElementsSnapshot) { element in
                        switch element {
                        case let .content(item):
                            // A handed-over item lives in Apple's app; Mio shows only its record.
                            ContentItemRow(
                                item: item,
                                linkedSessionTitle: linkedSessionTitle(for: item)
                            )
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
            .mioListGround()
            .navigationTitle("Tidslinje")
            .searchable(text: $searchText, prompt: "Sök i sessioner och skickat")
            .task {
                debouncedSearchText = searchText
                rebuildTimeline(using: searchText)
            }
            .onChange(of: searchText) { _, text in
                scheduleSearchRefresh(for: text)
            }
            .onChange(of: contentModel.stateRevision) { _, _ in
                rebuildTimeline(using: debouncedSearchText)
            }
            .onChange(of: sessionModel.stateRevision) { _, _ in
                rebuildTimeline(using: debouncedSearchText)
            }
            .onDisappear {
                searchTask?.cancel()
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
                Text(item.handoff.map { "Mio glömmer att ”\(item.title)” skickades. Posten i \($0.destination.title) finns kvar." }
                     ?? "\(item.kind.title) ”\(item.title)” tas bort från telefonen.")
            }
        }
    }

    @MainActor
    private func scheduleSearchRefresh(for text: String) {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            debouncedSearchText = text
            rebuildTimeline(using: text)
        }
    }

    private func rebuildTimeline(using search: String) {
        let query = TimelineSearch.normalized(search)
        let content = contentModel.items
            .filter { TimelineSearch.matches($0, query: query) }
            .map(TimelineElement.content)
        let sessions = sessionModel.allSessions
            .filter { TimelineSearch.matches($0, query: query) }
            .map(TimelineElement.session)
        timelineElementsSnapshot = (content + sessions).sorted {
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

private enum TimelineSearch {
    static let locale = Locale(identifier: "sv-SE")

    static func normalized(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
            .lowercased(with: locale)
    }

    static func matches(_ item: MioContentItem, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return normalized("\(item.kind.title) \(item.title) \(item.body)").contains(query)
    }

    static func matches(_ session: MioSession, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let transcriptText = session.transcripts.map(\.displayText).joined(separator: " ")
        return normalized("\(session.title ?? "") \(session.manualNote ?? "") \(transcriptText)").contains(query)
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
                    aiReviewSection(session)
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

    /// Every everyday AI answer for this session, including those without proposals.
    @ViewBuilder
    private func aiReviewSection(_ session: MioSession) -> some View {
        let reviews = MioEverydayReview.make(records: assistant.analyses, decisions: assistant.analysisDecisions,
                                             excludingSessionIDs: []).filter { $0.sessionID == session.id }
        if !session.isLesson, !reviews.isEmpty {
            Section {
                ForEach(reviews) { review in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(review.reviewedAt.formatted(.dateTime.hour().minute().locale(MioTheme.swedish))) · \(review.fragmentText) · \(review.outcome)")
                        ForEach(Array(review.uncertainties.enumerated()), id: \.offset) { _, uncertainty in
                            Label(uncertainty, systemImage: "questionmark.circle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("AI-genomgångar")
            } footer: {
                Text("Varje rad är ett svar från AI. Förslag granskar du från Hem; AI:ns frågor om texten visas bara här.")
            }
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

struct ContentItemRow: View {
    let item: MioContentItem
    let linkedSessionTitle: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind.symbolName)
                .font(.title3)
                .foregroundStyle(item.isCompleted ? Color.green : MioTheme.tint)
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
                    if let handoff = item.handoff {
                        Label("\(handoff.destination.title) · \(handoff.sentAt.formatted(date: .abbreviated, time: .shortened))",
                              systemImage: handoff.destination.symbolName)
                    } else {
                        Label(
                            item.allDay ? item.scheduledAt.formatted(date: .abbreviated, time: .omitted) + " · heldag"
                                : item.scheduledAt.formatted(date: .abbreviated, time: .shortened),
                            systemImage: "calendar"
                        )
                    }
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
