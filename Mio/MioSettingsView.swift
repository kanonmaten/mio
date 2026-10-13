import SwiftUI
import UIKit

private struct OpenMioSettingsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}
extension EnvironmentValues {
    var openMioSettings: () -> Void {
        get { self[OpenMioSettingsKey.self] }
        set { self[OpenMioSettingsKey.self] = newValue }
    }
}
struct MioSettingsToolbar: ToolbarContent {
    @Environment(\.openMioSettings) private var openSettings
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Inställningar", systemImage: "gearshape", action: openSettings)
        }
    }
}

@MainActor
enum MioFeedback {
    static func success() {
        guard UIApplication.shared.applicationState == .active,
              UserDefaults.standard.object(forKey: "mio.feedback.haptics") as? Bool != false else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

struct MioPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct TranscriptionStatusView: View {
    let model: MioViewModel
    @Environment(\.openMioSettings) private var openSettings
    var body: some View {
        Button(action: openSettings) {
            HStack(spacing: 8) {
                Image(systemName: model.connectionState == .connected ? "checkmark.icloud" : "network")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transkriptionsserver · \(model.connectionState.title)").font(.subheadline.weight(.medium))
                    if model.connectionState == .offline, model.runState == .listening {
                        Text("Mikrofonen är aktiv. Återansluter automatiskt. Ljud väntar högst 60 sekunder i minnet.").font(.caption)
                    } else {
                        Text("Privat via Tailscale · mål: text efter 15–30 sekunder, ännu inte telefonmätt").font(.caption)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption)
            }
            .foregroundStyle(model.connectionState == .connected ? Color.primary : Color.secondary)
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(MioPressStyle())
        .accessibilityHint("Öppnar inställningar för anslutningen")
        .accessibilityIdentifier("mio.transcription-state")
    }
}

struct CaptureGapsView: View {
    let session: MioSession
    var body: some View {
        if let gaps = session.captureGaps, !gaps.isEmpty {
            DisclosureGroup {
                ForEach(gaps) { gap in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(gap.startedAt.formatted(date: .omitted, time: .standard))–\(gap.endedAt.formatted(date: .omitted, time: .standard))")
                        Text(gap.reason).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } label: {
                Label("Ofullständigt ljudunderlag · \(gaps.count) avbrott", systemImage: "exclamationmark.triangle")
            }
        }
    }
}

/// The content of the single settings panel: one scrolling page in a fixed section order.
struct MioSettingsView: View {
    let model: MioViewModel
    let contentModel: MioContentViewModel
    @AppStorage("mio.feedback.haptics") private var haptics = true
    var body: some View {
        Form {
            MioComputerSection(model: model)
            MioAISettingsSection(model: model)
            Section {
                Text("Starta en lektion under Lektioner. Vardags-Mio pausas under tiden. När du avslutar skriver AI detaljerade anteckningar i sparade delar, med minst en minut mellan delarna. Ofullständiga anteckningar märks och fortsätter senare.")
                    .font(.footnote)
                Text("Historik och råtext finns under fliken Lektioner.").font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Lektioner") }
            Section("Notiser") {
                NavigationLink { MioNotificationSettingsView() } label: {
                    Label("Morgon- och kvällsnotis", systemImage: "bell")
                }
            }
            Section {
                Toggle("Diskreta vibrationer", isOn: $haptics)
                NavigationLink { MioGuideView() } label: { Label("Så använder du Mio", systemImage: "questionmark.circle") }
            } header: { Text("Mio") } footer: {
                Text("Mikrofonen startas av dig. Vid nätavbrott återansluter en aktiv session automatiskt; högst 60 sekunder ljud behålls i minnet.")
            }
            Section("Integritet och data") {
                NavigationLink("Export, radering och behörigheter") { MioPrivacySettingsView(model: model, contentModel: contentModel) }
            }
            Section("Om") {
                LabeledContent("Version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                NavigationLink("Diagnostik") { MioDiagnosticsView() }
            }
        }
        // The panel's glass chrome shows between plain rows; with Reduce Transparency it is solid.
        .scrollContentBackground(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .navigationTitle("Inställningar")
    }
}

/// Settings → AI: the persisted on/pause switch (on by default once paired) and its live state.
struct MioAISettingsSection: View {
    let model: MioViewModel
    @Environment(MioAnalysisCoordinator.self) private var analysis
    @Environment(MioAssistantViewModel.self) private var assistant
    @AppStorage(MioAIPreference.enabledKey) private var aiEnabled = MioAIPreference.defaultEnabled
    @AppStorage(MioCloudSettings.serverKey) private var server = ""
    @State private var isStarting = false

    var body: some View {
        Section {
            Toggle("AI", isOn: $aiEnabled)
                .disabled(server.isEmpty)
                .accessibilityIdentifier("mio.ai.enabled")
            if server.isEmpty {
                Text("Para datorn först.").foregroundStyle(.secondary)
            } else {
                Text(analysis.errorMessage ?? analysis.status).font(.footnote)
                if aiEnabled, !analysis.enabled {
                    Button {
                        isStarting = true
                        Task {
                            await analysis.resumeIfWanted(existingSessions: { model.allSessions }, assistant: assistant)
                            isStarting = false
                        }
                    } label: {
                        if isStarting { ProgressView("Startar AI …") } else { Text("Starta AI igen") }
                    }
                    .disabled(isStarting)
                }
            }
            NavigationLink("Kapacitet och uppgifter") { MioAIConnectionStatusView(model: model) }
        } header: {
            Text("AI")
        } footer: {
            Text("Vardagstal skickas samlat högst var femte minut, så att en dag ryms i Groqs gratiskvot. Frågor skickas direkt. Förslag sparas först när du väljer Ja. Pausen gäller tills du slår på AI igen.")
        }
    }
}

struct MioAIConnectionStatusView: View {
    let model: MioViewModel
    @Environment(MioAnalysisCoordinator.self) private var analysis
    @Environment(MioAssistantViewModel.self) private var assistant
    @State private var discovery = MioConnectionDiscovery.shared
    @State private var checkTask: Task<Void, Never>?
    @State private var localError: String?

    var body: some View {
        Form {
            Section("Separata tillstånd") {
                LabeledContent("Mikrofon", value: model.runState.title)
                LabeledContent("Pianissimo", value: model.connectionState.title)
                LabeledContent("Text-AI", value: analysis.enabled ? "Aktiverad" : "Av eller pausad")
                Text(analysis.status).font(.footnote)
                if let pausedUntil = analysis.pausedUntil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if context.date < pausedUntil {
                            HStack { Text("Vänta minst"); Text(pausedUntil, style: .timer) }
                        } else { Text("Väntan är över. AI fortsätter automatiskt.") }
                    }
                    .font(.footnote)
                }
            }
            Section {
                Button {
                    localError = nil
                    checkTask = Task {
                        do {
                            let connection = try MioCloudSettings.connection()
                            _ = try await discovery.inspect(connection: connection, forceRefresh: true)
                        } catch {
                            if !Task.isCancelled { localError = error.localizedDescription }
                        }
                    }
                } label: {
                    if discovery.isChecking { ProgressView("Kontrollerar gatewayen …") }
                    else { Label("Kontrollera AI-gatewayen", systemImage: "network") }
                }
                .disabled(!MioCloudSettings.isPaired || discovery.isChecking)
                .accessibilityIdentifier("mio.text-ai.connection-test")
                if let date = discovery.lastCheckedAt { LabeledContent("Senast kontrollerad", value: date.formatted()) }
                if let error = localError ?? discovery.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            } header: { Text("Skyddad anslutningskontroll") } footer: {
                Text("Kontrollen skickar ingen fråga och använder ingen AI-kvot. Den visar gatewayens konfiguration. Leverantörens inloggning, modellåtkomst och svarskvalitet provas först vid ett riktigt anrop.")
            }
            if let status = discovery.lastStatus {
                Section("Gatewayåtkomst") {
                    LabeledContent("Autentisering", value: "Godkänd")
                    LabeledContent("Protokoll", value: "Mio \(status.protocolVersion)")
                    LabeledContent("Gatewayversion", value: status.release)
                    Text("Leverantörens inloggning, modellåtkomst och svarskvalitet är inte verifierade av denna kontroll.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("AI-uppgifter") {
                    ForEach(MioAITaskID.allCases, id: \.self) { task in
                        let profile = status.tasks[task]
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent(taskTitle(task), value: (try? status.requireTask(task)) != nil ? "Konfigurerad" : "Inte tillgänglig")
                            if !profile.provider.isEmpty { Text("\(profile.provider) · \(profile.model)").font(.footnote).foregroundStyle(.secondary) }
                            if profile.configurationError != nil { Text("Kontrollera uppgiftens profil på servern.").font(.footnote) }
                        }
                    }
                }
                Section("Gemensam kapacitet") {
                    if let quota = status.quota {
                        if let remaining = quota.remaining {
                            LabeledContent("Kvar i delad dagskvot",
                                           value: "\(remaining) av \(quota.limit)\(quota.unit == .tokens ? " token" : "")")
                        } else { Text("Återstående dagskvot är okänd.") }
                    } else { Text("Servern har ingen daglig gräns. Minutgränsen och leverantörens egna gränser gäller.") }
                    if let reset = status.quota?.resetAt.flatMap(MioAnalysisResult.parseDate) {
                        LabeledContent("Nästa återställning", value: reset.formatted())
                    }
                    Text("Frågor, vardagsanalys och lektioner delar samma kapacitet. Den är en observation och reserveras inte av denna kontroll.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            let lessons = model.allSessions.filter(\.isLesson)
            if !lessons.isEmpty {
                Section("Förväntat återstående lektionsarbete") {
                    ForEach(lessons) { session in
                        let document = MioLessonDocument(session: session, records: assistant.analyses)
                        LabeledContent(session.title ?? "Lektion", value: "\(document.remainingRequestCount) AI-delar")
                    }
                    Text("Beräknat från sparat underlag och redan färdiga delar. Ingen kvot är reserverad. Nya lektionsdelar skickas tidigast efter 60 sekunder och bara när AI är på.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("AI-anslutning och kapacitet")
        .onDisappear { checkTask?.cancel() }
    }

    private func taskTitle(_ task: MioAITaskID) -> String {
        switch task { case .ask: "Enskilda frågor"; case .everyday: "Vardagsanalys"; case .lesson: "Lektionsanteckningar" }
    }
}

struct MioPrivacySettingsView: View {
    let model: MioViewModel
    let contentModel: MioContentViewModel
    @Environment(MioAssistantViewModel.self) private var assistant
    @Environment(MioWorkflowCoordinator.self) private var workflow
    @State private var outcome: MioOperationOutcome?
    @State private var showDeleteConfirmation = false
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PrivacyCard()
                Button("Öppna Mios behörigheter i iPhones inställningar") { model.openAppSettings() }
                DataCard(model: model, contentModel: contentModel, showDeleteConfirmation: $showDeleteConfirmation)
                if ![.off, .failed, .unavailable].contains(model.runState) {
                    Text("Avsluta sessionen innan du exporterar eller raderar all data.").font(.footnote)
                }
                if let error = outcome?.message ?? contentModel.errorMessage ?? model.errorMessage ?? assistant.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }.padding().frame(maxWidth: 680)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Integritet och data")
        .confirmationDialog("Radera all lokal Mio-data?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Radera permanent", role: .destructive) { Task { await deleteEverything() } }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Sessioner, poster, förslag, lektioner, diagnostik och datorns parning raderas. Mios alarm och notiser avbryts. Delade filer och kalenderkopior finns kvar där.")
        }
    }
    private func deleteEverything() async {
        outcome = await workflow.deleteAll()
    }
}
