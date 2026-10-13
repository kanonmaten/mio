import SwiftUI

struct CloudAssistantView: View {
    let items: [MioContentItem]
    let sessions: [MioSession]
    var suggestions: [String] = []
    var onAnswerReceived: (() -> Void)?

    @AppStorage(MioCloudSettings.serverKey) private var server = ""
    @Environment(\.openMioSettings) private var openSettings
    @Environment(MioWorkflowCoordinator.self) private var workflow
    @State private var question = ""
    @State private var drafts: [CloudContextDraft] = []
    @State private var showPicker = false
    @State private var answer: String?
    @State private var answerNoteReview: MioAnswerNoteDraft?
    @State private var isPreparing = false
    @State private var errorMessage: String?
    @State private var requestTask: Task<Void, Never>?
    @State private var activeRequestID: UUID?
    @State private var ownInvalidationID: UUID?

    init(items: [MioContentItem], sessions: [MioSession], initialQuestion: String = "", suggestions: [String] = [],
         onAnswerReceived: (() -> Void)? = nil) {
        self.items = items
        self.sessions = sessions
        self.suggestions = suggestions
        self.onAnswerReceived = onAnswerReceived
        _question = State(initialValue: initialQuestion)
    }

    private var isAsking: Bool { activeRequestID != nil }
    private var isPaired: Bool { !server.isEmpty }

    var body: some View {
        Form {
            if !isPaired {
                Section {
                    Text("Para datorn under Inställningar → Dator först.")
                    Button("Öppna inställningar") { openSettings() }
                }
            }

            if question.isEmpty, answer == nil, !isAsking, !suggestions.isEmpty {
                Section("Förslag") {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) { question = suggestion }
                    }
                }
            }

