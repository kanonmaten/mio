import SwiftUI
import UIKit

struct ContentView: View {
    @Bindable var model: MioViewModel
    @State private var showSettings = false
    @Bindable var contentModel: MioContentViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(MioAssistantViewModel.self) private var assistant
    @State private var maintenance = MioMaintenanceState.shared
    @Environment(MioWorkflowCoordinator.self) private var workflow
    @Environment(MioNavigationCoordinator.self) private var navigation
    @Environment(MioDayContext.self) private var day
    @State private var storesLoaded = false
    @AppStorage(MioCloudSettings.enabledKey) private var cloudEnabled = false
    @AppStorage(MioCloudSettings.serverKey) private var cloudServer = ""

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.selectedTab) {
            MioTabView(model: model, contentModel: contentModel)
                .tabItem { Label("Mio", systemImage: "waveform.and.mic") }
                .tag(MioAppTab.capture)

            LessonLibraryView(model: model, content: contentModel)
                .tabItem { Label("Lektioner", systemImage: "book") }
                .tag(MioAppTab.lessons)

            CalendarTabView(contentModel: contentModel, sessionModel: model)
                .tabItem { Label("Kalender", systemImage: "calendar") }
                .tag(MioAppTab.calendar)

            NotesTabView(contentModel: contentModel, sessionModel: model)
                .tabItem { Label("Anteckningar", systemImage: "note.text") }
                .tag(MioAppTab.notes)

            MorningTabView(contentModel: contentModel, sessionModel: model)
                .tabItem { Label("Morgon", systemImage: "sunrise") }
                .tag(MioAppTab.daily)
        }
        .tint(.indigo)
        .disabled(maintenance.blocksWork)
        .environment(\.openMioSettings, { showSettings = true })
        .sheet(isPresented: $showSettings, onDismiss: resolveNotificationRoute) {
            NavigationStack { MioSettingsView(model: model, contentModel: contentModel) }
                .disabled(maintenance.blocksWork)
                .safeAreaInset(edge: .top) {
                    if maintenance.recoveryBlocked { WorkflowRecoveryBanner(workflow: workflow) }
                }
                .overlay {
                    if maintenance.isDeleting || maintenance.isSnapshotting {
                        ProgressView(maintenance.isDeleting ? "Raderar lokal data…" : "Förbereder lokal export…")
                            .padding(24)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
        }
        .sheet(item: $navigation.presentedPost) { post in
            MioNotificationPostView(postID: post.id, contentModel: contentModel, sessionModel: model)
                .disabled(maintenance.blocksWork)
        }
        .onReceive(NotificationCenter.default.publisher(for: TranscriptionSettings.didChange)) { _ in
            Task { await model.transcriptionConfigurationChanged() }
        }
        .environment(maintenance)
        .safeAreaInset(edge: .top) {
            if maintenance.recoveryBlocked {
                WorkflowRecoveryBanner(workflow: workflow)
            }
        }
        .overlay {
            if maintenance.isDeleting || maintenance.isSnapshotting {
                ProgressView(maintenance.isDeleting ? "Raderar lokal data…" : "Förbereder lokal export…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task {
            await workflow.bootstrap()
            storesLoaded = true
            resolveNotificationRoute()
        }
        .onChange(of: scenePhase) { _, newPhase in
            model.handleScenePhase(newPhase)
            if newPhase == .active { day.refresh(); resolveNotificationRoute() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in day.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in day.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in day.refresh() }
        .onChange(of: navigation.pendingRoute) { _, _ in resolveNotificationRoute() }
        .onChange(of: maintenance.blocksWork) { _, blocked in if !blocked { resolveNotificationRoute() } }
        .onChange(of: cloudEnabled) { _, enabled in if !enabled { workflow.cloudConfigurationChanged() } }
        .onChange(of: cloudServer) { _, _ in workflow.cloudConfigurationChanged() }
        .onReceive(NotificationCenter.default.publisher(for: MioCloudSettings.didResetNotification)) { _ in workflow.cloudConfigurationChanged() }
        .onChange(of: assistant.stateRevision) { _, _ in workflow.invalidateExportIfSourcesChanged() }
        .onChange(of: model.stateRevision) { _, _ in workflow.invalidateExportIfSourcesChanged() }
        .onChange(of: contentModel.stateRevision) { _, _ in
            workflow.invalidateExportIfSourcesChanged()
            navigation.reconcile(using: notificationDestination)
        }
    }

    private func notificationDestination(_ id: UUID) -> MioAppTab? {
        guard let item = contentModel.item(id: id) else { return nil }
        return item.kind == .plan ? .calendar : .notes
    }

    private func resolveNotificationRoute() {
        guard storesLoaded, !maintenance.blocksWork, navigation.pendingRoute != nil else { return }
        if showSettings { showSettings = false; return }
        navigation.resolvePending(using: notificationDestination)
    }
}

private struct WorkflowRecoveryBanner: View {
    let workflow: MioWorkflowCoordinator
    @State private var retrying = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Raderingen behöver slutföras", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(workflow.deletion.message ?? "En tidigare radering är inte klar. Övriga ändringar väntar tills den är slutförd.")
                .font(.subheadline)
            Button("Försök slutföra raderingen igen") {
                retrying = true
                Task { _ = await workflow.resumeDeletion(); retrying = false }
            }
            .buttonStyle(.bordered)
            .disabled(retrying)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityElement(children: .contain)
    }
}

private struct MioTabView: View {
    @Environment(MioWorkflowCoordinator.self) private var workflow
    @Bindable var model: MioViewModel
    @Bindable var contentModel: MioContentViewModel
    @State private var showDeleteConfirmation = false
    @Environment(MioAssistantViewModel.self) private var assistant
    @Environment(MioMaintenanceState.self) private var maintenance

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    StatusHeader(model: model)
                    TranscriptionStatusView(model: model)
                    TextAIStateCard()
                    ControlsCard(model: model)
                    AssistantHubView(contentModel: contentModel, sessionModel: model)
                    if !workflow.pendingLessonIDs.isEmpty {
                        Card(title: "Lektionen behöver sparas färdigt", symbol: "exclamationmark.triangle") {
                            if let message = workflow.lastOutcome?.message { Text(message).font(.subheadline) }
                            Text("Underlaget finns kvar lokalt. Försök registrera lektionen igen.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("Försök spara lektionen igen") {
                                Task { _ = await workflow.retryLessonFinalization() }
                            }
                            .disabled(workflow.queuedCommands > 0)
                        }
                    }

                    if let errorMessage = model.errorMessage {
                        ErrorCard(message: errorMessage, openSettings: model.openAppSettings)
                    }
                    if let errorMessage = contentModel.errorMessage {
                        ErrorCard(message: errorMessage, openSettings: nil)
                    }
                    if let errorMessage = assistant.errorMessage {
                        ErrorCard(message: errorMessage, openSettings: nil)
                    }

                    if let session = model.currentSession {
                        DisclosureGroup("Transkription och diagnostik") {
                            CaptureGapsView(session: session)
                            LiveTranscriptCard(model: model, session: session)
                            TranscriptCard(session: session)
                            SessionStatisticsCard(model: model, session: session)
                            EvidenceCard(session: session)
                            DiagnosticCard(session: session)
                        }
                    } else {
                        FirstRunCard()
                    }


                }
                .frame(maxWidth: 680)
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Mio")
            .toolbar { MioSettingsToolbar() }
            .navigationBarTitleDisplayMode(.large)
        }
    }
}


