import SwiftUI

/// Settings → Säkerhetskopia (fas 6): the latest copy, "Säkerhetskopiera nu" and restoring one.
/// Restoring downloads the chosen copy, checks it and replaces Mio's data the next time Mio
/// starts, after a confirmation; it is refused while Mio listens and never touches data whose
/// schema it does not know.
struct MioBackupSettingsView: View {
    let model: MioViewModel
    @Environment(MioBackupTask.self) private var backup
    @Environment(MioWorkflowCoordinator.self) private var workflow
    @State private var discovery = MioConnectionDiscovery.shared
    @State private var backups: [MioBackupSummary] = []
    @State private var loading = false
    @State private var message: String?
    @State private var chosen: MioBackupSummary?
    @State private var pendingRestore = MioBackupRestore.hasPending(in: .standard)
    @State private var staging = false

    var body: some View {
        Form {
            Section {
                LabeledContent("På datorn", value: pcState)
                LabeledContent("Senaste försöket", value: attemptText)
                if let failure = backup.lastAttempt?.failure {
                    Text(MioBackupError.described(code: failure)).font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    Task {
                        message = nil
                        let attempt = await backup.backUpNow()
                        message = attempt.succeeded ? "Kopian är sparad på datorn." : MioBackupError.described(code: attempt.failure)
                    }
                } label: {
                    if backup.isRunning { ProgressView("Skickar kopian …") } else { Label("Säkerhetskopiera nu", systemImage: "arrow.up.doc") }
                }
                .disabled(backup.isRunning || !MioCloudSettings.isPaired)
            } footer: {
                Text("Varje natt när telefonen laddas skickar Mio en kopia av dina data via Tailscale till datorn. Datorn krypterar den och sparar de 14 senaste. Inget skickas till molnet, och ljud finns aldrig i kopian.")
            }
            if pendingRestore {
                Section {
                    Text("Återställningen är klar att göras. Stäng Mio helt (svep upp från appväxlaren) och öppna appen igen, så ersätts dina data med kopian.")
                    Button("Avbryt återställningen", role: .destructive) {
                        try? MioBackupRestore.cancel(in: .standard)
                        pendingRestore = MioBackupRestore.hasPending(in: .standard)
                    }
                } header: { Text("Väntar på omstart") }
            }
            Section {
                if loading { ProgressView("Hämtar listan …") }
                ForEach(backups) { copy in
                    Button {
                        chosen = copy
                    } label: {
                        LabeledContent(copy.createdAt.formatted(date: .abbreviated, time: .shortened),
                                       value: Int64(copy.bytes).formatted(.byteCount(style: .file)))
                    }
                    .disabled(staging)
                }
                if !loading && backups.isEmpty && MioCloudSettings.isPaired {
                    Button("Visa kopiorna på datorn") { Task { await load() } }
                }
                if staging { ProgressView("Hämtar och kontrollerar kopian …") }
            } header: { Text("Återställ") } footer: {
                Text("Återställningen ersätter allt i Mio på telefonen med kopian. Påminnelser och Kalender ändras inte.")
            }
            if let message {
                Section { Text(message) }
            }
        }
        .mioListGround()
        .navigationTitle("Säkerhetskopia")
        .navigationBarTitleDisplayMode(.inline)
        .task { if MioCloudSettings.isPaired { await load() } }
        .confirmationDialog("Ersätta Mios data med kopian?", isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }),
                            titleVisibility: .visible, presenting: chosen) { copy in
            Button("Ersätt med kopian från \(copy.createdAt.formatted(date: .abbreviated, time: .shortened))", role: .destructive) {
                Task { await stage(copy) }
            }
            Button("Avbryt", role: .cancel) {}
        } message: { _ in
            Text("Allt som har tillkommit efter kopian försvinner från telefonen. Exportera först under Lagring om du vill behålla det.")
        }
    }

    private var pcState: String {
        guard MioCloudSettings.isPaired else { return "Inte parad" }
        guard let status = discovery.lastStatus else { return "Inte kontrollerat" }
        guard let state = status.backup else { return "Tar inte emot kopior" }
        guard let latest = state.latestAt else { return "Ingen kopia än" }
        return "\(state.count) kopior, senast \(latest.formatted(date: .abbreviated, time: .shortened))"
    }

    private var attemptText: String {
        guard let attempt = backup.lastAttempt else { return "Inget än" }
        let when = attempt.at.formatted(date: .abbreviated, time: .shortened)
        return attempt.succeeded ? "Klart \(when)" : "Misslyckades \(when)"
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { backups = try await backup.listBackups() }
        catch { message = (error as? MioBackupError)?.errorDescription ?? MioBackupError.network.errorDescription }
    }

    private func stage(_ copy: MioBackupSummary) async {
        staging = true
        defer { staging = false }
        do {
            _ = try await backup.stageRestore(id: copy.id)
            pendingRestore = true
            message = nil
        } catch {
            message = (error as? MioBackupError)?.errorDescription ?? MioBackupError.localData.errorDescription
        }
    }
}
