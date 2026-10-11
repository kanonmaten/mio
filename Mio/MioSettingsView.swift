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

struct MioSettingsView: View {
    let model: MioViewModel
    let contentModel: MioContentViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("mio.feedback.haptics") private var haptics = true
    var body: some View {
        Form {
            Section {
                NavigationLink { TranscriptionSettingsView(model: model) } label: {
                    Label("Transkription · \(model.connectionState.title)", systemImage: "network")
                }
                NavigationLink { AnalysisSettingsView(model: model, content: contentModel) } label: {
                    Label("AI-assistent", systemImage: "sparkles")
                }
                NavigationLink { MioAIConnectionStatusView(model: model) } label: {
                    Label("AI-anslutning och kapacitet", systemImage: "checkmark.shield")
                }
            } header: { Text("Anslutningar") } footer: {
                Text("Ljud går till din Pianissimo-server. Valfri text-AI använder en separat anslutning och ett separat godkännande.")
            }
            Section("Mio och återkoppling") {
                Toggle("Diskreta vibrationer", isOn: $haptics)
                Text("Mikrofonen startas av dig. Efter paus trycker du Fortsätt. Vid nätavbrott återansluter en aktiv session automatiskt; högst 60 sekunder ljud behålls i minnet.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink("Integritet, export och radering") { MioPrivacySettingsView(model: model, contentModel: contentModel) }
                NavigationLink("Alarm, notiser och behörigheter") { SystemRemindersView() }
                NavigationLink("Så använder du Mio") { MioGuideView() }
            }
            Section("Om Mio") {
                LabeledContent("Version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                Text("Aktiv transkription kräver din dator och Tailscale. Ingen ljudfil sparas. Historik och diagnostik finns under Lektioner → Historik och råtext.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Inställningar")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Klart") { dismiss() } } }
    }
}

struct TranscriptionSettingsView: View {
    let model: MioViewModel
    @State private var address = TranscriptionSettings.address
    @State private var token = ""
    @State private var message: String?
    @State private var error: String?
    @State private var testing = false
    @State private var hasToken = TranscriptionSettings.hasToken
    @State private var testTask: Task<Void, Never>?
    private var canEdit: Bool { [.off, .paused, .failed, .unavailable].contains(model.runState) }
    var body: some View {
        Form {
            Section("Din Pianissimo-server") {
                TextField("https://dator.tailnet.ts.net", text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Transkriptionsserverns HTTPS-adress")
                SecureField("Ny token · tomt behåller sparad", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Label(hasToken ? "Token finns sparad" : "Ingen token sparad", systemImage: hasToken ? "key.fill" : "key")
                Button("Spara anslutning") {
                    do {
                        try TranscriptionSettings.save(address: address, token: token)
                        address = TranscriptionSettings.address; token = ""; hasToken = true
                        message = "Åtkomsttoken och serveradress sparade på telefonen. Testa anslutningen separat."
                        error = nil; MioFeedback.success()
                    } catch { self.error = error.localizedDescription; message = nil }
                }
                Button("Glöm transkriptionsanslutningen", role: .destructive) {
                    do {
                        try TranscriptionSettings.reset(); address = ""; token = ""; hasToken = false
                        message = "Transkriptionsanslutningen är borttagen."; error = nil
                    } catch { self.error = error.localizedDescription }
                }
            }
            .disabled(!canEdit || testing)
            if !canEdit { Section { Text("Pausa eller stoppa Mio innan du ändrar anslutningen.") } }
            Section("Anslutningskontroll · inget ljud skickas") {
                Button {
                    testing = true; error = nil; message = nil
                    testTask = Task {
                        defer { testing = false }
                        do {
                            try await model.testTranscriptionConnection()
                            guard !Task.isCancelled else { return }
                            message = "Anslutningen verifierad. Modellen är redo."; MioFeedback.success()
                        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                    }
                } label: {
                    if testing { ProgressView("Kontrollerar servern …") }
                    else { Label("Testa sparad anslutning", systemImage: "network") }
                }
                .disabled(testing || !token.isEmpty || address != TranscriptionSettings.address || !hasToken || !canEdit)
                LabeledContent("Server", value: model.connectionState.title)
                if let date = model.connectionCheckedAt { LabeledContent("Senast verifierad", value: date.formatted()) }
                if let version = model.serverVersion { LabeledContent("Serverversion", value: version) }
                if let metadata = model.serverMetadata {
                    LabeledContent("Modell", value: metadata.model)
                    LabeledContent("Revision", value: metadata.revision)
                    LabeledContent("Motor", value: metadata.backend)
                }
                if let message { Label(message, systemImage: "checkmark.circle").foregroundStyle(.green) }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            Section("Tailscale och integritet") {
                Text("Anslut iPhone till samma tailnet som datorn. Aktivera VPN On Demand i Tailscale för Wi-Fi och mobilnät. Mio kontrollerar serverns nåbarhet; det kan inte läsa Tailscales interna VPN-status.")
                Text("Starta Mio eller Starta lektion godkänner ljudöverföring till denna server tills du pausar eller stoppar. Ingen ljudfil sparas. Bara senaste 60 sekunderna kan räddas vid ett längre avbrott.")
                Text("Efter SideStore-förnyelse med LocalDevVPN: återanslut Tailscale och testa servern här.")
                Link("Tailscales guide för iPhone", destination: URL(string: "https://tailscale.com/docs/features/client/ios-vpn-on-demand")!)
            }
            .font(.footnote)
        }
        .navigationTitle("Transkription")
        .onDisappear { token = ""; testTask?.cancel() }
    }
}

struct CloudConnectionSettingsView: View {
    @AppStorage(MioCloudSettings.enabledKey) private var isEnabled = false
    @State private var serverAddress = MioCloudSettings.serverAddress
    @State private var newToken = ""
    @State private var useAccess = MioCloudSettings.usesAccess
    @State private var accessClientID = ""
    @State private var accessClientSecret = ""
    @State private var settingsMessage: String?
    @State private var errorMessage: String?
    var body: some View {
        Form {
            Section {
                Toggle("Tillåt molnfrågor", isOn: $isEnabled)
                Text(isEnabled
                     ? "Enskilda frågor kräver granskning och Skicka. Löpande textanalys aktiveras separat under AI-assistent."
                     : "Avstängt. Ingen text skickas till text-AI. Ljudtranskription har en separat anslutning.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Din text-AI-server") {
                TextField("https://mio.example.se", text: $serverAddress)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Serverns HTTPS-adress")
                SecureField("Ny åtkomsttoken eller tomt för att behålla", text: $newToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("Använd Cloudflare Access", isOn: $useAccess)
                if useAccess {
                    SecureField("Access Client ID", text: $accessClientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Access Client Secret", text: $accessClientSecret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Hämta paret från din service token i Cloudflare Zero Trust. Båda tomma behåller sparade värden på samma server. Stäng av och spara för att ta bort dem från telefonen.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("Spara anslutning") { saveSettings() }
                Button("Glöm anslutning och stäng av", role: .destructive) { forgetConnection() }
                if let settingsMessage { Text(settingsMessage).font(.footnote) }
                Text("Åtkomsttoken är samma hemliga värde som MIO_GATEWAY_TOKEN på din Worker. Klistra in värdet utan Bearer eller citattecken. Efter rotation behöver det nya värdet sparas här också. Leverantörens API-nyckel hör bara hemma på servern. Att spara gör inget nätanrop.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage { Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
        }
        .navigationTitle("Anslutning för text-AI")
        .onChange(of: isEnabled) { _, _ in MioConnectionDiscovery.shared.invalidate() }
        .onDisappear { newToken = ""; accessClientID = ""; accessClientSecret = "" }
    }
    private func saveSettings() {
        do {
            try MioCloudSettings.save(serverAddress: serverAddress, newToken: newToken, useAccess: useAccess,
                                      clientID: accessClientID, clientSecret: accessClientSecret)
            serverAddress = MioCloudSettings.serverAddress
            newToken = ""; accessClientID = ""; accessClientSecret = ""
            settingsMessage = "Åtkomsttoken och anslutning sparade. Ingen anslutningskontroll har gjorts."
            errorMessage = nil; MioFeedback.success()
        } catch { errorMessage = error.localizedDescription; settingsMessage = nil }
    }
    private func forgetConnection() {
        do {
            try MioCloudSettings.reset(); serverAddress = ""; newToken = ""
            accessClientID = ""; accessClientSecret = ""; useAccess = false
            settingsMessage = "Text-AI-anslutningen är borttagen."; errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

struct MioAIConnectionStatusView: View {
    let model: MioViewModel
    @Environment(MioAnalysisCoordinator.self) private var analysis
    @Environment(MioAssistantViewModel.self) private var assistant
    @AppStorage(MioCloudSettings.enabledKey) private var cloudEnabled = false
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
                        } else { Text("Väntan är över. Aktivera AI manuellt när du vill fortsätta.") }
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
                    else { Label("Testa text-AI-anslutning", systemImage: "network") }
                }
                .disabled(!cloudEnabled || discovery.isChecking)
                .accessibilityIdentifier("mio.text-ai.connection-test")
                if let date = discovery.lastCheckedAt { LabeledContent("Senast kontrollerad", value: date.formatted()) }
                if let error = localError ?? discovery.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            } header: { Text("Skyddad anslutningskontroll") } footer: {
                Text("Kontrollen skickar ingen fråga och använder ingen AI-kvot. Den visar gatewayens konfiguration. Leverantörens inloggning, modellåtkomst och svarskvalitet provas först vid ett separat godkänt anrop.")
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
                    Text("Beräknat från sparat underlag och redan färdiga delar. Ingen kvot är reserverad. Nya lektionsdelar skickas normalt tidigast efter 60 sekunder och kräver aktivt AI-läge.")
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
                Button("Öppna mikrofonbehörighet i iPhones inställningar") { model.openAppSettings() }
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
            Text("Sessioner, poster, förslag, lektioner, diagnostik och båda serveranslutningarna raderas. Mios alarm och notiser avbryts. Delade filer och kalenderkopior finns kvar där.")
        }
    }
    private func deleteEverything() async {
        outcome = await workflow.deleteAll()
    }
}
