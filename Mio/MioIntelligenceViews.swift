import SwiftUI
import UIKit

struct LessonStartButton: View {
    let model: MioViewModel
    @State private var showTitle = false
    @State private var title = ""

    var body: some View {
        Button { showTitle = true } label: {
            Label("Starta lektion", systemImage: "book.fill")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.glass)
        .disabled(model.isLessonActive || model.isSwitchingCaptureMode
                  || [.preparing, .stopping].contains(model.runState))
        .alert("Starta lektion", isPresented: $showTitle) {
            TextField("Ämne eller rubrik", text: $title)
            Button("Starta") { Task { await model.beginLesson(title: title) } }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Vardags-Mio pausas. Lektionen får eget textunderlag och AI-anteckningar när AI är på. Ljudet sparas inte.")
        }
    }
}

struct LessonLibraryView: View {
    let model: MioViewModel
    let content: MioContentViewModel
    @Environment(MioAnalysisCoordinator.self) private var analysis

    var body: some View {
        NavigationStack {
            List {
                Section { LessonStartButton(model: model) }
                Section("Dina lektioner") {
                    let lessons = model.allSessions.filter(\.isLesson)
                    if lessons.isEmpty {
                        Text("Starta en lektion för att samla textunderlag, detaljerade anteckningar och föreslagna läxor här.").foregroundStyle(.secondary)
                    }
                    ForEach(lessons) { session in
                        NavigationLink {
                            LessonDetailView(sessionID: session.id, model: model, content: content)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(session.title ?? "Lektion").font(.headline)
                                Text(session.endedAt == nil ? "Pågår · vardags-Mio är pausat" : session.startedAt.formatted())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Text(analysis.status).font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("Historik och råtext") { TimelineTabView(contentModel: content, sessionModel: model) }
                } footer: {
                    Text("Tidigare transkript och manuella poster finns kvar i historiken. AI får bara text som fångas medan AI är på.")
                }
            }
            .navigationTitle("Lektioner")
            .toolbar { MioSettingsToolbar() }
        }
    }
}

struct LessonDetailView: View {
    let sessionID: UUID
    let model: MioViewModel
    let content: MioContentViewModel
    @Environment(MioAssistantViewModel.self) private var assistant
    @Environment(MioAnalysisCoordinator.self) private var analysis
    @Environment(MioWorkflowCoordinator.self) private var workflow
    @State private var copied = false
    @State private var continuationTask: Task<Void, Never>?
    @State private var continuationID = UUID()
    @State private var isPreparingContinuation = false
    @State private var continuationError: String?
    private var session: MioSession? { model.session(id: sessionID) }

    var body: some View {
        List {
            if let session {
                if session.endedAt == nil, model.currentSession?.id == sessionID {
                    Section {
                        Text("Vardags-Mio är pausat under lektionen.")
                        TranscriptionStatusView(model: model)
                        if model.runState == .paused {
                            Button("Fortsätt lektionen") { model.beginListening() }
                        }
                        if model.runState == .stopping {
                            ProgressView("Avslutar redan fångad text …")
                            Button("Avbryt väntan") { model.cancelFinishing() }
                        }
                        if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
                        Button("Avsluta lektionen") { Task { await model.stopListening() } }
                            .disabled(![.listening, .paused, .interrupted].contains(model.runState))
                    }
                }
                Section { CaptureGapsView(session: session) }
                let records = assistant.analyses.filter { $0.sessionID == sessionID }
                let document = MioLessonDocument(session: session, records: records)
                Section("Detaljerade lektionsanteckningar · AI-utkast") {
                    if document.orderedRecords.isEmpty {
                        Text("Avsluta lektionen och välj att skapa anteckningar med AI. Du kan sedan kopiera dem till valfri AI för vidare hjälp.")
                            .foregroundStyle(.secondary)
                    }
                    Text(document.progress).font(.footnote).foregroundStyle(.secondary)
                    Text("Återstår: \(document.remainingCount) textdelar och \(document.remainingRequestCount) förväntade AI-anrop. Förbrukningen är delad med frågor och vardagsanalys; inget anrop är reserverat.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !document.orderedRecords.isEmpty {
                        Label(document.freshness.message,
                              systemImage: document.freshness == .current ? "checkmark.circle" : "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(copied ? "Anteckningen kopierad" : "Kopiera hela anteckningen", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = document.markdown
                            copied = true
                            MioFeedback.success()
                        }
                    }
                    ForEach(document.orderedRecords) { record in
                        Text(record.freshness(in: session).message).font(.footnote).foregroundStyle(.secondary)
                        ForEach(Array((record.sections ?? []).enumerated()), id: \.offset) { _, section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.heading).font(.headline)
                                Text(section.body).textSelection(.enabled)
                                DisclosureGroup("Textunderlag") {
                                    Text(section.evidence).font(.footnote).textSelection(.enabled)
                                }
                            }
                        }
                        ForEach(Array(record.uncertainties.enumerated()), id: \.offset) { _, uncertainty in
                            Label(uncertainty, systemImage: "questionmark.circle").foregroundStyle(.secondary)
                        }
                        if let metadata = record.metadata {
                            DisclosureGroup("Om AI-utkastet") {
                                Text("\(metadata.provider) · \(metadata.model) · instruktion \(metadata.promptVersion)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if records.contains(where: { $0.sections == nil && !$0.highlights.isEmpty }) {
                    Section("Äldre korta huvudpunkter") {
                        ForEach(records.filter { $0.sections == nil }) { record in
                            ForEach(Array(record.highlights.enumerated()), id: \.offset) { _, point in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(point.text).textSelection(.enabled)
                                    DisclosureGroup("Textunderlag") { Text(point.evidence).font(.footnote).textSelection(.enabled) }
                                }
                            }
                            ForEach(Array(record.uncertainties.enumerated()), id: \.offset) { _, uncertainty in
                                Label(uncertainty, systemImage: "questionmark.circle").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Text(analysis.status).font(.footnote).foregroundStyle(.secondary)
                    if let error = continuationError ?? analysis.errorMessage { Text(error).foregroundStyle(.red) }
                    if isPreparingContinuation { ProgressView("Kontrollerar lektionsanslutningen …") }
                    if session.endedAt != nil {
                        Button("Skapa eller fortsätt detaljerade anteckningar") { continueLesson(session) }
                            .disabled(isPreparingContinuation || analysis.isWorking || document.isComplete)
                        Text("Textdelar skickas till din dator, med minst en minut emellan. Arbetet fortsätter i bakgrunden när du lämnar appen; sparade delar finns kvar efter avbrott. Råljud skickas inte.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    NavigationLink("Granska föreslagna läxor och planer") { SuggestionInboxView(contentModel: content, sessionModel: model) }
                    NavigationLink("Originaltext, egen anteckning och radering") {
                        SessionEditorView(sessionID: sessionID, contentModel: content, sessionModel: model)
                    }
                }
            } else { Text("Lektionen finns inte längre.") }
        }
        .navigationTitle(session?.title ?? "Lektion")
        .onChange(of: assistant.analyses) { _, _ in copied = false }
        .onChange(of: session?.title) { _, _ in copied = false }
        .onChange(of: session?.transcripts) { _, _ in copied = false }
        .onDisappear {
            continuationID = UUID()
            continuationTask?.cancel()
            continuationTask = nil
            isPreparingContinuation = false
        }
    }

    private func continueLesson(_ approvedSession: MioSession) {
        if analysis.enabled {
            continuationError = nil
            workflow.requestLessonNotes(approvedSession, userInitiated: true)
            return
        }
        guard MioAIPreference.isEnabled(in: .standard) else {
            continuationError = "AI är pausad. Slå på AI under Inställningar → AI."
            return
        }
        let id = UUID()
        continuationID = id
        continuationTask?.cancel()
        isPreparingContinuation = true
        continuationTask = Task { @MainActor in
            defer {
                if continuationID == id { continuationTask = nil; isPreparingContinuation = false }
            }
            do {
                try await analysis.enable(existingSessions: model.allSessions, task: .lesson)
                try Task.checkCancellation()
                guard continuationID == id, model.session(id: approvedSession.id) != nil else { return }
                continuationError = nil
                workflow.requestLessonNotes(approvedSession, userInitiated: true)
            } catch is CancellationError { }
            catch { if continuationID == id { continuationError = error.localizedDescription } }
        }
    }
}
