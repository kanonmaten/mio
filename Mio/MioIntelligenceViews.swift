import SwiftUI
import UIKit

struct AnalysisSettingsView: View {
    @Environment(MioAnalysisCoordinator.self) private var analysis
    let model: MioViewModel
    let content: MioContentViewModel
    @Environment(\.openMioSettings) private var openSettings
    @State private var confirmEnable = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Löpande assistent") {
                Text("AI kan upptäcka planer och uppgifter i vanliga samtal utan att du säger Mio. Du granskar alltid förslagen innan de sparas som poster.")
                Text(analysis.status).foregroundStyle(.secondary)
                if analysis.enabled {
                    Button("Stäng av AI-tolkning", role: .destructive) { analysis.disable() }
                } else {
                    Button("Aktivera AI-tolkning …") { confirmEnable = true }
                }
                Text("Läget är av vid varje appstart. Under vardagslyssning skickas nya textutdrag ungefär en gång per minut. Paus/stopp avbryter väntande vardagsanalys. Avstängning avbryter även pågående lektionsanalys.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Lektioner") {
                Text("Starta en lektion med den separata knappen. Vardags-Mio pausas medan lektionsunderlaget fångas. När du avslutar kan aktiverad AI välja ut huvudpunkter, exempel och läxor. Långa lektioner bearbetas i flera delar; detta är anteckningar från delarna, inte en garanterat fullständig sammanfattning.")
                Text("Text-AI får endast text; ljud går till din privata Pianissimo-server. Ingen ljudfil sparas. AI kan missförstå feltranskriberad text. Du kan se textunderlaget bakom varje huvudpunkt.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Anslutning för text-AI") {
                NavigationLink("Server, token och molnfrågor") { CloudConnectionSettingsView() }
                Text("Ljudtranskription konfigureras separat under Transkription. Denna anslutning skickar endast godkänd text till AI.").font(.footnote)
            }
            if let error = error ?? analysis.errorMessage { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("AI-assistent")
        .confirmationDialog("Aktivera löpande AI-tolkning?", isPresented: $confirmEnable, titleVisibility: .visible) {
            Button("Ja, analysera text via min server") {
                do { try analysis.enable(existingSessions: model.allSessions); error = nil }
                catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("Nya textutdrag från vardagslyssning och text från lektioner du avslutar skickas till \(MioCloudSettings.serverAddress.isEmpty ? "din konfigurerade server" : MioCloudSettings.serverAddress) och vidare till dess AI-leverantör. Det sker utan godkännande för varje utdrag tills du stänger av läget. Använd läget bara när berörda personer samtycker. Kalender, uppgifter och minnen kräver fortfarande ditt godkännande.")
        }
    }
}

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
            Text("Vardags-Mio pausas. Lektionen får eget textunderlag och AI-anteckningar om du har aktiverat AI-tolkning. Ljudet sparas inte.")
        }
    }
}

struct LessonLibraryView: View {
    @Environment(\.openMioSettings) private var openSettings
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
                        Text("Starta en lektion för att samla huvudpunkter, exempel och läxor här.").foregroundStyle(.secondary)
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
                    Button("Inställningar") { openSettings() }
                    Text(analysis.status).font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("Historik och råtext") { TimelineTabView(contentModel: content, sessionModel: model) }
                } footer: {
                    Text("Tidigare transkript och manuella poster finns kvar i historiken. De skickas inte automatiskt till AI när du aktiverar läget.")
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
    @State private var confirmAnalysis = false
    @State private var copied = false
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
                    if !document.orderedRecords.isEmpty {
                        Button(copied ? "Anteckningen kopierad" : "Kopiera hela anteckningen", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = document.markdown
                            copied = true
                            MioFeedback.success()
                        }
                    }
                    ForEach(document.orderedRecords) { record in
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
                    if let error = analysis.errorMessage { Text(error).foregroundStyle(.red) }
                    if session.endedAt != nil {
                        Button("Skapa eller fortsätt detaljerade anteckningar …") { confirmAnalysis = true }
                            .disabled(!analysis.enabled || analysis.isWorking || document.isComplete)
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
        .confirmationDialog("Skicka lektionsunderlaget till AI?", isPresented: $confirmAnalysis, titleVisibility: .visible) {
            Button("Ja, analysera denna lektion") {
                if let session { analysis.summarizeLesson(session, assistant: assistant) }
            }
        } message: { Text("Återstående textdelar skickas till din AI-server för detaljerade anteckningar. Äldre korta huvudpunkter räknas inte som detaljerade anteckningar. Färdiga delar sparas. Håll appen öppen under bearbetningen; efter avbrott kan du fortsätta här. Råljud skickas inte.") }
    }
}
