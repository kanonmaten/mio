import AVFoundation
import SwiftUI
import Vision
import VisionKit

/// Settings → Dator: one pairing for Pianissimo and the AI gateway on the user's PC.
struct MioComputerSection: View {
    let model: MioViewModel
    @State private var discovery = MioConnectionDiscovery.shared
    @State private var paired = MioCloudSettings.isPaired
    @State private var hostName = MioComputerSection.savedHost
    @State private var hasTranscription = !TranscriptionSettings.address.isEmpty
    @State private var showScanner = false
    @State private var showManual = false
    @State private var confirmForget = false
    @State private var checkTask: Task<Void, Never>?
    @State private var isChecking = false
    @State private var message: String?
    @State private var error: String?
    @AppStorage("mio.consent.recordingNoticeShown") private var consentShown = false

    private var canEdit: Bool { [.off, .paused, .failed, .unavailable].contains(model.runState) }
    private static var savedHost: String {
        URLComponents(string: MioCloudSettings.serverAddress)?.host ?? ""
    }

    var body: some View {
        Section {
            if paired && !consentShown {
                MioRecordingConsentNotice { consentShown = true }
            }
            if paired {
                LabeledContent("Dator", value: hostName)
                LabeledContent("Transkription", value: hasTranscription ? model.connectionState.title : "Inte parad än")
                LabeledContent("AI", value: aiState)
            } else {
                Text("Para Mio med din dator: kör mio-pair i datorns terminal och skanna QR-koden.")
            }
            scanButton
            Button("Ange uppgifterna manuellt", systemImage: "keyboard") { showManual = true }
                .disabled(!canEdit)
                .sheet(isPresented: $showManual) {
                    MioManualPairingView { payload in
                        showManual = false
                        pair(payload)
                    }
                }
            if paired {
                Button {
                    check()
                } label: {
                    if isChecking { ProgressView("Kontrollerar datorn …") }
                    else { Label("Kontrollera anslutningen", systemImage: "network") }
                }
                .disabled(isChecking)
                .accessibilityIdentifier("mio.computer.check")
                NavigationLink("Transkription och Tailscale") { MioTranscriptionDetailsView(model: model) }
                Button("Glöm datorn", role: .destructive) { confirmForget = true }
                    .disabled(!canEdit)
                    .confirmationDialog("Glömma datorn?", isPresented: $confirmForget, titleVisibility: .visible) {
                        Button("Glöm datorn", role: .destructive) { forget() }
                        Button("Avbryt", role: .cancel) {}
                    } message: {
                        Text("Adresser och tokens för transkription och AI tas bort från telefonen. Inget på datorn ändras.")
                    }
            }
            if !canEdit { Text("Pausa eller stoppa Mio innan du parar om eller glömmer datorn.").font(.footnote) }
            if let message { Label(message, systemImage: "checkmark.circle").foregroundStyle(.green) }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
        } header: {
            Text("Dator")
        } footer: {
            Text("Ljud går till Pianissimo och text till AI-gatewayen, båda på din dator via Tailscale. Kontrollen skickar inget ljud och använder ingen AI-kvot.")
        }
    }

    /// The one row that is always present carries the scanner sheet and the change observers.
    private var scanButton: some View {
        Button(paired ? "Para om med QR-kod" : "Skanna QR-kod", systemImage: "qrcode.viewfinder") {
            Task { await startScan() }
        }
        .disabled(!canEdit)
        .sheet(isPresented: $showScanner) {
            MioQRScannerSheet { text in
                showScanner = false
                do { pair(try MioPairingPayload.parse(text)) }
                catch { self.error = error.localizedDescription; message = nil }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MioCloudSettings.didResetNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: TranscriptionSettings.didChange)) { _ in refresh() }
        .onDisappear { checkTask?.cancel() }
    }

    private var aiState: String {
        if discovery.isChecking { return "Kontrolleras …" }
        if let status = discovery.lastStatus { return "Svarar · gateway \(status.release)" }
        if discovery.errorMessage != nil { return "Svarar inte" }
        return "Inte kontrollerad"
    }

    private func refresh() {
        paired = MioCloudSettings.isPaired
        hostName = Self.savedHost
        hasTranscription = !TranscriptionSettings.address.isEmpty
    }

    private func startScan() async {
        error = nil; message = nil
        guard DataScannerViewController.isSupported else {
            error = "Den här iPhonen kan inte skanna koden. Ange uppgifterna manuellt."
            return
        }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        if DataScannerViewController.isAvailable {
            showScanner = true
        } else {
            error = "Mio får inte använda kameran. Tillåt kameran i iPhones inställningar eller ange uppgifterna manuellt."
        }
    }

    private func pair(_ payload: MioPairingPayload) {
        do {
            try MioCloudSettings.savePairing(payload)
            refresh()
            message = payload.transcriptionOrigin == nil
                ? "Parad med \(payload.hostName). Pianissimo saknas i koden; transkriptionen paras när den finns på datorn."
                : "Parad med \(payload.hostName)."
            error = nil
            MioFeedback.success()
            check()
        } catch {
            self.error = error.localizedDescription
            message = nil
        }
    }

