import SwiftUI

struct AnalysisSettingsView: View {
    @Environment(MioAnalysisCoordinator.self) private var analysis
    let model: MioViewModel
    let content: MioContentViewModel
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
                Text("Inget råljud skickas eller sparas. AI kan missförstå feltranskriberad text. Du kan se textunderlaget bakom varje huvudpunkt.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Anslutning") {
                NavigationLink("Konfigurera server och tillåt molnfrågor") {
                    CloudAssistantView(items: content.items, sessions: model.allSessions)
                }
                Text("Serveradress, åtkomsttoken och en aktiverad molnanslutning krävs. Leverantörens API-nyckel hör enbart hemma på servern. Anrop kan kosta pengar och serverns dagsgräns gäller även löpande analys.")
                    .font(.footnote).foregroundStyle(.secondary)
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
        .disabled(model.isLessonActive || model.isSwitchingCaptureMode || model.isInstallingAdvancedModel
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
                    NavigationLink("AI-inställningar och status") { AnalysisSettingsView(model: model, content: content) }
                    Text(analysis.status).font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("Historik och råtext") { TimelineTabView(contentModel: content, sessionModel: model) }
                } footer: {
                    Text("Tidigare transkript och manuella poster finns kvar i historiken. De skickas inte automatiskt till AI när du aktiverar läget.")
                }
            }
            .navigationTitle("Lektioner")
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
    private var session: MioSession? { model.session(id: sessionID) }

    var body: some View {
        List {
            if let session {
                if session.endedAt == nil, model.currentSession?.id == sessionID {
                    Section {
                        Text("Vardags-Mio är pausat under lektionen.")
                        Button("Avsluta lektionen") { Task { await model.stopListening() } }
                            .disabled(![.listening, .paused, .interrupted].contains(model.runState))
                    }
                }
                let records = assistant.analyses.filter { $0.sessionID == sessionID }
                Section("Viktigt från lektionen · AI-utkast") {
                    if records.flatMap(\.highlights).isEmpty {
                        Text("Inga AI-anteckningar ännu. Aktivera AI-tolkning och avsluta lektionen, eller analysera den sparade lektionen här.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(records) { record in
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
                Section {
                    Text(analysis.status).font(.footnote).foregroundStyle(.secondary)
                    if let error = analysis.errorMessage { Text(error).foregroundStyle(.red) }
                    if session.endedAt != nil {
                        Button("Analysera återstående lektionsdelar med AI …") { confirmAnalysis = true }
                            .disabled(!analysis.enabled || analysis.isWorking)
                    }
                    NavigationLink("Granska föreslagna läxor och planer") { SuggestionInboxView(contentModel: content, sessionModel: model) }
                    NavigationLink("Originaltext, egen anteckning och radering") {
                        SessionEditorView(sessionID: sessionID, contentModel: content, sessionModel: model)
                    }
                }
            } else { Text("Lektionen finns inte längre.") }
        }
        .navigationTitle(session?.title ?? "Lektion")
        .confirmationDialog("Skicka lektionsunderlaget till AI?", isPresented: $confirmAnalysis, titleVisibility: .visible) {
            Button("Ja, analysera denna lektion") {
                if let session { analysis.summarizeLesson(session, assistant: assistant) }
            }
        } message: { Text("De delar av denna lektions text som inte redan analyserats skickas till din AI-server. Råljud skickas inte.") }
    }
}
