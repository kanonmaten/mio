import SwiftUI

struct CloudAssistantView: View {
    let items: [MioContentItem]
    let sessions: [MioSession]
    var onAnswerReceived: (() -> Void)?

    @AppStorage("mio.cloud.enabled") private var isEnabled = false
    @Environment(\.openMioSettings) private var openSettings
    @State private var serverAddress = ""
    @State private var newToken = ""
    @State private var useAccess = false
    @State private var accessClientID = ""
    @State private var accessClientSecret = ""
    @State private var settingsMessage: String?
    @State private var question = ""
    @State private var drafts: [CloudContextDraft] = []
    @State private var showPicker = false
    @State private var preview: CloudRequestPreview?
    @State private var answer: String?
    @State private var errorMessage: String?
    @State private var requestTask: Task<Void, Never>?
    @State private var activeRequestID: UUID?

    init(items: [MioContentItem], sessions: [MioSession], initialQuestion: String = "", onAnswerReceived: (() -> Void)? = nil) {
        self.items = items
        self.sessions = sessions
        self.onAnswerReceived = onAnswerReceived
        _question = State(initialValue: initialQuestion)
    }

    private var isAsking: Bool { activeRequestID != nil }

    var body: some View {
        Form {
            Section {
                if !isEnabled { Text("Tillåt först text-AI under Inställningar → AI-assistent.") }
                Button("Öppna AI-inställningar") { openSettings() }
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
                    ProgressView("Väntar på svar…")
                    Button("Avbryt frågan", role: .cancel) { cancelRequest() }
                    Text("En redan skickad fråga kan inte återkallas. Servern försöker avbryta när anslutningen stängs.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Button("Granska innan du skickar") { preparePreview() }
                        .disabled(!isEnabled || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !isEnabled {
                        Text("Slå på Tillåt molnfrågor i Inställningar för att kunna granska en fråga. AI-tolkning behöver inte vara på.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Skriv en fråga i Din fråga för att kunna granska den.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            if let answer {
                Section("AI-svar · kontrollera uppgifterna") {
                    Text(verbatim: answer).textSelection(.enabled)
                    Text("Svaret är rådgivande. Det kan innehålla fel och skapar inga poster, påminnelser eller kalenderhändelser. Svaret sparas inte av Mio när du lämnar vyn.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Rensa fråga och svar", role: .destructive) { clearConversation() }
                }
            }
        }
        .navigationTitle("Fråga Mio AI")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSettings() }
        .onDisappear { clearConversation(); newToken = ""; accessClientID = ""; accessClientSecret = "" }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { clearConversation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: MioCloudSettings.didResetNotification)) { _ in
            loadSettings()
            settingsMessage = nil
            clearConversation()
        }
        .sheet(isPresented: $showPicker) { contextPicker }
        .sheet(item: $preview) { candidate in
            CloudRequestPreviewView(preview: candidate) { send(candidate) }
        }
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

    private func loadSettings() {
        serverAddress = MioCloudSettings.serverAddress
        useAccess = MioCloudSettings.usesAccess
        newToken = ""
        accessClientID = ""
        accessClientSecret = ""
    }

    private func preparePreview() {
        do {
            guard newToken.isEmpty, accessClientID.isEmpty, accessClientSecret.isEmpty,
                  useAccess == MioCloudSettings.usesAccess,
                  (try? MioCloudSettings.endpoint(for: serverAddress))
                    == (try? MioCloudSettings.endpoint(for: MioCloudSettings.serverAddress))
            else { throw MioCloudError.changedConfiguration }
            let request = MioCloudRequest(question: question, context: drafts.map { MioCloudContext(label: $0.label, text: $0.text) })
            _ = try request.validatedData()
            let connection = try MioCloudSettings.connection()
            preview = CloudRequestPreview(request: request, connection: connection)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func send(_ candidate: CloudRequestPreview) {
        preview = nil
        do {
            guard try MioCloudSettings.connection() == candidate.connection else { throw MioCloudError.changedConfiguration }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard !isAsking else { return }
        let requestID = UUID()
        activeRequestID = requestID
        answer = nil
        errorMessage = nil
        requestTask = Task {
            do {
                let result = try await MioCloudService.ask(candidate.request, connection: candidate.connection)
                guard !Task.isCancelled, activeRequestID == requestID else { return }
                answer = result
                onAnswerReceived?()
            } catch is CancellationError {
                // Cancellation never produces a late answer or starts a retry.
            } catch {
                guard activeRequestID == requestID else { return }
                errorMessage = error.localizedDescription
            }
            if activeRequestID == requestID {
                activeRequestID = nil
                requestTask = nil
            }
        }
    }

    private func cancelRequest() {
        requestTask?.cancel()
        requestTask = nil
        activeRequestID = nil
    }

    private func clearConversation() {
        cancelRequest()
        preview = nil
        question = ""
        drafts = []
        answer = nil
        errorMessage = nil
    }
}

private struct CloudContextDraft: Identifiable {
    let id: String
    var label: String
    var text: String
}

private struct CloudRequestPreview: Identifiable {
    let id = UUID()
    let request: MioCloudRequest
    let connection: MioCloudConnection
}

private struct CloudRequestPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let preview: CloudRequestPreview
    let send: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Mottagare") {
                    Text(preview.connection.endpoint.absoluteString).textSelection(.enabled)
                    Text("Din server vidarebefordrar texten till den AI-leverantör och eventuell mellanliggande gateway som du valt i serverinställningarna. Servern använder sin egen API-nyckel och anropet kan kosta pengar.")
                }
                Section("Exakt fråga som skickas") { Text(verbatim: preview.request.question).textSelection(.enabled) }
                Section("Exakt vald kontext som skickas") {
                    if preview.request.context.isEmpty { Text("Ingen kontext.") }
                    ForEach(Array(preview.request.context.enumerated()), id: \.offset) { _, context in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: context.label).bold()
                            Text(verbatim: context.text).textSelection(.enabled)
                        }
                    }
                }
                Section {
                    Text("Skicka bara text som du får dela. Inget ljud, andra poster, teknisk sessionsdiagnostik eller tidigare frågor följer med. Den separata åtkomsttokenen skickas skyddat till din server för inloggning.")
                    Text("Mio-servern sparar inga frågor eller svar. Vald AI-leverantör och eventuell mellanliggande gateway behandlar texten enligt sina datavillkor. Granska villkoren när du byter leverantör.")
                    Button("Ja, skicka denna fråga till molnet", action: send)
                        .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Granska och godkänn")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { dismiss() } } }
        }
    }
}
