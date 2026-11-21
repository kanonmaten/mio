import AVFAudio
import SwiftUI
import UIKit
import UserNotifications

/// Reads the inputs for `MioHealthCheck` from what Mio already knows. Shared by the settings line
/// and "Kontrollera allt", so the two always agree; it makes no network call.
@MainActor
enum MioHealthReader {
    static func inputs(model: MioViewModel, analysis: MioAnalysisCoordinator, workflow: MioWorkflowCoordinator,
                       discovery: MioConnectionDiscovery, notifications: UNAuthorizationStatus) -> MioHealthInputs {
        let microphone: MioPermissionState = switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .notDetermined
        }
        let notification: MioPermissionState = switch notifications {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        default: .notDetermined
        }
        let reminders: MioPermissionState = switch workflow.reminders.access() {
        case .granted: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        }
        let paired = MioCloudSettings.isPaired
        let enabled = MioAIPreference.isEnabled(in: .standard)
        return MioHealthInputs(microphone: microphone, notifications: notification, reminders: reminders, paired: paired,
                               gateway: discovery.reachability, pianissimo: MioHealthCheck.reachability(model.connectionState),
                               aiEnabled: enabled,
                               aiWorking: paired && enabled && analysis.enabled && analysis.errorMessage == nil)
    }
}

/// The first line of settings: "Allt fungerar", "Något är fel" or "Kontrollera allt". Opens the page.
struct MioHealthSummaryRow: View {
    let model: MioViewModel
    @Environment(MioAnalysisCoordinator.self) private var analysis
    @Environment(MioWorkflowCoordinator.self) private var workflow
    @State private var discovery = MioConnectionDiscovery.shared
    @State private var services = MioSystemServices.shared
    @AppStorage(MioAIPreference.enabledKey) private var aiEnabled = MioAIPreference.defaultEnabled

    var body: some View {
        let rows = MioHealthCheck.rows(MioHealthReader.inputs(model: model, analysis: analysis, workflow: workflow,
                                                             discovery: discovery, notifications: services.notificationStatus))
        let summary = MioHealthCheck.summary(rows)
        NavigationLink { MioCheckAllView(model: model) } label: {
            Label {
                Text(summary.text).font(.headline)
            } icon: {
                Image(systemName: MioHealthBadge.symbol(summary.state)).foregroundStyle(MioHealthBadge.color(summary.state))
            }
        }
        .accessibilityIdentifier("mio.settings.health")
        .task { await services.refresh() }
    }
}

enum MioHealthBadge {
    static func symbol(_ state: MioHealthState) -> String {
        switch state {
        case .ok: "checkmark.circle.fill"
        case .problem: "exclamationmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    static func color(_ state: MioHealthState) -> Color {
        switch state {
        case .ok: .green
        case .problem: .red
        case .unknown: .secondary
        }
    }
}

/// "Kontrollera allt" (fas 6): microphone, notifications, Reminders, Tailscale, the PC, Pianissimo
/// and AI, a green or red line each with one action, and "Skicka felrapport".
struct MioCheckAllView: View {
    let model: MioViewModel
    @Environment(MioAnalysisCoordinator.self) private var analysis
    @Environment(MioWorkflowCoordinator.self) private var workflow
    @Environment(MioAssistantViewModel.self) private var assistant
    @Environment(MioBackupTask.self) private var backup
    @Environment(\.openURL) private var openURL
    @State private var discovery = MioConnectionDiscovery.shared
    @State private var services = MioSystemServices.shared
    @State private var checking = false
    @State private var recentEvents: [String] = []
    @AppStorage(MioAIPreference.enabledKey) private var aiEnabled = MioAIPreference.defaultEnabled

    var body: some View {
        let rows = currentRows
        List {
            Section {
                ForEach(rows) { row in rowView(row) }
            } footer: {
                Text("Grönt betyder att det fungerade senast Mio kontrollerade. Kontrollera igen frågar datorn på nytt men skickar ingen text till AI.")
            }
            Section {
                Button {
                    Task { await checkAgain() }
                } label: {
                    if checking { ProgressView("Kontrollerar …") } else { Label("Kontrollera igen", systemImage: "arrow.clockwise") }
                }
                .disabled(checking)
                ShareLink(item: errorReport(rows)) {
                    Label("Skicka felrapport", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("mio.check.report")
            } footer: {
                Text("Felrapporten innehåller versioner, vad som fungerar och felkoder, men ingen text från dina lektioner, poster eller förslag.")
            }
        }
        .mioListGround()
        .navigationTitle("Kontrollera allt")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await services.refresh()
            recentEvents = MioErrorReportEvents.lines(await MioDiagnosticsRepository.shared.snapshot().events)
            // Only when nothing has been checked during this launch.
            if discovery.reachability == .unknown || model.connectionState == .unchecked { await checkAgain() }
        }
    }

    private var currentRows: [MioHealthRow] {
        MioHealthCheck.rows(MioHealthReader.inputs(model: model, analysis: analysis, workflow: workflow,
                                                   discovery: discovery, notifications: services.notificationStatus))
    }

    @ViewBuilder
    private func rowView(_ row: MioHealthRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(row.item.title).font(.headline)
            } icon: {
                Image(systemName: MioHealthBadge.symbol(row.state)).foregroundStyle(MioHealthBadge.color(row.state))
            }
            Text(row.detail).font(.subheadline).foregroundStyle(.secondary)
            if let title = row.actionTitle, row.action != .checkAgain {
                if row.action == .pair {
                    NavigationLink(title) { MioComputerSettingsView(model: model) }
                        .font(.subheadline)
                } else {
                    Button(title) { Task { await perform(row) } }
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mio.check.\(row.item.rawValue)")
    }

    private func perform(_ row: MioHealthRow) async {
        switch row.action {
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        case .requestPermission:
            switch row.item {
            case .microphone: _ = await AVAudioApplication.requestRecordPermission()
            case .notifications: _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            case .reminders: _ = await workflow.reminders.requestAccess()
            default: break
            }
            await services.refresh()
        case .openTailscale:
            // Tailscale's own URL scheme; iPhone's Settings if it is not installed. Ej verifierat.
            if let url = URL(string: "tailscale://") {
                openURL(url) { accepted in
                    if !accepted, let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
                }
            }
        case .resumeAI:
            aiEnabled = true
        case .pair, .checkAgain, nil:
            await checkAgain()
        }
    }

    private func checkAgain() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        await services.refresh()
        guard MioCloudSettings.isPaired else { return }
        try? await model.testTranscriptionConnection()
        if let connection = try? MioCloudSettings.connection(),
           let status = try? await discovery.inspect(connection: connection, forceRefresh: true) {
            backup.schedule(status: status)
        }
    }

    private func errorReport(_ rows: [MioHealthRow]) -> String {
        let info = Bundle.main.infoDictionary
        return MioErrorReport(appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
                              build: info?["CFBundleVersion"] as? String ?? "?",
                              system: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
                              createdAt: .now, rows: rows, sessionCount: model.allSessions.count,
                              contentCount: workflow.content.items.count, suggestionCount: assistant.suggestions.count,
                              signingDaysLeft: MioSigningInfo.expiration.map { MioSigning.daysLeft(until: $0, now: .now) },
                              backup: backup.lastAttempt, recentEvents: recentEvents).text
    }
}