    /// Model-free checks only: Pianissimo's health and the gateway's protected status.
    private func check() {
        checkTask?.cancel()
        isChecking = true
        checkTask = Task {
            defer { isChecking = false }
            var problems: [String] = []
            do {
                _ = try await discovery.inspect(connection: try MioCloudSettings.connection(), forceRefresh: true)
            } catch is CancellationError { return }
            catch { problems.append("AI: \(error.localizedDescription)") }
            if !TranscriptionSettings.address.isEmpty {
                do { try await model.testTranscriptionConnection() }
                catch is CancellationError { return }
                catch { problems.append("Transkription: \(error.localizedDescription)") }
            }
            guard !Task.isCancelled else { return }
            if problems.isEmpty {
                if message == nil { message = "Datorn svarar. Ingen AI-kvot användes." }
                error = nil
            } else {
                error = problems.joined(separator: "\n")
            }
        }
    }

    private func forget() {
        checkTask?.cancel()
        var failures: [String] = []
        do { try MioCloudSettings.reset() } catch { failures.append(error.localizedDescription) }
        do { try TranscriptionSettings.reset() } catch { failures.append(error.localizedDescription) }
        refresh()
        message = failures.isEmpty ? "Datorn är glömd på telefonen." : nil
        error = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }
}

/// Pianissimo details that used to live under Transkription; the address and token now come from pairing.
struct MioTranscriptionDetailsView: View {
    let model: MioViewModel
    var body: some View {
        Form {
            Section("Pianissimo") {
                LabeledContent("Adress", value: TranscriptionSettings.address.isEmpty ? "Inte parad" : TranscriptionSettings.address)
                LabeledContent("Server", value: model.connectionState.title)
                if let date = model.connectionCheckedAt { LabeledContent("Senast verifierad", value: date.formatted()) }
                if let version = model.serverVersion { LabeledContent("Serverversion", value: version) }
                if let metadata = model.serverMetadata {
                    LabeledContent("Modell", value: metadata.model)
                    LabeledContent("Revision", value: metadata.revision)
                    LabeledContent("Motor", value: metadata.backend)
                }
            }
            Section("Tailscale och integritet") {
                Text("Anslut iPhone till samma tailnet som datorn. Aktivera VPN On Demand i Tailscale för Wi-Fi och mobilnät. Mio kontrollerar serverns nåbarhet; det kan inte läsa Tailscales interna VPN-status.")
                Text("Starta Mio eller Starta lektion godkänner ljudöverföring till datorn tills du pausar eller stoppar. Ingen ljudfil sparas. Bara de senaste 60 sekunderna kan räddas vid ett längre avbrott.")
                Text("Efter SideStore-förnyelse med LocalDevVPN: återanslut Tailscale och kontrollera anslutningen under Dator.")
                Link("Tailscales guide för iPhone", destination: URL(string: "https://tailscale.com/docs/features/client/ios-vpn-on-demand")!)
            }
            .font(.footnote)
        }
        .navigationTitle("Transkription")
    }
}

/// Fallback when the camera cannot scan: the four values `mio-pair --text` prints.
struct MioManualPairingView: View {
    let onPair: (MioPairingPayload) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var aiURL = MioCloudSettings.serverAddress
    @State private var aiToken = ""
    @State private var transcriptionURL = TranscriptionSettings.address
    @State private var transcriptionToken = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://dator.tailnet.ts.net:8443", text: $aiURL)
                        .keyboardType(.URL).textContentType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("AI-adress")
                    SecureField("AI-token", text: $aiToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("AI-gateway") }
                Section {
                    TextField("https://dator.tailnet.ts.net", text: $transcriptionURL)
                        .keyboardType(.URL).textContentType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Transkriptionsadress")
                    SecureField("Transkriptionstoken", text: $transcriptionToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Transkription · valfri") } footer: {
                    Text("Kör mio-pair --text på datorn för att se värdena. Lämna transkriptionen tom om Pianissimo inte är installerat än. Stäng terminalen efteråt.")
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
            }
            .navigationTitle("Para manuellt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Para") {
                        do {
                            onPair(try MioPairingPayload.manual(aiURL: aiURL, aiToken: aiToken,
                                transcriptionURL: transcriptionURL, transcriptionToken: transcriptionToken))
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(aiURL.isEmpty || aiToken.isEmpty)
                }
            }
        }
        .onDisappear { aiToken = ""; transcriptionToken = "" }
    }
}

struct MioQRScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MioQRScannerView(onCode: onCode)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Skanna koden från mio-pair")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { dismiss() } } }
        }
    }
}

/// VisionKit's live scanner limited to QR codes. Mio reads only the first code and stops; the
/// camera image is never stored.
private struct MioQRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true,
                                                isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        // Scanning starts once the controller is on screen.
        Task { @MainActor in try? scanner.startScanning() }
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: (String) -> Void
        private var finished = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !finished else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item, let payload = barcode.payloadStringValue else { continue }
                finished = true
                dataScanner.stopScanning()
                onCode(payload)
                return
            }
        }
    }
}

/// Shown once after the first pairing (user decision 2026-10-11: AI is on by default).
private struct MioRecordingConsentNotice: View {
    let acknowledge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Innan du lyssnar", systemImage: "person.2.wave.2").font(.headline)
            Text("Spela bara in andra med deras samtycke och enligt lokala regler. Berätta att Mio lyssnar och pausa när någon inte vill vara med. På lektioner och arbetsplatser kan egna regler gälla.")
            Text("Ljudet går till din dator och sparas aldrig som fil. AI är på från början och kan pausas under AI. Förslag sparas först när du väljer Ja.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Jag förstår", action: acknowledge)
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
    }
}