            Section("Din fråga") {
                TextEditor(text: $question)
                    .frame(minHeight: 100)
                    .accessibilityLabel("Fråga till Mio AI")
                    .disabled(isAsking)
                Text("\(question.utf8.count) / 2 000 byte")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if drafts.isEmpty {
                    Text("Ingen kontext vald. Bara frågan skickas.")
                        .foregroundStyle(.secondary)
                }
                ForEach($drafts) { $draft in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Rubrik som skickas", text: $draft.label)
                        TextEditor(text: $draft.text)
                            .frame(minHeight: 90)
                            .accessibilityLabel("Valt utdrag: \(draft.label)")
                        Text("Text: \(draft.text.utf8.count) / 4 000 byte. Ta bort detaljer som frågan inte behöver.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Ta bort utdrag", role: .destructive) {
                            drafts.removeAll { $0.id == draft.id }
                        }
                    }
                    .disabled(isAsking)
                }
                Button("Välj post eller sessionsutdrag") { showPicker = true }
                    .disabled(isAsking || drafts.count >= 6)
            } header: {
                Text("Vald kontext · \(drafts.count) av 6")
            } footer: {
                Text("Urvalet börjar alltid tomt. Kopiorna här kan kortas utan att ändra originalen. Ingen annan historik följer med.")
            }

            Section {
                if isAsking {
                    ProgressView(isPreparing ? "Kontrollerar AI-gatewayen …" : "Väntar på svar …")
                    Button("Avbryt frågan", role: .cancel) { cancelRequest() }
                    Text("En redan skickad fråga kan inte återkallas. Servern försöker avbryta när anslutningen stängs.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Button("Skicka frågan", systemImage: "paperplane") { send() }
                        .disabled(!isPaired || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("mio.question.send")
                    Text("Bara frågan och vald kontext skickas, via din dator till Groq. Inget ljud och ingen annan historik följer med.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            if let answer {
                Section("AI-svar · kontrollera uppgifterna") {
                    Text(verbatim: answer).textSelection(.enabled)
                    Text("Svaret är rådgivande. Det kan innehålla fel och skapar inga poster, påminnelser eller kalenderhändelser. Svaret försvinner när du lämnar vyn om du inte själv sparar det som en anteckning.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Granska och spara i Anteckningar") { answerNoteReview = workflow.questions.answerDraft }
                        .disabled(workflow.questions.answerDraft == nil)
                    Button("Rensa fråga och svar", role: .destructive) { clearConversation() }
                }
            }
        }
        .navigationTitle("Fråga Mio AI")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { clearConversation() }
        .onChange(of: workflow.questions.generation) { _, generation in
            if generation == ownInvalidationID {
                ownInvalidationID = nil
            } else {
                // Full deletion can stop before credential reset. Its workflow
                // generation still clears temporary answers and approved drafts.
                clearConversation(invalidateWorkflow: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MioCloudSettings.didResetNotification)) { _ in
            clearConversation()
        }
        .sheet(item: $answerNoteReview) { draft in MioAnswerNoteReviewView(draft: draft) }
        .sheet(isPresented: $showPicker) { contextPicker }
    }

    private var contextPicker: some View {
        NavigationStack {
            List {
                Section("Manuella poster") {
                    if items.isEmpty { Text("Det finns inga manuella poster.") }
                    ForEach(items) { item in
                        Button {
                            appendDraft(
                                id: "item-\(item.id)",
                                label: "\(item.kind.title): \(item.title)",
                                text: item.body.isEmpty ? item.title : item.body
                            )
                        } label: {
                            Label(item.title, systemImage: isSelected("item-\(item.id)") ? "checkmark.circle.fill" : "plus.circle")
                        }
                        .disabled(drafts.count >= 6 || isSelected("item-\(item.id)"))
                    }
                }
                Section("Avslutade sessioner · välj enskilda utdrag") {
                    let completed = sessions.filter { $0.endedAt != nil }
                    if completed.isEmpty { Text("Stoppa en session för att välja utdrag ur den.") }
                    ForEach(completed) { session in
                        NavigationLink {
                            List(session.transcripts) { segment in
                                Button {
                                    appendDraft(
                                        id: "segment-\(session.id)-\(segment.id)",
                                        label: "Sessionsutdrag: \(session.title ?? "utan titel")",
                                        text: segment.displayText
                                    )
                                } label: {
                                    Label {
                                        Text(verbatim: segment.displayText).lineLimit(5)
                                    } icon: {
                                        Image(systemName: isSelected("segment-\(session.id)-\(segment.id)") ? "checkmark.circle.fill" : "plus.circle")
                                    }
                                }
                                .disabled(drafts.count >= 6 || isSelected("segment-\(session.id)-\(segment.id)"))
                            }
                            .navigationTitle("Välj ett utdrag")
                        } label: {
                            VStack(alignment: .leading) {
                                Text(session.title ?? "Session utan titel")
                                Text(session.startedAt, style: .date)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Välj kontext")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Klart") { showPicker = false } } }
        }
    }

    private func isSelected(_ id: String) -> Bool { drafts.contains { $0.id == id } }

    private func appendDraft(id: String, label: String, text: String) {
        guard drafts.count < 6, !isSelected(id) else { return }
        drafts.append(CloudContextDraft(id: id, label: label, text: text))
    }

    /// Questions send at once (user decision 2026-10-11); the gateway status check and the
    /// strict validation of the answer stay. The same send also covers re-sending after an error.
    private func send() {
        guard !isAsking else { return }
        let request = MioCloudRequest(question: question, context: drafts.map { MioCloudContext(label: $0.label, text: $0.text) })
        let connection: MioCloudConnection
        do {
            _ = try request.validatedData()
            connection = try MioCloudSettings.connection()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let generation = workflow.questions.generation
        let requestID = UUID()
        activeRequestID = requestID
        isPreparing = true
        answer = nil
        answerNoteReview = nil
        errorMessage = nil
        requestTask = Task {
            defer {
                if activeRequestID == requestID { activeRequestID = nil; requestTask = nil; isPreparing = false }
            }
            let prepared: MioPreparedConnection
            do {
                prepared = try await MioConnectionDiscovery.shared.prepare(connection: connection, task: .ask)
            } catch {
                guard !Task.isCancelled, activeRequestID == requestID, workflow.questions.generation == generation else { return }
                MioConnectionDiscovery.shared.handle(error: error)
                errorMessage = error.localizedDescription
                return
            }
            guard !Task.isCancelled, activeRequestID == requestID, workflow.questions.generation == generation else { return }
            isPreparing = false
            let result = await workflow.questions.sendApproved(request, connection: prepared.connection,
                                                               expectedGeneration: generation)
            guard !Task.isCancelled, activeRequestID == requestID, workflow.questions.generation == generation else { return }
            if result.outcome.isSuccess, let received = result.answer {
                answer = received
                onAnswerReceived?()
            } else if result.outcome != .cancelled {
                errorMessage = result.outcome.message
            }
        }
    }

    private func cancelRequest(invalidateWorkflow: Bool = true) {
        if invalidateWorkflow {
            workflow.questions.invalidate()
            // User cancellation retains the reviewed draft for a manual retry.
            // This ID prevents our observation from treating it as full deletion.
            ownInvalidationID = workflow.questions.generation
        }
        requestTask?.cancel()
        requestTask = nil
        activeRequestID = nil
        isPreparing = false
    }

    private func clearConversation(invalidateWorkflow: Bool = true) {
        cancelRequest(invalidateWorkflow: invalidateWorkflow)
        question = ""
        drafts = []
        answer = nil
        answerNoteReview = nil
        errorMessage = nil
    }
}

private struct CloudContextDraft: Identifiable {
    let id: String
    var label: String
    var text: String
}

private struct MioAnswerNoteReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MioWorkflowCoordinator.self) private var workflow
    let draft: MioAnswerNoteDraft
    @State private var title: String
    @State private var bodyText: String
    @State private var isSaving = false
    @State private var outcome: MioOperationOutcome?
    @State private var showShare = false

    init(draft: MioAnswerNoteDraft) {
        self.draft = draft
        _title = State(initialValue: draft.title)
        _bodyText = State(initialValue: draft.body)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Anteckning · granska svaret") {
                    TextField("Rubrik", text: $title)
                    TextEditor(text: $bodyText).frame(minHeight: 180).accessibilityLabel("Svarstext som sparas i Anteckningar")
                    Text("Kontrollera och redigera uppgifterna. Dela-arket öppnas med texten; välj Anteckningar. Inget nytt AI-anrop görs och Mio behåller ingen kopia av svaret.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let message = outcome?.message { Section { Text(message).foregroundStyle(.red) } }
                Button("Spara i Anteckningar") { showShare = true }
                    .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .navigationTitle("Granska anteckning")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { dismiss() }.disabled(isSaving) } }
        }
        .interactiveDismissDisabled(isSaving)
        .sheet(isPresented: $showShare) {
            MioShareSheet(text: [title, bodyText].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")) { destination in
                showShare = false
                guard let destination else { return }
                isSaving = true
                Task {
                    let result = await workflow.saveAnswerNote(draft, title: title, body: bodyText, destination: destination)
                    outcome = result; isSaving = false
                    if result.isSuccess { dismiss() }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