private struct StatusHeader: View {
    let model: MioViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.14))
                    .frame(width: 96, height: 96)
                Image(systemName: statusSymbol)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .symbolEffect(.pulse, isActive: model.runState == .listening && !reduceMotion)
                    .accessibilityHidden(true)
            }

            Text(model.runState == .off ? "Plats för din dag" : model.runState.title)
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
            Text(model.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Label("Mikrofon · \(microphoneState)", systemImage: model.runState == .listening ? "mic.fill" : "mic.slash")
                .font(.subheadline.weight(.medium))
                .accessibilityIdentifier("mio.microphone-state")

            if model.runState == .paused, let remaining = model.pauseRemainingText {
                Label("Pausen når sin valda tid om \(remaining). Fortsätt manuellt.", systemImage: "timer")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    private var statusColor: Color {
        switch model.runState {
        case .listening: .green
        case .paused, .preparing, .stopping, .interrupted: .orange
        case .failed, .unavailable: .red
        case .off: .secondary
        }
    }

    private var microphoneState: String {
        switch model.runState {
        case .listening: "Aktiv"
        case .paused: "Pausad, fortsätt manuellt"
        case .preparing: "Startar"
        case .stopping: "Stoppar"
        case .interrupted, .failed: "Stoppad, fortsätt manuellt"
        case .unavailable: "Inte tillgänglig"
        case .off: "Avstängd"
        }
    }

    private var statusSymbol: String {
        switch model.runState {
        case .listening: "waveform.and.mic"
        case .paused: "pause.fill"
        case .interrupted: "phone.down.fill"
        case .preparing: "hourglass"
        case .stopping: "stop.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .unavailable: "iphone.slash"
        case .off: "mic.slash.fill"
        }
    }
}

private struct TextAIStateCard: View {
    @Environment(MioAnalysisCoordinator.self) private var analysis
    @Environment(MioWorkflowCoordinator.self) private var workflow
    @AppStorage(MioCloudSettings.enabledKey) private var cloudEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Text-AI · \(state)", systemImage: "text.bubble")
                .font(.subheadline.weight(.medium))
            Text(analysis.errorMessage ?? analysis.status)
                .font(.caption).foregroundStyle(.secondary)
            Text("Mikrofon och transkription har egna tillstånd. Frågor skickas efter din granskning.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mio.text-ai-state")
    }

    private var state: String {
        if !cloudEnabled { return "Avstängd" }
        if workflow.questions.isSending { return "Fråga skickad" }
        if analysis.isWorking { return "Analyserar godkända utdrag" }
        if analysis.enabled { return "Löpande analys aktiverad" }
        return "Enskilda godkända frågor"
    }
}

private struct ControlsCard: View {
    let model: MioViewModel

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            VStack(spacing: 12) {
                switch model.runState {
                case .off, .failed, .unavailable:
                    PrimaryActionButton(title: "Starta Mio", symbol: "mic.fill", color: .indigo) {
                        model.beginListening()
                    }

                case .preparing:
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Kontrollerar server och mikrofon …")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    Button("Avbryt — håll Mio avstängd", role: .destructive) {
                        model.cancelPreparation()
                    }
                    .buttonStyle(.bordered)

                case .stopping:
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Mikrofonen stängs · avslutar fångad text …")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()

                    Button("Avbryt väntande transkription", role: .cancel) { model.cancelFinishing() }

                case .listening:
                    PrimaryActionButton(title: model.isLessonActive ? "Avsluta lektionen" : "Stäng av Mio", symbol: "stop.fill", color: .red) {
                        Task { await model.stopListening() }
                    }

                    Menu {
                        Button("30 minuter") {
                            Task { await model.pause(.thirtyMinutes) }
                        }
                        Button("1 timme") {
                            Task { await model.pause(.oneHour) }
                        }
                        Button("Tills jag startar igen") {
                            Task { await model.pause(.untilResumed) }
                        }
                    } label: {
                        Label(model.isLessonActive ? "Pausa lektionen" : "Pausa Mio", systemImage: "pause.circle")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)

                case .paused:
                    PrimaryActionButton(title: model.isLessonActive ? "Fortsätt lektionen" : "Fortsätt Mio", symbol: "play.fill", color: .indigo) {
                        model.beginListening()
                    }
                    Button(role: .destructive) {
                        Task { await model.stopListening() }
                    } label: {
                        Label("Avsluta sessionen", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                case .interrupted:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Väntar på att iOS avslutar ljudavbrottet …")
                            .font(.subheadline.weight(.semibold))
                    }
                    Button(role: .destructive) {
                        Task { await model.stopListening() }
                    } label: {
                        Label("Stoppa Mio", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                if !model.isLessonActive { LessonStartButton(model: model) }
                if model.isLessonActive { Text("Lektionsläge · vardags-Mio är pausat").font(.footnote).foregroundStyle(.secondary) }
                if model.currentSession?.isLesson == true, model.currentSession?.endedAt != nil,
                   [.off, .failed, .unavailable].contains(model.runState) {
                    Button("Tillbaka till vardags-Mio") { model.returnToEveryday() }
                }
            }
            .disabled(model.isSwitchingCaptureMode)
        }
    }
}

struct PrivacyCard: View {
    var body: some View {
        Card(title: "Integritet", symbol: "hand.raised.fill") {
            VStack(alignment: .leading, spacing: 10) {
                PrivacyLine(symbol: "iphone", text: "När du startar Mio skickas mikrofonljud privat via Tailscale till din Pianissimo-server. Text och tidsstämplar sparas på telefonen.")
                PrivacyLine(symbol: "waveform.slash", text: "Ljud finns endast tillfälligt i minnet. Vid serveravbrott behålls högst 60 sekunder; äldre tal markeras som saknat. Inga ljudfiler sparas.")
                PrivacyLine(symbol: "cloud", text: "Text-AI är valfri och avstängd från början. Enskilda frågor kräver granskning före Skicka. Löpande analys kräver separat aktivering och använder bara nytt godkänt textunderlag.")
                PrivacyLine(symbol: "mic.slash", text: "Paus och stopp stänger mikrofonen. Redan fångat ljud kan transkriberas under högst 15 sekunder; du kan avbryta väntan.")
                PrivacyLine(symbol: "person.2.slash", text: "Testa kontrollerat. Spela inte in andra, en lektion eller en arbetsplats utan tydligt tillstånd och enligt lokala regler.")
            }
        }
    }
}

private struct LiveTranscriptCard: View {
    let model: MioViewModel
    let session: MioSession

    var body: some View {
        Card(title: "Live-test", symbol: "quote.bubble") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Säg till exempel: “I dag testar vi procent. Mio, kom ihåg att provet är på fredag.”")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if !model.liveTranscript.isEmpty {
                    Text(model.liveTranscript)
                        .italic()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Pågående tolkning: \(model.liveTranscript)")
                } else if let latest = session.transcripts.last {
                    Text(latest.displayText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    Text(model.runState == .listening ? "Väntar på tal …" : "Ingen färdig text ännu.")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }

                Label(
                    "Mio upptäckt \(session.mioDetectionCount) \(session.mioDetectionCount == 1 ? "gång" : "gånger")",
                    systemImage: session.mioDetectionCount > 0 ? "checkmark.circle.fill" : "ear"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(session.mioDetectionCount > 0 ? .green : .secondary)
            }
        }
    }
}

private struct SessionStatisticsCard: View {
    let model: MioViewModel
    let session: MioSession

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        Card(title: "Mätningar", symbol: "gauge.with.dots.needle.67percent") {
            LazyVGrid(columns: columns, spacing: 10) {
                Metric(title: "Tid", value: durationText, symbol: "clock")
                Metric(title: "Textdelar", value: "\(session.transcripts.count)", symbol: "text.alignleft")
                Metric(title: "Mio", value: "\(session.mioDetectionCount)", symbol: "waveform.badge.mic")
                Metric(title: "Avbrottshändelser", value: "\(session.interruptionCount)", symbol: "phone.arrow.down.left")
                Metric(title: "Batteriprover", value: "\(session.batteryReadings.count)", symbol: "battery.75percent")
                Metric(title: "Batteriskillnad", value: model.batteryDropText, symbol: "chart.line.downtrend.xyaxis")
            }
        }
    }

    private var durationText: String {
        let seconds = Int(model.duration)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
            : String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

private struct EvidenceCard: View {
    let session: MioSession

    var body: some View {
        Card(title: "Bevis från telefonen", symbol: "doc.text.magnifyingglass") {
            VStack(spacing: 0) {
                EvidenceRow(
                    title: "Svensk text skapad",
                    passed: !session.transcripts.isEmpty,
                    pendingText: "Säg några meningar"
                )
                Divider()
                EvidenceRow(
                    title: "Ordet Mio upptäckt",
                    passed: session.mioDetectionCount > 0,
                    pendingText: "Säg Mio tydligt i en mening"
                )
                Divider()
                EvidenceRow(
                    title: "Bakgrund/låst skärm loggad",
                    passed: session.transcripts.contains(where: \.wasObservedInBackground),
                    pendingText: "Lås telefonen och säg en testmening"
                )
                Divider()
                EvidenceRow(
                    title: "Batteri över tid",
                    passed: session.batteryReadings.count >= 2,
                    pendingText: "Minst två mätningar behövs"
                )
            }
        }
    }
}

private struct TranscriptCard: View {
    let session: MioSession

    var body: some View {
        Card(title: "Tidsstämplad text", symbol: "text.document") {
            if session.transcripts.isEmpty {
                Text("Här visas färdiga lokala textdelar.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(session.transcripts.suffix(20).reversed())) { segment in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(segment.createdAt.formatted(date: .omitted, time: .standard))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                if segment.containsMio {
                                    Text("MIO")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.green)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.green.opacity(0.12), in: Capsule())
                                }
                                if segment.wasObservedInBackground {
                                    Text("BAKGRUND")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.blue)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.blue.opacity(0.12), in: Capsule())
                                }
                                Spacer()
                            }
                            Text(segment.displayText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if segment.correctedText != nil {
                                Label("Manuellt rättad; originalet finns kvar i exporten", systemImage: "pencil")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 10)
                        if segment.id != session.transcripts.suffix(20).first?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

private struct DiagnosticCard: View {
    let session: MioSession

    var body: some View {
        Card(title: "Händelselogg", symbol: "list.bullet.rectangle") {
            if session.events.isEmpty {
                Text("Inga händelser ännu.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(session.events.suffix(24).reversed())) { event in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: eventSymbol(event.kind))
                                .foregroundStyle(eventColor(event.kind))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.createdAt.formatted(date: .omitted, time: .standard))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(event.message)
                                    .font(.subheadline)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private func eventSymbol(_ kind: DiagnosticEventKind) -> String {
        switch kind {
        case .info: "info.circle"
        case .lifecycle: "iphone"
        case .interruption: "phone.down"
        case .routeChange: "airpodsmax"
        case .wakeWord: "waveform.badge.mic"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private func eventColor(_ kind: DiagnosticEventKind) -> Color {
        switch kind {
        case .wakeWord: .green
        case .warning, .interruption: .orange
        case .error: .red
        default: .secondary
        }
    }
}

struct DataCard: View {
    let model: MioViewModel
    let contentModel: MioContentViewModel
    @Binding var showDeleteConfirmation: Bool
    @Environment(MioWorkflowCoordinator.self) private var workflow
    @State private var outcome: MioOperationOutcome?

    var body: some View {
        Card(title: "Export och radering", symbol: "externaldrive") {
            VStack(spacing: 12) {
                Text("Exporten är en ögonblicksbild av poster, förslag, lektioner, sessionstext och diagnostik. Skapa en ny export efter nya AI-fel. Råljud och AI-inloggningsuppgifter ingår aldrig. Delade filer och kalenderkopior kan inte återkallas här.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let exportURL = contentModel.exportURL {
                    ShareLink(item: exportURL) {
                        Label("Dela lokal export", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(contentModel.isPreparingExport)
                }
                Button {
                    Task { outcome = await workflow.prepareExport() }
                } label: {
                    if contentModel.isPreparingExport {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label(contentModel.exportURL == nil ? "Skapa lokal export" : "Skapa ny export", systemImage: "doc.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!canManageData || contentModel.isPreparingExport)

                if let message = outcome?.message {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }

                Button("Radera all lokal data", role: .destructive) {
                    showDeleteConfirmation = true
                }
                .disabled(!canManageData)
            }
        }
    }

    private var canManageData: Bool {
        model.runState == .off || model.runState == .failed || model.runState == .unavailable
    }
}

private struct FirstRunCard: View {
    var body: some View {
        Card(title: "Börja med Mio", symbol: "1.circle") {
            VStack(alignment: .leading, spacing: 9) {
                Text("1. Öppna Inställningar och testa din transkriptionsserver. Starta sedan Mio och tillåt mikrofonen.")
                Text("2. Säg svenska meningar och ordet Mio.")
                Text("3. Prova ‘Mio, anteckna att vi arbetar med procent’. Se Förslag och välj Ja, Nej eller Inte nu.")
                Text("4. Använd Starta lektion för lektionsläge. Historik och råtext finns under Lektioner.")
                Text("5. Använd Morgon för dagens planer och Kväll för att se tillbaka.")
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ErrorCard: View {
    let message: String
    let openSettings: (() -> Void)?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Något behöver åtgärdas", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(message)
                    .font(.subheadline)
                if message.localizedCaseInsensitiveContains("mikrofon"), let openSettings {
                    Button("Öppna iPhones inställningar", action: openSettings)
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Card<Content: View>: View {
    let title: String?
    let symbol: String?
    let content: Content

    init(
        title: String? = nil,
        symbol: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label(title, systemImage: symbol ?? "circle")
                    .font(.headline)
            }
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }
}

private struct PrimaryActionButton: View {
    let title: String
    let symbol: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.glassProminent)
        .tint(color)
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }
}

private struct CheckRow: View {
    let title: String
    let detail: String
    let result: Bool?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch result {
        case true: "checkmark.circle.fill"
        case false: "xmark.circle.fill"
        case nil: "questionmark.circle.fill"
        }
    }

    private var color: Color {
        switch result {
        case true: .green
        case false: .red
        case nil: .secondary
        }
    }
}

private struct PrivacyLine: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.subheadline)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.blue)
        }
    }
}

private struct Metric: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(12)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct EvidenceRow: View {
    let title: String
    let passed: Bool
    let pendingText: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: passed ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(passed ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if !passed {
                    Text(pendingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 9)
    }
}
